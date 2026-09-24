#!/bin/bash

generate_vars() {
    local cc=""
    local c1 c2 n1 n2
    local response
    response=$(curl -4 -sS --connect-timeout 3 --max-time 5 \
        "https://api.ip.sb/geoip" 2>/dev/null)
    cc=$(echo "$response" |
        jq -r '.country_code // empty' 2>/dev/null |
        tr '[:lower:]' '[:upper:]')
    if [[ ! "$cc" =~ ^[A-Z]{2}$ ]]; then
        response=$(curl -4 -sS --connect-timeout 3 --max-time 5 \
            "https://ipapi.co/json/" 2>/dev/null)
        cc=$(echo "$response" |
            jq -r '.country_code // empty' 2>/dev/null |
            tr '[:lower:]' '[:upper:]')
    fi
    if [[ ! "$cc" =~ ^[A-Z]{2}$ ]]; then
        response=$(curl -4 -sS --connect-timeout 3 --max-time 5 \
            "https://ipinfo.io/json" 2>/dev/null)

        cc=$(echo "$response" |
            jq -r '.country // empty' 2>/dev/null |
            tr '[:lower:]' '[:upper:]')
    fi
    if [[ "$cc" =~ ^[A-Z]{2}$ ]]; then
        printf -v c1 '%d' "'${cc:0:1}"
        printf -v c2 '%d' "'${cc:1:1}"
        n1=$((0x1F1E6 + c1 - 65))
        n2=$((0x1F1E6 + c2 - 65))
        printf -v isp '%b' \
            "\\U$(printf '%08X' "$n1")\\U$(printf '%08X' "$n2")"
    else
        isp="🌐"
    fi
}

# 用于存放已分配端口的数组
declare -A used_ports
get_available_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65535 -n 1)
        if [ -n "${used_ports[$port]}" ]; then
            continue
        fi
        if port_is_used "$port" "$protocol"; then
            continue
        fi
        used_ports[$port]=1
        echo "$port"
        break
    done
}
port_is_used() {
    local port="$1"
    local protocol="$2"
    if command -v ss >/dev/null 2>&1; then
        if [ "$protocol" = "udp" ]; then
            ss -H -lun | grep -qE "[:.]${port}([[:space:]]|$)"
        else
            ss -H -ltn | grep -qE "[:.]${port}([[:space:]]|$)"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if [ "$protocol" = "udp" ]; then
            netstat -lun | grep -qE "[:.]${port}([[:space:]]|$)"
        else
            netstat -ltn | grep -qE "[:.]${port}([[:space:]]|$)"
        fi
    fi
}
# 获取ip
get_realip() {
    local ip=""
    local v6=""
    ip=$(curl -4 -sL --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null)
    if [ -z "$ip" ]; then
        v6=$(curl -6 -sL --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null)
        if [ -n "$v6" ]; then
            echo "[$v6]"
            return 0
        fi
        return 1
    fi
    if curl -4 -sL --connect-timeout 3 --max-time 5 \
        http://ipinfo.io/org 2>/dev/null |
        grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        v6=$(curl -6 -sL --connect-timeout 3 --max-time 5 \
            ip.sb 2>/dev/null)
        if [ -n "$v6" ]; then
            echo "[$v6]"
            return 0
        fi
    fi
    echo "$ip"
}
ip_address() {
    ipv4_address=$(curl -4 -sS -L -m 3 https://ipv4.ip.sb 2>/dev/null | tr -d '[:space:]')
    ipv6_address=$(curl -6 -sS -L -m 3 https://ipv6.ip.sb 2>/dev/null | tr -d '[:space:]')
    [[ "$ipv4_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ipv4_address=""
    [[ "$ipv6_address" =~ : ]] || ipv6_address=""
}

# 定义常量
uuid=$(cat /proc/sys/kernel/random/uuid)
uuid99=$(cat /proc/sys/kernel/random/uuid)
nginx_port=$(get_available_port)
tuic_port=$(get_available_port)
socks_port=$(get_available_port)
http_port=$(get_available_port)
anytls_port=$(get_available_port)
xtls_reality=$(get_available_port)
vless_tcp_tls=$(get_available_port)
anytls_reality=$(get_available_port)
naive_port=$(get_available_port)
h2_reality=$(get_available_port)
hy2_port=$(get_available_port)
grpc_reality=$(get_available_port)
xhttp_port=$(get_available_port)
xray_xhttp_reality=$(get_available_port)
vless_ws_port=$(get_available_port)
vmess_ws_port=$(get_available_port)
trojan_ws_port=$(get_available_port)
username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

BASE_DIR="/etc/sing-box"
DATA_DIR="$BASE_DIR/user_manager"
LIMIT_DIR="$DATA_DIR/limits"
TRAFFIC_DIR="$DATA_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
PYTHON="$(command -v python3 2>/dev/null || true)"

to_chinese() {
    local clean_status=$(echo "$1" | sed 's/\x1b\[[0-9;]*m//g')
    [ -z "$clean_status" ] && clean_status="unknown" 
    case "$clean_status" in
        "running")       echo -e "\033[1;32m运行中\033[0m" ;;
        "not running")   echo -e "\033[1;33m未运行\033[0m" ;;
        "not installed") echo -e "\033[1;31m未安装\033[0m" ;;
        *)               echo -e "\033[0;37m$clean_status\033[0m" ;;
    esac
}

