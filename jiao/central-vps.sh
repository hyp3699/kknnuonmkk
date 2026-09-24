#!/bin/bash
set -e
BASE_DIR=/etc/central-vps
CONFIG_DIR=$BASE_DIR/config
DATA_DIR=$BASE_DIR/data
CENTRAL_CONFIG=$CONFIG_DIR/central.json
VPS_FILE=$DATA_DIR/vps.json
WG_NAME=central0
WG_DIR=/etc/wireguard
WG_CONF=$WG_DIR/$WG_NAME.conf
WG_PORT=51820
REGISTER_PORT=18089
AGENT_PORT=18090
GITHUB_RAW_URL="https://raw.githubusercontent.com/你的用户名/你的仓库/main/central-vps.sh"
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$WG_DIR"
chmod 700 "$BASE_DIR" "$CONFIG_DIR" "$DATA_DIR"
generate_token() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
}
generate_keypair() {
    local private_key public_key
    private_key=$(wg genkey)
    public_key=$(printf '%s' "$private_key" | wg pubkey)
    printf '%s\n%s\n' "$private_key" "$public_key"
}
init_central() {
    if [ ! -f "$CENTRAL_CONFIG" ]; then
        local keys private_key public_key
        keys=$(generate_keypair)
        private_key=$(printf '%s\n' "$keys" | sed -n '1p')
        public_key=$(printf '%s\n' "$keys" | sed -n '2p')
        cat > "$CENTRAL_CONFIG" <<EOF
{
  "wg_private_key":"$private_key",
  "wg_public_key":"$public_key",
  "wg_ip":"10.77.0.1",
  "wg_port":$WG_PORT,
  "register_port":$REGISTER_PORT,
  "agent_port":$AGENT_PORT
}
EOF
        chmod 600 "$CENTRAL_CONFIG"
    fi
    [ -f "$VPS_FILE" ] || printf '{"vps":[]}\n' > "$VPS_FILE"
}
json_get() {
    python3 - "$1" "$2" <<'PY'
import json,sys
p,k=sys.argv[1:]
with open(p,encoding="utf-8") as f:
    d=json.load(f)
v=d
for x in k.split("."):
    v=v.get(x,"") if isinstance(v,dict) else ""
print(v)
PY
}
central_ip() {
    local ip
    ip=$(json_get "$CENTRAL_CONFIG" wg_ip)
    printf '%s' "$ip"
}
central_public_key() {
    json_get "$CENTRAL_CONFIG" wg_public_key
}
central_private_key() {
    json_get "$CENTRAL_CONFIG" wg_private_key
}
central_public_ip() {
    local ip
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    printf '%s' "$ip"
}
install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq wireguard wireguard-tools python3 curl >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wireguard-tools python3 curl >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wireguard-tools python3 curl >/dev/null
    fi
}
write_central_wg() {
    local private_key
    private_key=$(central_private_key)
    cat > "$WG_CONF" <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = $WG_PORT
PrivateKey = $private_key
SaveConfig = false
EOF
    chmod 600 "$WG_CONF"
}
reload_central_wg() {
    if wg show "$WG_NAME" >/dev/null 2>&1; then
        wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    fi
    wg-quick up "$WG_NAME" >/dev/null 2>&1
    systemctl enable "$WG_NAME" >/dev/null 2>&1 || true
}
add_wg_peer() {
    local public_key="$1"
    local wg_ip="$2"
    if ! grep -qF "$public_key" "$WG_CONF"; then
        cat >> "$WG_CONF" <<EOF
[Peer]
PublicKey = $public_key
AllowedIPs = $wg_ip/32
EOF
        if wg show "$WG_NAME" >/dev/null 2>&1; then
            wg set "$WG_NAME" peer "$public_key" allowed-ips "$wg_ip/32"
        fi
    fi
}
next_wg_ip() {
    python3 - "$VPS_FILE" <<'PY'
import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p))
except:
    d={"vps":[]}
used={x.get("wg_ip") for x in d.get("vps",[])}
for i in range(2,255):
    ip=f"10.77.0.{i}"
    if ip not in used:
        print(ip)
        break
