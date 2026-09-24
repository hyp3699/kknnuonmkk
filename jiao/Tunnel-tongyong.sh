#!/bin/bash
set -e
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
    python3 -c 'import secrets; print(secrets.token_hex(16))'
}
install_wireguard() {
    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        return 0
    fi
    echo "正在检查 WireGuard..."
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
        echo "无法自动安装 WireGuard"
        echo "请手动安装 wireguard-tools"
        exit 1
    fi
    if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
        echo "WireGuard 安装失败"
        echo "请检查系统软件源"
        exit 1
    fi
    echo "WireGuard 已就绪"
    echo "wg       : $(command -v wg)"
    echo "wg-quick : $(command -v wg-quick)"
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
import json, sys
vps_file, config_file = sys.argv[1:]
with open(vps_file, encoding="utf-8") as f:
    data = json.load(f)
with open(config_file, "a", encoding="utf-8") as f:
    for item in data.get("vps", []):
        key = item.get("wg_public_key", "")
        ip = item.get("wg_address", "")
        if key and ip:
            f.write("\n[Peer]\n")
            f.write("PublicKey = " + key + "\n")
            f.write("AllowedIPs = " + ip.split("/")[0] + "/32\n")
PY
    chmod 600 "$WG_CONFIG"
    systemctl enable "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    else
        systemctl start "wg-quick@$WG_INTERFACE.service"
    fi
}
allocate_wg_ip() {
    python3 - "$VPS_FILE" "$WG_NETWORK" <<'PY'
import json, sys
p, network = sys.argv[1:]
with open(p, encoding="utf-8") as f:
    data = json.load(f)
used = set()
for item in data.get("vps", []):
    address = item.get("wg_address", "")
    if address:
        try:
            used.add(int(address.split(".")[-1].split("/")[0]))
        except Exception:
            pass
for i in range(2, 255):
    if i not in used:
        print(f"{network}.{i}")
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
import json, sys
vps_file, config_file = sys.argv[1:]
with open(vps_file, encoding="utf-8") as f:
    data = json.load(f)
with open(config_file, "a", encoding="utf-8") as f:
    for item in data.get("vps", []):
        key = item.get("wg_public_key", "")
        ip = item.get("wg_address", "")
        if key and ip:
            f.write("\n[Peer]\n")
            f.write("PublicKey = " + key + "\n")
            f.write("AllowedIPs = " + ip.split("/")[0] + "/32\n")
PY
    chmod 600 "$WG_CONFIG"
    systemctl enable "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
    else
        systemctl start "wg-quick@$WG_INTERFACE.service"
    fi
}
server() {
    exec 9>/run/central-vps-server.lock
    if ! flock -n 9; then
        echo "central-vps API 已经在运行"
        exit 0
    fi
    python3 - "$VPS_FILE" "$PORT" "$WG_PUBLIC_KEY" "$WG_PORT" "$WG_INTERFACE" "$WG_NETWORK" <<'PY'
import json
import os
import sys
import subprocess
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
FILE = sys.argv[1]
PORT = int(sys.argv[2])
WG_PUBLIC_FILE = sys.argv[3]
WG_PORT = int(sys.argv[4])
WG_INTERFACE = sys.argv[5]
WG_NETWORK = sys.argv[6]
WG_CONFIG = "/etc/wireguard/" + WG_INTERFACE + ".conf"
_cached_ip = ""
def load():
    with open(FILE, "r", encoding="utf-8") as f:
        return json.load(f)
def save(data):
    tmp = FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, FILE)
