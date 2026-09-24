#!/bin/bash
set -e
BASE_DIR=/etc/central-vps
DATA_DIR=$BASE_DIR/data
VPS_FILE=$DATA_DIR/vps.json
LOCAL_SCRIPT=/usr/local/bin/central-vps.sh
SCRIPT_URL="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/central-vps.sh"
PORT=18089
AGENT_URL="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/agent.sh"
WG_INTERFACE=wg0
WG_PORT=51821
WG_NETWORK=10.88.0
WG_ADDRESS=10.88.0.1/24
WG_DIR=/etc/wireguard
WG_CONFIG=$WG_DIR/wg0.conf
WG_PRIVATE_KEY=$WG_DIR/privatekey
WG_PUBLIC_KEY=$WG_DIR/publickey
mkdir -p "$DATA_DIR"
chmod 700 "$BASE_DIR" "$DATA_DIR"
[ -f "$VPS_FILE" ] || echo '{"vps":[]}' > "$VPS_FILE"
get_ipv4() {
curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
}
get_ipv6() {
curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true
}
generate_token() {
tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}
install_wireguard() {
if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
return
fi
if command -v apt-get >/dev/null 2>&1; then
apt-get update -y >/dev/null 2>&1
apt-get install -y wireguard >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
dnf install -y wireguard-tools >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
yum install -y wireguard-tools >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
apk add wireguard-tools >/dev/null 2>&1
else
echo "无法安装 WireGuard"
exit 1
fi
}
init_wireguard() {
install_wireguard
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"
if [ ! -s "$WG_PRIVATE_KEY" ]; then
wg genkey > "$WG_PRIVATE_KEY"
chmod 600 "$WG_PRIVATE_KEY"
fi
if [ ! -s "$WG_PUBLIC_KEY" ]; then
cat "$WG_PRIVATE_KEY" | wg pubkey > "$WG_PUBLIC_KEY"
chmod 644 "$WG_PUBLIC_KEY"
fi
cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $WG_ADDRESS
ListenPort = $WG_PORT
PrivateKey = $(cat "$WG_PRIVATE_KEY")
EOF
python3 - "$VPS_FILE" "$WG_CONFIG" <<'PY'
import json,sys
vps_file,config_file=sys.argv[1:]
with open(vps_file) as f:
 d=json.load(f)
with open(config_file,"a") as f:
 for x in d.get("vps",[]):
  key=x.get("wg_public_key","")
  ip=x.get("wg_address","")
  if key and ip:
   f.write("\n[Peer]\n")
   f.write("PublicKey = "+key+"\n")
   f.write("AllowedIPs = "+ip.split("/")[0]+"/32\n")
PY
chmod 600 "$WG_CONFIG"
systemctl enable wg-quick@$WG_INTERFACE >/dev/null 2>&1 || true
systemctl restart wg-quick@$WG_INTERFACE
}
allocate_wg_ip() {
python3 - "$VPS_FILE" <<'PY'
import json,sys
p=sys.argv[1]
with open(p) as f:
 d=json.load(f)
used=set()
for x in d.get("vps",[]):
 a=x.get("wg_address","")
 if a:
  try:
   used.add(int(a.split(".")[-1].split("/")[0]))
  except:
   pass
for i in range(2,255):
 if i not in used:
  print(f"10.88.0.{i}")
  break
PY
}
rebuild_wg_config() {
cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $WG_ADDRESS
ListenPort = $WG_PORT
PrivateKey = $(cat "$WG_PRIVATE_KEY")
EOF
python3 - "$VPS_FILE" "$WG_CONFIG" <<'PY'
import json,sys
vps_file,config_file=sys.argv[1:]
with open(vps_file) as f:
 d=json.load(f)
with open(config_file,"a") as f:
 for x in d.get("vps",[]):
  key=x.get("wg_public_key","")
  ip=x.get("wg_address","")
  if key and ip:
   f.write("\n[Peer]\n")
   f.write("PublicKey = "+key+"\n")
   f.write("AllowedIPs = "+ip.split("/")[0]+"/32\n")
PY
chmod 600 "$WG_CONFIG"
systemctl restart wg-quick@$WG_INTERFACE
}
server() {
init_wireguard
python3 - "$VPS_FILE" "$PORT" "$WG_PUBLIC_KEY" "$WG_PORT" "$WG_INTERFACE" <<'PY'
import json,sys,threading
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
FILE=sys.argv[1]
PORT=int(sys.argv[2])
WG_PUBLIC_FILE=sys.argv[3]
WG_PORT=int(sys.argv[4])
WG_INTERFACE=sys.argv[5]
LOCK=threading.Lock()
def load():
 with open(FILE) as f:
  return json.load(f)
def save(d):
 tmp=FILE+".tmp"
 with open(tmp,"w") as f:
  json.dump(d,f,ensure_ascii=False,indent=2)
 import os
 os.replace(tmp,FILE)
def public_ip():
 import subprocess
 try:
  return subprocess.check_output(["curl","-4","-fsS","--max-time","5","https://api.ipify.org"],text=True).strip()
 except:
  return ""
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):
  pass
 def send_json(self,code,data):
  raw=json.dumps(data,ensure_ascii=False).encode()
  self.send_response(code)
  self.send_header("Content-Type","application/json")
  self.send_header("Content-Length",str(len(raw)))
  self.end_headers()
  self.wfile.write(raw)
 def do_POST(self):
  if self.path!="/api/register":
   self.send_json(404,{"ok":False})
   return
  try:
   length=int(self.headers.get("Content-Length","0"))
   data=json.loads(self.rfile.read(length))
   token=data.get("token","")
   wg_key=data.get("wg_public_key","")
   if not token or not wg_key:
    self.send_json(400,{"ok":False,"error":"missing token or wg_public_key"})
    return
   with LOCK:
    d=load()
    item=None
    for x in d.get("vps",[]):
     if x.get("token")==token:
      item=x
      break
    if not item:
     self.send_json(403,{"ok":False,"error":"invalid token"})
     return
    if item.get("wg_public_key") and item.get("wg_public_key")!=wg_key:
     self.send_json(403,{"ok":False,"error":"wireguard key mismatch"})
     return
    if not item.get("wg_address"):
     used=set()
     for x in d.get("vps",[]):
      a=x.get("wg_address","")
      if a:
       try:
        used.add(int(a.split(".")[-1].split("/")[0]))
       except:
        pass
     address=""
     for i in range(2,255):
      if i not in used:
       address=f"10.88.0.{i}"
       break
     if not address:
      self.send_json(500,{"ok":False,"error":"no wg address available"})
      return
     item["wg_address"]=address
    item["wg_public_key"]=wg_key
    item["online"]=True
    item["ipv4"]=data.get("ipv4","")
    item["ipv6"]=data.get("ipv6","")
    item["country"]=data.get("country","")
    item["hostname"]=data.get("hostname","")
    item["os"]=data.get("os","")
    item["arch"]=data.get("arch","")
    save(d)
    import subprocess
    subprocess.run(["wg","set",WG_INTERFACE,"peer",wg_key,"allowed-ips",item["wg_address"]+"/32"],check=False)
    endpoint=public_ip()
    self.send_json(200,{
     "ok":True,
     "wg_address":item["wg_address"],
     "wg_server_public_key":open(WG_PUBLIC_FILE).read().strip(),
     "wg_endpoint":endpoint+":"+str(WG_PORT)
    })
  except Exception as e:
   self.send_json(500,{"ok":False,"error":str(e)})
