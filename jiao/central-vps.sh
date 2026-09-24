#!/bin/bash
set -e
BASE_DIR=/etc/central-vps
DATA_DIR=$BASE_DIR/data
VPS_FILE=$DATA_DIR/vps.json
PORT=18089
AGENT_URL="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/agent.sh"
mkdir -p "$DATA_DIR"
chmod 700 "$BASE_DIR" "$DATA_DIR"
[ -f "$VPS_FILE" ] || echo '{"vps":[]}' > "$VPS_FILE"
generate_token() {
tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}
server() {
python3 - "$VPS_FILE" "$PORT" <<'PY'
import json,sys
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
FILE=sys.argv[1]
PORT=int(sys.argv[2])
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
            d=json.load(open(FILE))
            item=None
            for x in d.get("vps",[]):
                if x.get("token")==token:
                    item=x
                    break
            if not item:
                self.send_json(403,{"ok":False,"error":"invalid token"})
                return
            item["online"]=True
            item["ipv4"]=data.get("ipv4","")
            item["ipv6"]=data.get("ipv6","")
            item["country"]=data.get("country","")
            item["hostname"]=data.get("hostname","")
            item["os"]=data.get("os","")
            item["arch"]=data.get("arch","")
            json.dump(d,open(FILE,"w"),ensure_ascii=False,indent=2)
            self.send_json(200,{"ok":True})
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
ExecStart=$0 --server
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now central-vps.service >/dev/null
}
add_vps() {
local name token
read -rp "请输入 VPS 名称: " name
[ -n "$name" ] || return
token=$(generate_token)
python3 - "$VPS_FILE" "$name" "$token" <<'PY'
import json,sys
p,name,token=sys.argv[1:]
d=json.load(open(p))
d["vps"]=[x for x in d["vps"] if x.get("name")!=name]
d["vps"].append({"name":name,"token":token,"online":False,"ipv4":"","ipv6":"","country":"","hostname":"","os":"","arch":""})
json.dump(d,open(p,"w"),ensure_ascii=False,indent=2)
PY
echo
echo "========================================"
echo "请在目标 VPS 执行："
echo "========================================"
echo
echo "curl -fsSL $AGENT_URL | bash -s -- \"$token\""
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
python3 - "$VPS_FILE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if not d["vps"]:
 print("暂无 VPS")
else:
 for i,x in enumerate(d["vps"],1):
  status="在线" if x.get("online") else "离线"
  print(f"{i}. {x['name']} | {x.get('country','')} | {x.get('ipv4','')} | {status}")
PY
echo
echo "1. 查看 VPS"
echo "2. 删除 VPS"
echo "0. 返回"
read -rp "请选择: " choice
case "$choice" in
1)
read -rp "输入 VPS 名称: " name
python3 - "$VPS_FILE" "$name" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d["vps"]:
 if x["name"]==sys.argv[2]:
  print()
  print("VPS名称   :",x.get("name",""))
  print("国家/地区 :",x.get("country",""))
  print("IPv4      :",x.get("ipv4",""))
  print("IPv6      :",x.get("ipv6",""))
  print("主机名    :",x.get("hostname",""))
  print("系统      :",x.get("os",""))
  print("架构      :",x.get("arch",""))
  print("状态      :","在线" if x.get("online") else "离线")
  break
else:
 print("不存在")
PY
read -rp "按 Enter 返回..." _
;;
2)
read -rp "输入 VPS 名称: " name
python3 - "$VPS_FILE" "$name" <<'PY'
import json,sys
p,name=sys.argv[1:]
d=json.load(open(p))
d["vps"]=[x for x in d["vps"] if x["name"]!=name]
json.dump(d,open(p,"w"),ensure_ascii=False,indent=2)
PY
;;
0) return ;;
esac
done
}
main() {
start_server
while true; do
clear
echo "================================"
echo "       中央 VPS 管理脚本"
echo "================================"
echo
echo "1. 添加 VPS"
echo "2. 管理 VPS"
echo "3. 安装 sing-box"
echo "4. 卸载 sing-box"
echo
echo "0. 退出"
echo
read -rp "请选择: " choice
case "$choice" in
1) add_vps ;;
2) manage_vps ;;
3) echo "暂未实现"; read -rp "按 Enter 返回..." _ ;;
4) echo "暂未实现"; read -rp "按 Enter 返回..." _ ;;
0) exit 0 ;;
esac
done
}
case "${1:-}" in
--server) server ;;
*) main ;;
esac