# 获取ip
get_realip() {
    local ip=""
    local v6=""
    ip=$(curl -4 -sL --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null)
    if [ -z "$ip" ]; then
        v6=$(curl -6 -sL --connect-timeout 3 --max-time 5 ip.sb 2>/dev/null)
        if [ -n "$v6" ]; then
            echo "[$v6]"
            return 0
        fi
        return 1
    fi
    if curl -4 -sL --connect-timeout 3 --max-time 5 \
        http://ipinfo.io/org 2>/dev/null |
        grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        v6=$(curl -6 -sL --connect-timeout 3 --max-time 5 \
            ip.sb 2>/dev/null)
        if [ -n "$v6" ]; then
            echo "[$v6]"
            return 0
        fi
    fi
    echo "$ip"
}
ip_address() {
    ipv4_address=$(curl -4 -sS -L -m 3 https://ipv4.ip.sb 2>/dev/null | tr -d '[:space:]')
    ipv6_address=$(curl -6 -sS -L -m 3 https://ipv6.ip.sb 2>/dev/null | tr -d '[:space:]')
    [[ "$ipv4_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ipv4_address=""
    [[ "$ipv6_address" =~ : ]] || ipv6_address=""
}


manage_nodes_menu() {
    if [ -z "$private_key" ]; then
        output=$(${work_dir}/sing-box generate reality-keypair)
        private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
        short_id=$(openssl rand -hex 6)
    fi
    if systemctl is-active --quiet singbox-traffic.service; then
        :
    else
        systemctl start singbox-traffic.service >/dev/null 2>&1 || true
    fi
    CONF_DIR="/etc/sing-box/conf"
    URL_DIR="/etc/sing-box/url"
    SUB_FILE="/etc/sing-box/sub.txt"
	mkdir -p "$CONF_DIR" "$URL_DIR"
    while true; do
        clear
        green "================= 入站管理 ================="
        echo
        green "a. 添加入站"
        green "b. 添加用户"
        echo
        green "---------------- 已添加用户 ----------------"
local user_entries=()
local user_index=1
local user_dir
local user_name
shopt -s nullglob
for user_dir in "$URL_DIR"/*; do
    [ -d "$user_dir" ] || continue
    user_name=$(basename "$user_dir")
    [ -f "$user_dir/$user_name-uuid" ] || continue
    [ -f "$user_dir/$user_name" ] || continue
    [ -f "$user_dir/$user_name-sub" ] || continue
    user_entries+=("$user_name")
    green "y${user_index}. ${user_name}"
    user_index=$((user_index + 1))
done
shopt -u nullglob
if [ ${#user_entries[@]} -eq 0 ]; then
    yellow "暂无已添加用户"
fi
echo
        green "---------------- 已添加入站 ----------------"
local entries=()
local index=1
local file
local filename
local inbound_type
local inbound_number
local inbound_port
local port_text
local port_status
shopt -s nullglob
for file in "$CONF_DIR"/*.json; do
    [ -f "$file" ] || continue
    filename=$(basename "$file")
    if [[ "$filename" =~ ^(.+)-([0-9]+)\.json$ ]]; then
        inbound_type="${BASH_REMATCH[1]}"
        inbound_number="${BASH_REMATCH[2]}"
        entries+=("$file|$inbound_type|$inbound_number")
        inbound_port=$(jq -r '.inbounds[0].listen_port // empty' "$file" 2>/dev/null)
        case "$inbound_type" in
            hysteria2|tuic)
                port_text="UDP端口未放行"
                port_status="red"
                if [ -n "$inbound_port" ] && command -v nft >/dev/null 2>&1; then
                    if nft list chain inet filter script_input 2>/dev/null |
                        grep -Eq "udp dport ${inbound_port} .*accept"; then
                        port_text="UDP端口已放行"
                        port_status="green"
                    fi
                fi
                ;;
            *)
                port_text="TCP端口未放行"
                port_status="red"
                if [ -n "$inbound_port" ] && command -v nft >/dev/null 2>&1; then
                    if nft list chain inet filter script_input 2>/dev/null |
                        grep -Eq "tcp dport ${inbound_port} .*accept"; then
                        port_text="TCP端口已放行"
                        port_status="green"
                    fi
                fi
                ;;
        esac
		printf "%s. %-30s " "$index" "${inbound_type}-${inbound_number}"
        if [ "$port_status" = "green" ]; then
            green "$port_text"
        else
            red "$port_text"
        fi
        index=$((index + 1))
    fi
done
firewall_policy=$(nft list chain inet filter input 2>/dev/null |
    awk '/policy/ {print $NF}' |
    tr -d ';')
if [ "$firewall_policy" = "drop" ]; then
    green "--------------- 防火墙已开启 ---------------"
else
    red "--------------- 防火墙未开启 ---------------"
fi
shopt -u nullglob
if [ ${#entries[@]} -eq 0 ]; then
    yellow "暂无已添加入站"
fi
echo
        green "0. 返回"
        echo
        read -rp "请选择: " choice
        case "$choice" in
            a|A)
                add_inbound_menu
                ;;
            b|B)
                add_user_menu
                ;;
            0)
                return
                ;;
            '')
                continue
                ;;
            *)
    if [[ "$choice" =~ ^y([0-9]+)$ ]]; then
        local user_num="${BASH_REMATCH[1]}"
        local user_pos=$((user_num - 1))
        if [ "$user_pos" -ge 0 ] && [ "$user_pos" -lt "${#user_entries[@]}" ]; then
            manage_single_user "${user_entries[$user_pos]}"
        else
            red "无效用户编号"
            sleep 1
        fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#entries[@]}" ]; then
        manage_single_inbound "${entries[$((choice - 1))]}"
    else
        red "无效选项"
        sleep 1
    fi
    ;;
        esac
    done
}
get_next_inbound_number() {
    local inbound_type="$1"
    local number=1
    while [ -f "$CONF_DIR/${inbound_type}-${number}.json" ]; do
        number=$((number + 1))
    done
    echo "$number"
}
get_inbound_config_file() {
    local inbound_type="$1"
    local number="$2"
    echo "$CONF_DIR/${inbound_type}-${number}.json"
}

add_user_menu() {
local CONF_DIR="/etc/sing-box/conf"
local URL_DIR="/etc/sing-box/url"
local MAIN_CONFIG="/etc/sing-box/conf/config.json"
local NGINX_CONF_DIR="/etc/nginx/conf.d"
local NGINX_USER_CONF_DIR="/etc/nginx/conf.d/singbox_users"
local NGINX_MAIN_CONF="/etc/nginx/conf.d/singbox_sub.conf"
local input_username="${1:-}"
local input_uuid="${2:-}"
local input_path="${3:-}"

local username
local uuid
local SUB_SERVICE="/usr/local/bin/sing-box-subscription.py"
local SUB_SERVICE_UNIT="/etc/systemd/system/sing-box-subscription.service"
local TRAFFIC_STATE="/etc/sing-box/user_manager/traffic/state.json"
local LIMIT_DIR="/etc/sing-box/user_manager/limits"

mkdir -p "$URL_DIR" "$NGINX_CONF_DIR" "$NGINX_USER_CONF_DIR" "$LIMIT_DIR"

local need_ssl_init=1
if [[ -f "$NGINX_MAIN_CONF" ]]; then
    local existing_domain
    existing_domain=$(grep -iE '^\s*server_name\s+' "$NGINX_MAIN_CONF" | head -n 1 | awk '{print $2}' | tr -d ';')
    if [[ -n "$existing_domain" && "$existing_domain" != "_" ]]; then
        need_ssl_init=0
    fi
fi

if [[ "$need_ssl_init" -eq 1 ]]; then
    if ! check_and_issue_ssl ""; then
        red "证书准备失败，无法继续添加用户。"
        sleep 2
        return
    fi
    if [[ -z "$domain" || -z "$cert_file" || -z "$key_file" ]]; then
        red "未获取到有效的域名/IP或证书路径，取消添加用户。"
        sleep 2
        return
    fi

    echo
    skyblue "============== 请选择订阅监听端口 =============="
    echo " 1) 443 (默认)"
    echo " 2) 2053"
    echo " 3) 2083"
    echo " 4) 2087"
    echo " 5) 2096"
    echo " 6) 8443"
    skyblue "================================================"
    local sub_port_choice sub_port=443
    read -rp "请输入选择 [1-6]（默认 1）: " sub_port_choice
    case "$sub_port_choice" in
        2) sub_port=2053 ;;
        3) sub_port=2083 ;;
        4) sub_port=2087 ;;
        5) sub_port=2096 ;;
        6) sub_port=8443 ;;
        *) sub_port=443 ;;
    esac

    cat > "$NGINX_MAIN_CONF" <<NGINX_EOF
server {
	listen ${sub_port} ssl http2;
    listen [::]:${sub_port} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    include /etc/nginx/conf.d/singbox_users/*.conf;

    location / {
        return 404;
    }
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
NGINX_EOF

    if ! nginx -t >/dev/null 2>&1; then
        rm -f "$NGINX_MAIN_CONF"
        red "Nginx 主配置文件生成失败，语法检查未通过！"
        sleep 2
        return
    fi
    systemctl restart nginx >/dev/null 2>&1
fi
# ==========================================================
cat > "$SUB_SERVICE" <<'PY_EOF'
import base64
import json
import os
import re
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TRAFFIC_STATE = "/etc/sing-box/user_manager/traffic/state.json"
LIMIT_DIR = "/etc/sing-box/user_manager/limits"
URL_DIR = "/etc/sing-box/url"

def format_bytes(value):
    try:
        value = float(value)
    except Exception:
        value = 0
    if value >= 1024**3:
        return f"{value/1024**3:.2f} GB"
    if value >= 1024**2:
        return f"{value/1024**2:.2f} MB"
    if value >= 1024:
        return f"{value/1024:.2f} KB"
    return f"{int(value)} B"

import time
def load_json(path, retries=3, delay=0.05):
    for _ in range(retries):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            time.sleep(delay)
    return {}

def make_subscription(username):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", username):
        return None
    links_file = os.path.join(URL_DIR, username, username)
    if not os.path.isfile(links_file):
        return None
    try:
        with open(links_file, "r", encoding="utf-8") as f:
            links = f.read().strip()
    except Exception:
        return None

    state = load_json(TRAFFIC_STATE)
    user_data = state.get("users", {}).get(username, {})
    used = int(user_data.get("period_total", 0) or 0)
    
    limit_file = os.path.join(LIMIT_DIR, f"{username}.json")
    limit_data = load_json(limit_file)
    enabled = bool(limit_data.get("enabled", False))
    limit_bytes = int(limit_data.get("limit_bytes", 0) or 0)
    
    if enabled and limit_bytes > 0:
        remaining = max(limit_bytes - used, 0)
        remark = f"📊 剩余流量: {format_bytes(remaining)} | 已用: {format_bytes(used)}"
    else:
        remark = f"📊 剩余流量: 无限制 | 已用: {format_bytes(used)}"
    
    # 加入 URL 编码，防止特殊字符导致客户端排序混乱或不显示
    safe_remark = urllib.parse.quote(remark)
    traffic_line = f"vless://00000000-0000-0000-0000-000000000000@127.0.0.1:10000?encryption=none&security=none&type=tcp#{safe_remark}"
    
    # 物理上强制拼接在第一行
    content = traffic_line + "\n" + links
    return base64.b64encode(content.encode("utf-8")).decode("ascii") + "\n"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        match = re.fullmatch(r"/sub/([A-Za-z0-9._-]+)", self.path)
        if not match:
            self.send_response(404)
            self.end_headers()
            return
        content = make_subscription(match.group(1))
        if content is None:
            self.send_response(404)
            self.end_headers()
            return
        data = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, format, *args):
        return

ThreadingHTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
PY_EOF
chmod 755 "$SUB_SERVICE"
cat > "$SUB_SERVICE_UNIT" <<'EOF'
[Unit]
Description=Sing-box Dynamic Subscription Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/sing-box-subscription.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$SUB_SERVICE_UNIT"
systemctl daemon-reload
systemctl enable --now sing-box-subscription.service >/dev/null 2>&1
systemctl restart sing-box-subscription.service >/dev/null 2>&1
# ==========================================================
local max_num=0
local f n
shopt -s nullglob
for f in "$URL_DIR"/test-user-*; do
[ -d "$f" ] || continue
n=$(basename "$f" | sed -n 's/^test-user-\([0-9]\+\)$/\1/p')
if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$max_num" ]; then
max_num="$n"
fi
done
shopt -u nullglob
if [[ -n "$input_username" ]]; then
    username="$input_username"
else
    username="test-user-$((max_num + 1))"
fi
if [[ -n "$input_uuid" ]]; then
    uuid="$input_uuid"
else
    uuid=$(cat /proc/sys/kernel/random/uuid)
fi
while true; do
clear
green "================ 添加用户 ================"
echo
green "用户名：$username"
green "UUID：$uuid"
echo
green "---------------- 选择入站 ----------------"
local entries=()
local index=1
local file
shopt -s nullglob
for file in "$CONF_DIR"/*.json; do
[ -f "$file" ] || continue
case "$(basename "$file")" in
    config.json|cloudflared.json)
        continue
        ;;
esac
while IFS=$'\t' read -r inbound_type inbound_tag; do
[ -n "$inbound_type" ] || continue
[ -n "$inbound_tag" ] || continue
entries+=("$file|$inbound_type|$inbound_tag")
green "${index}. ${inbound_tag}"
index=$((index + 1))
done < <(python3 - "$file" <<'PY'
import json
import sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    for inbound in data.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue
        inbound_type = str(inbound.get("type", "")).strip()
        inbound_tag = str(inbound.get("tag", "")).strip()
        if inbound_type and inbound_tag:
            print(f"{inbound_type}\t{inbound_tag}")
except Exception:
    pass
PY
)
done
shopt -u nullglob
if [ ${#entries[@]} -eq 0 ]; then
yellow "暂无可用入站"
sleep 1
return
fi
echo
green "请输入要添加的入站编号，可多选，例如：1 2 3"
green "输入 0 返回"
echo
read -rp "请选择: " choice
[ "$choice" = "0" ] && return
[ -z "$choice" ] && continue
local selected=()
local invalid=0
for n in $choice; do
if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#entries[@]}" ]; then
selected+=("${entries[$((n - 1))]}")
else
invalid=1
fi
done
if [ "$invalid" -eq 1 ] || [ "${#selected[@]}" -eq 0 ]; then
red "存在无效入站编号"
sleep 1
continue
fi
local selected_data=""
for f in "${selected[@]}"; do
if [ -n "$selected_data" ]; then
selected_data+=$'\n'
fi
selected_data+="$f"
done
local force_overwrite=0
if [[ -n "$input_username" ]]; then
    force_overwrite=1
fi
SELECTED_DATA="$selected_data" \
USERNAME="$username" \
USER_UUID="$uuid" \
MAIN_CONFIG="$MAIN_CONFIG" \
URL_DIR="$URL_DIR" \
NGINX_USER_CONF_DIR="$NGINX_USER_CONF_DIR" \
FORCE_OVERWRITE="$force_overwrite" \
INPUT_PATH="$input_path" \
python3 - <<'PY'
import os
import json
import base64
import re
import tempfile
import secrets
import subprocess
import copy
import urllib.parse
import ipaddress

username = os.environ["USERNAME"]
user_uuid = os.environ["USER_UUID"]
main_config = os.environ["MAIN_CONFIG"]
url_dir = os.environ["URL_DIR"]
nginx_user_conf_dir = os.environ["NGINX_USER_CONF_DIR"]
force_overwrite = os.environ.get("FORCE_OVERWRITE", "0") == "1"
input_path = os.environ.get("INPUT_PATH", "").strip()
user_dir = os.path.join(url_dir, username)
if force_overwrite and os.path.isdir(user_dir):
    import shutil
    shutil.rmtree(user_dir)
os.makedirs(user_dir, exist_ok=True)
os.chmod(user_dir, 0o755)

uuid_file = os.path.join(user_dir, f"{username}-uuid")
links_file = os.path.join(user_dir, username)
sub_file = os.path.join(user_dir, f"{username}-sub")

with open(uuid_file, "w", encoding="utf-8") as f:
    f.write(f"{username}\n{user_uuid}\n")
os.chmod(uuid_file, 0o644)

selected_data = os.environ["SELECTED_DATA"]
selected = [x for x in selected_data.splitlines() if x.strip()]

def find_inbound(data, tag):
    if not isinstance(data, dict):
        return None
    inbounds = data.get("inbounds")
    if not isinstance(inbounds, list):
        return None
    for inbound in inbounds:
        if not isinstance(inbound, dict):
            continue
        if str(inbound.get("tag", "")).strip() == tag:
            return inbound
    return None

def add_user_to_config(path, tag):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    inbound = find_inbound(data, tag)
    if inbound is None:
        raise RuntimeError(f"未找到入站: {tag}")
    users = inbound.get("users")
    if not isinstance(users, list):
        raise RuntimeError(f"入站没有 users 数组: {tag}")
    
    existing_user = None
    for u in users:
        if isinstance(u, dict) and u.get("name") == username:
            existing_user = u
            break

    if existing_user is not None:
        if "uuid" in existing_user:
            existing_user["uuid"] = user_uuid
        elif "password" in existing_user:
            existing_user["password"] = user_uuid
    else:
        template = None
        for u in users:
            if isinstance(u, dict):
                template = u
                break
        
        if template is not None:
            new_user = copy.deepcopy(template)
            new_user["name"] = username
            if "uuid" in new_user:
                new_user["uuid"] = user_uuid
            elif "password" in new_user:
                new_user["password"] = user_uuid
        else:
            new_user = {"name": username}
            if inbound.get("type") in ("tuic", "hysteria2", "hy2", "anytls"):
                new_user["password"] = user_uuid
            if inbound.get("type") in ("tuic", "vless", "vmess", "trojan"):
                new_user["uuid"] = user_uuid
        users.append(new_user)
    # ==============================================================================

    fd, tmp = tempfile.mkstemp(prefix=".singbox-user-", dir=os.path.dirname(path))
    os.close(fd)
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def replace_link(line, protocol):
    line = line.rstrip("\n")
    if not line.strip():
        return line
    if protocol == "tuic":
        return re.sub(r'^(tuic://)[^:@]+:', r'\g<1>' + user_uuid + ':', line, count=1)
    if protocol == "vless":
        return re.sub(r'^(vless://)[^@]+@', r'\g<1>' + user_uuid + '@', line, count=1)
    if protocol in ("hysteria2", "hy2"):
        return re.sub(r'^(hysteria2://|hy2://)[^@]+@', lambda m: m.group(1) + user_uuid + "@", line, count=1)
    if protocol == "anytls":
        return re.sub(r'^(anytls://)[^@]+@', r'\g<1>' + user_uuid + '@', line, count=1)
    if protocol == "vmess":
        m = re.match(r'^(vmess://)([^#\s]+)(.*)$', line)
        if not m:
            return line
        try:
            raw = base64.b64decode(m.group(2) + "===")
            obj = json.loads(raw.decode("utf-8"))
            obj["id"] = user_uuid
            encoded = base64.b64encode(json.dumps(obj, ensure_ascii=False, separators=(", ", ": ")).encode("utf-8")).decode("ascii")
            return m.group(1) + encoded + m.group(3)
        except Exception:
            return line
    return line
def has_ip_address(host):
    try:
        import ipaddress
        ipaddress.ip_address(host.strip("[]"))
        return True
    except Exception:
        return False
def is_valid_connection(line, inbound_type):
    line = line.strip()
    if not line:
        return False
    protocol = inbound_type.lower()
    if protocol == "vmess":
        try:
            m = re.match(r'^vmess://([^#\s]+)', line)
            if not m:
                return False
            encoded = m.group(1)
            encoded += "=" * (-len(encoded) % 4)
            try:
                raw = base64.urlsafe_b64decode(encoded)
            except Exception:
                raw = base64.b64decode(encoded)
            obj = json.loads(raw.decode("utf-8"))
            host = str(obj.get("add", "")).strip()
            sni = str(obj.get("sni", "")).strip()
            if has_ip_address(host) and not sni:
                return False
            return True
        except Exception:
            return False
    if protocol in ("vless", "trojan"):
        try:
            parsed = urllib.parse.urlsplit(line)
            host = parsed.hostname or ""
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            sni = query.get("sni", [""])[0].strip()
            if has_ip_address(host) and not sni:
                return False
            return True
        except Exception:
            return False
    return True
def copy_links(inbound_type, inbound_tag):
    src_candidates = [
        os.path.join(url_dir, f"{inbound_tag}.txt"),
        os.path.join(url_dir, f"{inbound_type}.txt")
    ]
    src = None
    for candidate in src_candidates:
        if os.path.isfile(candidate):
            src = candidate
            break
    if src is None:
        return 0
    count = 0
    protocol = inbound_type.lower()
    with open(src, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    need_check = protocol in ("vless", "vmess", "trojan")
    filtered_lines = []
    for line in lines:
        if not line.strip():
            continue
        if need_check and not is_valid_connection(line, protocol):
            continue
        filtered_lines.append(line)
    if not filtered_lines:
        return 0
    mode = "a" if os.path.exists(links_file) and os.path.getsize(links_file) > 0 else "w"
    with open(links_file, mode, encoding="utf-8") as out:
        if mode == "a":
            out.write("\n")
        for line in filtered_lines:
            out.write(replace_link(line, protocol) + "\n")
            count += 1
    return count

for item in selected:
    parts = item.split("|", 2)
    if len(parts) != 3:
        raise RuntimeError("入站数据格式错误")
    path, inbound_type, inbound_tag = parts
    add_user_to_config(path, inbound_tag)

try:
    with open(main_config, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
experimental = data.setdefault("experimental", {})
v2ray_api = experimental.setdefault("v2ray_api", {})
v2ray_api.setdefault("listen", "127.0.0.1:9094")
stats = v2ray_api.setdefault("stats", {})
stats.setdefault("enabled", True)
users = stats.setdefault("users", [])
if username not in users:
    users.append(username)
fd, tmp = tempfile.mkstemp(prefix=".singbox-config-", dir=os.path.dirname(main_config))
os.close(fd)
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, os.stat(main_config).st_mode & 0o777)
    os.replace(tmp, main_config)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)

total_links = 0
for item in selected:
    _, inbound_type, inbound_tag = item.split("|", 2)
    total_links += copy_links(inbound_type, inbound_tag)

if os.path.isfile(links_file):
    with open(links_file, "r", encoding="utf-8") as f:
        links_text = f.read().strip()
        
    import urllib.parse
    traffic_state = "/etc/sing-box/user_manager/traffic/state.json"
    limit_dir = "/etc/sing-box/user_manager/limits"
    used = 0
    limit_bytes = 0
    enabled = False
    try:
        with open(traffic_state, "r", encoding="utf-8") as f:
            state = json.load(f)
            used = int(state.get("users", {}).get(username, {}).get("period_total", 0) or 0)
    except Exception:
        pass
    try:
        with open(os.path.join(limit_dir, f"{username}.json"), "r", encoding="utf-8") as f:
            limit_data = json.load(f)
            enabled = bool(limit_data.get("enabled", False))
            limit_bytes = int(limit_data.get("limit_bytes", 0) or 0)
    except Exception:
        pass
    
    def format_b(val):
        try:
            val = float(val)
        except Exception:
            val = 0
        if val >= 1024**3: return f"{val/1024**3:.2f} GB"
        if val >= 1024**2: return f"{val/1024**2:.2f} MB"
        if val >= 1024: return f"{val/1024:.2f} KB"
        return f"{int(val)} B"
        
    if enabled and limit_bytes > 0:
        rem = max(limit_bytes - used, 0)
        remark = f"📊 剩余流量: {format_b(rem)} | 已用: {format_b(used)}"
    else:
        remark = f"📊 剩余流量: 无限制 | 已用: {format_b(used)}"
        
    safe_remark = urllib.parse.quote(remark)
    traffic_line = f"vless://00000000-0000-0000-0000-000000000000@127.0.0.1:10000?encryption=none&security=none&type=tcp#{safe_remark}"
    
    final_text = traffic_line + "\n" + links_text
    with open(sub_file, "wb") as f:
        f.write(base64.b64encode(final_text.encode("utf-8")))
    os.chmod(sub_file, 0o644)
# ==========================================================

def generate_sub_path():
    while True:
        token = secrets.token_urlsafe(18)
        token = re.sub(r'[^A-Za-z0-9-]', '', token)
        if len(token) < 16:
            continue
        location = "/" + token
        duplicated = False
        if os.path.isdir(nginx_user_conf_dir):
            for name in os.listdir(nginx_user_conf_dir):
                if not name.endswith(".conf"):
                    continue
                path = os.path.join(nginx_user_conf_dir, name)
                if not os.path.isfile(path):
                    continue
                try:
                    with open(path, "r", encoding="utf-8", errors="ignore") as f:
                        if f"location = {location}" in f.read():
                            duplicated = True
                            break
                except Exception:
                    continue
        if not duplicated:
            return location

if input_path:
    sub_path = input_path
else:
    sub_path = generate_sub_path()
path_file = os.path.join(user_dir, f"{username}-path")
with open(path_file, "w", encoding="utf-8") as f:
    f.write(sub_path)

nginx_conf = os.path.join(nginx_user_conf_dir, f"{username}.conf")

nginx_content = f"""location = {sub_path} {{
proxy_pass http://127.0.0.1:18080/sub/{username};
proxy_http_version 1.1;
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_no_cache 1;
proxy_cache_bypass 1;
}}"""

with open(nginx_conf, "w", encoding="utf-8") as f:
    f.write(nginx_content)
os.chmod(nginx_conf, 0o644)

result = subprocess.run(["nginx", "-t"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if result.returncode != 0:
    try:
        os.unlink(nginx_conf)
    except Exception:
        pass
    raise RuntimeError("Nginx 配置语法检查失败")

result = subprocess.run(["systemctl", "reload", "nginx"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if result.returncode != 0:
    raise RuntimeError("Nginx reload 失败")
PY
local result=$?
if [ "$result" -eq 0 ]; then
local sub_path_val=""
if [ -f "$URL_DIR/$username/$username-path" ]; then
    sub_path_val=$(cat "$URL_DIR/$username/$username-path")
fi
local current_domain current_port
current_domain=$(grep -iE '^\s*server_name\s+' "$NGINX_MAIN_CONF" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ';')
current_port=$(grep -iE '^\s*listen\s+' "$NGINX_MAIN_CONF" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ';')

green "用户创建成功"
echo
green "用户名：$username"
green "UUID：$uuid"
if [[ -n "$current_domain" && -n "$sub_path_val" ]]; then
    if [[ -n "$current_port" && "$current_port" != "443" ]]; then
        green "订阅链接：https://${current_domain}:${current_port}${sub_path_val}"
    else
        green "订阅链接：https://${current_domain}${sub_path_val}"
    fi
fi
green "用户目录：$URL_DIR/$username"
green "订阅文件：$URL_DIR/$username/$username-sub"
echo
if systemctl is-active --quiet sing-box; then
systemctl reload sing-box >/dev/null 2>&1 || true
fi
read -rp "按回车返回..." _
return
else
red "用户创建失败"
sleep 2
return
fi
done
}



add_inbound_menu() {
    while true; do
        clear
        green "================ 添加入站 ================"
        echo
        green "1. VLESS Reality"
        green "2. Hysteria2"
        green "3. TUIC"
        green "4. HTTP Reality"
        green "5. gRPC Reality"
        green "6. AnyTLS"
        green "7. AnyTLS Reality"
        green "8. SOCKS5"
        green "10. XHTTP Reality"
        green "11. VLESS XHTTP"
     
        green "13. XHTTP UDP TLS"
        green "14. XHTTP TCP+UDP CDN TLS"
        green "15. VLESS TCP TLS"
        green "16. Naiveproxy"
		
        green "18. VMess WS"
        green "19. VLESS WS"
        echo
        green "--------------------------------------------"
        green "0. 返回"
        echo
        read -rp "请选择入站类型: " choice
        case "$choice" in
            1) add_inbound "vless-reality" ;;
            2) add_inbound "hysteria2" ;;
            3) add_inbound "tuic" ;;
            4) add_inbound "http-reality" ;;
            5) add_inbound "grpc-reality" ;;
            6) add_inbound "anytls" ;;
            7) add_inbound "anytls-reality" ;;
            8) add_inbound "socks5" ;;
           
            10) add_inbound "xhttp-reality" ;;
            11) add_inbound "vless-xhttp" ;;
            
            13) add_inbound "xhttp-udp-tls" ;;
            14) add_inbound "xhttp-tcpudp-cdn-tls" ;;
            15) add_inbound "vless-tcp-tls" ;;
            16) add_inbound "naiveproxy" ;;
			
			18) add_inbound "vmess-ws" ;;
            19) add_inbound "vless-ws" ;;
            0) return ;;
            *) red "无效选项"; sleep 1 ;;
        esac
    done
}
add_inbound() {
    local inbound_type="$1"
    local engine="$2"
    local inbound_number
    local config_file
    inbound_number=$(get_next_inbound_number "$inbound_type")
    config_file=$(get_inbound_config_file "$inbound_type" "$inbound_number" "$engine")
    green "================ 添加入站 ================"
    echo
    green "入站类型：${inbound_type}"
    green "自动编号：${inbound_number}"
    green "配置文件：${config_file}"
    green "核心：${engine}"
    echo
    case "$inbound_type" in
        vless-reality)
	generate_vars
    server_ip=$(get_realip)
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-${inbound_number}",
      "listen": "::",
      "listen_port": $xtls_reality,
      "users": [
        {
          "name": "vless-reality-user${inbound_number}",
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        },
		{
          "name": "tttttt",
          "uuid": "$uuid99",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ]
}
EOF
    allow_port "$xtls_reality/tcp" >/dev/null 2>&1
	node_remark="${isp}vless_tcp_reality"
	add_v2ray_api_user "vless-reality-user${inbound_number}"
    url="vless://${uuid}@${server_ip}:${xtls_reality}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${node_remark}"
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
	   hysteria2)
	generate_vars
    server_ip=$(get_realip)
	fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
	echo -e "\n请选择 TLS 证书类型:"
    echo -e " 1) \e[32m使用自签名证书\e[0m"
    echo -e " 2) \e[32m使用真实域名证书\e[0m"
    read -rp "请输入数字 [1-2] (默认 1): " cert_type
    [ -z "$cert_type" ] && cert_type=1
    if [ "$cert_type" -eq 2 ]; then
        if check_and_issue_ssl; then
            cert_path="$cert_file"
            key_path="$key_file"
            url_param="sni=${domain}"
        else
            return 1
        fi
    else
        cert_path="$work_dir/cert.pem"
        key_path="$work_dir/private.key"
        url_param="insecure=1&sni=www.bing.com&pinSHA256=${fingerprint}"
    fi
	cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-${inbound_number}",
      "listen": "::",
      "listen_port": $hy2_port,
	  "bbr_profile": "standard",
      "users": [
        {
		  "name": "hysteria2-user${inbound_number}",
          "password": "$uuid"
        },
		{
		  "name": "tttttt",
          "password": "$uuid99"
        }
      ],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ]
}
EOF
    allow_port "$hy2_port/udp" >/dev/null 2>&1
    node_remark="${isp}hysteria2"
	add_v2ray_api_user "hysteria2-user${inbound_number}"
    url="hysteria2://${uuid}@${server_ip}:${hy2_port}/?${url_param}&alpn=h3#${node_remark}"
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
	;;
        tuic)
	generate_vars
    server_ip=$(get_realip)
    echo -e "\n请选择 TLS 证书类型:"
    echo -e " 1) \e[32m使用自签名证书\e[0m"
    echo -e " 2) \e[32m使用真实域名证书\e[0m"
    read -rp "请输入数字 [1-2] (默认 1): " cert_type
    [ -z "$cert_type" ] && cert_type=1
    if [ "$cert_type" -eq 2 ]; then
        if check_and_issue_ssl; then
            cert_path="$cert_file"
            key_path="$key_file"
            url_param="sni=${domain}"
        else
            return 1
        fi
    else
        cert_path="$work_dir/cert.pem"
        key_path="$work_dir/private.key"
        url_param="insecure=1&sni=www.bing.com"
    fi
	cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-${inbound_number}",
      "listen": "::",
      "listen_port": $tuic_port,
      "users": [
        {
		  "name": "tuic-user${inbound_number}",
          "uuid": "$uuid",
          "password": "$password"
        },
		{
		  "name": "tttttt",
          "uuid": "$uuid99",
          "password": "$password"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ]
}
EOF
    allow_port "$tuic_port/udp" >/dev/null 2>&1
    node_remark="${isp}tuic"
	add_v2ray_api_user "tuic-user${inbound_number}"
    url="tuic://${uuid}:${password}@${server_ip}:${tuic_port}/?${url_param}&congestion_control=bbr&udp_relay_mode=native&alpn=h3#${node_remark}"
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
	;;
        http-reality)
	generate_vars
    server_ip=$(get_realip)
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "http-reality-${inbound_number}",
      "listen": "::",
      "listen_port": $h2_reality,
      "users": [
        {
		  "name": "http-reality-user${inbound_number}",
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      },
      "transport": {
        "type": "http"
      },
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 1000,
          "down_mbps": 1000
        }
      }
    }
  ]
}
EOF
    allow_port "$h2_reality/tcp" >/dev/null 2>&1
	node_remark="${isp}http_reality"
	add_v2ray_api_user "http-reality-user${inbound_number}"
    url="vless://${uuid}@${server_ip}:${h2_reality}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=http#${node_remark}"
	url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
        grpc-reality)
	generate_vars
    server_ip=$(get_realip)
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "grpc-reality-${inbound_number}",
      "listen": "::",
      "listen_port": $grpc_reality,
      "users": [
        {
		  "name": "grpc-reality-user${inbound_number}",
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      },
      "transport": {
        "type": "grpc",
        "service_name": "grpc"
      },
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 200,
          "down_mbps": 200
        }
      }
    }
  ]
}
EOF
    allow_port "$grpc_reality/tcp" >/dev/null 2>&1
	node_remark="${isp}grpc_reality"
	add_v2ray_api_user "grpc-reality-user${inbound_number}"
    url="vless://${uuid}@${server_ip}:${grpc_reality}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=grpc&serviceName=grpc#${node_remark}"
	url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
        anytls)
    generate_vars
    server_ip=$(get_realip)
	fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
    echo -e "\n请选择 TLS 证书类型:"
    echo -e " 1) \e[32m使用自签名证书\e[0m"
    echo -e " 2) \e[32m使用真实域名证书\e[0m"
    read -rp "请输入数字 [1-2] (默认 1): " cert_type
    [ -z "$cert_type" ] && cert_type=1
    if [ "$cert_type" -eq 2 ]; then
        if check_and_issue_ssl; then
            cert_path="$cert_file"
            key_path="$key_file"
            url_param="sni=${domain}"
        else
            return 1
        fi
    else
        cert_path="$work_dir/cert.pem"
        key_path="$work_dir/private.key"
        url_param="insecure=1&sni=www.bing.com&pinSHA256=${fingerprint}"
    fi
    cat > "$config_file" << EOF
{
    "inbounds":[
        {
            "type":"anytls",
            "tag":"anytls-${inbound_number}",
            "listen":"::",
            "listen_port":$anytls_port,
            "users":[
                {
				    "name": "anytls-user${inbound_number}",
                    "password":"$password"
                }
            ],
            "padding_scheme":[
                "stop=6",
                "0=30-50",
                "1=80-400",
                "2=400-500,c,500-1000,c,500-1000",
                "3=9-9,500-1000",
                "4=500-1000",
                "5=500-1000"
            ],
            "tls":{
                "enabled":true,
                "certificate_path":"$cert_path",
                "key_path":"$key_path"
            }
        }
    ]
}
EOF
	allow_port "$anytls_port/tcp" >/dev/null 2>&1
	node_remark="${isp}anytls"
	add_v2ray_api_user "anytls-user${inbound_number}"
    url="anytls://${password}@${server_ip}:${anytls_port}?${url_param}&alpn=h3#${node_remark}"
	url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
        anytls-reality) green "这里接入 AnyTLS Reality 创建逻辑" ;;
        socks5)
    generate_vars
    server_ip=$(get_realip)
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-${inbound_number}",
      "listen": "::",
      "listen_port": $socks_port,
      "users": [
        {
		  "name": "socks${inbound_number}",
          "username": "$username",
          "password": "$password"
        }
      ]
    }
  ]
}
EOF
	node_remark="${isp}socks_port"
	add_v2ray_api_user "socks${inbound_number}"
    url="socks://${username}:${password}@${server_ip}:${socks_port}#${node_remark}"
	url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
        xhttp-reality)
    generate_vars
    server_ip=$(get_realip)
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "xhttp-reality-${inbound_number}",
      "listen": "::",
      "listen_port": $xray_xhttp_reality,
      "users": [
        {
          "name": "xhttp-reality-user${inbound_number}",
          "uuid": "$uuid"
        },
        {
          "name": "tttttt",
          "uuid": "$uuid99"
        }
      ],
      "tls": {
        "enabled": true,
		"server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [
            "$short_id"
          ]
        }
      },
      "transport": {
        "type": "xhttp",
        "mode": "auto",
        "path": "/sssisuiu-xhttp"
      }
    }
  ]
}

EOF
    allow_port "$xray_xhttp_reality/tcp" >/dev/null 2>&1
	node_remark="${isp}vless_xhttp_reality"
	add_v2ray_api_user "xhttp-reality-user${inbound_number}"
    url="vless://${uuid}@${server_ip}:${xray_xhttp_reality}?encryption=none&flow=&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=xhttp&path=/sssisuiu-xhttp&mode=auto#${node_remark}"	
	url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
    vless-xhttp)
    generate_vars
    server_ip=$(get_realip)
    xhttp_path="/$(openssl rand -hex 6)-xhttp"
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-xhttp-${inbound_number}",
      "listen": "::",
      "listen_port": $xhttp_port,
      "users": [
        {
          "name": "vless-xhttp-user${inbound_number}",
          "uuid": "$uuid"
        },
        {
          "name": "tttttt",
          "uuid": "$uuid99"
        }
      ],
      "transport": {
        "type": "xhttp",
        "path": "$xhttp_path"
      }
    }
  ]
}
EOF
    local add_cert
    local xhttp_tls="false"
    reading "是否为此入站添加 TLS 证书？(y/回车跳过): " add_cert
    if [[ "$add_cert" =~ ^[Yy]$ ]]; then
        check_and_issue_ssl "" || return 1
        jq --arg domain "$domain" --arg cert "$cert_file" --arg key "$key_file" \
            '.inbounds[0].tls = {"enabled":true,"server_name":$domain,"certificate_path":$cert,"key_path":$key}' \
            "$config_file" > "${config_file}.tmp" &&
        mv -f "${config_file}.tmp" "$config_file"
        xhttp_tls="true"
    fi
    xhttp_remark="${isp}xhttp"
    if [[ "$xhttp_tls" == "true" ]]; then
        url="vless://${uuid}@${server_ip}:${xhttp_port}?encryption=none&security=tls&sni=${domain}&type=xhttp&path=${xhttp_path}#${node_remark}"
    else
        url="vless://${uuid}@${server_ip}:${xhttp_port}?encryption=none&security=none&type=xhttp&path=${xhttp_path}#${node_remark}"
    fi
    add_v2ray_api_user "vless-xhttp-user${inbound_number}"
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
    update_sub_file
    systemctl reload sing-box
    green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
        xhttp-udp-tls) green "这里接入 XHTTP UDP TLS 创建逻辑" ;;
        xhttp-tcpudp-cdn-tls) green "这里接入 XHTTP TCP+UDP CDN TLS 创建逻辑" ;;
        vless-tcp-tls)
	generate_vars
    server_ip=$(get_realip)
    check_and_issue_ssl || return 1
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-tcp-tls-${inbound_number}",
      "listen": "::",
      "listen_port": $vless_tcp_tls,
      "users": [
        {
		  "name": "vless-tcp-tls-user${inbound_number}",
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${domain:-$server_ip}",
        "certificate_path": "$cert_file",
        "key_path": "$key_file"
      }
    }
  ]
}
EOF
	allow_port "$vless_tcp_tls/tcp" >/dev/null 2>&1
	node_remark="${isp}vless_tcp_tls"
	add_v2ray_api_user "vless_tcp_tls-user${inbound_number}"
    url="vless://${uuid}@${domain:-$server_ip}:${vless_tcp_tls}?encryption=none&security=tls&sni=${domain:-$server_ip}&type=tcp#${node_remark}"
	url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
        naiveproxy)
    check_and_issue_ssl || return 1
    generate_vars
    server_ip=$(get_realip)
    echo ""
    naive_port=$(get_available_port)
    if [[ ! "$naive_port" =~ ^[0-9]+$ ]]; then
        red "获取 Naive 端口失败：${naive_port:-<空>}"
        return 1
    fi
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-${inbound_number}",
      "listen": "::",
      "listen_port": $naive_port,
      "users": [
        {
		  "name": "naive-user${inbound_number}",
          "username": "$uuid",
          "password": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$cert_file",
        "key_path": "$key_file"
      }
    }
  ]
}
EOF
	allow_port "$naive_port/tcp" >/dev/null 2>&1
    allow_port "$naive_port/udp" >/dev/null 2>&1
    node_remark_h2="${isp}naive_h2"
    node_remark_h3="${isp}naive_h3"
    naive_server="${domain:-$server_ip}"
    NAIVE_H2_URL="naive+https://${uuid}:${uuid}@${naive_server}:${naive_port}?security=tls&sni=${naive_server}&insecure=0#${node_remark_h2}"
    NAIVE_H3_URL="naive+quic://${uuid}:${uuid}@${naive_server}:${naive_port}?congestion_control=bbr&security=tls&sni=${naive_server}&insecure=0#${node_remark_h3}"
	add_v2ray_api_user "naive-user${inbound_number}"
	url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    {
      echo "$NAIVE_H2_URL"
	  echo
      echo "$NAIVE_H3_URL"
    } > "$url_file" 
	update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green "节点链接："
	green  "$NAIVE_H2_URL"
    echo
	red  "$NAIVE_H3_URL"
    green "--------------------------------------------------"
    ;;
        vmess-ws)
	generate_vars
    server_ip=$(get_realip)
    vmess_path="/$(openssl rand -hex 6)-ws"
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-${inbound_number}",
      "listen": "::",
      "listen_port": $vmess_ws_port,
      "users": [
        {
          "name": "vmess-ws-user${inbound_number}",
          "uuid": "$uuid"
        },
		{
          "name": "tttttt",
          "uuid": "$uuid99"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$vmess_path",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF
    local add_cert
    local vmess_tls="false"
    reading "是否为此入站添加 TLS 证书？(y/回车跳过): " add_cert
    if [[ "$add_cert" =~ ^[Yy]$ ]]; then
        check_and_issue_ssl "" || return 1
        jq --arg domain "$domain" --arg cert "$cert_file" --arg key "$key_file" \
            '.inbounds[0].tls = {"enabled":true,"server_name":$domain,"certificate_path":$cert,"key_path":$key}' \
            "$config_file" > "${config_file}.tmp" &&
        mv -f "${config_file}.tmp" "$config_file"
        vmess_tls="true"
    fi
    vmess_remark="${isp}vmess_ws"
    if [[ "$vmess_tls" == "true" ]]; then
        VMESS="{ \"v\": \"2\", \"ps\": \"${vmess_remark}\", \"add\": \"${server_ip}\", \"port\": \"${vmess_ws_port}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"encryption\": \"auto\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"${domain}\", \"path\": \"${vmess_path}\", \"tls\": \"tls\", \"sni\": \"${domain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": false }"
    else
        VMESS="{ \"v\": \"2\", \"ps\": \"${vmess_remark}\", \"add\": \"${server_ip}\", \"port\": \"${vmess_ws_port}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"encryption\": \"auto\", \"net\": \"ws\", \"type\": \"auto\", \"path\": \"${vmess_path}\" }"
    fi
    url="vmess://$(echo -n "$VMESS" | base64 -w0)"
    add_v2ray_api_user "vmess-ws-user${inbound_number}"
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file" 
    update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
	vless-ws)
	generate_vars
    server_ip=$(get_realip)
    vless_path="/$(openssl rand -hex 6)-ws"
    cat > "$config_file" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-${inbound_number}",
      "listen": "::",
      "listen_port": $vless_ws_port,
      "users": [
        {
          "name": "vless-ws-user${inbound_number}",
          "uuid": "$uuid"
        },
		{
          "name": "tttttt",
          "uuid": "$uuid99"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$vless_path",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF
    local add_cert
    local vless_tls="false"
    reading "是否为此入站添加 TLS 证书？(y/回车跳过): " add_cert
    if [[ "$add_cert" =~ ^[Yy]$ ]]; then
        check_and_issue_ssl "" || return 1
        jq --arg domain "$domain" --arg cert "$cert_file" --arg key "$key_file" \
            '.inbounds[0].tls = {"enabled":true,"server_name":$domain,"certificate_path":$cert,"key_path":$key}' \
            "$config_file" > "${config_file}.tmp" &&
        mv -f "${config_file}.tmp" "$config_file"
        vmess_tls="true"
    fi
    vless_remark="${isp}vless_ws"
    if [[ "$vless_tls" == "true" ]]; then
    url="vless://${uuid}@${server_ip}:${vless_ws_port}?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=tls&sni=${domain}&type=ws&path=/asasbsbs-vless?ed=2048#${node_remark}"
    else
    url="vless://${uuid}@${server_ip}:${vless_ws_port}?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=none&type=ws&path=/asasbsbs-vless?ed=2048#${node_remark}"
    fi
    add_v2ray_api_user "vless-ws-user${inbound_number}"
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    echo "$url" > "$url_file"
    update_sub_file
    systemctl reload sing-box
	green "--------------------------------------------------"
    green " 节点链接: "
    green "$url"
    green "--------------------------------------------------"
    ;;
        *) red "未知入站类型" ;;
    esac
    echo
    read -rp "按回车返回..." _
}
hy2_port_hopping_enabled() {
    local inbound_number="$1"
    local hop_comment="Hysteria2_Hop_${inbound_number}"
    if nft list chain ip hysteria_nat prerouting >/dev/null 2>&1; then
        if nft -a list chain ip hysteria_nat prerouting 2>/dev/null | grep -Fq "comment \"$hop_comment\""; then
            return 0
        fi
    fi
    if [ -f /proc/net/if_inet6 ] && nft list chain ip6 hysteria_nat prerouting >/dev/null 2>&1; then
        if nft -a list chain ip6 hysteria_nat prerouting 2>/dev/null | grep -Fq "comment \"$hop_comment\""; then
            return 0
        fi
    fi
    return 1
}
hy2_obfs_enabled() {
    local config_file="$1"
    local inbound_type="$2"
    local inbound_number="$3"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    if command -v jq >/dev/null 2>&1; then
        if jq -e '.inbounds[0].obfs.type == "gecko"' "$config_file" >/dev/null 2>&1; then
            return 0
        fi
    fi
    if [ -f "$url_file" ] && grep -qE '(^|[?&])obfs=gecko(&|$)' "$url_file"; then
        return 0
    fi
    return 1
}
manage_hy2_port_hopping_menu() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    while true; do
        clear
        green "================ 端口跳跃管理 ================"
        echo
        green "入站：${inbound_type}-${inbound_number}"
        echo
        if hy2_port_hopping_enabled "$inbound_number"; then
            green "当前状态：已开启"
            echo
            green "1. 修改端口跳跃"
            red "2. 关闭端口跳跃"
        else
            yellow "当前状态：未开启"
            echo
            green "1. 开启端口跳跃"
        fi
        echo
        green "--------------------------------------------"
        green "0. 返回"
        echo
        read -rp "请选择: " choice
        case "$choice" in
            1)
                hy2_port_hopping "$config_file" "$engine" "$inbound_type" "$inbound_number"
                ;;
            2)
                if hy2_port_hopping_enabled "$inbound_number"; then
                    disable_hy2_port_hopping "$config_file" "$engine" "$inbound_type" "$inbound_number"
                else
                    red "无效选项"
                    sleep 1
                fi
                ;;
            0)
                return
                ;;
            *)
                red "无效选项"
                sleep 1
                ;;
        esac
    done
}
manage_hy2_obfs_menu() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    while true; do
        clear
        green "================ Hysteria2 混淆管理 ================"
        echo
        green "入站：${inbound_type}-${inbound_number}"
        echo
        if hy2_obfs_enabled "$config_file" "$inbound_type" "$inbound_number"; then
            green "当前状态：已开启"
            echo
            green "1. 重新生成混淆"
            red "2. 关闭混淆"
        else
            yellow "当前状态：未开启"
            echo
            green "1. 开启混淆"
        fi
        echo
        green "--------------------------------------------"
        green "0. 返回"
        echo
        read -rp "请选择: " choice
        case "$choice" in
            1)
                modify_hy2_obfs "$config_file" "$engine" "$inbound_type" "$inbound_number"
                ;;
            2)
                if hy2_obfs_enabled "$config_file" "$inbound_type" "$inbound_number"; then
                    disable_hy2_obfs "$config_file" "$engine" "$inbound_type" "$inbound_number"
                else
                    red "无效选项"
                    sleep 1
                fi
                ;;
            0)
                return
                ;;
            *)
                red "无效选项"
                sleep 1
                ;;
        esac
    done
}
format_bytes() {
    local bytes="${1:-0}"
    "$PYTHON" - "$bytes" <<'PY'
import sys
try:
    n = int(float(sys.argv[1]))
except:
    n = 0
units = ["B", "KB", "MB", "GB", "TB", "PB"]
i = 0
v = float(n)
while v >= 1024 and i < len(units) - 1:
    v /= 1024
    i += 1
if i == 0:
    print(f"{int(v)} {units[i]}")
elif v >= 100:
    print(f"{v:.0f} {units[i]}")
elif v >= 10:
    print(f"{v:.1f} {units[i]}")
else:
    print(f"{v:.2f} {units[i]}")
PY
}
get_user_traffic() {
    local user="$1"
    if [ ! -f "$TRAFFIC_STATE" ]; then
        echo "0 0 0 0 0 0 0"
        return
    fi
    "$PYTHON" - "$TRAFFIC_STATE" "$user" <<'PY'
import sys
import json
fn = sys.argv[1]
user = sys.argv[2]
try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("0 0 0 0 0 0 0")
    raise SystemExit
d = data.get("users", {}).get(user, {})
uplink = int(d.get("uplink", 0) or 0)
downlink = int(d.get("downlink", 0) or 0)
total = int(d.get("total", uplink + downlink) or 0)
connections = int(d.get("connections", 0) or 0)
period_uplink = int(d.get("period_uplink", 0) or 0)
period_downlink = int(d.get("period_downlink", 0) or 0)
period_total = int(d.get("period_total", period_uplink + period_downlink) or 0)
print(uplink, downlink, total, connections, period_uplink, period_downlink, period_total)
PY
}
show_limit() {
    local username="$1"
    if [ -z "$username" ]; then
        echo "流量限制：未设置        流量周期：未设置"
        echo "已用流量：未统计        流量状态：正常"
        return
    fi
    local limit_file=""
    local file
    local file_user
    for file in "$LIMIT_DIR"/*.json; do
        [ -f "$file" ] || continue
        file_user=$(jq -r '.user // empty' "$file" 2>/dev/null)
        if [ "$file_user" = "$username" ]; then
            limit_file="$file"
            break
        fi
    done
    if [ -z "$limit_file" ]; then
        echo "流量限制：未设置        流量周期：未设置"
        echo "已用流量：未统计        流量状态：正常"
        return
    fi
    local enabled
    local limit_bytes
    local period
    local disabled_by_limit
    local used=0
    enabled=$(jq -r '.enabled // false' "$limit_file" 2>/dev/null)
    limit_bytes=$(jq -r '.limit_bytes // 0' "$limit_file" 2>/dev/null)
    period=$(jq -r '.period // "none"' "$limit_file" 2>/dev/null)
    disabled_by_limit=$(jq -r '.disabled_by_limit // false' "$limit_file" 2>/dev/null)
    if [ -f "$TRAFFIC_STATE" ]; then
        used=$(jq -r --arg u "$username" '.users[$u].period_total // 0' "$TRAFFIC_STATE" 2>/dev/null)
    fi
    if ! [[ "$used" =~ ^[0-9]+$ ]]; then
        used=0
    fi
    local period_cn
    case "$period" in
        day|daily)
            period_cn="每天"
            ;;
        month|monthly)
            period_cn="每月"
            ;;
        *)
            period_cn="未设置"
            ;;
    esac
    if [ "$enabled" != "true" ] || [ "$limit_bytes" -le 0 ] 2>/dev/null; then
        echo "流量限制：未设置        流量周期：未设置"
        printf "已用流量：%-12s " "$(format_bytes "$used")"
        green "流量状态：正常"
        return
    fi
    printf "流量限制：%-12s    流量周期：%s\n" "$(format_bytes "$limit_bytes")" "$period_cn"
    printf "已用流量：%-12s    " "$(format_bytes "$used")"
    if [ "$disabled_by_limit" = "true" ]; then
        red "流量状态：已停用"
    else
        green "流量状态：正常"
    fi
}

manage_single_inbound() {
    local selected="$1"
    local config_file=""
    local engine=""
    local inbound_type=""
    local inbound_number=""
    local traffic_user=""
    IFS='|' read -r config_file inbound_type inbound_number <<< "$selected"
    traffic_user="${inbound_type}-user${inbound_number}"
	while true; do
        clear
        green "================= 入站管理 ================="
        echo
        green "入站：${inbound_type}-${inbound_number}"
        green "类型：${inbound_type}"
        green "路径：${config_file}"
        echo
        echo -e "${skyblue}流量统计${re}"
        if [ -f "$TRAFFIC_STATE" ] && [ -n "$traffic_user" ]; then
            local traffic
            traffic="$(get_user_traffic "$traffic_user")"
            local uplink
            local downlink
            local total
            local connections
            local period_uplink
            local period_downlink
            local period_total
            read -r uplink downlink total connections period_uplink period_downlink period_total <<< "$traffic"
            printf "上传：%-18s 总流量：%s\n" "$(format_bytes "$uplink")" "$(format_bytes "$total")"
            printf "下载：%-18s 本周期：%s\n" "$(format_bytes "$downlink")" "$(format_bytes "$period_total")"
        else
            echo "上传：未统计          总流量：未统计"
            echo "下载：未统计          本周期：未统计"
        fi
        echo -e "${skyblue}流量限制${re}"
        show_limit "$traffic_user"
        green "-------------------------------------------"
        red "s. 删除入站"
        green "1. 修改UUID"
        green "2. 修改端口"
        green "3. 流量限制"
        green "4. 查看链接"
        green "5. 查看配置"
        case "$inbound_type" in
            vless-reality|grpc-reality|xhttp-reality)
                green "6. 修改 Reality 域名"
                ;;
            hysteria2)
                if hy2_port_hopping_enabled "$inbound_number"; then
                    green "7. 端口跳跃（已开启）"
                else
                    yellow "7. 端口跳跃（未开启）"
                fi
                if hy2_obfs_enabled "$config_file" "$inbound_type" "$inbound_number"; then
                    green "8. 混淆（已开启）"
                else
                    yellow "8. 混淆（未开启）"
                fi
                ;;
			vless-xhttp)
                green "6. 开启CDN"
                ;;
            vless-ws|vmess-ws|trojan-ws)
                green "6. 开启CDN"
                green "7. 开启隧道"
                ;;
        esac
        echo
        green "-------------------------------------------"
        green "0. 返回"
        echo
        read -rp "请选择: " choice
        case "$choice" in
            s|S)
                if delete_inbound "$config_file" "$engine" "$inbound_type" "$inbound_number"; then
                    return
                fi
                ;;
            1)
                modify_inbound_uuid "$config_file" "$engine" "$inbound_type" "$inbound_number" "$traffic_user"
                ;;
            2)
                modify_inbound_port "$config_file" "$engine" "$inbound_type" "$inbound_number"
                ;;
            3)
                bash /etc/sing-box/sing-box-name.sh "$traffic_user"
                ;;
            4)
                show_inbound_url "$inbound_type" "$inbound_number"
                ;;
    5)
        show_inbound_config "$config_file"
        ;;
    6)
        case "$inbound_type" in
        vless-reality|grpc-reality|xhttp-reality)
            modify_reality_domain "$config_file" "$engine" "$inbound_type" "$inbound_number"
            ;;
        vless-ws|vmess-ws|trojan-ws|vless-xhttp)
            enable_ws_cdn "$config_file" "$engine" "$inbound_type" "$inbound_number"
            ;;
        *)
            red "当前入站没有此功能"
            sleep 1
            ;;
    esac
    ;;
       
    7)
    case "$inbound_type" in
        vless-ws|vmess-ws|trojan-ws)
            enable_ws_argo "$config_file" "$engine" "$inbound_type" "$inbound_number"
            ;;
        *)
            red "当前入站没有此功能"
            sleep 1
            ;;
    esac
    ;;
0)
    return
    ;;
*)
    red "无效选项"
    sleep 1
    ;;
esac
done
}
manage_single_user() {
    local username="$1"
    while true; do
        clear
        green "================ 用户管理 ================"
        echo
        green "用户：${username}"
        echo
echo -e "${skyblue}流量统计${re}"
local traffic=""
local uplink=""
local downlink=""
local total=""
local period_total=""
if [ -f "$TRAFFIC_STATE" ]; then
    traffic="$(get_user_traffic "$username" 2>/dev/null)"
    read -r uplink downlink total _ _ _ period_total <<< "$traffic"
fi
if [ -n "$total" ]; then
    printf "上传：%-18s 总流量：%s\n" \
        "$(format_bytes "$uplink")" \
        "$(format_bytes "$total")"
    printf "下载：%-18s 本周期：%s\n" \
        "$(format_bytes "$downlink")" \
        "$(format_bytes "$period_total")"
else
    echo "上传：未统计          总流量：未统计"
    echo "下载：未统计          本周期：未统计"
fi

echo -e "${skyblue}流量限制${re}"
show_limit "$username"
        green "---------------- 用户协议 ----------------"
local user_protocols=()
local protocol_file
local protocol_tag
local protocol_type
local protocol_found
shopt -s nullglob
for protocol_file in "$CONF_DIR"/*.json; do
    [ -f "$protocol_file" ] || continue
    [ "$(basename "$protocol_file")" = "config.json" ] && continue
    protocol_found=$(python3 - "$protocol_file" "$username" <<'PY'
import json
import sys
from pathlib import Path
try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    username = sys.argv[2]
    for inbound in data.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue
        for user in inbound.get("users", []):
            if isinstance(user, dict) and user.get("name") == username:
                print(inbound.get("tag", ""))
                raise SystemExit
except Exception:
    pass
PY
)
    [ -n "$protocol_found" ] || continue
    protocol_tag="$protocol_found"
    if [[ ! " ${user_protocols[*]} " =~ " ${protocol_tag} " ]]; then
        user_protocols+=("$protocol_tag")
    fi
done
shopt -u nullglob
if [ ${#user_protocols[@]} -eq 0 ]; then
    echo "暂无协议"
else
    local protocol_index=1
    for protocol_tag in "${user_protocols[@]}"; do
        echo "${protocol_index}. ${protocol_tag}"
        protocol_index=$((protocol_index + 1))
    done
fi
echo
        green "------------------------------------------"
        red "s. 删除用户"
        green "1. 流量限制"
        green "2. 查看订阅连接"
		green "3. 重新添加协议"
        echo
        green "------------------------------------------"
        green "0. 返回"
        echo
        read -rp "请选择: " choice
        case "$choice" in
            s|S)
               delete_user "$username"
               local result=$?
               [ "$result" -eq 2 ] && return
               ;;
			1)
               bash /etc/sing-box/sing-box-name.sh "$username"
               ;;
            2)
        green "================ 订阅连接 ================"
        echo
        local user_dir="/etc/sing-box/url/$username"
        local links_file="$user_dir/$username"
        local sub_file="$user_dir/$username-sub"
        local path_file="$user_dir/$username-path"
        local nginx_user_conf="/etc/nginx/conf.d/singbox_users/$username.conf"
        local NGINX_MAIN_CONF="/etc/nginx/conf.d/singbox_sub.conf"
        if [ ! -f "$links_file" ] || [ ! -f "$sub_file" ] || [ ! -f "$nginx_user_conf" ]; then
            red "订阅文件或 Nginx 用户配置不存在"
            sleep 1
            continue
        fi
        local sub_path=""
        if [ -f "$path_file" ]; then
            sub_path=$(cat "$path_file")
        else
            sub_path=$(sed -n 's/^[[:space:]]*location = \([^ ]*\) {.*/\1/p' "$nginx_user_conf" | head -1)
        fi
        if [ -z "$sub_path" ]; then
            red "无法读取订阅路径配置"
            sleep 1
            continue
        fi
        local current_domain="" current_port="" subscription_url="" formatted_domain=""
        if [ -f "$NGINX_MAIN_CONF" ]; then
            current_domain=$(grep -iE '^\s*server_name\s+' "$NGINX_MAIN_CONF" 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ';')
            current_port=$(grep -iE '^\s*listen\s+' "$NGINX_MAIN_CONF" 2>/dev/null | head -n 1 | grep -oE '[0-9]+' | head -n 1)
        fi
        if [ -z "$current_domain" ] || [ "$current_domain" == "_" ]; then
            red "错误: 未能在 $NGINX_MAIN_CONF 中找到有效的 server_name"
            sleep 2
            continue
        fi
        if [[ "$current_domain" == *:* && "$current_domain" != [*]* ]]; then
            formatted_domain="[${current_domain}]"
        else
            formatted_domain="$current_domain"
        fi
        current_port=${current_port:-443}
        if [[ "$current_port" != "443" ]]; then
            subscription_url="https://${formatted_domain}:${current_port}${sub_path}"
        else
            subscription_url="https://${formatted_domain}${sub_path}"
        fi
        green "节点连接："
        echo
        cat "$links_file"
        echo
		green "订阅地址："
        echo
        green "$subscription_url"
        echo
        read -rp "按回车返回..."
        ;;
		3)
    local user_dir="/etc/sing-box/url/$username"
    local uuid_file="$user_dir/${username}-uuid"
    local path_file="$user_dir/${username}-path"
    if [ ! -f "$uuid_file" ]; then
        red "用户 UUID 文件不存在"
        sleep 1
        continue
    fi
    if [ ! -f "$path_file" ]; then
        red "用户订阅路径文件不存在"
        sleep 1
        continue
    fi
    local old_username
    local old_uuid
    local old_path
    old_username=$(sed -n '1p' "$uuid_file" | tr -d '[:space:]')
    old_uuid=$(sed -n '2p' "$uuid_file" | tr -d '[:space:]')
    old_path=$(cat "$path_file" | tr -d '[:space:]')
    if [ -z "$old_username" ] || [ -z "$old_uuid" ] || [ -z "$old_path" ]; then
        red "无法完整读取用户信息"
        sleep 1
        continue
    fi
	delete_user "$old_username" 1 1
    add_user_menu "$old_username" "$old_uuid" "$old_path"
    ;;
        0)
        return
        ;;
            *)
                red "无效选项"
                sleep 1
                ;;
        esac
    done
}
show_inbound_config() {
    local config_file="$1"
    local config_content=""
    clear
    green "================ 入站配置 ================"
    echo
    if [ -f "$config_file" ]; then
        if command -v jq >/dev/null 2>&1; then
            config_content=$(jq . "$config_file")
        else
            config_content=$(cat "$config_file")
        fi
        echo
        purple "$config_content"
        echo
    else
        red "配置文件不存在"
    fi
    echo
    read -rp "按回车返回..." _
}
show_inbound_url() {
    local inbound_type="$1"
    local inbound_number="$2"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local nginx_conf="/etc/nginx/conf.d/sing-box.conf"
    local domain_conf="/etc/nginx/conf.d/sing-box1.conf"
    local found_any=false
    local line=""
    local sub_domain=""
    local sub_port=""
    local sub_path=""
    local domain_url=""
    local server_ip=""
    local lujing=""
    local base64_url=""
    green "================ 节点连接 ================"
    echo
    green "入站：${inbound_type}-${inbound_number}"
    echo	
	if [ -f "$url_file" ]; then
    echo
    purple "$(cat "$url_file")"
    echo
    else
    red "对应链接文件不存在"
    fi
    green "================ 订阅链接 ================"
    echo
    if [ -f "$domain_conf" ]; then
        sub_domain=$(sed -n 's/^\s*server_name\s\+\([^;]\+\);.*/\1/p' "$domain_conf" | tr -d ' ')
        sub_port=$(sed -n 's/^\s*listen\s\+\([0-9]\+\).*/\1/p' "$domain_conf" | head -n 1)
        sub_path=$(sed -n 's|.*location = /\([^ {]*\).*|\1|p' "$domain_conf")
        if [ -n "$sub_domain" ] && [ "$sub_domain" != "_" ] && [ -n "$sub_port" ] && [ -n "$sub_path" ]; then
            domain_url="https://${sub_domain}:${sub_port}/${sub_path}"
            green "订阅链接: ${purple}${domain_url}${re}"
            found_any=true
        fi
    fi
    if [ -f "$nginx_conf" ]; then
        server_ip=$(get_realip)
        lujing=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "$nginx_conf")
        sub_port=$(sed -n 's/^\s*listen \([0-9]\+\);/\1/p' "$nginx_conf" | head -n 1)
        if [ -n "$server_ip" ] && [ -n "$sub_port" ] && [ -n "$lujing" ]; then
            base64_url="http://${server_ip}:${sub_port}/${lujing}"
            green "订阅链接: ${purple}${base64_url}${re}"
            found_any=true
        fi
    fi
    if [ "$found_any" = false ]; then
        red "订阅服务未配置或订阅已关闭"
    fi
    echo
    read -rp "按回车返回..." _
}
edit_inbound() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    clear
    green "================ 修改入站 ================"
    echo
    green "入站：${inbound_type}-${inbound_number}"
    green "核心：${engine}"
    green "配置：${config_file}"
    echo
    yellow "这里后续接入对应入站的修改逻辑"
    echo
    read -rp "按回车返回..." _
}
delete_user_traffic_data() {
    local username="$1"
    [ -n "$username" ] || return 0
    local state_file="/etc/sing-box/user_manager/traffic/state.json"
    local limit_file="/etc/sing-box/user_manager/limits/${username}.json"
    if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
        local tmp_file
        tmp_file=$(mktemp)
        if jq --arg u "$username" '
            del(.users[$u]) |
            del(.stats_counters[$u]) |
            del(.connections[$u])
        ' "$state_file" > "$tmp_file"; then
            chmod 600 "$tmp_file"
            mv -f "$tmp_file" "$state_file"
        else
            rm -f "$tmp_file"
            red "删除 ${username} 的流量数据失败"
            return 1
        fi
    fi
    rm -f "$limit_file"
    return 0
}
delete_inbound() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local inbound_port=""
    local v2ray_api_user=""
	local cdn_domain=""

    echo
    red "确定删除 ${inbound_type}-${inbound_number}？"
    green "配置文件：${config_file}"
    green "链接文件：${url_file}"
    echo
    read -rp "输入 y 确认删除: " confirm
    [ "$confirm" = "y" ] || return 1
    if [ ! -f "$config_file" ]; then
        red "错误：配置文件不存在，删除取消。"
        sleep 1
        return 1
    fi
	case "$inbound_type" in
    vless-ws|vmess-ws|trojan-ws|vless-xhttp)
        cdn_domain=$(get_inbound_cdn_domain "$inbound_type" "$inbound_number")
        if [[ -n "$cdn_domain" ]]; then
            reading "检测到此入站存在 CDN：${cdn_domain}，是否同时删除 CDN 回源规则和 DNS 记录？(y/N): " delete_cdn
            if [[ "$delete_cdn" =~ ^[Yy]$ ]]; then
                cf_remove_cdn_rules "$cdn_domain"
            fi
        fi
        ;;
    esac
    if command -v jq >/dev/null 2>&1; then
    v2ray_api_user=$(jq -r '.. | objects | .name? // empty' "$config_file" 2>/dev/null | head -n1)
    fi

    if command -v jq >/dev/null 2>&1; then
        inbound_port=$(jq -r '.. | objects | select(has("listen_port")) | .listen_port' "$config_file" 2>/dev/null | head -n1)
    fi
    if [ -z "$inbound_port" ] || [ "$inbound_port" = "null" ]; then
        inbound_port=$(grep -m1 '"listen_port"' "$config_file" 2>/dev/null | tr -cd '0-9')
    fi
    if [ "$inbound_type" = "hysteria2" ]; then
        if nft list chain ip nat prerouting &>/dev/null; then
            for handle in $(nft -a list chain ip nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                nft delete rule ip nat prerouting handle "$handle" 2>/dev/null
            done
        fi
        if [ -f /proc/net/if_inet6 ] && nft list chain ip6 nat prerouting &>/dev/null; then
            for handle in $(nft -a list chain ip6 nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                nft delete rule ip6 nat prerouting handle "$handle" 2>/dev/null
            done
        fi
    fi
    if [ -n "$inbound_port" ] && [ "$inbound_port" != "443" ]; then
        if nft list chain inet filter input &>/dev/null; then
            for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$inbound_port" '$0 ~ "dport "p {print $NF}'); do
                nft delete rule inet filter input handle "$handle" 2>/dev/null
            done
        fi
        nft list ruleset > /etc/nftables.conf 2>/dev/null
    fi
    rm -f "$config_file"
    rm -f "$url_file"
    if [ -n "$v2ray_api_user" ]; then
    delete_v2ray_api_user "$v2ray_api_user"
    if ! delete_user_traffic_data "$v2ray_api_user"; then
        red "警告：${v2ray_api_user} 的流量数据清理失败"
    fi
    fi
    update_sub_file
    systemctl reload sing-box
    green "==============================================="
    green " 入站已移除：${inbound_type}-${inbound_number}"
    green "==============================================="
    echo
    sleep 1
    return 0
}

delete_user() {
    local username="$1"
	local force_delete="${2:-0}"
    local preserve_data="${3:-0}"
    if [ -z "$username" ]; then
        red "错误：用户名不能为空"
        sleep 1
        return 1
    fi
    if [[ "$force_delete" != "1" ]]; then
    echo
    red "确定删除用户：${username}？"
    yellow "会从所有入站中删除该用户。"
    yellow "入站配置文件本身不会删除。"
    echo
    read -rp "输入 y 确认删除: " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || return 1
    fi
    if ! [[ "$username" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        red "错误：用户名格式无效"
        sleep 1
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        red "错误：系统没有 python3"
        sleep 1
        return 1
    fi
 
   python3 - "$CONF_DIR" "$TRAFFIC_STATE" "$LIMIT_DIR" "$URL_DIR" "$username" "$preserve_data" <<'PY'
import json
import sys
import shutil
from pathlib import Path
conf_dir = Path(sys.argv[1])
traffic_state = Path(sys.argv[2])
limit_dir = Path(sys.argv[3])
url_dir = Path(sys.argv[4])
username = sys.argv[5]
preserve_data = sys.argv[6] == "1"
def atomic_write(path, data):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8"
    )
    tmp.chmod(0o600)
    tmp.replace(path)
deleted_from_inbounds = 0
for fn in sorted(conf_dir.glob("*.json")):
    if fn.name == "config.json":
        continue
    try:
        cfg = json.loads(fn.read_text(encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(cfg, dict):
        continue
    changed = False
    for inbound in cfg.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue
        users = inbound.get("users")
        if not isinstance(users, list):
            continue
        new_users = []
        for user in users:
            if isinstance(user, dict) and user.get("name") == username:
                deleted_from_inbounds += 1
                changed = True
            else:
                new_users.append(user)
        if changed:
            inbound["users"] = new_users
    if changed:
        try:
            atomic_write(fn, cfg)
        except Exception:
            pass
config_file = conf_dir / "config.json"
if config_file.exists():
    try:
        cfg = json.loads(config_file.read_text(encoding="utf-8"))
        changed = False
        experimental = cfg.get("experimental")
        if isinstance(experimental, dict):
            v2ray_api = experimental.get("v2ray_api")
            if isinstance(v2ray_api, dict):
                stats = v2ray_api.get("stats")
                if isinstance(stats, dict):
                    users = stats.get("users")
                    if isinstance(users, list):
                        new_users = [u for u in users if u != username]
                        if new_users != users:
                            stats["users"] = new_users
                            changed = True
        if changed:
            atomic_write(config_file, cfg)
    except Exception:
        pass
if not preserve_data and traffic_state.exists():
    try:
        state = json.loads(traffic_state.read_text(encoding="utf-8"))
        if isinstance(state, dict):
            changed = False
            users = state.get("users")
            if isinstance(users, dict) and username in users:
                del users[username]
                changed = True

            counters = state.get("stats_counters")
            if isinstance(counters, dict) and username in counters:
                del counters[username]
                changed = True

            if changed:
                atomic_write(traffic_state, state)
    except Exception:
        pass
if not preserve_data:
    limit_file = limit_dir / f"{username}.json"
    try:
        if limit_file.exists():
            limit_file.unlink()
    except Exception:
        pass
user_dir = url_dir / username
try:
    if user_dir.exists() and user_dir.is_dir():
        shutil.rmtree(user_dir)
except Exception:
    pass
nginx_conf = Path("/etc/nginx/conf.d/singbox_users") / f"{username}.conf"
try:
    if nginx_conf.exists():
        nginx_conf.unlink()
except Exception:
    pass
print(deleted_from_inbounds)
PY
    local result=$?
    if [ "$result" -ne 0 ]; then
        red "删除用户失败"
        sleep 1
        return 1
    fi
    systemctl reload sing-box >/dev/null 2>&1
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1
        fi
    fi
    update_sub_file
    if [[ "$force_delete" != "1" ]]; then
    green "==============================================="
    green " 用户已删除：${username}"
    green "==============================================="
    echo
    sleep 1
    fi
	return 2
}