def public_ip():
    global _cached_ip

    if _cached_ip:
        return _cached_ip
    try:
        req = urllib.request.Request(
            "https://api.ipify.org",
            headers={"User-Agent": "curl/7.68.0"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            _cached_ip = resp.read().decode("utf-8").strip()
            return _cached_ip

    except Exception:
        return ""
def persist_peer(public_key, wg_address):
    if not public_key or not wg_address:
        return False
    try:
        if os.path.exists(WG_CONFIG):
            with open(WG_CONFIG, "r", encoding="utf-8") as f:
                config = f.read()
        else:
            config = ""
        blocks = config.split("[Peer]")
        for block in blocks[1:]:
            for line in block.splitlines():
                line = line.strip()
                if line.startswith("PublicKey"):
                    parts = line.split("=", 1)
                    if len(parts) == 2:
                        existing_key = parts[1].strip()
                        if existing_key == public_key:
                            return True
                    break
        config = config.rstrip() + "\n\n"
        config += "[Peer]\n"
        config += "PublicKey = " + public_key + "\n"
        config += "AllowedIPs = " + wg_address.split("/")[0] + "/32\n"
        tmp = WG_CONFIG + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(config)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, WG_CONFIG)
        return True
    except Exception:
        try:
            if os.path.exists(WG_CONFIG + ".tmp"):
                os.remove(WG_CONFIG + ".tmp")
        except Exception:
            pass
        return False
class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    def send_json(self, code, data):
        raw = json.dumps(
            data,
            ensure_ascii=False
        ).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def do_POST(self):
        if self.path != "/api/register":
            self.send_json(
                404,
                {
                    "ok": False,
                    "error": "not found"
                }
            )
            return
        try:
            length = int(
                self.headers.get(
                    "Content-Length",
                    "0"
                )
            )
            if length <= 0 or length > 10240:
                self.send_json(
                    400,
                    {
                        "ok": False,
                        "error": "invalid request size"
                    }
                )
                return
            body = self.rfile.read(length)
            data = json.loads(body)
            token = data.get("token", "")
            wg_key = data.get("wg_public_key", "")
            if not token or not wg_key:
                self.send_json(
                    400,
                    {
                        "ok": False,
                        "error": "missing token or wg_public_key"
                    }
                )
                return
            db = load()
            item = None
            for x in db.get("vps", []):
                if x.get("token") == token:
                    item = x
                    break
            if item is None:
                self.send_json(
                    403,
                    {
                        "ok": False,
                        "error": "invalid token"
                    }
                )
                return
            old_key = item.get(
                "wg_public_key",
                ""
            )
           if old_key and old_key != wg_key:
                self.send_json(
                    403,
                    {
                        "ok": False,
                        "error": "wireguard key mismatch"
                    }
                )
                return
            if not item.get("wg_address"):
                used = set()
                for x in db.get("vps", []):
                    address = x.get(
                        "wg_address",
                        ""
                    )
                    if address:
                        try:
                            last_octet = int(
                                address
                                .split(".")[-1]
                                .split("/")[0]
                            )
                            used.add(last_octet)
                        except Exception:
                            pass
                address = ""
                for i in range(2, 255):
                    if i not in used:
                        address = f"{WG_NETWORK}.{i}"
                        break
                if not address:
                    self.send_json(
                        500,
                        {
                            "ok": False,
                            "error": "no wg address available"
                        }
                    )
                    return
                item["wg_address"] = address
            item["wg_public_key"] = wg_key
            item["online"] = True
            item["ipv4"] = data.get(
                "ipv4",
                ""
            )
            item["ipv6"] = data.get(
                "ipv6",
                ""
            )
            item["country"] = data.get(
                "country",
                ""
            )
            item["hostname"] = data.get(
                "hostname",
                ""
            )
            item["os"] = data.get(
                "os",
                ""
            )
            item["arch"] = data.get(
                "arch",
                ""
            )
            save(db)
            wg_result = subprocess.run(
                [
                    "wg",
                    "set",
                    WG_INTERFACE,
                    "peer",
                    wg_key,
                    "allowed-ips",
                    item["wg_address"] + "/32"
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False
            )
            if wg_result.returncode != 0:
                self.send_json(
                    500,
                    {
                        "ok": False,
                        "error": "failed to configure wireguard peer"
                    }
                )
                return
            if not persist_peer(
                wg_key,
                item["wg_address"]
            ):
                self.send_json(
                    500,
                    {
                        "ok": False,
                        "error": "failed to save wireguard peer"
                    }
                )
                return
            endpoint = public_ip()
            if not endpoint:
                self.send_json(
                    500,
                    {
                        "ok": False,
                        "error": "failed to get central public IPv4"
                    }
                )
                return
            try:
               with open(
                    WG_PUBLIC_FILE,
                    "r",
                    encoding="utf-8"
                ) as f:
                    server_key = f.read().strip()
            except Exception:
                self.send_json(
                    500,
                    {
                        "ok": False,
                        "error": "failed to read server public key"
                    }
                )
                return
            self.send_json(
                200,
                {
                    "ok": True,
                    "wg_address": item["wg_address"],
                    "wg_server_public_key": server_key,
                    "wg_endpoint": endpoint + ":" + str(WG_PORT)
                }
            )
        except Exception as e:
            self.send_json(
                500,
                {
                    "ok": False,
                    "error": str(e)
                }
            )
server = HTTPServer(
    ("0.0.0.0", PORT),
    Handler
)
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
add_vps() {
    local name token central_ip
    read -rp "请输入 VPS 名称: " name
    [ -n "$name" ] || return
    central_ip=$(get_ipv4)
    if [ -z "$central_ip" ]; then
        echo "获取中央 VPS 公网 IP 失败"
        read -rp "按 Enter 返回..." _
        return
    fi
    token=$(generate_token)
    python3 - "$VPS_FILE" "$name" "$token" <<'PY'
import json, sys
p, name, token = sys.argv[1:]
with open(p, encoding="utf-8") as f:
    data = json.load(f)
data["vps"] = [x for x in data["vps"] if x.get("name") != name]
data["vps"].append({
    "name": name, "token": token, "online": False,
    "ipv4": "", "ipv6": "", "country": "", "hostname": "",
    "os": "", "arch": "", "wg_address": "", "wg_public_key": ""
})
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
    init_wireguard
    echo "========================================"
    echo "中央 VPS IPv4: $central_ip"
    echo "========================================"
    echo "请在目标 VPS 执行："
    echo
    printf 'curl -fsSL %s | bash -s -- "%s" "%s"\n' "$AGENT_URL" "$central_ip" "$token"
    echo
    echo "========================================"
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
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
if not data["vps"]:
    print("暂无 VPS")
else:
    for i, x in enumerate(data["vps"], 1):
        status = "在线" if x.get("online") else "离线"
        print(f"{i}. {x.get('name','')} | {x.get('country','')} | {x.get('ipv4','')} | {status}")
PY
        echo
        echo "0. 返回"
        echo
        read -rp "请选择 VPS: " choice
        [ "$choice" = "0" ] && return
        selected=$(python3 - "$VPS_FILE" "$choice" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
try:
    i = int(sys.argv[2]) - 1
    if 0 <= i < len(data["vps"]):
        print(json.dumps(data["vps"][i], ensure_ascii=False))
except Exception:
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
import json, sys
x = json.loads(sys.argv[1])
print("名称      :", x.get("name", ""))
print("国家/地区 :", x.get("country", ""))
print("IPv4      :", x.get("ipv4", ""))
print("IPv6      :", x.get("ipv6", ""))
print("主机名    :", x.get("hostname", ""))
print("系统      :", x.get("os", ""))
print("架构      :", x.get("arch", ""))
print("WG 地址   :", x.get("wg_address", ""))
print("状态      :", "在线" if x.get("online") else "离线")
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
import json, sys
print(json.loads(sys.argv[1]).get("wg_address", ""))
PY
)
                if [ -z "$wg_ip" ]; then
                    echo "该 VPS 尚未建立 WG 通信"
                    read -rp "按 Enter 返回..." _
                    continue
                fi
                echo "WG 地址: $wg_ip"
                echo "当前正在建立命令控制通道，重启功能下一步接入"
                read -rp "按 Enter 返回..." _
                ;;
            2)
                name=$(python3 - "$selected" <<'PY'
import json, sys
print(json.loads(sys.argv[1]).get("name", ""))
PY
)
                echo
                read -rp "确认删除 VPS [$name]？输入 yes: " confirm
                if [ "$confirm" = "yes" ]; then
                    python3 - "$VPS_FILE" "$name" <<'PY'
import json, sys
p, name = sys.argv[1:]
with open(p, encoding="utf-8") as f:
    data = json.load(f)
data["vps"] = [x for x in data["vps"] if x.get("name") != name]
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
                    rebuild_wg_config
                    echo "VPS 已删除"
                    sleep 1
                    break
                fi
                ;;
            0)
                break
                ;;
            esac
        done
    done
}
update_script() {
    echo "正在更新脚本..."
    curl -fsSL "$SCRIPT_URL" -o "$LOCAL_SCRIPT"
    chmod 700 "$LOCAL_SCRIPT"
    echo "脚本已成功更新！"
    sleep 1
    exec /bin/bash "$LOCAL_SCRIPT" --menu
}
delete_script() {
    echo
    echo "========================================"
    echo "          删除中央 VPS 管理系统"
    echo "========================================"
    echo
    echo "只删除本管理系统创建的内容："
    echo
    echo "  - central-vps.service"
    echo "  - $WG_INTERFACE"
    echo "  - $WG_CONFIG"
    echo "  - $WG_PRIVATE_KEY"
    echo "  - $WG_PUBLIC_KEY"
    echo "  - /etc/central-vps"
    echo "  - /usr/local/bin/central-vps.sh"
    echo
    echo "不会删除："
    echo "  - route64"
    echo "  - central0"
    echo "  - 其他 WireGuard 配置"
    echo "  - WireGuard 软件包"
    echo
    read -rp "确认删除？输入 yes: " confirm
    [ "$confirm" = "yes" ] || return
    echo
    echo "开始删除..."
    echo
    echo "[1/6] 停止 central-vps.service..."
    systemctl stop central-vps.service >/dev/null 2>&1 || true
    systemctl disable central-vps.service >/dev/null 2>&1 || true
    echo
    echo "[2/6] 停止 $WG_INTERFACE..."
    systemctl stop "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    echo
    echo "[3/6] 删除 $WG_INTERFACE..."
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        ip link set "$WG_INTERFACE" down >/dev/null 2>&1 || true
        ip link del "$WG_INTERFACE" >/dev/null 2>&1 || true
    fi
    echo
    echo "[4/6] 删除 systemd 文件..."
    rm -f /etc/systemd/system/central-vps.service
    systemctl daemon-reload
    systemctl reset-failed central-vps.service >/dev/null 2>&1 || true
    echo
    echo "[5/6] 删除中央管理系统文件..."
    rm -f "$WG_CONFIG" "$WG_PRIVATE_KEY" "$WG_PUBLIC_KEY"
    rm -rf /etc/central-vps
    rm -f /usr/local/bin/central-vps.sh
    rm -f /run/central-vps-server.lock
    echo
    echo "[6/6] 检查..."
    echo
    echo "===== 当前 WireGuard ====="
    if command -v wg >/dev/null 2>&1; then
        wg show
    fi
    echo
    echo "===== 检查 $WG_INTERFACE ====="
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        echo "⚠ $WG_INTERFACE 仍然存在"
    else
        echo "✓ $WG_INTERFACE 已删除"
    fi
    echo
    echo "===== 检查配置 ====="
    if [ -e "$WG_CONFIG" ]; then echo "⚠ $WG_CONFIG 仍然存在"; else echo "✓ $WG_CONFIG 已删除"; fi
    if [ -e "$WG_PRIVATE_KEY" ]; then echo "⚠ $WG_PRIVATE_KEY 仍然存在"; else echo "✓ $WG_PRIVATE_KEY 已删除"; fi
    if [ -e "$WG_PUBLIC_KEY" ]; then echo "⚠ $WG_PUBLIC_KEY 仍然存在"; else echo "✓ $WG_PUBLIC_KEY 已删除"; fi
    echo
    echo "===== 检查管理文件 ====="
    if [ -e /etc/central-vps ]; then echo "⚠ /etc/central-vps 仍然存在"; else echo "✓ /etc/central-vps 已删除"; fi
    if [ -e /usr/local/bin/central-vps.sh ]; then echo "⚠ central-vps.sh 仍然存在"; else echo "✓ central-vps.sh 已删除"; fi
    echo
    echo "===== WireGuard 软件 ====="
    if command -v wg >/dev/null 2>&1; then echo "✓ wg 保留: $(command -v wg)"; else echo "⚠ wg 不存在"; fi
    if command -v wg-quick >/dev/null 2>&1; then echo "✓ wg-quick 保留: $(command -v wg-quick)"; else echo "⚠ wg-quick 不存在"; fi
    echo
    echo "========================================"
    echo "       中央 VPS 管理系统已删除"
    echo "========================================"
    echo
    echo "保留："
    echo "  ✓ route64"
    echo "  ✓ central0"
    echo "  ✓ 其他 WireGuard"
    echo "  ✓ WireGuard 软件包"
    echo "  ✓ wg"
    echo "  ✓ wg-quick"
    echo
    echo "删除："
    echo "  ✓ $WG_INTERFACE"
    echo "  ✓ $WG_CONFIG"
    echo "  ✓ $WG_PRIVATE_KEY"
    echo "  ✓ $WG_PUBLIC_KEY"
    echo "  ✓ central-vps.service"
    echo "  ✓ /etc/central-vps"
    echo "  ✓ /usr/local/bin/central-vps.sh"
    echo
    exit 0
}
main() {
    mkdir -p "$(dirname "$LOCAL_SCRIPT")
    if [ ! -f "$LOCAL_SCRIPT" ]; then
        tmp="${LOCAL_SCRIPT}.tmp"
        if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then
            rm -f "$tmp"
            echo "脚本下载失败"
            exit 1
        fi
        chmod 700 "$tmp"
        if ! bash -n "$tmp"; then
            rm -f "$tmp"
            echo "下载的脚本语法错误"
            exit 1
        fi
        mv -f "$tmp" "$LOCAL_SCRIPT"
        echo "脚本下载成功"
    fi
    if [ ! -f /etc/systemd/system/central-vps.service ]; then
        "$LOCAL_SCRIPT" --setup-server
    elif ! systemctl is-active \
        --quiet central-vps.service \
        2>/dev/null; then
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
        echo "================================"
        echo "       中央 VPS 管理脚本 1"
        echo "================================"
        echo
        echo "1. 添加 VPS"
        echo "2. 管理 VPS"
        echo "3. 安装 sing-box"
        echo "4. 卸载 sing-box"
        echo "5. 更新脚本"
        echo "6. 删除管理脚本"
        echo
        echo "0. 退出"
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
            echo "暂未实现"
            read -rp "按 Enter 返回..." _
            ;;
        4)
            echo "暂未实现"
            read -rp "按 Enter 返回..." _
            ;;
        5)
            update_script
            ;;
        6)
            delete_script
            ;;
        0)
            exit 0
            ;;
        esac
    done
    ;;
*)
    main
    ;;
esac
