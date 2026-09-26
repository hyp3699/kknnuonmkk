#!/bin/bash
set -e
umask 077
CENTRAL_IP="${1:-}"
TOKEN="${2:-}"
SSH_PUBLIC_KEY="${3:-}"
CENTRAL_URL="http://${CENTRAL_IP}:18089/api/register"
WG_INTERFACE=central-mgmt
WG_NETWORK=10.231.47
WG_ADDRESS_PREFIX=24
WG_SERVER_ADDRESS=10.231.47.1
WG_DIR=/etc/wireguard
WG_CONFIG=$WG_DIR/central-mgmt.conf
WG_PRIVATE_KEY=$WG_DIR/central-mgmt-privatekey
AGENT_DIR=/etc/central-vps-agent
AGENT_TOKEN_FILE=$AGENT_DIR/token
AGENT_ADDRESS_FILE=$AGENT_DIR/address
AGENT_SCRIPT=/usr/local/bin/central-vps-agent.py
AGENT_MENU=/usr/local/bin/central-vps-agent-menu
AGENT_SERVICE=central-vps-agent.service
AGENT_PORT=18090
[ -n "$CENTRAL_IP" ] || {
    echo "缺少中央 VPS IP"
    exit 1
}
[ -n "$TOKEN" ] || {
    echo "缺少注册码"
    exit 1
}
[ -n "$SSH_PUBLIC_KEY" ] || {
    echo "缺少SSH 公钥"
    exit 1
}
command -v curl >/dev/null 2>&1 || {
    echo "未安装 curl"
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    echo "未安装 python3"
    exit 1
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
get_ipv4() {
    curl -4 -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        https://api.ipify.org \
        2>/dev/null || true
}
get_ipv6() {
    curl -6 -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        https://api64.ipify.org \
        2>/dev/null || true
}
get_country() {
    local ip="$1"
    [ -n "$ip" ] || return
    curl -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        "https://ipapi.co/$ip/country_name/" \
        2>/dev/null || true
}
install_wireguard
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"
mkdir -p "$AGENT_DIR"
chmod 700 "$AGENT_DIR"
install_ssh_key() {
    local ssh_dir="/root/.ssh"
    local authorized_keys="$ssh_dir/authorized_keys"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$authorized_keys"
    chmod 600 "$authorized_keys"
    if ! grep -qxF "$SSH_PUBLIC_KEY" "$authorized_keys" 2>/dev/null; then
        printf '%s\n' "$SSH_PUBLIC_KEY" >> "$authorized_keys"
    fi
}
install_ssh_key
printf '%s\n' "$SSH_PUBLIC_KEY" > "$AGENT_DIR/ssh_public_key"
chmod 600 "$AGENT_DIR/ssh_public_key"
if [ ! -f "$WG_PRIVATE_KEY" ]; then
    wg genkey > "$WG_PRIVATE_KEY"
    chmod 600 "$WG_PRIVATE_KEY"
fi
PRIVATE_KEY=$(cat "$WG_PRIVATE_KEY")
PUBLIC_KEY=$(printf '%s' "$PRIVATE_KEY" | wg pubkey)
if [ ! -s "$AGENT_TOKEN_FILE" ]; then
    python3 - <<'PY' > "$AGENT_TOKEN_FILE"
import secrets
print(secrets.token_urlsafe(24))
PY
fi
chmod 600 "$AGENT_TOKEN_FILE"
AGENT_TOKEN=$(cat "$AGENT_TOKEN_FILE")
IPV4=$(get_ipv4)
IPV6=$(get_ipv6)
COUNTRY=$(get_country "$IPV4")
HOSTNAME=$(hostname)
OS=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null || uname -s)
ARCH=$(uname -m)
PAYLOAD=$(python3 - "$TOKEN" "$PUBLIC_KEY" "$IPV4" "$IPV6" "$COUNTRY" "$HOSTNAME" "$OS" "$ARCH" "$AGENT_TOKEN" <<'PY'
import json
import sys
print(json.dumps({
    "token": sys.argv[1],
    "wg_public_key": sys.argv[2],
    "ipv4": sys.argv[3],
    "ipv6": sys.argv[4],
    "country": sys.argv[5],
    "hostname": sys.argv[6],
    "os": sys.argv[7],
    "arch": sys.argv[8],
    "agent_token": sys.argv[9]
}, ensure_ascii=False))
PY
)
RESULT=$(curl -fsS \
    --connect-timeout 5 \
    --max-time 15 \
    -X POST \
    "$CENTRAL_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")
