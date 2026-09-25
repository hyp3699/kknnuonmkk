#!/bin/bash
set -e
export LANG=en_US.UTF-8
re="\033[0m"
red="\e[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
BASE_DIR=/etc/central-vps
DATA_DIR=$BASE_DIR/data
VPS_FILE=$DATA_DIR/vps.json
LOCAL_SCRIPT=/usr/local/bin/central-vps.sh
SCRIPT_URL="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/central-vps.sh"
PORT=18089
AGENT_URL="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/agent.sh"
WG_INTERFACE=central-mgmt
WG_PORT=51821
WG_NETWORK=10.231.47
WG_ADDRESS=10.231.47.1/24
WG_DIR=/etc/wireguard
WG_CONFIG=$WG_DIR/central-mgmt.conf
WG_PRIVATE_KEY=$WG_DIR/central-mgmt-privatekey
WG_PUBLIC_KEY=$WG_DIR/central-mgmt-publickey
mkdir -p "$BASE_DIR" "$DATA_DIR"
chmod 700 "$BASE_DIR" "$DATA_DIR"
[ -f "$VPS_FILE" ] || echo '{"vps":[]}' > "$VPS_FILE"
chmod 600 "$VPS_FILE"
get_ipv4() {
    curl -4 -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true
}
get_ipv6() {
    curl -6 -fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null || true
}
generate_token() {
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
}
install_wireguard() {
    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        return 0
    fi
    green "正在安装 WireGuard..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y wireguard-tools
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wireguard-tools
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wireguard-tools
    elif command -v apk >/dev/null 2>&1; then
        apk add wireguard-tools
    else
        red "无法自动安装 WireGuard"
        exit 1
    fi
    if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
        red "WireGuard 安装失败"
        exit 1
    fi
}
write_wg_config() {
    cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $WG_ADDRESS
ListenPort = $WG_PORT
PrivateKey = $(cat "$WG_PRIVATE_KEY")
EOF
    python3 - "$VPS_FILE" "$WG_CONFIG" <<'PY'
import json
import sys
vps_file,config_file=sys.argv[1:]
with open(vps_file,encoding="utf-8") as f:
    data=json.load(f)
with open(config_file,"a",encoding="utf-8") as f:
    for item in data.get("vps",[]):
        key=item.get("wg_public_key","")
        ip=item.get("wg_address","")
        if key and ip:
            f.write("\n[Peer]\n")
            f.write("PublicKey = "+key+"\n")
            f.write("AllowedIPs = "+ip.split("/")[0]+"/32\n")
PY
    chmod 600 "$WG_CONFIG"
}
apply_wg_config() {
    systemctl enable "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    else
        systemctl start "wg-quick@$WG_INTERFACE.service"
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
        wg pubkey < "$WG_PRIVATE_KEY" > "$WG_PUBLIC_KEY"
        chmod 644 "$WG_PUBLIC_KEY"
    fi
    write_wg_config
    apply_wg_config
}
allocate_wg_ip() {
    python3 - "$VPS_FILE" "$WG_NETWORK" <<'PY'
import json
import sys
p,network=sys.argv[1:]
with open(p,encoding="utf-8") as f:
    data=json.load(f)
used=set()
for item in data.get("vps",[]):
    address=item.get("wg_address","")
    if address:
        try:
            used.add(int(address.split(".")[-1].split("/")[0]))
        except Exception:
            pass
for i in range(2,255):
    if i not in used:
        print(f"{network}.{i}")
        break
PY
}
rebuild_wg_config() {
    write_wg_config
    apply_wg_config
}
persist_peer() {
    local public_key="$1"
    local wg_address="$2"
    python3 - "$WG_CONFIG" "$public_key" "$wg_address" <<'PY'
import os
import sys
config,public_key,address=sys.argv[1:]
try:
    with open(config,"r",encoding="utf-8") as f:
        text=f.read()
except Exception:
    sys.exit(1)
target=address.split("/")[0]+"/32"
blocks=text.split("\n[Peer]")
found=False
new_blocks=[]
for i,block in enumerate(blocks):
    if i==0:
        new_blocks.append(block)
        continue
    full="[Peer]"+block
    lines=full.splitlines()
    key=""
    for line in lines:
        if line.strip().startswith("PublicKey"):
            key=line.split("=",1)[1].strip()
            break
    if key==public_key:
        found=True
        replaced=[]
        has_allowed=False
        for line in lines:
            if line.strip().startswith("AllowedIPs"):
                replaced.append("AllowedIPs = "+target)
                has_allowed=True
            else:
                replaced.append(line)
        if not has_allowed:
            replaced.append("AllowedIPs = "+target)
        full="\n".join(replaced)
    new_blocks.append(full)
if not found:
    new_blocks.append("[Peer]\nPublicKey = "+public_key+"\nAllowedIPs = "+target+"\n")
result="\n".join(new_blocks)
tmp=config+".tmp"
with open(tmp,"w",encoding="utf-8") as f:
    f.write(result.rstrip()+"\n")
    f.flush()
    os.fsync(f.fileno())
os.chmod(tmp,0o600)
os.replace(tmp,config)
PY
}