server=ThreadingHTTPServer(("0.0.0.0",PORT),Handler)
server.serve_forever()
PY
}
start_server() {
cat > /etc/systemd/system/central-vps.service <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/bin/bash $LOCAL_SCRIPT --server
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now central-vps.service >/dev/null
}
add_vps() {
local name token central_ip
read -rp "请输入 VPS 名称: " name
[ -n "$name" ] || return
central_ip=$(get_ipv4)
if [ -z "$central_ip" ]; then
echo
echo "获取中央 VPS 公网 IP 失败"
read -rp "按 Enter 返回..." _
return
fi
token=$(generate_token)
python3 - "$VPS_FILE" "$name" "$token" <<'PY'
import json,sys
p,name,token=sys.argv[1:]
with open(p) as f:
 d=json.load(f)
d["vps"]=[x for x in d["vps"] if x.get("name")!=name]
d["vps"].append({
"name":name,
"token":token,
"online":False,
"ipv4":"",
"ipv6":"",
"country":"",
"hostname":"",
"os":"",
"arch":"",
"wg_address":"",
"wg_public_key":""
})
with open(p,"w") as f:
 json.dump(d,f,ensure_ascii=False,indent=2)
PY
init_wireguard
echo
echo "========================================"
echo "中央 VPS IPv4: $central_ip"
echo "========================================"
echo "请在目标 VPS 执行："
echo
printf 'curl -fsSL %s | bash -s -- "%s" "%s"\n' "$AGENT_URL" "$central_ip" "$token"
echo
echo "========================================"
echo
read -rp "按 Enter 返回..." _
}
manage_vps() {
while true; do
clear
echo "================================"
echo "             管理 VPS"
echo "================================"
echo
python3 - "$VPS_FILE" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
 d=json.load(f)
if not d["vps"]:
 print("暂无 VPS")
else:
 for i,x in enumerate(d["vps"],1):
  status="在线" if x.get("online") else "离线"
  print(f"{i}. {x.get('name','')} | {x.get('country','')} | {x.get('ipv4','')} | {status}")
PY
echo
echo "0. 返回"
echo
read -rp "请选择 VPS: " choice
[ "$choice" = "0" ] && return
selected=$(python3 - "$VPS_FILE" "$choice" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
 d=json.load(f)
try:
 i=int(sys.argv[2])-1
 if 0 <= i < len(d["vps"]):
  print(json.dumps(d["vps"][i],ensure_ascii=False))
except:
 pass
PY
)
[ -n "$selected" ] || continue
while true; do
clear
echo "================================"
echo "             VPS 管理"
echo "================================"
echo
python3 - "$selected" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
print("名称     :",x.get("name",""))
print("国家/地区 :",x.get("country",""))
print("IPv4     :",x.get("ipv4",""))
print("IPv6     :",x.get("ipv6",""))
print("主机名   :",x.get("hostname",""))
print("系统     :",x.get("os",""))
print("架构     :",x.get("arch",""))
print("WG 地址  :",x.get("wg_address",""))
print("状态     :","在线" if x.get("online") else "离线")
PY
echo
echo "--------------------------------"
echo "1. 重启 VPS"
echo "2. 删除 VPS"
echo "0. 返回"
echo
read -rp "请选择: " action
case "$action" in
1)
wg_ip=$(python3 - "$selected" <<'PY'
import json,sys
print(json.loads(sys.argv[1]).get("wg_address",""))
PY
)
if [ -z "$wg_ip" ]; then
echo
echo "该 VPS 尚未建立 WG 通信"
read -rp "按 Enter 返回..." _
continue
fi
echo
echo "WG 地址: $wg_ip"
echo "当前正在建立命令控制通道，重启功能下一步接入"
read -rp "按 Enter 返回..." _
;;
2)
name=$(python3 - "$selected" <<'PY'
import json,sys
print(json.loads(sys.argv[1]).get("name",""))
PY
)
echo
read -rp "确认删除 VPS [$name]？输入 yes: " confirm
if [ "$confirm" = "yes" ]; then
python3 - "$VPS_FILE" "$name" <<'PY'
import json,sys
p,name=sys.argv[1:]
with open(p) as f:
 d=json.load(f)