echo "$RESULT"
WG_ADDRESS=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("wg_address",""))')
WG_SERVER_KEY=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("wg_server_public_key",""))')
WG_ENDPOINT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("wg_endpoint",""))')
if [ -z "$WG_ADDRESS" ] || [ -z "$WG_SERVER_KEY" ] || [ -z "$WG_ENDPOINT" ]; then
    echo "WG 参数获取失败"
    exit 1
fi
cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $WG_ADDRESS/$WG_ADDRESS_PREFIX
PrivateKey = $PRIVATE_KEY

[Peer]
PublicKey = $WG_SERVER_KEY
Endpoint = $WG_ENDPOINT
AllowedIPs = $WG_NETWORK.0/24
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONFIG"
printf '%s\n' "$WG_ADDRESS" > "$AGENT_ADDRESS_FILE"
chmod 600 "$AGENT_ADDRESS_FILE"
cat > "$AGENT_SCRIPT" <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
AGENT_DIR = "/etc/central-vps-agent"
TOKEN_FILE = os.path.join(AGENT_DIR, "token")
ADDRESS_FILE = os.path.join(AGENT_DIR, "address")
PORT = 18090
COMMAND_TIMEOUT = 30
def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""
TOKEN = read_file(TOKEN_FILE)
BIND_ADDRESS = read_file(ADDRESS_FILE)
if not TOKEN:
    print("Agent token missing", file=sys.stderr)
    sys.exit(1)
if not BIND_ADDRESS:
    print("Agent WG address missing", file=sys.stderr)
    sys.exit(1)
class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    def send_json(self, code, data):
        raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def authorized(self):
        auth = self.headers.get("Authorization", "")
        return auth == "Bearer " + TOKEN
    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except Exception:
            return None
        if length <= 0 or length > 65536:
            return None
        try:
            return json.loads(self.rfile.read(length))
        except Exception:
            return None
    def do_GET(self):
        if not self.authorized():
            self.send_json(401, {"ok": False, "error": "unauthorized"})
            return
        if self.path != "/api/info":
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        try:
            hostname = os.uname().nodename
            try:
                with open("/etc/os-release", "r", encoding="utf-8") as f:
                    os_release = f.read()
            except Exception:
                os_release = ""
            pretty_name = ""
            for line in os_release.splitlines():
                if line.startswith("PRETTY_NAME="):
                    pretty_name = line.split("=", 1)[1].strip('"')
                    break
            self.send_json(200, {
                "ok": True,
                "hostname": hostname,
                "os": pretty_name,
                "arch": os.uname().machine,
                "wg_address": BIND_ADDRESS
            })
        except Exception as e:
            self.send_json(500, {"ok": False, "error": str(e)})
    def do_POST(self):
        if not self.authorized():
            self.send_json(401, {"ok": False, "error": "unauthorized"})
            return
        if self.path != "/api/command":
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        data = self.read_json()
        if not isinstance(data, dict):
            self.send_json(400, {"ok": False, "error": "invalid json"})
            return
        command = data.get("command", "")
        if not isinstance(command, str):
            self.send_json(400, {"ok": False, "error": "invalid command"})
            return
        command = command.strip()
        if not command:
            self.send_json(400, {"ok": False, "error": "empty command"})
            return
        if len(command) > 16384:
            self.send_json(400, {"ok": False, "error": "command too long"})
            return
        try:
            result = subprocess.run(
                ["/bin/bash", "-lc", command],
                capture_output=True,
                text=True,
                timeout=COMMAND_TIMEOUT
            )
            self.send_json(200, {
                "ok": True,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "returncode": result.returncode
            })
        except subprocess.TimeoutExpired as e:
            stdout = e.stdout or ""
            stderr = e.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", "replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", "replace")
            self.send_json(200, {
                "ok": False,
                "stdout": stdout,
                "stderr": stderr,
                "returncode": 124,
                "error": "command timeout"
            })
        except Exception as e:
            self.send_json(500, {"ok": False, "error": str(e)})