PY
}
save_vps() {
    python3 - "$VPS_FILE" "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import json,sys,time
p,name,country,public_ip,wg_ip,token,public_key=sys.argv[1:]
try:
    d=json.load(open(p))
except:
    d={"vps":[]}
d["vps"]=[x for x in d.get("vps",[]) if x.get("name")!=name]
d["vps"].append({
    "name":name,
    "country":country,
    "public_ip":public_ip,
    "wg_ip":wg_ip,
    "token":token,
    "wg_public_key":public_key,
    "created_at":int(time.time()),
    "online":False
})
with open(p,"w") as f:
    json.dump(d,f,ensure_ascii=False,indent=2)
PY
    chmod 600 "$VPS_FILE"
}
remove_vps_data() {
    python3 - "$VPS_FILE" "$1" <<'PY'
import json,sys
p,name=sys.argv[1:]
d=json.load(open(p))
d["vps"]=[x for x in d.get("vps",[]) if x.get("name")!=name]
with open(p,"w") as f:
    json.dump(d,f,ensure_ascii=False,indent=2)
PY
}
get_vps() {
    python3 - "$VPS_FILE" "$1" <<'PY'
import json,sys
p,name=sys.argv[1:]
d=json.load(open(p))
for x in d.get("vps",[]):
    if x.get("name")==name:
        print(json.dumps(x,ensure_ascii=False))
        break
PY
}
central_register_server() {
    python3 - "$CENTRAL_CONFIG" "$VPS_FILE" "$WG_CONF" "$REGISTER_PORT" "$AGENT_PORT" "$WG_NAME" <<'PY'
import json,sys,os,subprocess,threading
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
config_file,vps_file,wg_conf,register_port,agent_port,wg_name=sys.argv[1:]
register_port=int(register_port)
agent_port=int(agent_port)
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
            n=int(self.headers.get("Content-Length","0"))
            body=json.loads(self.rfile.read(n))
            token=body.get("token","")
            pub=body.get("wg_public_key","")
            name=body.get("name","")
            country=body.get("country","")
            public_ip=body.get("public_ip","")
            if not token or not pub or not name:
                self.send_json(400,{"ok":False,"error":"invalid"})
                return
            d=json.load(open(vps_file))
            item=next((x for x in d.get("vps",[]) if x.get("token")==token),None)
            if not item:
                self.send_json(403,{"ok":False,"error":"invalid token"})
                return
            wg_ip=item["wg_ip"]
            item["name"]=name
            item["country"]=country
            item["public_ip"]=public_ip
            item["wg_public_key"]=pub
            item["online"]=True
            json.dump(d,open(vps_file,"w"),ensure_ascii=False,indent=2)
            with open(wg_conf,"a") as f:
                f.write("\n[Peer]\nPublicKey = "+pub+"\nAllowedIPs = "+wg_ip+"/32\n")
            subprocess.run(["wg","set",wg_name,"peer",pub,"allowed-ips",wg_ip+"/32"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            central=json.load(open(config_file))
            self.send_json(200,{
                "ok":True,
                "wg_ip":wg_ip,
                "central_wg_ip":central["wg_ip"],
                "central_wg_port":central["wg_port"],
                "central_wg_public_key":central["wg_public_key"],
                "agent_port":agent_port
            })
        except Exception as e:
            self.send_json(500,{"ok":False,"error":str(e)})
server=ThreadingHTTPServer(("0.0.0.0",register_port),Handler)
server.serve_forever()
PY
}
install_central_service() {
    cat > /etc/systemd/system/central-vps-register.service <<EOF
[Unit]
After=network-online.target wg-quick@$WG_NAME.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/central-vps.sh --register-server
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now central-vps-register.service >/dev/null
}
create_add_command() {
    local token="$1"
    local public_ip="$2"
    printf '\n'
    printf '%s\n' '=========================================='
    printf '%s\n' '请在目标 VPS 执行以下命令：'
    printf '%s\n' '=========================================='
    printf 'curl -fsSL %s | bash -s -- --agent-install --server %s --token %s\n' "$GITHUB_RAW_URL" "$public_ip" "$token"
    printf '%s\n' '=========================================='
    printf '\n'
}
add_vps() {
    local name country token public_ip wg_ip
    printf '\n================ 添加 VPS ================\n\n'
    read -rp "VPS名称: " name
    [ -n "$name" ] || return
    read -rp "国家/地区: " country
    read -rp "中央VPS公网IP: " public_ip
    if [ -z "$public_ip" ]; then
        public_ip=$(central_public_ip)
    fi
    wg_ip=$(next_wg_ip)
    token=$(generate_token)
    save_vps "$name" "$country" "" "$wg_ip" "$token" ""
    create_add_command "$token" "$public_ip"
    printf '等待 VPS 连接'
    local i=0
    while [ $i -lt 120 ]; do
        if python3 - "$VPS_FILE" "$token" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get("vps",[]):
    if x.get("token")==sys.argv[2] and x.get("online"):
        raise SystemExit(0)
raise SystemExit(1)
PY
        then
            printf '\n\n✓ VPS 已连接\n\n'
            show_vps_by_token "$token"
            read -rp "按 Enter 返回..." _
            return
        fi
        printf '.'
        sleep 1
        i=$((i+1))
    done
    printf '\n\n等待超时，请确认目标 VPS 已执行命令。\n'
    read -rp "按 Enter 返回..." _
}
show_vps_by_token() {
    python3 - "$VPS_FILE" "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get("vps",[]):
    if x.get("token")==sys.argv[2]:
        print("VPS名称    :",x.get("name",""))
        print("国家/地区  :",x.get("country",""))
        print("公网IP     :",x.get("public_ip",""))
        print("WireGuard  :",x.get("wg_ip",""))
        print("状态       :","在线" if x.get("online") else "离线")
        break
PY
}
list_vps() {
    python3 - "$VPS_FILE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
items=d.get("vps",[])
if not items:
    print("暂无 VPS")
    raise SystemExit
print("================================ VPS 列表 ================================")
for i,x in enumerate(items,1):
    print(f"{i}. {x.get('name','')}  |  {x.get('country','')}  |  {x.get('public_ip','')}  |  {x.get('wg_ip','')}  |  {'在线' if x.get('online') else '离线'}")
print("=========================================================================")
PY
}
test_vps() {
    local name="$1" wg_ip token
    wg_ip=$(python3 - "$VPS_FILE" "$name" <<'PY'
import json,sys
for x in json.load(open(sys.argv[1])).get("vps",[]):
    if x.get("name")==sys.argv[2]:
        print(x.get("wg_ip",""))
        break
PY
)
    token=$(python3 - "$VPS_FILE" "$name" <<'PY'
import json,sys
for x in json.load(open(sys.argv[1])).get("vps",[]):
    if x.get("name")==sys.argv[2]:
        print(x.get("token",""))
        break
PY
)
    curl -fsS --max-time 5 -H "Authorization: Bearer $token" "http://$wg_ip:$AGENT_PORT/api/status"
}
delete_vps() {
    local name pub
    read -rp "输入要删除的 VPS 名称: " name
    [ -n "$name" ] || return
    pub=$(python3 - "$VPS_FILE" "$name" <<'PY'
import json,sys
for x in json.load(open(sys.argv[1])).get("vps",[]):
    if x.get("name")==sys.argv[2]:
        print(x.get("wg_public_key",""))
        break
PY
)
    if [ -n "$pub" ]; then
        wg set "$WG_NAME" peer "$pub" remove >/dev/null 2>&1 || true
        python3 - "$WG_CONF" "$pub" <<'PY'
import sys,re
p,pub=sys.argv[1:]
s=open(p).read()
s=re.sub(r'\n\[Peer\]\nPublicKey = '+re.escape(pub)+r'\nAllowedIPs = [^\n]+\n','\n',s)
open(p,'w').write(s)
PY
    fi
    remove_vps_data "$name"
    wg-quick save "$WG_NAME" >/dev/null 2>&1 || true
    printf '\nVPS 已删除。\n'
    sleep 1
}
manage_vps() {
    while true; do
        clear
        echo "================================"
        echo "           管理 VPS"
        echo "================================"
        list_vps
        echo
        echo "1. 测试通信"
        echo "2. 删除 VPS"
        echo "0. 返回"
        echo
        read -rp "请选择: " choice
        case "$choice" in
            1)
                read -rp "VPS名称: " name
                echo
                test_vps "$name" || echo "通信失败"
                read -rp "按 Enter 返回..." _
                ;;
            2) delete_vps ;;
            0) return ;;
        esac
    done
}
central_main() {
    install_packages
    init_central
    write_central_wg
    reload_central_wg
    install_central_service
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
            3) echo; echo "暂未接入 sing-box"; read -rp "按 Enter 返回..." _ ;;
            4) echo; echo "暂未接入 sing-box"; read -rp "按 Enter 返回..." _ ;;
            0) exit 0 ;;
        esac
    done
}
agent_install() {
    local server="$1"
    local token="$2"
    local name country public_ip
    if [ -z "$server" ] || [ -z "$token" ]; then
        echo "参数错误"
        exit 1
    fi
    install_packages
    mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$DATA_DIR" "$WG_DIR"
    local keys private_key public_key
    keys=$(generate_keypair)
    private_key=$(printf '%s\n' "$keys" | sed -n '1p')
    public_key=$(printf '%s\n' "$keys" | sed -n '2p')
    name=$(hostname)
    country=""
    public_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    local response
    response=$(python3 - "$server" "$REGISTER_PORT" "$token" "$public_key" "$name" "$country" "$public_ip" <<'PY'
import json,sys,urllib.request
server,port,token,pub,name,country,public_ip=sys.argv[1:]
data=json.dumps({
    "token":token,
    "wg_public_key":pub,
    "name":name,
    "country":country,
    "public_ip":public_ip
}).encode()
req=urllib.request.Request(
    f"http://{server}:{port}/api/register",
    data=data,
    headers={"Content-Type":"application/json"}
)
try:
    with urllib.request.urlopen(req,timeout=10) as r:
        print(r.read().decode())
except Exception as e:
    print(json.dumps({"ok":False,"error":str(e)}))
PY
)
    local ok
    ok=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok",False))')
    if [ "$ok" != "True" ]; then
        echo "注册失败"
        echo "$response"
        exit 1
    fi
    local wg_ip central_wg_ip central_wg_port central_pub agent_port
    wg_ip=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["wg_ip"])')
    central_wg_ip=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["central_wg_ip"])')
    central_wg_port=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["central_wg_port"])')
    central_pub=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["central_wg_public_key"])')
    agent_port=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["agent_port"])')
    cat > "$CONFIG_DIR/agent.json" <<EOF
{
  "name":"$name",
  "country":"$country",
  "token":"$token",
  "wg_private_key":"$private_key",
  "wg_public_key":"$public_key",
  "wg_ip":"$wg_ip",
  "central_wg_ip":"$central_wg_ip",
  "central_wg_port":$central_wg_port,
  "central_wg_public_key":"$central_pub",
  "agent_port":$agent_port
}
EOF
    chmod 600 "$CONFIG_DIR/agent.json"
    cat > "$WG_DIR/$WG_NAME.conf" <<EOF