server() {
    exec 9>/run/central-vps-server.lock
    if ! flock -n 9; then
        red "central-vps API 已经在运行"
        exit 0
    fi
    python3 - "$VPS_FILE" "$PORT" "$WG_PUBLIC_KEY" "$WG_PORT" "$WG_INTERFACE" "$WG_NETWORK" "$WG_CONFIG" <<'PY'
import json
import os
import sys
import subprocess
from http.server import HTTPServer,BaseHTTPRequestHandler
FILE=sys.argv[1]
PORT=int(sys.argv[2])
WG_PUBLIC_FILE=sys.argv[3]
WG_PORT=int(sys.argv[4])
WG_INTERFACE=sys.argv[5]
WG_NETWORK=sys.argv[6]
WG_CONFIG=sys.argv[7]
def load():
    with open(FILE,"r",encoding="utf-8") as f:
        return json.load(f)
def save(data):
    tmp=FILE+".tmp"
    with open(tmp,"w",encoding="utf-8") as f:
        json.dump(data,f,ensure_ascii=False,indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp,0o600)
    os.replace(tmp,FILE)
def public_ip():
    try:
        return subprocess.check_output(["curl","-4","-fsS","--max-time","5","https://api.ipify.org"],text=True).strip()
    except Exception:
        return ""
def persist_peer(public_key,wg_address):
    try:
        with open(WG_CONFIG,"r",encoding="utf-8") as f:
            text=f.read()
    except Exception:
        return False
    target=wg_address.split("/")[0]+"/32"
    blocks=text.split("\n[Peer]")
    found=False
    result=[blocks[0]]
    for block in blocks[1:]:
        full="[Peer]"+block
        lines=full.splitlines()
        key=""
        for line in lines:
            if line.strip().startswith("PublicKey"):
                key=line.split("=",1)[1].strip()
                break
        if key==public_key:
            found=True
            new_lines=[]
            replaced=False
            for line in lines:
                if line.strip().startswith("AllowedIPs"):
                    new_lines.append("AllowedIPs = "+target)
                    replaced=True
                else:
                    new_lines.append(line)
            if not replaced:
                new_lines.append("AllowedIPs = "+target)
            full="\n".join(new_lines)
        result.append(full)
    if not found:
        result.append("[Peer]\nPublicKey = "+public_key+"\nAllowedIPs = "+target+"\n")
    tmp=WG_CONFIG+".tmp"
    with open(tmp,"w",encoding="utf-8") as f:
        f.write("\n".join(result).rstrip()+"\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp,0o600)
    os.replace(tmp,WG_CONFIG)
    return True
def save_traffic_report(source_address,traffic_data):
    if not isinstance(traffic_data,dict):
        return False,"invalid traffic data"
    db=load()
    vps_item=None
    for x in db.get("vps",[]):
        address=x.get("wg_address","")
        if address:
            address=address.split("/")[0]
        if address==source_address:
            vps_item=x
            break
    if vps_item is None:
        return False,"unknown vps"
    vps_name=vps_item.get("name","")
    if not vps_name:
        return False,"vps name missing"
    users_dir=os.path.join(os.path.dirname(FILE),"users")
    os.makedirs(users_dir,mode=0o700,exist_ok=True)
    for username,data in traffic_data.items():
        if not isinstance(username,str) or not username:
            continue
        if not isinstance(data,dict):
            continue
        user_dir=os.path.join(users_dir,username)
        if not os.path.isdir(user_dir):
            continue
        username_file=os.path.join(user_dir,"username")
        uuid_file=os.path.join(user_dir,"uuid")
        if not os.path.isfile(username_file):
            continue
        if not os.path.isfile(uuid_file):
            continue
        traffic_file=os.path.join(user_dir,"traffic.json")
        try:
            if os.path.isfile(traffic_file):
                with open(traffic_file,"r",encoding="utf-8") as f:
                    traffic=json.load(f)
            else:
                traffic={}
        except Exception:
            traffic={}
        if not isinstance(traffic,dict):
            traffic={}
        traffic.setdefault("vps",{})
        traffic["vps"][vps_name]={
            "wg_address":source_address,
            "upload":int(data.get("upload",0) or 0),
            "download":int(data.get("download",0) or 0),
            "total":int(data.get("total",0) or 0),
            "period_upload":int(data.get("period_upload",0) or 0),
            "period_download":int(data.get("period_download",0) or 0),
            "period_total":int(data.get("period_total",0) or 0)
        }
        total_upload=0
        total_download=0
        total=0
        period_upload=0
        period_download=0
        period_total=0
        for vps_data in traffic["vps"].values():
            if not isinstance(vps_data,dict):
                continue
            total_upload+=int(vps_data.get("upload",0) or 0)
            total_download+=int(vps_data.get("download",0) or 0)
            total+=int(vps_data.get("total",0) or 0)
            period_upload+=int(vps_data.get("period_upload",0) or 0)
            period_download+=int(vps_data.get("period_download",0) or 0)
            period_total+=int(vps_data.get("period_total",0) or 0)
        traffic["upload"]=total_upload
        traffic["download"]=total_download
        traffic["total"]=total
        traffic["period_upload"]=period_upload
        traffic["period_download"]=period_download
        traffic["period_total"]=period_total
        tmp=traffic_file+".tmp"
        with open(tmp,"w",encoding="utf-8") as f:
            json.dump(traffic,f,ensure_ascii=False,indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp,0o600)
        os.replace(tmp,traffic_file)
    return True,"ok"
class Handler(BaseHTTPRequestHandler):
    def log_message(self,format,*args):
        pass
    def send_json(self,code,data):
        raw=json.dumps(data,ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length",str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def do_POST(self):
        if self.path=="/api/traffic/report":
            try:
                length=int(self.headers.get("Content-Length","0"))
                if length<=0 or length>1048576:
                    self.send_json(400,{"ok":False,"error":"invalid request size"})
                    return
                data=json.loads(self.rfile.read(length))
                if not isinstance(data,dict):
                    self.send_json(400,{"ok":False,"error":"invalid json"})
                    return
                users=data.get("users",{})
                if not isinstance(users,dict):
                    self.send_json(400,{"ok":False,"error":"invalid users"})
                    return
                source_address=self.client_address[0]
                ok,message=save_traffic_report(source_address,users)
                if not ok:
                    self.send_json(403,{"ok":False,"error":message})
                    return
                self.send_json(200,{"ok":True})
            except Exception as e:
                self.send_json(500,{"ok":False,"error":str(e)})
            return
        if self.path!="/api/register":
            self.send_json(404,{"ok":False,"error":"not found"})
            return
        try:
            length=int(self.headers.get("Content-Length","0"))
            if length<=0 or length>10240:
                self.send_json(400,{"ok":False,"error":"invalid request size"})
                return
            data=json.loads(self.rfile.read(length))
            token=data.get("token","")
            wg_key=data.get("wg_public_key","")
            agent_token=data.get("agent_token","")
            if not token or not wg_key:
                self.send_json(400,{"ok":False,"error":"missing token or wg_public_key"})
                return
            db=load()
            item=None
            for x in db.get("vps",[]):
                if x.get("token")==token:
                    item=x
                    break
            if item is None:
                self.send_json(403,{"ok":False,"error":"invalid token"})
                return
            old_key=item.get("wg_public_key","")
            if old_key and old_key!=wg_key:
                self.send_json(403,{"ok":False,"error":"wireguard key mismatch"})
                return
            if not item.get("wg_address"):
                used=set()
                for x in db.get("vps",[]):
                    address=x.get("wg_address","")
                    if address:
                        try:
                            used.add(int(address.split(".")[-1].split("/")[0]))
                        except Exception:
                            pass
                address=""
                for i in range(2,255):
                    if i not in used:
                        address=f"{WG_NETWORK}.{i}"
                        break
                if not address:
                    self.send_json(500,{"ok":False,"error":"no wg address available"})
                    return
                item["wg_address"]=address
            item["wg_public_key"]=wg_key
            item["agent_token"]=agent_token
            item["online"]=True
            item["ipv4"]=data.get("ipv4","")
            item["ipv6"]=data.get("ipv6","")
            item["country"]=data.get("country","")
            item["hostname"]=data.get("hostname","")
            item["os"]=data.get("os","")
            item["arch"]=data.get("arch","")
            save(db)
            subprocess.run(["wg","set",WG_INTERFACE,"peer",wg_key,"allowed-ips",item["wg_address"]+"/32"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
            persist_peer(wg_key,item["wg_address"])
            endpoint=public_ip()
            if not endpoint:
                self.send_json(500,{"ok":False,"error":"failed to get central public IPv4"})
                return
            try:
                with open(WG_PUBLIC_FILE,"r",encoding="utf-8") as f:
                    server_key=f.read().strip()
            except Exception:
                self.send_json(500,{"ok":False,"error":"failed to read server public key"})
                return
            self.send_json(200,{"ok":True,"wg_address":item["wg_address"],"wg_server_public_key":server_key,"wg_endpoint":endpoint+":"+str(WG_PORT)})
        except Exception as e:
            self.send_json(500,{"ok":False,"error":str(e)})
server=HTTPServer(("0.0.0.0",PORT),Handler)
server.serve_forever()
PY
}
    

        
start_server() {
    cat > /etc/systemd/system/central-vps.service <<EOF
[Unit]
Description=Central VPS Management API
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/bin/bash $LOCAL_SCRIPT --server
Restart=on-failure
RestartSec=5
KillMode=control-group
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable central-vps.service >/dev/null 2>&1 || true
    systemctl restart central-vps.service
}


get_vps_count() {
    python3 - "$VPS_FILE" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data=json.load(f)
    print(len(data.get("vps", [])))
except Exception:
    print(0)
PY
}
get_vps_field() {
    local index="$1"
    local field="$2"
    python3 - "$VPS_FILE" "$index" "$field" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data=json.load(f)
    vps=data.get("vps", [])
    index=int(sys.argv[2])
    field=sys.argv[3]
    if 0 <= index < len(vps):
        value=vps[index].get(field, "")
        if value is None:
            value=""
        print(value)
except Exception:
    pass
PY
}




add_vps() {
    local name
    local token
    local central_ip
    read -rp "请输入 VPS 名称: " name
    [ -n "$name" ] || return
    if python3 - "$VPS_FILE" "$name" <<'PY'
import json
import sys
with open(sys.argv[1],encoding="utf-8") as f:
    data=json.load(f)
for x in data.get("vps",[]):
    if x.get("name")==sys.argv[2]:
        sys.exit(0)
sys.exit(1)
PY
    then
        yellow "VPS 名称已存在"
        read -rp "按 Enter 返回..." _
        return
    fi
    central_ip=$(get_ipv4)
    if [ -z "$central_ip" ]; then
        red "获取中央 VPS 公网 IP 失败"
        read -rp "按 Enter 返回..." _
        return
    fi
    token=$(generate_token)
    python3 - "$VPS_FILE" "$name" "$token" <<'PY'
import json
import sys
p,name,token=sys.argv[1:]
with open(p,encoding="utf-8") as f:
    data=json.load(f)
data["vps"].append({"name":name,"token":token,"agent_token":"","online":False,"ipv4":"","ipv6":"","country":"","hostname":"","os":"","arch":"","wg_address":"","wg_public_key":""})
with open(p,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY
    chmod 600 "$VPS_FILE"
    init_wireguard
    echo
    green "========================================"
    green "中央 VPS IPv4: $central_ip"
    green "========================================"
    green "请在目标 VPS 执行："
    echo
    echo -e "\033[33mcurl -fsSL $AGENT_URL | bash -s -- \"$central_ip\" \"$token\"\033[0m"
    echo
    green "========================================"
    read -rp "按 Enter 返回..." _
}
set_vps_offline() {
    local name="$1"
    python3 - "$VPS_FILE" "$name" <<'PY'
import json
import sys
p,name=sys.argv[1:]
with open(p,encoding="utf-8") as f:
    data=json.load(f)
for x in data.get("vps",[]):
    if x.get("name")==name:
        x["online"]=False
with open(p,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY
    chmod 600 "$VPS_FILE"
}
agent_request() {
    local address="$1"
    local token="$2"
    local method="$3"
    local path="$4"
    local command="${5:-}"
    local url="http://${address}:18090${path}"
    if [ "$method" = "GET" ]; then
        curl -sS --connect-timeout 3 --max-time 10 -H "Authorization: Bearer ${token}" "$url"
    else
        python3 - "$command" "$token" "$url" <<'PY'
import json
import sys
import urllib.request
import urllib.error
command=sys.argv[1]
token=sys.argv[2]
url=sys.argv[3]
payload=json.dumps({"command":command},ensure_ascii=False).encode("utf-8")
req=urllib.request.Request(url,data=payload,method="POST",headers={"Authorization":f"Bearer {token}","Content-Type":"application/json"})
try:
    with urllib.request.urlopen(req,timeout=35) as response:
        print(response.read().decode("utf-8"))
except urllib.error.HTTPError as e:
    body=e.read().decode("utf-8",errors="replace")
    print(json.dumps({"ok":False,"error":f"HTTP {e.code}","detail":body},ensure_ascii=False))
except Exception as e:
    print(json.dumps({"ok":False,"error":str(e)},ensure_ascii=False))
PY
    fi
}
check_agent() {
    local address="$1"
    local token="$2"
    local result
    result=$(agent_request "$address" "$token" GET "/api/info") || return 1
    python3 - "$result" <<'PY'
import json
import sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("ok") else 1)
PY
}
show_vps_detail() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" 'echo "===== 系统信息 =====";echo "主机名: $(hostname 2>/dev/null)";echo "系统: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)";echo "内核: $(uname -r 2>/dev/null)";echo "架构: $(uname -m 2>/dev/null)";echo "运行时间: $(uptime -p 2>/dev/null || uptime)";echo;echo "===== CPU =====";echo "CPU 核心: $(nproc 2>/dev/null || echo N/A)";echo "CPU 型号: $(lscpu 2>/dev/null | awk -F: "/Model name/ {gsub(/^[ \t]+/,"""",\$2);print \$2;exit}")";echo "CPU 负载: $(awk "{print \$1,\$2,\$3}" /proc/loadavg 2>/dev/null)";echo "CPU 使用率:";top -bn1 2>/dev/null | grep -E "Cpu\(s\)" | head -n 1 || true;echo;echo "===== 内存 =====";free -h 2>/dev/null || true;echo;echo "===== 磁盘 =====";df -hT 2>/dev/null || true;echo;echo "===== 网络接口 =====";ip -br addr 2>/dev/null || true;echo;echo "===== 路由 =====";ip route 2>/dev/null || true;echo;echo "===== DNS =====";if command -v resolvectl >/dev/null 2>&1;then resolvectl status 2>/dev/null | grep -E "DNS Servers|Current DNS Server" || true;else grep -v "^[[:space:]]*#" /etc/resolv.conf 2>/dev/null || true;fi;echo;echo "===== WireGuard =====";wg show central-mgmt 2>/dev/null || true') || {
        red "Agent 连接失败"
        return 1
    }
    python3 - "$name" "$address" "$result" <<'PY'
import json
import sys
name=sys.argv[1]
address=sys.argv[2]
result=sys.argv[3]
try:
    d=json.loads(result)
except Exception:
    red="Agent 返回数据格式错误"
    print(red)
    sys.exit(1)
if not d.get("ok"):
    print("执行失败："+str(d.get("error","未知错误")))
    if d.get("detail"):
        print(d["detail"],end="")
    if d.get("stderr"):
        print(d["stderr"],end="")
    sys.exit(1)
print("========================================")
print("              VPS 详细信息")
print("========================================")
print("VPS 名称 :",name)
print("WG 地址  :",address)
print("========================================")
print()
print(d.get("stdout",""),end="")
if d.get("stderr"):
    print()
    print("stderr:")
    print(d["stderr"],end="")
PY
}
execute_vps_command() {
    local name="$1"
    local address="$2"
    local token="$3"
    local command
    local result
    echo
    green "========================================"
    green "              执行 VPS 命令"
    green "========================================"
    echo
    green "VPS 名称 : $name"
    green "WG 地址  : $address"
    echo
    yellow "请输入要执行的 Linux 命令："
    echo
    read -r -p "> " command
    [ -n "$command" ] || return
    result=$(agent_request "$address" "$token" POST "/api/command" "$command") || {
        red "Agent 连接失败"
        return 1
    }
    echo
    python3 - "$result" <<'PY'
import json
import sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    print("Agent 返回数据格式错误")
    sys.exit(1)
print("========================================")
print("              执行结果")
print("========================================")
if not d.get("ok"):
    print("执行失败："+str(d.get("error","未知错误")))
    if d.get("stdout"):
        print(d["stdout"],end="")
    if d.get("stderr"):
        print(d["stderr"],end="")
    if d.get("detail"):
        print(d["detail"],end="")
    sys.exit(1)
if d.get("stdout"):
    print(d["stdout"],end="")
if d.get("stderr"):
    print()
    print("stderr:")
    print(d["stderr"],end="")
print()
print("返回码:",d.get("returncode",-1))
PY
}
restart_vps() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result
    local confirm
    echo
    green "========================================"
    green "              重启 VPS"
    green "========================================"
    echo
    green "VPS 名称 : $name"
    green "WG 地址  : $address"
    echo
    yellow "确定重启此 VPS？输入 yes 确认:"
    read -r confirm
    [ "$confirm" = "yes" ] || return
    result=$(agent_request "$address" "$token" POST "/api/command" 'nohup sh -c "sleep 2; /sbin/reboot" >/dev/null 2>&1 & echo "REBOOT_SCHEDULED"') || {
        red "Agent 连接失败"
        return 1
    }
    echo
    if python3 - "$result" <<'PY'
import json
import sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    print("Agent 返回数据格式错误")
    sys.exit(1)
if not d.get("ok"):
    print("重启失败："+str(d.get("error","未知错误")))
    if d.get("detail"):
        print(d["detail"],end="")
    sys.exit(1)
print(d.get("stdout",""),end="")
PY
    then
        echo
        green "VPS 重启已安排，约 2 秒后重启。"
    else
        red "重启命令执行失败"
    fi
    sleep 2
}

show_namess_url() {
    local username="$1"
    local user_dir="$DATA_DIR/users/$username"
    local nodes_dir="$user_dir/nodes"
    local node_file=""
    local node_name=""
    local found_any=false
    green "================ 用户节点 ================"
    echo
    green "用户：${username}"
    echo
    if [ ! -d "$nodes_dir" ]; then
        red "该用户没有节点目录"
        echo
        read -rp "按回车返回..." _
        return
    fi
    while IFS= read -r node_file; do
        [ -f "$node_file" ] || continue
        node_name=$(basename "$node_file")
        [ -n "$node_name" ] || continue
        found_any=true
        green "---------------- ${node_name} ----------------"
        if [ -s "$node_file" ]; then
            purple "$(cat "$node_file")"
        else
            yellow "该 VPS 暂无节点链接"
        fi
        echo
    done < <(find "$nodes_dir" -maxdepth 1 -type f -printf '%p\n' 2>/dev/null | sort)
    if [ "$found_any" = false ]; then
        red "该用户暂无 VPS 节点"
    fi
    echo
    read -rp "按回车返回..." _
}

format_bytes() {
    local bytes="${1:-0}"
    python3 - "$bytes" <<'PY'
import sys
try:
    value=float(sys.argv[1])
except Exception:
    value=0
units=["B","KB","MB","GB","TB","PB"]
i=0
while value >= 1024 and i < len(units)-1:
    value /= 1024
    i += 1
if i == 0:
    print(f"{int(value)} {units[i]}")
elif value >= 100:
    print(f"{value:.0f} {units[i]}")
elif value >= 10:
    print(f"{value:.1f} {units[i]}")
else:
    print(f"{value:.2f} {units[i]}")
PY
}

manage_single_vps() {
    local index="$1"
    local info name address token agent_token ipv4 action confirm
    
    # 性能优化：单次读取即可获取单一 VPS 的所有字段
    info=$(python3 - "$VPS_FILE" "$index" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        v = json.load(f).get("vps", [])[int(sys.argv[2])]
        print(f"{v.get('name', '')}\t{v.get('wg_address', '')}\t{v.get('token', '')}\t{v.get('agent_token', '')}\t{v.get('ipv4', '')}")
except Exception:
    pass
PY
    )
    IFS=$'\t' read -r name address token agent_token ipv4 <<< "$info"

    if [ -z "$name" ] || [ -z "$address" ]; then
        red "VPS 数据不完整"
        sleep 1
        return
    fi
    if [ -z "$agent_token" ]; then
        echo
        red "此 VPS 尚未保存 Agent Token"
        yellow "请重新运行 Agent 注册脚本"
        echo
        read -rp "按 Enter 返回..." _
        return
    fi
    while true; do
        clear
        green "========================================"
        green "              VPS 管理"
        green "========================================"
        echo
        green "1. 查看 VPS 详细信息"
        green "2. 执行 VPS 命令"
        green "3. 重启 VPS"
        green "4. 删除 VPS"
        echo
        green "0. 返回"
        echo
        read -rp "请选择: " action
        case "$action" in
            1)
                clear
                show_vps_detail "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            2)
                clear
                execute_vps_command "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            3)
                clear
                restart_vps "$name" "$address" "$agent_token"
                ;;
            4)
                clear
                red "========================================"
                red "              删除 VPS"
                red "========================================"
                echo
                red "VPS 名称: $name"
                red "公网 IP : $ipv4"
                echo
                yellow "确认删除此 VPS？输入 yes:"
                read -r confirm
                if [ "$confirm" = "yes" ]; then
                    delete_vps "$name"
                    rebuild_wg_config
                    echo
                    green "VPS 已删除"
                    sleep 1
                    return
                fi
                ;;
            0)
                return
                ;;
            *)
                red "无效选择"
                sleep 1
                ;;
        esac
    done
}
manage_vps() {
    while true; do
        clear
        green "========================================"
        green "              管理 VPS"
        green "========================================"
        echo
        
        # 性能优化：替代在 bash 循环中产生极高开销的多次 Python/磁盘 I/O 读写
        # 仅通过一次 Python 调用读取整个 VPS 列表并交给 Bash 处理
        local vps_list
        vps_list=$(python3 - "$VPS_FILE" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        vps = json.load(f).get("vps", [])
        if not vps:
            print("EMPTY")
        else:
            for i, v in enumerate(vps):
                name = v.get("name")
                ipv4 = v.get("ipv4")
                print(f"{i}\t{name if name else '-'}\t{ipv4 if ipv4 else '-'}")
except Exception:
    pass
PY
        )
        if [ -z "$vps_list" ] || [ "$vps_list" = "EMPTY" ]; then
            yellow "暂无 VPS"
            echo
            read -rp "按 Enter 返回..." _
            return
        fi

        green "编号  名称                    公网 IP"
        green "----------------------------------------------"
        
        local count=0
        while IFS=$'\t' read -r i name ipv4; do
            [ -z "$i" ] && continue
            count=$((count+1))
            green "$((i+1)).    $name                    $ipv4"
        done <<< "$vps_list"
        
        echo
        if [ "$count" -eq 1 ]; then
            green "1. 选择 VPS"
        else
            green "1～$count. 选择 VPS"
        fi
        green "0. 返回"
        echo
        read -rp "请选择 VPS: " choice
        [ "$choice" = "0" ] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            manage_single_vps "$((choice-1))"
        else
            red "无效选择"
            sleep 1
        fi
    done
}
delete_vps() {
    local name="$1"
    python3 - "$VPS_FILE" "$name" <<'PY'
import json
import sys
p,name=sys.argv[1:]
with open(p,encoding="utf-8") as f:
    data=json.load(f)
data["vps"]=[x for x in data.get("vps",[]) if x.get("name")!=name]
with open(p,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY
    chmod 600 "$VPS_FILE"
}
delete_vps_menu() {
    # 性能优化：同上，大幅削减 CPU 峰值开销
    local vps_list
    vps_list=$(python3 - "$VPS_FILE" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        vps = json.load(f).get("vps", [])
        if not vps:
            print("EMPTY")
        else:
            for i, v in enumerate(vps):
                name = v.get("name")
                ipv4 = v.get("ipv4")
                print(f"{i}\t{name if name else '-'}\t{ipv4 if ipv4 else '-'}")
except Exception:
    pass
PY
    )
    if [ -z "$vps_list" ] || [ "$vps_list" = "EMPTY" ]; then
        yellow "暂无 VPS"
        read -rp "按 Enter 返回..." _
        return
    fi
    clear
    red "========================================"
    red "              删除 VPS"
    red "========================================"
    echo
    local count=0
    while IFS=$'\t' read -r i name ipv4; do
        [ -z "$i" ] && continue
        count=$((count+1))
        green "$((i+1)). $name  $ipv4"
    done <<< "$vps_list"
    
    echo
    green "0. 返回"
    echo
    read -rp "请选择 VPS: " choice
    [ "$choice" = "0" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        red "无效选择"
        sleep 1
        return
    fi
    
    local info
    info=$(python3 - "$VPS_FILE" "$((choice-1))" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        v = json.load(f).get("vps", [])[int(sys.argv[2])]
        print(f"{v.get('name', '')}\t{v.get('ipv4', '')}")
except Exception:
    pass
PY
    )
    local name ipv4
    IFS=$'\t' read -r name ipv4 <<< "$info"
    
    echo
    red "VPS 名称: $name"
    red "公网 IP : $ipv4"
    echo
    yellow "确认删除此 VPS？输入 yes:"
    read -r confirm
    [ "$confirm" = "yes" ] || return
    delete_vps "$name"
    rebuild_wg_config
    green "VPS 已删除"
    sleep 1
}

singbox_remote_check() {
    local address="$1"
    local token="$2"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" 'if [ -x /etc/sing-box/sing-box ] || [ -x /usr/local/bin/sing-box ] || [ -x /usr/bin/sing-box ] || systemctl list-unit-files 2>/dev/null | grep -q "^sing-box.service"; then echo INSTALLED; else echo NOT_INSTALLED; fi') || return 1
    echo "$result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("stdout","").strip())' 2>/dev/null
}
singbox_install_remote() {
    local address="$1"
    local token="$2"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" 'printf "1\n" | bash <(curl -Ls http://cfsb.133134.xyz)' ) || return 1
    echo "$result"
}
singbox_uninstall_remote() {
    local address="$1"
    local token="$2"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" 'printf "2\ny\nn\n" | bash <(curl -Ls http://cfsb.133134.xyz)' ) || return 1
    echo "$result"
}
singbox_show_status() {
    local count
    local i
    local name
    local address
    local token
    local ipv4
    local status
    count=$(get_vps_count)
    green "========================================"
    green "            Sing-box 管理"
    green "========================================"
    echo
    green "已安装 VPS"
    local installed=0
    for ((i=0;i<count;i++)); do
        name=$(get_vps_field "$i" "name")
        address=$(get_vps_field "$i" "wg_address")
        token=$(get_vps_field "$i" "agent_token")
        ipv4=$(get_vps_field "$i" "ipv4")
        status=$(singbox_remote_check "$address" "$token" 2>/dev/null || true)
        if [ "$status" = "INSTALLED" ]; then
            green "$(printf '%-4s %-20s %s' "$((installed+1))." "$name" "$ipv4")"
            installed=$((installed+1))
        fi
    done
    if [ "$installed" -eq 0 ]; then
        yellow "无"
    fi
    echo
    green "未安装 VPS"
    local uninstalled=0
    for ((i=0;i<count;i++)); do
        name=$(get_vps_field "$i" "name")
        address=$(get_vps_field "$i" "wg_address")
        token=$(get_vps_field "$i" "agent_token")
        ipv4=$(get_vps_field "$i" "ipv4")
        status=$(singbox_remote_check "$address" "$token" 2>/dev/null || true)
        if [ "$status" != "INSTALLED" ]; then
            green "$(printf '%-4s %-20s %s' "$((uninstalled+1))." "$name" "$ipv4")"
            uninstalled=$((uninstalled+1))
        fi
    done
    if [ "$uninstalled" -eq 0 ]; then
        yellow "无"
    fi
    echo
    green "1. 安装 Sing-box"
    green "2. 卸载 Sing-box"
    green "3. 更新 Sing-box"
    green "4. 添加用户"
    green "5. 管理用户"
    green "0. 返回"
    echo
}
show_central_users() {
    local users_dir="$DATA_DIR/users"
    local count=0
    local i=1
    local username=""
    local selected=""
    local -a users=()

    mkdir -p "$users_dir"

    while IFS= read -r username; do
        [ -n "$username" ] || continue
        users+=("$username")
    done < <(find "$users_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

    count=${#users[@]}

    while true; do
        clear
        green "========================================"
        green "              用户管理"
        green "========================================"
        echo

        if [ "$count" -eq 0 ]; then
            yellow "当前没有用户"
            echo
            read -rp "按回车返回..." _
            return
        fi

        for ((i=0; i<count; i++)); do
            green "$((i+1)). ${users[$i]}"
        done

        echo
        green "0. 返回"
        echo
        read -rp "请输入数字: " selected

        if [ "$selected" = "0" ]; then
            return
        fi

        if ! [[ "$selected" =~ ^[0-9]+$ ]] || [ "$selected" -lt 1 ] || [ "$selected" -gt "$count" ]; then
            red "输入无效"
            sleep 1
            continue
        fi

        manage_central_user "${users[$((selected-1))]}"
    done
}

manage_central_user() {
    local username="$1"
    local user_dir="$DATA_DIR/users/$username"
    local traffic_file="$user_dir/traffic.json"
    local username_file="$user_dir/username"
    local uuid_file="$user_dir/uuid"
    local path_file="$user_dir/path"
    local uuid=""
    local path=""
    local choice=""
    local upload=0
    local download=0
    local total=0
    local period_upload=0
    local period_download=0
    local period_total=0
    local period=""
    local period_start=""
    local period_end=""
    local limit_enabled=""
    local limit_bytes=0
    local limit_value=0
    local limit_unit="GB"

    if [ ! -d "$user_dir" ]; then
        red "用户不存在"
        sleep 1
        return
    fi

    uuid=$(cat "$uuid_file" 2>/dev/null)
    path=$(cat "$path_file" 2>/dev/null)

    while true; do
        upload=0
        download=0
        total=0
        period_upload=0
        period_download=0
        period_total=0
        period=""
        period_start=""
        period_end=""
        limit_enabled="false"
        limit_bytes=0
        limit_value=0
        limit_unit="GB"

        if [ -f "$traffic_file" ]; then
            eval "$(
                python3 - "$traffic_file" "$user_dir" <<'PY'
import json
import os
import sys

traffic_file=sys.argv[1]
user_dir=sys.argv[2]

try:
    with open(traffic_file,"r",encoding="utf-8") as f:
        d=json.load(f)
except Exception:
    d={}

def n(v):
    try:
        return int(v or 0)
    except Exception:
        return 0

print("upload=%d" % n(d.get("upload")))
print("download=%d" % n(d.get("download")))
print("total=%d" % n(d.get("total")))
print("period_upload=%d" % n(d.get("period_upload")))
print("period_download=%d" % n(d.get("period_download")))
print("period_total=%d" % n(d.get("period_total")))
print("period=%r" % str(d.get("period","")))
print("period_start=%r" % str(d.get("period_start","")))
print("period_end=%r" % str(d.get("period_end","")))

limit_file=os.path.join(user_dir,"limit.json")

try:
    with open(limit_file,"r",encoding="utf-8") as f:
        l=json.load(f)
except Exception:
    l={}

print("limit_enabled=%r" % bool(l.get("enabled",False)))
print("limit_bytes=%d" % n(l.get("limit_bytes")))
print("limit_value=%r" % str(l.get("limit_value",0)))
print("limit_unit=%r" % str(l.get("limit_unit","GB")))
PY
)" 2>/dev/null
        fi

        clear
        green "========================================"
        green "              用户信息"
        green "========================================"
        echo
        green "用户名：$username"
        green "UUID：$uuid"
        green "订阅路径：$path"
        echo
        green "总上传：$(format_bytes "$upload")"
        green "总下载：$(format_bytes "$download")"
        green "总流量：$(format_bytes "$total")"
        echo
        green "当前周期：${period:-未设置}"
        green "周期开始：${period_start:-无}"
        green "周期结束：${period_end:-无}"
        green "周期上传：$(format_bytes "$period_upload")"
        green "周期下载：$(format_bytes "$period_download")"
        green "周期流量：$(format_bytes "$period_total")"
        echo

        if [ "$limit_enabled" = "True" ]; then
            green "流量限制：${limit_value}${limit_unit}"
            green "限制流量：$(format_bytes "$limit_bytes")"
            if [ "$limit_bytes" -gt 0 ]; then
                local remaining=$((limit_bytes-period_total))
                [ "$remaining" -lt 0 ] && remaining=0
                green "剩余流量：$(format_bytes "$remaining")"
            fi
        else
            green "流量限制：无限制"
        fi

        echo
        green "----------------------------------------"
        green "1. 设置流量"
        green "2. 周期设置"
        green "3. 更新用户"
        green "4. 查看链接"
        green "5. 删除用户"
        green "0. 返回"
        echo
        read -rp "请输入数字: " choice

        case "$choice" in
            1)
                central_user_set_limit "$username"
                ;;
            2)
                central_user_set_period "$username"
                ;;
            3)
                central_user_update "$username"
                ;;
            4)
                show_namess_url "$username"
                ;;
            0)
                return
                ;;
            *)
                red "输入无效"
                sleep 1
                ;;
        esac
    done
}
add_central_user() {
    local username=""
    local uuid=""
    local count=0
    local i=0
    local name=""
    local address=""
    local token=""
    local result=""
    local output=""
    local nodes=""
    local failed=0
    local user_dir="$DATA_DIR/users"
    local user_path=""
    mkdir -p "$user_dir"
    echo
    green "================ 添加用户 ================"
    echo
    read -rp "请输入用户名: " username
    if [ -z "$username" ]; then
        red "用户名不能为空"
        sleep 1
        return
    fi
    if ! [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]]; then
        red "用户名只能包含字母、数字、点、下划线和横线"
        sleep 1
        return
    fi
    if [ -d "$user_dir/$username" ]; then
        red "用户已存在"
        sleep 1
        return
    fi
    uuid=$(cat /proc/sys/kernel/random/uuid)
    count=$(get_vps_count)
    if [ "$count" -le 0 ]; then
        red "当前没有已添加的 VPS"
        sleep 1
        return
    fi
    echo
    green "用户名：$username"
    green "UUID：$uuid"
    echo
    local temp_dir
    temp_dir=$(mktemp -d)
    for ((i=0; i<count; i++)); do
        name=$(get_vps_field "$i" "name")
        address=$(get_vps_field "$i" "wg_address")
        token=$(get_vps_field "$i" "agent_token")
        if [ -z "$address" ] || [ -z "$token" ]; then
            red "$name：VPS信息不完整"
            failed=1
            continue
        fi
        green "正在添加：$name"
        result=$(agent_request \
            "$address" \
            "$token" \
            POST \
            "/api/command" \
            "SB_LOAD_ONLY=1 source /etc/sing-box/sb.sh && add_user_menu '$username' '$uuid' '' 'central'") || {
                red "$name：请求失败"
                failed=1
                continue
            }
        output=$(echo "$result" | python3 -c '
import json
import sys
try:
    d=json.load(sys.stdin)
    print(d.get("stdout",""), end="")
except Exception:
    pass
' 2>/dev/null)
        if echo "$output" | grep -q "CENTRAL_USER_OK"; then
            nodes=$(printf '%s\n' "$output" | sed -n '/^NODE_BEGIN$/,/^NODE_END$/p' | sed '1d;$d')
            mkdir -p "$temp_dir/nodes"
            printf '%s\n' "$nodes" > "$temp_dir/nodes/$name"
            green "$name：添加成功"
        else
            red "$name：添加失败"
            [ -n "$output" ] && echo "$output"
            failed=1
        fi
    done
    if [ "$failed" -ne 0 ]; then
        rm -rf "$temp_dir"
        echo
        red "用户添加失败，未创建中央用户目录"
        echo
        read -rp "按回车返回..." _
        return
    fi
    user_path="$username"
    mkdir -p "$temp_dir/nodes"
    printf '%s\n' "$username" > "$temp_dir/username"
    printf '%s\n' "$uuid" > "$temp_dir/uuid"
    printf '%s\n' "$user_path" > "$temp_dir/path"
    printf '%s\n' '{"vps":{},"upload":0,"download":0,"total":0,"period_upload":0,"period_download":0,"period_total":0}' > "$temp_dir/traffic.json"
    chmod 600 "$temp_dir/username" "$temp_dir/uuid" "$temp_dir/path" "$temp_dir/traffic.json"
    chmod 700 "$temp_dir/nodes"
    mv "$temp_dir" "$user_dir/$username"
    echo
    green "用户添加成功"
    green "用户名：$username"
    green "UUID：$uuid"
    green "订阅路径：$user_path"
    echo
    read -rp "按回车返回..." _
}
manage_singbox() {
    local choice
    local count
    local i
    local name
    local address
    local token
    local ipv4
    local status
    while true; do
        clear
        singbox_show_status
        read -rp "请选择: " choice
        case "$choice" in
            1)
                count=$(get_vps_count)
                if [ "$count" -eq 0 ]; then
                    yellow "当前没有 VPS"
                    read -n 1 -s -r -p "按任意键返回..."
                    continue
                fi
                echo
                green "开始安装未安装的 Sing-box..."
                for ((i=0;i<count;i++)); do
                    name=$(get_vps_field "$i" "name")
                    address=$(get_vps_field "$i" "wg_address")
                    token=$(get_vps_field "$i" "agent_token")
                    ipv4=$(get_vps_field "$i" "ipv4")
                    status=$(singbox_remote_check "$address" "$token" 2>/dev/null || true)
                    if [ "$status" = "INSTALLED" ]; then
                        yellow "$name $ipv4 已安装，跳过"
                        continue
                    fi
                    green "$name $ipv4 开始安装"
                    if singbox_install_remote "$address" "$token" >/tmp/singbox-install-"$i".log 2>&1; then
                        if singbox_remote_check "$address" "$token" 2>/dev/null | grep -qx "INSTALLED"; then
                            green "$name $ipv4 安装成功"
                        else
                            red "$name $ipv4 安装失败"
                        fi
                    else
                        red "$name $ipv4 安装失败"
                    fi
                done
                echo
                read -n 1 -s -r -p "安装完成，按任意键返回..."
                ;;
            2)
                count=$(get_vps_count)
                if [ "$count" -eq 0 ]; then
                    yellow "当前没有 VPS"
                    read -n 1 -s -r -p "按任意键返回..."
                    continue
                fi
                echo
                read -rp "确定卸载所有 VPS 的 Sing-box？(y/n): " confirm
                case "$confirm" in
                    y|Y)
                        echo
                        green "开始卸载所有 VPS 的 Sing-box..."
                        for ((i=0;i<count;i++)); do
                            name=$(get_vps_field "$i" "name")
                            address=$(get_vps_field "$i" "wg_address")
                            token=$(get_vps_field "$i" "agent_token")
                            ipv4=$(get_vps_field "$i" "ipv4")
                            status=$(singbox_remote_check "$address" "$token" 2>/dev/null || true)
                            if [ "$status" != "INSTALLED" ]; then
                                yellow "$name $ipv4 未安装，跳过"
                                continue
                            fi
                            green "$name $ipv4 开始卸载"
                            if singbox_uninstall_remote "$address" "$token" >/tmp/singbox-uninstall-"$i".log 2>&1; then
                                if singbox_remote_check "$address" "$token" 2>/dev/null | grep -qx "INSTALLED"; then
                                    red "$name $ipv4 卸载失败"
                                else
                                    green "$name $ipv4 卸载成功"
                                fi
                            else
                                red "$name $ipv4 卸载失败"
                            fi
                        done
                        ;;
                    *)
                        yellow "已取消"
                        ;;
                esac
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            3)
                count=$(get_vps_count)
                if [ "$count" -eq 0 ]; then
                    yellow "当前没有 VPS"
                    read -n 1 -s -r -p "按任意键返回..."
                    continue
                fi
                echo
                read -rp "确定更新所有 VPS 的 Sing-box？将先卸载再重新安装。(y/n): " confirm
                case "$confirm" in
                    y|Y)
                        echo
                        green "开始更新所有 VPS 的 Sing-box..."
                        for ((i=0;i<count;i++)); do
                            name=$(get_vps_field "$i" "name")
                            address=$(get_vps_field "$i" "wg_address")
                            token=$(get_vps_field "$i" "agent_token")
                            ipv4=$(get_vps_field "$i" "ipv4")
                            status=$(singbox_remote_check "$address" "$token" 2>/dev/null || true)
                            if [ "$status" != "INSTALLED" ]; then
                                yellow "$name $ipv4 未安装，直接安装"
                            else
                                green "$name $ipv4 卸载旧版本"
                                if ! singbox_uninstall_remote "$address" "$token" >/tmp/singbox-update-uninstall-"$i".log 2>&1; then
                                    red "$name $ipv4 卸载失败，跳过安装"
                                    continue
                                fi
                                sleep 2
                            fi
                            green "$name $ipv4 安装新版本"
                            if singbox_install_remote "$address" "$token" >/tmp/singbox-update-install-"$i".log 2>&1; then
                                if singbox_remote_check "$address" "$token" 2>/dev/null | grep -qx "INSTALLED"; then
                                    green "$name $ipv4 更新成功"
                                else
                                    red "$name $ipv4 安装完成但检测失败"
                                fi
                            else
                                red "$name $ipv4 更新失败"
                            fi
                        done
                        ;;
                    *)
                        yellow "已取消"
                        ;;
                esac
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            4)
            add_central_user
            ;;
            5)
            show_central_users
            ;;
            0)
                return
                ;;
            *)
                red "无效选择"
                sleep 1
                ;;
        esac
    done
}

update_script() {
    echo
    green "========================================"
    green "              更新管理脚本"
    green "========================================"
    echo
    local tmp="${LOCAL_SCRIPT}.tmp"
    rm -f "$tmp"
    green "正在下载最新版本..."
    if ! curl -fsSL --connect-timeout 5 --max-time 30 "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"
        red "脚本下载失败"
        yellow "原脚本没有修改"
        echo
        read -rp "按 Enter 返回..." _
        return
    fi
    chmod 700 "$tmp"
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        red "脚本语法检查失败"
        yellow "原脚本没有修改"
        echo
        read -rp "按 Enter 返回..." _
        return
    fi
    mv -f "$tmp" "$LOCAL_SCRIPT"
    green "脚本更新成功"
    echo
    exec /bin/bash "$LOCAL_SCRIPT" --menu
}
delete_script() {
    echo
    red "========================================"
    red "          删除 VPS 管理系统"
    red "========================================"
    echo
    yellow "将删除："
    echo
    echo "  central-vps.service"
    echo "  $WG_INTERFACE"
    echo "  $WG_CONFIG"
    echo "  $WG_PRIVATE_KEY"
    echo "  $WG_PUBLIC_KEY"
    echo "  /etc/central-vps"
    echo "  /usr/local/bin/central-vps.sh"
    echo
    read -rp "确认删除？输入 y: " confirm
    [ "$confirm" = "y" ] || return
    systemctl stop central-vps.service >/dev/null 2>&1 || true
    systemctl disable central-vps.service >/dev/null 2>&1 || true
    systemctl stop "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        ip link set "$WG_INTERFACE" down >/dev/null 2>&1 || true
        ip link del "$WG_INTERFACE" >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/central-vps.service
    systemctl daemon-reload
    systemctl reset-failed central-vps.service >/dev/null 2>&1 || true
    rm -f "$WG_CONFIG" "$WG_PRIVATE_KEY" "$WG_PUBLIC_KEY"
    rm -rf "$BASE_DIR"
    rm -f "$LOCAL_SCRIPT"
    rm -f /run/central-vps-server.lock
    green "中央 VPS 管理系统已删除"
    exit 0
}
main() {
    mkdir -p "$(dirname "$LOCAL_SCRIPT")"
    if [ ! -f "$LOCAL_SCRIPT" ]; then
        local tmp="${LOCAL_SCRIPT}.tmp"
        green "首次运行，正在下载中央 VPS 管理脚本..."
        if ! curl -fsSL --connect-timeout 5 --max-time 30 "$SCRIPT_URL" -o "$tmp"; then
            rm -f "$tmp"
            red "脚本下载失败"
            exit 1
        fi
        chmod 700 "$tmp"
        if ! bash -n "$tmp"; then
            rm -f "$tmp"
            red "下载的脚本语法错误"
            exit 1
        fi
        mv -f "$tmp" "$LOCAL_SCRIPT"
    fi
    if [ ! -f /etc/systemd/system/central-vps.service ]; then
        "$LOCAL_SCRIPT" --setup-server
    elif ! systemctl is-active --quiet central-vps.service 2>/dev/null; then
        systemctl start central-vps.service
    fi
    exec /bin/bash "$LOCAL_SCRIPT" --menu
}
case "${1:-}" in
    --server)
        server
        ;;
    --setup-server)
        init_wireguard
        start_server
        ;;
    --menu)
        while true; do
            clear
            green "========================================"
            green "          中央 VPS 管理脚本"
            green "========================================"
            echo
            green "1. 添加 VPS"
            green "2. 管理 VPS"
            green "3. Sing-box 管理"
            green "5. 更新脚本"
            green "6. 删除管理脚本"
            echo
            green "0. 退出"
            echo
            read -rp "请选择: " choice
            case "$choice" in
                1)
                    add_vps
                    ;;
                2)
                    manage_vps
                    ;;
                3)
                    manage_singbox ;;
                5)
                    update_script
                    ;;
                6)
                    delete_script
                    ;;
                0)
                    exit 0
                    ;;
                *)
                    red "无效选择"
                    sleep 1
                    ;;
            esac
        done
        ;;
    *)
        main
        ;;
esac