server = HTTPServer((BIND_ADDRESS, PORT), Handler)
server.serve_forever()
PY
chmod 700 "$AGENT_SCRIPT"
cat > "/etc/systemd/system/$AGENT_SERVICE" <<EOF
[Unit]
Description=Central VPS Agent API
After=network-online.target wg-quick@$WG_INTERFACE.service
Wants=network-online.target
Requires=wg-quick@$WG_INTERFACE.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $AGENT_SCRIPT
Restart=on-failure
RestartSec=5
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "wg-quick@$WG_INTERFACE" >/dev/null 2>&1 || true
systemctl restart "wg-quick@$WG_INTERFACE"
sleep 2
if ping -c 2 -W 3 "$WG_SERVER_ADDRESS" >/dev/null 2>&1; then
    echo "========================================"
    echo "WG 通信成功"
    echo "本机 WG: $WG_ADDRESS"
    echo "中央 WG: $WG_SERVER_ADDRESS"
    echo "接口: $WG_INTERFACE"
    echo "========================================"
else
    echo "========================================"
    echo "WG 已启动，但无法 ping 中央 VPS"
    echo "本机 WG: $WG_ADDRESS"
    echo "中央 WG: $WG_SERVER_ADDRESS"
    echo "接口: $WG_INTERFACE"
    echo "========================================"
    wg show "$WG_INTERFACE"
    exit 1
fi
systemctl enable "$AGENT_SERVICE" >/dev/null 2>&1 || true
systemctl restart "$AGENT_SERVICE"
sleep 1
if systemctl is-active --quiet "$AGENT_SERVICE"; then
    echo "========================================"
    echo "Agent 管理 API 已启动"
    echo "地址: $WG_ADDRESS:$AGENT_PORT"
    echo "接口: $WG_INTERFACE"
    echo "========================================"
else
    echo "Agent 管理 API 启动失败"
    systemctl status "$AGENT_SERVICE" --no-pager
    exit 1
fi
# ==================== Agent 本地管理菜单 ====================

cat > "$AGENT_MENU" <<'MENU'
#!/bin/bash

AGENT_DIR="/etc/central-vps-agent"
AGENT_SCRIPT="/usr/local/bin/central-vps-agent.py"
AGENT_MENU="/usr/local/bin/central-vps-agent-menu"
AGENT_SERVICE="central-vps-agent.service"

WG_INTERFACE="central-mgmt"
WG_CONFIG="/etc/wireguard/central-mgmt.conf"
WG_PRIVATE_KEY="/etc/wireguard/central-mgmt-privatekey"