d["vps"]=[x for x in d["vps"] if x.get("name")!=name]
with open(p,"w") as f:
 json.dump(d,f,ensure_ascii=False,indent=2)
PY
rebuild_wg_config
echo
echo "VPS 已删除"
sleep 1
break
fi
;;
0) break ;;
esac
done
done
}
delete_script() {
echo
echo "================================"
echo "             删除管理脚本"
echo "================================"
echo
echo "将停止并删除中央 VPS 管理系统的全部内容。"
echo
echo "不会卸载 WireGuard 软件包。"
echo
read -rp "确认彻底删除？输入 yes: " confirm
[ "$confirm" = "yes" ] || return

echo
echo "正在停止所有相关服务..."

# 停止中央 VPS 服务
systemctl disable --now central-vps.service >/dev/null 2>&1 || true

# 停止所有 wg-quick 实例
systemctl disable --now wg-quick@wg0.service >/dev/null 2>&1 || true
systemctl disable --now wg-quick@central0.service >/dev/null 2>&1 || true

# 停止可能存在的其他 WireGuard wg-quick 服务
while read -r service; do
    [ -n "$service" ] || continue
    systemctl disable --now "$service" >/dev/null 2>&1 || true
done < <(
    systemctl list-units --all --type=service --no-legend 2>/dev/null |
    awk '{print $1}' |
    grep '^wg-quick@.*\.service$' || true
)

echo "正在停止残留进程..."

# 停止 central-vps 相关进程
pkill -f '/usr/local/bin/central-vps.sh' >/dev/null 2>&1 || true
pkill -f 'central-vps.sh --server' >/dev/null 2>&1 || true

# 停止所有 wg-quick 相关进程
pkill -f 'wg-quick.*wg0' >/dev/null 2>&1 || true
pkill -f 'wg-quick.*central0' >/dev/null 2>&1 || true

echo "正在删除所有 WireGuard 接口..."

# 删除所有 WireGuard 接口
while read -r interface; do
    [ -n "$interface" ] || continue
    ip link del "$interface" >/dev/null 2>&1 || true
done < <(
    wg show interfaces 2>/dev/null || true
)

echo "正在删除 systemd 服务..."

# 删除中央 VPS 服务
rm -f /etc/systemd/system/central-vps.service

# 删除所有 wg-quick@*.service 的自定义残留链接
rm -f /etc/systemd/system/wg-quick@wg0.service
rm -f /etc/systemd/system/wg-quick@central0.service

systemctl daemon-reload

# 清除失败状态
systemctl reset-failed central-vps.service >/dev/null 2>&1 || true
systemctl reset-failed wg-quick@wg0.service >/dev/null 2>&1 || true
systemctl reset-failed wg-quick@central0.service >/dev/null 2>&1 || true

echo "正在删除中央 VPS 管理文件..."

# 删除本地管理脚本
rm -f /usr/local/bin/central-vps.sh

# 删除中央 VPS 全部数据
rm -rf /etc/central-vps

echo "正在删除 WireGuard 全部配置..."

# 删除 WireGuard 配置和密钥
rm -rf /etc/wireguard

echo "正在清理 systemd..."

systemctl daemon-reload

echo
echo "========================================"
echo "       中央 VPS 管理系统已彻底删除"
echo "========================================"
echo
echo "已停止："
echo "  ✓ central-vps.service"
echo "  ✓ 所有 wg-quick 服务"
echo "  ✓ central-vps 相关进程"
echo "  ✓ wg-quick 相关进程"
echo
echo "已删除："
echo "  ✓ /usr/local/bin/central-vps.sh"
echo "  ✓ /etc/central-vps"
echo "  ✓ /etc/systemd/system/central-vps.service"
echo "  ✓ /etc/wireguard"
echo "  ✓ 所有 WireGuard 接口"
echo "  ✓ 所有 WireGuard 配置和密钥"
echo
echo "WireGuard 软件包未卸载。"
echo
exit 0

}
main() {
mkdir -p "$(dirname "$LOCAL_SCRIPT")"
curl -fsSL "$SCRIPT_URL" -o "$LOCAL_SCRIPT"
chmod 700 "$LOCAL_SCRIPT"
exec /bin/bash "$LOCAL_SCRIPT" --menu
}
case "${1:-}" in
--server)
server
;;
--menu)
while true; do
clear
echo "================================"
echo "       中央 VPS 管理脚本 1 "
echo "================================"
echo
echo "1. 添加 VPS"
echo "2. 管理 VPS"
echo "3. 安装 sing-box"
echo "4. 卸载 sing-box"
echo "5. 删除管理脚本"
echo
echo "0. 退出"
echo
read -rp "请选择: " choice
case "$choice" in
1) add_vps ;;
2) manage_vps ;;
3) echo "暂未实现"; read -rp "按 Enter 返回..." _ ;;
4) echo "暂未实现"; read -rp "按 Enter 返回..." _ ;;
5) delete_script ;;
0) exit 0 ;;
esac
done
;;
*)
main
;;
esac
