#!/bin/bash
set -e
umask 077
CENTRAL_IP="${1:-}"
TOKEN="${2:-}"
SSH_PUBLIC_KEY="${3:-}"
# One-time registration code: the code passed as $2 is sent only
# in the registration request, is never written to disk, and must
# not be reused. A reinstall needs a newly issued code from central.
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
# Validate before CENTRAL_URL is used: IPv4 (octet-checked) or a plain hostname only.
if [[ "$CENTRAL_IP" =~ [^A-Za-z0-9.-] ]]; then
    echo "中央 VPS IP 格式异常"
    exit 1
fi
if [[ "$CENTRAL_IP" =~ ^[0-9.]+$ ]]; then
    IFS='.' read -r -a _IP_PARTS <<<"$CENTRAL_IP"
    if [ "${#_IP_PARTS[@]}" -ne 4 ]; then
        echo "中央 VPS IP 格式异常"
        exit 1
    fi
    for _OCTET in "${_IP_PARTS[@]}"; do
        if ! [[ "$_OCTET" =~ ^[0-9]+$ ]] || [ "$_OCTET" -gt 255 ]; then
            echo "中央 VPS IP 格式异常"
            exit 1
        fi
    done
elif ! [[ "$CENTRAL_IP" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "中央 VPS IP 格式异常"
    exit 1
fi
[ -n "$TOKEN" ] || {
    echo "缺少注册码"
    exit 1
}
[ -n "$SSH_PUBLIC_KEY" ] || {
    echo "缺少SSH 公钥"
    exit 1
}
if [[ "$SSH_PUBLIC_KEY" == *$'\n'* || "$SSH_PUBLIC_KEY" == *$'\r'* ]]; then
    echo "SSH 公钥必须为单行"
    exit 1
fi
if ! [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    echo "SSH 公钥格式异常"
    exit 1
fi
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
if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
    echo "WireGuard 工具安装后仍不可用"
    exit 1
fi
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
    if [[ "$SSH_PUBLIC_KEY" == *$'\n'* || "$SSH_PUBLIC_KEY" == *$'\r'* ]]; then
        echo "SSH 公钥必须为单行"
        exit 1
    fi
    if ! grep -qxF "$SSH_PUBLIC_KEY" "$authorized_keys" 2>/dev/null; then
        printf '%s\n' "$SSH_PUBLIC_KEY" >> "$authorized_keys"
    fi
}
install_ssh_key
printf '%s\n' "$SSH_PUBLIC_KEY" > "$AGENT_DIR/ssh_public_key"
chmod 600 "$AGENT_DIR/ssh_public_key"
if [ -f "$WG_PRIVATE_KEY" ]; then
    chmod 600 "$WG_PRIVATE_KEY"
    _WG_KEY_OK=1
    if [ ! -s "$WG_PRIVATE_KEY" ] || [ "$(wc -l < "$WG_PRIVATE_KEY")" -gt 1 ]; then
        _WG_KEY_OK=0
    elif ! [[ "$(cat "$WG_PRIVATE_KEY")" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        _WG_KEY_OK=0
    fi
    if [ "$_WG_KEY_OK" -ne 1 ]; then
        echo "WireGuard 私钥文件无效，重新生成"
        mv -f "$WG_PRIVATE_KEY" "$WG_PRIVATE_KEY.invalid"
        wg genkey > "$WG_PRIVATE_KEY"
        chmod 600 "$WG_PRIVATE_KEY"
    fi
else
    wg genkey > "$WG_PRIVATE_KEY"
    chmod 600 "$WG_PRIVATE_KEY"
fi
PRIVATE_KEY=$(cat "$WG_PRIVATE_KEY")
if ! PUBLIC_KEY=$(printf '%s' "$PRIVATE_KEY" | wg pubkey); then
    echo "WireGuard 私钥无效，无法派生公钥，请检查 $WG_PRIVATE_KEY"
    exit 1
fi
if [ -z "$PUBLIC_KEY" ]; then
    echo "WireGuard 公钥派生失败，请检查 $WG_PRIVATE_KEY"
    exit 1
fi
_AGT_TOKEN_OK=0
if [ -s "$AGENT_TOKEN_FILE" ]; then
    _AGT_CANDIDATE=$(cat "$AGENT_TOKEN_FILE")
    if [[ "$_AGT_CANDIDATE" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
        _AGT_TOKEN_OK=1
    fi
fi
if [ "$_AGT_TOKEN_OK" -ne 1 ]; then
    _AGT_TMP=$(mktemp "$AGENT_DIR/.token.tmp.XXXXXX")
    python3 - <<'PY' > "$_AGT_TMP"
import secrets
print(secrets.token_urlsafe(24))
PY
    chmod 600 "$_AGT_TMP"
    mv -f "$_AGT_TMP" "$AGENT_TOKEN_FILE"
fi
chmod 600 "$AGENT_TOKEN_FILE"
AGENT_TOKEN=$(cat "$AGENT_TOKEN_FILE")
if ! [[ "$AGENT_TOKEN" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
    echo "Agent token 无效"
    exit 1
fi
IPV4=$(get_ipv4)
IPV6=$(get_ipv6)
COUNTRY=$(get_country "$IPV4")
HOST_NAME=$(hostname)
OS=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null || uname -s)
ARCH=$(uname -m)
PAYLOAD=$(python3 - "$TOKEN" "$PUBLIC_KEY" "$IPV4" "$IPV6" "$COUNTRY" "$HOST_NAME" "$OS" "$ARCH" "$AGENT_TOKEN" <<'PY'
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
# 不用 curl -f：中央返回 4xx 时也要拿到响应体，才能显示真实原因（invalid token / key mismatch 等）
HTTP_CODE=0
RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT
HTTP_CODE=$(curl -sS \
    --connect-timeout 5 \
    --max-time 15 \
    -o "$RESULT_FILE" \
    -w '%{http_code}' \
    -X POST \
    "$CENTRAL_URL" \
    -H "Content-Type: application/json" \
    --data-binary @- <<<"$PAYLOAD") || {
    echo "无法连接中央 VPS：$CENTRAL_URL"
    echo "请检查中央 IP、18089 端口是否放行、中央 API 服务是否运行"
    exit 1
}
RESULT=$(cat "$RESULT_FILE")
PARSED=$(printf '%s' "$RESULT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR\t中央返回的不是 JSON")
    sys.exit(0)
if not isinstance(d, dict) or not d.get("ok"):
    err = d.get("error", "unknown error") if isinstance(d, dict) else "unknown error"
    print("ERR\t" + str(err))
    sys.exit(0)
vals = [str(d.get(k, "")).replace("\t", " ").replace("\n", " ") or "-" for k in ("wg_address", "wg_server_public_key", "wg_endpoint")]
print("OK\t" + "\t".join(vals))
')
IFS=$'\t' read -r PARSE_STATUS WG_ADDRESS WG_SERVER_KEY WG_ENDPOINT <<<"$PARSED"
if [ "$PARSE_STATUS" != "OK" ]; then
    echo "注册失败（HTTP $HTTP_CODE）：$WG_ADDRESS"
    case "$WG_ADDRESS" in
        *"invalid token"*) echo "注册码无效，请在中央端重新添加 VPS 获取新的安装命令" ;;
        *"key mismatch"*) echo "本机 WG 密钥与中央记录不一致：请在中央端删除该 VPS 后重新添加" ;;
    esac
    if [ "$HTTP_CODE" != "200" ]; then
        printf '%s\n' "$RESULT" | head -c 500
        echo
    fi
    exit 1
fi
[ "$WG_ADDRESS" = "-" ] && WG_ADDRESS=""
[ "$WG_SERVER_KEY" = "-" ] && WG_SERVER_KEY=""
[ "$WG_ENDPOINT" = "-" ] && WG_ENDPOINT=""
# 中央返回的值会写入 WG 配置，先校验格式，再报成功
if ! [[ "$WG_ADDRESS" =~ ^${WG_NETWORK//./\\.}\.[0-9]{1,3}$ ]] \
    || ! [[ "$WG_SERVER_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || ! [[ "$WG_ENDPOINT" =~ ^[0-9.]+:[0-9]{1,5}$ ]]; then
    echo "中央返回的 WG 参数格式异常：$WG_ADDRESS / $WG_ENDPOINT"
    exit 1
fi
_WG_LAST_OCTET="${WG_ADDRESS##*.}"
if ! [[ "$_WG_LAST_OCTET" =~ ^[0-9]+$ ]] || [ "$_WG_LAST_OCTET" -lt 2 ] || [ "$_WG_LAST_OCTET" -gt 254 ]; then
    echo "中央返回的 WG 地址超出节点分配范围"
    exit 1
fi
_EP_HOST="${WG_ENDPOINT%:*}"
_EP_PORT="${WG_ENDPOINT##*:}"
_EP_OK=1
IFS='.' read -r -a _EP_PARTS <<<"$_EP_HOST"
if [ "${#_EP_PARTS[@]}" -ne 4 ]; then
    _EP_OK=0
else
    for _EP_PART in "${_EP_PARTS[@]}"; do
        if ! [[ "$_EP_PART" =~ ^[0-9]+$ ]] || [ "$_EP_PART" -gt 255 ]; then
            _EP_OK=0
        fi
    done
fi
if [ "$_EP_OK" -ne 1 ] || ! [[ "$_EP_PORT" =~ ^[0-9]+$ ]] || [ "$_EP_PORT" -lt 1 ] || [ "$_EP_PORT" -gt 65535 ]; then
    echo "中央返回的 WG 端点格式异常"
    exit 1
fi
if [ -z "$WG_ADDRESS" ] || [ -z "$WG_SERVER_KEY" ] || [ -z "$WG_ENDPOINT" ]; then
    echo "WG 参数获取失败"
    exit 1
fi
echo "注册成功，本机 WG 地址：$WG_ADDRESS"

WG_CONFIG_BAK="$WG_CONFIG.bak"
if [ -f "$WG_CONFIG" ]; then
    cp -p "$WG_CONFIG" "$WG_CONFIG_BAK"
    chmod 600 "$WG_CONFIG_BAK"
fi
WG_CONFIG_TMP="$WG_CONFIG.tmp.$$"
cat > "$WG_CONFIG_TMP" <<EOF
[Interface]
Address = $WG_ADDRESS/$WG_ADDRESS_PREFIX
PrivateKey = $PRIVATE_KEY

[Peer]
PublicKey = $WG_SERVER_KEY
Endpoint = $WG_ENDPOINT
AllowedIPs = $WG_NETWORK.0/24
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONFIG_TMP"
if ! grep -qxF "Address = $WG_ADDRESS/$WG_ADDRESS_PREFIX" "$WG_CONFIG_TMP" \
    || ! grep -qxF "PrivateKey = $PRIVATE_KEY" "$WG_CONFIG_TMP" \
    || ! grep -qxF "PublicKey = $WG_SERVER_KEY" "$WG_CONFIG_TMP" \
    || ! grep -qxF "Endpoint = $WG_ENDPOINT" "$WG_CONFIG_TMP"; then
    rm -f "$WG_CONFIG_TMP"
    echo "WireGuard 配置生成异常，未覆盖原配置"
    exit 1
fi
mv -f "$WG_CONFIG_TMP" "$WG_CONFIG"
chmod 600 "$WG_CONFIG"
printf '%s\n' "$WG_ADDRESS" > "$AGENT_ADDRESS_FILE"
chmod 600 "$AGENT_ADDRESS_FILE"
cat > "$AGENT_SCRIPT" <<'PY'
#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import hmac
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
AGENT_DIR = "/etc/central-vps-agent"
TOKEN_FILE = os.path.join(AGENT_DIR, "token")
ADDRESS_FILE = os.path.join(AGENT_DIR, "address")
PORT = 18090
COMMAND_TIMEOUT = 30
# COMMAND_TIMEOUT applies only to the foreground command, not to
# detached children. Long work (for example a sing-box download)
# must be backgrounded by the sender, for example:
#   nohup setsid bash -c '...' >/var/log/job.log 2>&1 < /dev/null &
# Such a child runs in a different session, so the foreground
# timeout/kill below does not kill it, provided its output is
# redirected to a file and not left on the agent's pipes.
MAX_COMMAND_OUTPUT = 262144
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
    # 单个连接最多等 15 秒，防止半开连接卡死 agent
    timeout = 15
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
        return hmac.compare_digest(auth.encode("utf-8"), ("Bearer " + TOKEN).encode("utf-8"))
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
            proc = subprocess.Popen(
                ["/bin/bash", "-lc", command],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            try:
                _stdout, _stderr = proc.communicate(timeout=COMMAND_TIMEOUT)
                _returncode = proc.returncode
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
                try:
                    _stdout, _stderr = proc.communicate(timeout=2)
                except Exception:
                    try:
                        proc.stdout.close()
                    except Exception:
                        pass
                    try:
                        proc.stderr.close()
                    except Exception:
                        pass
                    _stdout, _stderr = "", ""
                self.send_json(200, {
                    "ok": False,
                    "stdout": _stdout[:MAX_COMMAND_OUTPUT] if _stdout else "",
                    "stderr": _stderr[:MAX_COMMAND_OUTPUT] if _stderr else "",
                    "returncode": 124,
                    "error": "command timeout"
                })
                return
            _stdout = _stdout or ""
            _stderr = _stderr or ""
            if len(_stdout) > MAX_COMMAND_OUTPUT:
                _stdout = _stdout[:MAX_COMMAND_OUTPUT] + "\n[output truncated]"
            if len(_stderr) > MAX_COMMAND_OUTPUT:
                _stderr = _stderr[:MAX_COMMAND_OUTPUT] + "\n[output truncated]"
            self.send_json(200, {
                "ok": True,
                "stdout": _stdout,
                "stderr": _stderr,
                "returncode": _returncode
            })
        except subprocess.TimeoutExpired as e:
            stdout = e.stdout or ""
            stderr = e.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", "replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", "replace")
            if len(stdout) > MAX_COMMAND_OUTPUT:
                stdout = stdout[:MAX_COMMAND_OUTPUT] + "\n[output truncated]"
            if len(stderr) > MAX_COMMAND_OUTPUT:
                stderr = stderr[:MAX_COMMAND_OUTPUT] + "\n[output truncated]"
            self.send_json(200, {
                "ok": False,
                "stdout": stdout,
                "stderr": stderr,
                "returncode": 124,
                "error": "command timeout"
            })
        except Exception as e:
            self.send_json(500, {"ok": False, "error": str(e)})
# 多线程：一个慢请求不会阻塞其他请求（例如状态查询）
ThreadingHTTPServer.daemon_threads = True
server = ThreadingHTTPServer((BIND_ADDRESS, PORT), Handler)
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
if ! systemctl enable "wg-quick@$WG_INTERFACE" >/dev/null 2>&1; then
    echo "WireGuard 服务开机自启设置失败"
    exit 1
fi
if ! systemctl restart "wg-quick@$WG_INTERFACE"; then
    echo "WireGuard 重启失败，尝试恢复原配置"
    if [ -f "$WG_CONFIG_BAK" ]; then
        cp -p "$WG_CONFIG_BAK" "$WG_CONFIG"
        chmod 600 "$WG_CONFIG"
        systemctl restart "wg-quick@$WG_INTERFACE" || true
    fi
    exit 1
fi
# 很多机器/防火墙会丢 ICMP，不能只靠 ping 判断。ping 用来触发握手，再看 WG 是否握手成功。
WG_OK=0
for _ in 1 2 3 4 5; do
    sleep 2
    if ping -c 1 -W 2 "$WG_SERVER_ADDRESS" >/dev/null 2>&1; then
        WG_OK=1
        break
    fi
    HANDSHAKE=$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n 1)
    if [ -n "$HANDSHAKE" ] && [ "$HANDSHAKE" != "0" ]; then
        WG_OK=2
        break
    fi
done
echo "========================================"
case "$WG_OK" in
    1) echo "WG 通信成功" ;;
    2) echo "WG 握手成功（中央不回 ping，属正常）" ;;
    *) echo "警告：WG 暂未握手成功，停止安装 Agent"
       echo "请检查中央 VPS 的 UDP 51821 端口是否放行"
       exit 1 ;;
esac
echo "本机 WG: $WG_ADDRESS"
echo "中央 WG: $WG_SERVER_ADDRESS"
echo "接口: $WG_INTERFACE"
echo "========================================"
[ "$WG_OK" = "0" ] && wg show "$WG_INTERFACE" 2>/dev/null | sed 's/\(private key:\).*/\1 (hidden)/'
if ! systemctl enable "$AGENT_SERVICE" >/dev/null 2>&1; then
    echo "Agent 服务开机自启设置失败"
    exit 1
fi
systemctl restart "$AGENT_SERVICE"
_AGENT_OK=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet "$AGENT_SERVICE"; then
        _AGENT_OK=1
        break
    fi
    sleep 1
done
if [ "$_AGENT_OK" -eq 1 ]; then
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
        sed 's/^\(PrivateKey[[:space:]]*=\).*/\1 ******（已隐藏）/' "$WG_CONFIG"
        echo "----------------------------------------"
        echo
    fi

    if command -v wg >/dev/null 2>&1; then
        echo "WireGuard 运行信息："
        echo "----------------------------------------"
        wg show "$WG_INTERFACE" 2>/dev/null | sed 's/\(private key:\).*/\1 (hidden)/' || true
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
    # Best-effort unregister: tell central to drop this node record
    # so a reinstall with a new WireGuard key does not hit a key
    # mismatch. Runs while WireGuard is still up. Any failure is
    # ignored and never blocks uninstall. Uses the stored agent
    # token and WG address, not the one-time registration code.
    if command -v curl >/dev/null 2>&1 && [ -f "$AGENT_DIR/token" ] && [ -f "$AGENT_DIR/address" ]; then
        _UNREG_TOKEN=$(cat "$AGENT_DIR/token" 2>/dev/null || true)
        _UNREG_ADDR=$(cat "$AGENT_DIR/address" 2>/dev/null || true)
        if [ -n "$_UNREG_TOKEN" ] && [ -n "$_UNREG_ADDR" ]; then
            _UNREG_URL="http://${WG_SERVER_ADDRESS:-10.231.47.1}:18089/api/unregister"
            _UNREG_PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"agent_token": sys.argv[1], "wg_address": sys.argv[2]}))' "$_UNREG_TOKEN" "$_UNREG_ADDR" 2>/dev/null || true)
            if [ -n "$_UNREG_PAYLOAD" ]; then
                curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' --data "$_UNREG_PAYLOAD" "$_UNREG_URL" >/dev/null 2>&1 || true
            fi
        fi
    fi
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
        if [ -s "$SSH_KEY_FILE" ]; then
            TMP_FILE=$(mktemp)
            grep -vxF -f "$SSH_KEY_FILE" /root/.ssh/authorized_keys > "$TMP_FILE" || true
            chmod 600 "$TMP_FILE"
            mv -f "$TMP_FILE" /root/.ssh/authorized_keys
        fi
    fi
    rm -f "$AGENT_SCRIPT"
    rm -f "$AGENT_MENU"
    _YY_BAK=$(ls -t /usr/bin/yy.bak.* 2>/dev/null | head -n 1 || true)
    if [ -n "$_YY_BAK" ] && [ -e "$_YY_BAK" ]; then
        mv -f "$_YY_BAK" /usr/bin/yy
    else
        rm -f /usr/bin/yy
    fi
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
# 创建本地 yy 快捷命令；已有非本菜单的 yy 时先备份，不直接覆盖。
if [ -e /usr/bin/yy ] && [ ! -L /usr/bin/yy ]; then
    mv -f /usr/bin/yy "/usr/bin/yy.bak.$(date +%s)"
    echo "已有 yy 已备份"
elif [ -L /usr/bin/yy ] && [ "$(readlink /usr/bin/yy)" != "$AGENT_MENU" ]; then
    mv -f /usr/bin/yy "/usr/bin/yy.bak.$(date +%s)"
    echo "已有 yy 链接已备份"
fi
ln -sfn "$AGENT_MENU" /usr/bin/yy
echo
echo "快捷命令已创建: yy"