show_info() {
    clear

    echo "========================================"
    echo "        Central VPS Agent"
    echo "========================================"
    echo

    echo "Agent 服务 : $AGENT_SERVICE"

    if systemctl is-active --quiet "$AGENT_SERVICE"; then
        echo "Agent 状态 : 运行中"
    else
        echo "Agent 状态 : 未运行"
    fi

    echo "Agent 地址 : $(cat "$AGENT_DIR/address" 2>/dev/null || echo "未知")"
    echo "Agent 端口 : 18090"
    echo

    echo "WireGuard  : $WG_INTERFACE"

    if command -v wg >/dev/null 2>&1 &&
       wg show "$WG_INTERFACE" >/dev/null 2>&1; then
        echo "WG 状态    : 运行中"
    else
        echo "WG 状态    : 未运行"
    fi

    echo "WG 配置    : $WG_CONFIG"
    echo

    if [ -f "$WG_CONFIG" ]; then
        echo "WireGuard 配置："
        echo "----------------------------------------"
        cat "$WG_CONFIG"
        echo "----------------------------------------"
        echo
    fi

    if command -v wg >/dev/null 2>&1; then
        echo "WireGuard 运行信息："
        echo "----------------------------------------"
        wg show "$WG_INTERFACE" 2>/dev/null || true
        echo "----------------------------------------"
        echo
    fi

    echo "Agent 文件："
    echo "----------------------------------------"
    echo "$AGENT_DIR"
    echo "$AGENT_SCRIPT"
    echo "$AGENT_MENU"
    echo "/etc/systemd/system/$AGENT_SERVICE"
    echo "$WG_CONFIG"
    echo "$WG_PRIVATE_KEY"
    echo "/usr/bin/yy"
    echo "----------------------------------------"
    echo

    echo "========================================"
    echo "输入 s 卸载 Central VPS Agent"
    echo "按 Enter 返回"
    echo "========================================"
    echo
}

uninstall_agent() {
    clear
    echo "========================================"
    echo "      卸载 Central VPS Agent"
    echo "========================================"
    echo
    echo "将停止并删除本 Agent 创建的全部服务和文件。"
    echo
    read -rp "确认卸载？输入 y: " confirm
    if [ "$confirm" != "y" ]; then
        echo
        echo "已取消"
        sleep 1
        return
    fi
    echo
    echo "正在停止服务..."
    systemctl disable --now "$AGENT_SERVICE" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$AGENT_SERVICE"
    if command -v wg-quick >/dev/null 2>&1; then
        wg-quick down "$WG_INTERFACE" >/dev/null 2>&1 || true
    fi
    systemctl disable "wg-quick@$WG_INTERFACE" >/dev/null 2>&1 || true
    rm -f "$WG_CONFIG"
    rm -f "$WG_PRIVATE_KEY"
    SSH_KEY_FILE="$AGENT_DIR/ssh_public_key"
    if [ -f "$SSH_KEY_FILE" ] && [ -f /root/.ssh/authorized_keys ]; then
        SSH_KEY=$(cat "$SSH_KEY_FILE" 2>/dev/null || true)
        if [ -n "$SSH_KEY" ]; then
            TMP_FILE=$(mktemp)
            while IFS= read -r line; do
                [ "$line" = "$SSH_KEY" ] && continue
                printf '%s\n' "$line"
            done < /root/.ssh/authorized_keys > "$TMP_FILE"
            chmod 600 "$TMP_FILE"
            mv -f "$TMP_FILE" /root/.ssh/authorized_keys
        fi
    fi
    rm -f "$AGENT_SCRIPT"
    rm -f "$AGENT_MENU"
    rm -f /usr/bin/yy
    rm -rf "$AGENT_DIR"
    systemctl daemon-reload
    echo
    echo "========================================"
    echo "Central VPS Agent 已完全卸载"
    echo "========================================"
    echo
    echo "已删除："
    echo "  Agent 服务"
    echo "  Agent 程序"
    echo "  Agent 配置"
    echo "  central-mgmt WireGuard"
    echo "  Agent SSH 公钥"
    echo "  yy 快捷命令"
    echo
    echo "原有 y 命令未修改"
    echo
    exit 0
}
while true; do
    show_info
    read -rp "请选择: " choice
    case "$choice" in
        s|S)
            uninstall_agent
            ;;
        "")
            exit 0
            ;;
        *)
            echo
            echo "无效输入"
            sleep 1
            ;;
    esac
done
MENU
chmod 700 "$AGENT_MENU"
# 创建本地 yy 快捷命令
ln -sfn "$AGENT_MENU" /usr/bin/yy
echo
echo "快捷命令已创建: yy"