[Interface]
Address = $wg_ip/24
PrivateKey = $private_key
[Peer]
PublicKey = $central_pub
Endpoint = $server:$central_wg_port
AllowedIPs = $central_wg_ip/32
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_DIR/$WG_NAME.conf"
    wg-quick down "$WG_NAME" >/dev/null 2>&1 || true
    wg-quick up "$WG_NAME"
    install_agent_service
    echo
    echo "VPS 已连接中央服务器"
    echo "WireGuard: $wg_ip"
}
install_agent_service() {
    cat > /usr/local/bin/central-vps.sh <<'EOF'
#!/bin/bash
exec bash /etc/central-vps/agent-main.sh "$@"
EOF
    chmod +x /usr/local/bin/central-vps.sh
    cat > /etc/central-vps/agent-main.sh <<'EOF'
#!/bin/bash
BASE_DIR=/etc/central-vps
CONFIG_DIR=$BASE_DIR/config
CONFIG_FILE=$CONFIG_DIR/agent.json
WG_NAME=central0
python3 - "$CONFIG_FILE" <<'PY'
import json,sys
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
c=json.load(open(sys.argv[1]))
token=c["token"]
name=c["name"]
country=c.get("country","")
wg_ip=c["wg_ip"]
port=int(c["agent_port"])
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
    def auth(self):
        return self.headers.get("Authorization","")==f"Bearer {token}"
    def do_GET(self):
        if not self.auth():
            self.send_json(401,{"ok":False,"error":"unauthorized"})
            return
        if self.path=="/api/status":
            import socket,subprocess
            try:
                sb=subprocess.run(["systemctl","is-active","sing-box"],capture_output=True,text=True).stdout.strip()
            except:
                sb="unknown"
            self.send_json(200,{
                "ok":True,
                "name":name,
                "country":country,
                "hostname":socket.gethostname(),
                "wg_ip":wg_ip,
                "sing_box":sb
            })
            return
        self.send_json(404,{"ok":False})
server=ThreadingHTTPServer((wg_ip,port),Handler)
server.serve_forever()
PY
EOF
    chmod +x /etc/central-vps/agent-main.sh
    cat > /etc/systemd/system/central-vps-agent.service <<EOF
[Unit]
After=network-online.target wg-quick@$WG_NAME.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/etc/central-vps/agent-main.sh
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now central-vps-agent.service >/dev/null
}
case "${1:-}" in
    --central)
        central_main
        ;;
    --register-server)
        init_central
        central_register_server
        ;;
    --agent-install)
        shift
        server=""
        token=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --server) server="$2"; shift 2 ;;
                --token) token="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        agent_install "$server" "$token"
        ;;
    *)
        if [ -f "$CENTRAL_CONFIG" ]; then
            central_main
        else
            echo "1. 中央 VPS"
            echo "2. 被控 VPS"
            read -rp "请选择: " mode
            case "$mode" in
                1) central_main ;;
                2) echo "请使用中央 VPS 生成的安装命令" ;;
            esac
        fi
        ;;
esac
