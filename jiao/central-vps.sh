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
mkdir -p "$BASE_DIR" "$DATA_DIR"
chmod 700 "$BASE_DIR" "$DATA_DIR"
[ -f "$VPS_FILE" ] || echo '{"vps":[]}' > "$VPS_FILE"
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
    echo "正在安装 WireGuard..."
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
        exit 1
    fi
    if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
        echo "WireGuard 安装失败"
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
    write_wg_config
    apply_wg_config
}
persist_peer() {
    local public_key="$1"
    local wg_address="$2"
    python3 - "$WG_CONFIG" "$public_key" "$wg_address" <<'PY'
import os
import sys
config, public_key, address = sys.argv[1:]
try:
    with open(config, "r", encoding="utf-8") as f:
        text = f.read()
except Exception:
    sys.exit(1)
target = address.split("/")[0] + "/32"
blocks = text.split("\n[Peer]")
found = False
new_blocks = []
for i, block in enumerate(blocks):
    if i == 0:
        new_blocks.append(block)
        continue
    full = "[Peer]" + block
    lines = full.splitlines()
    key = ""
    for line in lines:
        if line.strip().startswith("PublicKey"):
            key = line.split("=", 1)[1].strip()
            break
    if key == public_key:
        found = True
        replaced = []
        for line in lines:
            if line.strip().startswith("AllowedIPs"):
                replaced.append("AllowedIPs = " + target)
            else:
                replaced.append(line)
        full = "\n".join(replaced)
    new_blocks.append(full)
if not found:
    new_blocks.append(
        "[Peer]\n"
        "PublicKey = " + public_key + "\n"
        "AllowedIPs = " + target + "\n"
    )
result = "\n".join(new_blocks)
tmp = config + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(result.rstrip() + "\n")
    f.flush()
    os.fsync(f.fileno())
os.chmod(tmp, 0o600)
os.replace(tmp, config)
PY
}

server() {
    exec 9>/run/central-vps-server.lock
    if ! flock -n 9; then
        echo "central-vps API 已经在运行"
        exit 0
    fi
    python3 - "$VPS_FILE" "$PORT" "$WG_PUBLIC_KEY" "$WG_PORT" "$WG_INTERFACE" "$WG_NETWORK" "$WG_CONFIG" <<'PY'
import json
import os
import sys
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
FILE = sys.argv[1]
PORT = int(sys.argv[2])
WG_PUBLIC_FILE = sys.argv[3]
WG_PORT = int(sys.argv[4])
WG_INTERFACE = sys.argv[5]
WG_NETWORK = sys.argv[6]
WG_CONFIG = sys.argv[7]
def load():
    with open(FILE, "r", encoding="utf-8") as f:
        return json.load(f)
def save(data):
    tmp = FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, FILE)
def public_ip():
    try:
        return subprocess.check_output(
            ["curl", "-4", "-fsS", "--max-time", "5", "https://api.ipify.org"],
            text=True
        ).strip()
    except Exception:
        return ""
def persist_peer(public_key, wg_address):
    try:
        with open(WG_CONFIG, "r", encoding="utf-8") as f:
            text = f.read()
    except Exception:
        return False
    target = wg_address.split("/")[0] + "/32"
    blocks = text.split("\n[Peer]")
    found = False
    result = [blocks[0]]
    for block in blocks[1:]:
        full = "[Peer]" + block
        lines = full.splitlines()
        key = ""
        for line in lines:
            if line.strip().startswith("PublicKey"):
                key = line.split("=", 1)[1].strip()
                break
        if key == public_key:
            found = True
            new_lines = []
            replaced = False
            for line in lines:
                if line.strip().startswith("AllowedIPs"):
                    new_lines.append("AllowedIPs = " + target)
                    replaced = True
                else:
                    new_lines.append(line)
            if not replaced:
                new_lines.append("AllowedIPs = " + target)
            full = "\n".join(new_lines)
        result.append(full)
    if not found:
        result.append(
            "[Peer]\n"
            "PublicKey = " + public_key + "\n"
            "AllowedIPs = " + target + "\n"
        )
    tmp = WG_CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(result).rstrip() + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, WG_CONFIG)
    return True
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
    def do_POST(self):
        if self.path != "/api/register":
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 10240:
                self.send_json(400, {"ok": False, "error": "invalid request size"})
                return
            data = json.loads(self.rfile.read(length))
            token = data.get("token", "")
            wg_key = data.get("wg_public_key", "")
            agent_token = data.get("agent_token", "")
            if not token or not wg_key:
                self.send_json(400, {"ok": False, "error": "missing token or wg_public_key"})
                return
            db = load()
            item = None
            for x in db.get("vps", []):
                if x.get("token") == token:
                    item = x
                    break
            if item is None:
                self.send_json(403, {"ok": False, "error": "invalid token"})
                return
            old_key = item.get("wg_public_key", "")
            if old_key and old_key != wg_key:
                self.send_json(403, {"ok": False, "error": "wireguard key mismatch"})
                return
            if not item.get("wg_address"):
                used = set()
                for x in db.get("vps", []):
                    address = x.get("wg_address", "")
                    if address:
                        try:
                            used.add(int(address.split(".")[-1].split("/")[0]))
                        except Exception:
                            pass
                address = ""
                for i in range(2, 255):
                    if i not in used:
                        address = f"{WG_NETWORK}.{i}"
                        break
                if not address:
                    self.send_json(500, {"ok": False, "error": "no wg address available"})
                    return
                item["wg_address"] = address
            item["wg_public_key"] = wg_key
            item["agent_token"] = agent_token
            item["online"] = True
            item["ipv4"] = data.get("ipv4", "")
            item["ipv6"] = data.get("ipv6", "")
            item["country"] = data.get("country", "")
            item["hostname"] = data.get("hostname", "")
            item["os"] = data.get("os", "")
            item["arch"] = data.get("arch", "")
            save(db)
            subprocess.run(
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
            persist_peer(wg_key, item["wg_address"])
            endpoint = public_ip()
            if not endpoint:
                self.send_json(500, {"ok": False, "error": "failed to get central public IPv4"})
                return
            try:
                with open(WG_PUBLIC_FILE, "r", encoding="utf-8") as f:
                    server_key = f.read().strip()
            except Exception:
                self.send_json(500, {"ok": False, "error": "failed to read server public key"})
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
            self.send_json(500, {"ok": False, "error": str(e)})
server = HTTPServer(("0.0.0.0", PORT), Handler)
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
    local name
    local token
    local central_ip
    read -rp "请输入 VPS 名称: " name
    [ -n "$name" ] || return
    if python3 - "$VPS_FILE" "$name" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for x in data.get("vps", []):
    if x.get("name") == sys.argv[2]:
        sys.exit(0)
sys.exit(1)
PY
    then
        echo "VPS 名称已存在"
        read -rp "按 Enter 返回..." _
        return
    fi
    central_ip=$(get_ipv4)
    if [ -z "$central_ip" ]; then
        echo "获取中央 VPS 公网 IP 失败"
        read -rp "按 Enter 返回..." _
        return
    fi
    token=$(generate_token)
    python3 - "$VPS_FILE" "$name" "$token" <<'PY'
import json
import sys
p, name, token = sys.argv[1:]
with open(p, encoding="utf-8") as f:
    data = json.load(f)
data["vps"].append({
    "name": name,
    "token": token,
    "agent_token": "",
    "online": False,
    "ipv4": "",
    "ipv6": "",
    "country": "",
    "hostname": "",
    "os": "",
    "arch": "",
    "wg_address": "",
    "wg_public_key": ""
})
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
    chmod 600 "$VPS_FILE"
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
    read -rp "按 Enter 返回..." _
}

get_vps_count() {
    python3 - "$VPS_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(len(json.load(f).get("vps", [])))
PY
}

get_vps_field() {
    local index="$1"
    local field="$2"
    python3 - "$VPS_FILE" "$index" "$field" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
try:
    value = data["vps"][int(sys.argv[2])].get(sys.argv[3], "")
    if isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)
except Exception:
    print("")
PY
}

set_vps_offline() {
    local name="$1"
    python3 - "$VPS_FILE" "$name" <<'PY'
import json
import sys
p, name = sys.argv[1:]
with open(p, encoding="utf-8") as f:
    data = json.load(f)
for x in data.get("vps", []):
    if x.get("name") == name:
        x["online"] = False
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
    chmod 600 "$VPS_FILE"
}

agent_command() {
    local wg_ip="$1"
    local agent_token="$2"
    local command="$3"
    python3 - "$wg_ip" "$agent_token" "$command" <<'PY'
import sys
import json
import urllib.request
import urllib.error
wg_ip = sys.argv[1]
token = sys.argv[2]
command = sys.argv[3]
url = f"http://{wg_ip}:18090/api/command"
payload = json.dumps({
    "command": command
}).encode()
req = urllib.request.Request(
    url,
    data=payload,
    method="POST",
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    },
)
try:
    with urllib.request.urlopen(req, timeout=35) as response:
        body = response.read().decode()
        print(body)
except urllib.error.HTTPError as e:
    body = e.read().decode(errors="replace")
    print(json.dumps({
        "ok": False,
        "error": f"HTTP {e.code}",
        "detail": body
    }, ensure_ascii=False))
except Exception as e:
    print(json.dumps({
        "ok": False,
        "error": str(e)
    }, ensure_ascii=False))
PY
}


check_agent() {
    local address="$1"
    local token="$2"
    local result
    result=$(agent_request "$address" "$token" GET "/api/info") || return 1
    printf '%s' "$result" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    sys.exit(0 if d.get("ok") else 1)
except:
    sys.exit(1)
'
}

show_vps_system() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result
    result=$(agent_request "$address" "$token" GET "/api/info") || {
        echo "Agent 连接失败"
        return
    }
    python3 - "$name" "$result" <<'PY'
import json
import sys
name = sys.argv[1]
try:
    d = json.loads(sys.argv[2])
except Exception:
    print("Agent 返回数据格式错误")
    sys.exit(0)
if not d.get("ok"):
    print("获取系统信息失败：" + d.get("error", "unknown error"))
    sys.exit(0)
print("========================================")
print("              系统信息")
print("========================================")
print("VPS 名称  :", name)
print("主机名    :", d.get("hostname", ""))
print("系统      :", d.get("os", ""))
print("架构      :", d.get("arch", ""))
print("WG 地址   :", d.get("wg_address", ""))
print("========================================")
PY
}

show_vps_cpu() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" \
        'echo "===== CPU ====="; lscpu | grep -E "^(CPU\(s\)|Model name|Architecture)" || true; echo; echo "===== LOAD ====="; uptime') || {
        echo "Agent 连接失败"
        return
    }
    printf '%s' "$result" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except:
    print("Agent 返回数据格式错误")
    raise SystemExit
if not d.get("ok"):
    print("执行失败:",d.get("error","unknown error"))
    raise SystemExit
print(d.get("stdout",""),end="")
if d.get("stderr"):
    print(d["stderr"],end="")
'
}
show_vps_memory() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" \
        'free -h; echo; echo "===== /proc/meminfo ====="; grep -E "^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):" /proc/meminfo') || {
        echo "Agent 连接失败"
        return
    }
    printf '%s' "$result" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except:
    print("Agent 返回数据格式错误")
    raise SystemExit
if not d.get("ok"):
    print("执行失败:",d.get("error","unknown error"))
    raise SystemExit
print(d.get("stdout",""),end="")
if d.get("stderr"):
    print(d["stderr"],end="")
'
}
show_vps_disk() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" \
        'df -hT; echo; echo "===== BLOCK DEVICES ====="; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT') || {
        echo "Agent 连接失败"
        return
    }
    printf '%s' "$result" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except:
    print("Agent 返回数据格式错误")
    raise SystemExit
if not d.get("ok"):
    print("执行失败:",d.get("error","unknown error"))
    raise SystemExit
print(d.get("stdout",""),end="")
if d.get("stderr"):
    print(d["stderr"],end="")
'
}
show_vps_network() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result
    result=$(agent_request "$address" "$token" POST "/api/command" \
        'echo "===== INTERFACES ====="; ip -br addr; echo; echo "===== ROUTES ====="; ip route; echo; echo "===== DNS ====="; resolvectl status 2>/dev/null | grep -E "DNS Servers|Current DNS Server" || cat /etc/resolv.conf') || {
        echo "Agent 连接失败"
        return
    }
    printf '%s' "$result" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except:
    print("Agent 返回数据格式错误")
    raise SystemExit
if not d.get("ok"):
    print("执行失败:",d.get("error","unknown error"))
    raise SystemExit
print(d.get("stdout",""),end="")
if d.get("stderr"):
    print(d["stderr"],end="")
'
}
execute_vps_command() {
    local name="$1"
    local address="$2"
    local token="$3"
    local command
    local result
    echo
    echo "========================================"
    echo "              执行命令"
    echo "========================================"
    echo "VPS: $name"
    echo "WG : $address"
    echo
    read -r -p "> " command
    [ -n "$command" ] || return
    result=$(agent_request "$address" "$token" POST "/api/command" "$command") || {
        echo "Agent 连接失败"
        return
    }
    echo
    echo "========================================"
    echo "              执行结果"
    echo "========================================"
    printf '%s' "$result" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except:
    print("Agent 返回数据格式错误")
    raise SystemExit
if not d.get("ok"):
    print("执行失败:",d.get("error","unknown error"))
    if d.get("stdout"):
        print(d["stdout"],end="")
    if d.get("stderr"):
        print(d["stderr"],end="")
    raise SystemExit
if d.get("stdout"):
    print(d["stdout"],end="")
if d.get("stderr"):
    print("\n----- stderr -----")
    print(d["stderr"],end="")
print("\n返回码:",d.get("returncode",-1))
'
}
restart_vps() {
    local name="$1"
    local address="$2"
    local token="$3"
    local result

    echo
    echo "========================================"
    echo "              重启 VPS"
    echo "========================================"
    echo "VPS: $name"
    echo "WG : $address"
    echo

    read -r -p "确定重启此 VPS？输入 yes 确认: " confirm
    [ "$confirm" = "yes" ] || return

    result=$(agent_request "$address" "$token" POST "/api/command" \
        'nohup sh -c "sleep 2; /sbin/reboot" >/dev/null 2>&1 & echo "REBOOT_SCHEDULED"') || {
        echo
        echo "Agent 连接失败"
        return
    }

    echo
    if printf '%s' "$result" | python3 -c '
import json
import sys

try:
    d = json.load(sys.stdin)
except Exception:
    print("Agent 返回数据格式错误")
    raise SystemExit(1)

if not d.get("ok"):
    print("重启失败：" + str(d.get("error", "unknown error")))
    raise SystemExit(1)

print(d.get("stdout", ""), end="")
' ; then
        echo
        echo "VPS 重启已安排，约 2 秒后重启。"
    else
        echo
        echo "重启命令执行失败"
    fi

    sleep 2
}
manage_single_vps() {
    local index="$1"
    local name
    local address
    local token
    local agent_token
    name=$(get_vps_field "$index" name)
    address=$(get_vps_field "$index" wg_address)
    token=$(get_vps_field "$index" token)
    agent_token=$(get_vps_field "$index" agent_token)
    if [ -z "$name" ] || [ -z "$address" ]; then
        echo "VPS 数据不完整"
        sleep 1
        return
    fi
    if [ -z "$agent_token" ]; then
        echo
        echo "此 VPS 尚未保存 Agent Token"
        echo "请重新运行 Agent 注册脚本"
        echo
        read -rp "按 Enter 返回..." _
        return
    fi
    while true; do
        clear
        echo "========================================"
        echo "              VPS 管理"
        echo "========================================"
        echo
        echo "VPS 名称 : $name"
        echo "WG 地址  : $address"
        echo
        echo "1. 查看系统信息"
        echo "2. CPU"
        echo "3. 内存"
        echo "4. 磁盘"
        echo "5. 网络"
        echo "6. 执行命令"
        echo "7. 重启 VPS"
        echo "0. 返回"
        echo
        read -rp "请选择: " action
        case "$action" in
            1)
                clear
                show_vps_system "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            2)
                clear
                show_vps_cpu "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            3)
                clear
                show_vps_memory "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            4)
                clear
                show_vps_disk "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            5)
                clear
                show_vps_network "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            6)
                clear
                execute_vps_command "$name" "$address" "$agent_token"
                echo
                read -rp "按 Enter 返回..." _
                ;;
            7)
                restart_vps "$name" "$address" "$agent_token"
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}
manage_vps() {
    while true; do
        clear
        echo "========================================"
        echo "              管理 VPS"
        echo "========================================"
        echo
        local count
        count=$(get_vps_count)
        if [ "$count" -eq 0 ]; then
            echo "暂无 VPS"
            echo
            read -rp "按 Enter 返回..." _
            return
        fi
        python3 - "$VPS_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for i, x in enumerate(data.get("vps", []), 1):
    name = x.get("name", "")
    country = x.get("country", "")
    ipv4 = x.get("ipv4", "")
    address = x.get("wg_address", "")
    online = x.get("online", False)
    print(
        f"{i}. {name:<18} "
        f"{country:<15} "
        f"{ipv4:<16} "
        f"{address:<15} "
        f"{'在线' if online else '离线'}"
    )
PY
        echo
        echo "0. 返回"
        echo
        read -rp "请选择 VPS: " choice
        [ "$choice" = "0" ] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            manage_single_vps "$((choice - 1))"
        else
            echo "无效选择"
            sleep 1
        fi
    done
}
delete_vps() {
    local name="$1"
    python3 - "$VPS_FILE" "$name" <<'PY'
import json
import sys
p, name = sys.argv[1:]
with open(p, encoding="utf-8") as f:
    data = json.load(f)
data["vps"] = [x for x in data.get("vps", []) if x.get("name") != name]
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
    chmod 600 "$VPS_FILE"
}
delete_vps_menu() {
    local count
    count=$(get_vps_count)
    if [ "$count" -eq 0 ]; then
        echo "暂无 VPS"
        read -rp "按 Enter 返回..." _
        return
    fi
    clear
    echo "========================================"
    echo "              删除 VPS"
    echo "========================================"
    echo
    python3 - "$VPS_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for i, x in enumerate(data.get("vps", []), 1):
    print(f"{i}. {x.get('name','')} {x.get('wg_address','')}")
PY
    echo
    echo "0. 返回"
    echo
    read -rp "请选择 VPS: " choice
    [ "$choice" = "0" ] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo "无效选择"
        sleep 1
        return
    fi
    local name
    local address
    name=$(get_vps_field "$((choice - 1))" name)
    address=$(get_vps_field "$((choice - 1))" wg_address)
    echo
    read -rp "确认删除 [$name]？输入 yes: " confirm
    [ "$confirm" = "yes" ] || return
    delete_vps "$name"
    rebuild_wg_config
    echo "VPS 已删除"
    sleep 1
}
update_script() {
    echo
    echo "========================================"
    echo "              更新管理脚本"
    echo "========================================"
    echo
    local tmp="${LOCAL_SCRIPT}.tmp"
    rm -f "$tmp"
    echo "正在下载最新版本..."
    if ! curl -fsSL --connect-timeout 5 --max-time 30 "$SCRIPT_URL" -o "$tmp"; then
        rm -f "$tmp"
        echo
        echo "脚本下载失败"
        echo "原脚本没有修改"
        echo
        read -rp "按 Enter 返回..." _
        return
    fi
    chmod 700 "$tmp"
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        echo
        echo "脚本语法检查失败"
        echo "原脚本没有修改"
        echo
        read -rp "按 Enter 返回..." _
        return
    fi
    mv -f "$tmp" "$LOCAL_SCRIPT"
    echo
    echo "脚本更新成功"
    echo
    exec /bin/bash "$LOCAL_SCRIPT" --menu
}
delete_script() {
    echo
    echo "========================================"
    echo "          删除中央 VPS 管理系统"
    echo "========================================"
    echo
    echo "将删除："
    echo
    echo "  central-vps.service"
    echo "  $WG_INTERFACE"
    echo "  $WG_CONFIG"
    echo "  $WG_PRIVATE_KEY"
    echo "  $WG_PUBLIC_KEY"
    echo "  /etc/central-vps"
    echo "  /usr/local/bin/central-vps.sh"
    echo
    echo "不会删除："
    echo "  route64"
    echo "  central0"
    echo "  其他 WireGuard"
    echo "  WireGuard 软件包"
    echo
    read -rp "确认删除？输入 yes: " confirm
    [ "$confirm" = "yes" ] || return
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
    echo
    echo "中央 VPS 管理系统已删除"
    echo
    exit 0
}
main() {
    mkdir -p "$(dirname "$LOCAL_SCRIPT")"
    if [ ! -f "$LOCAL_SCRIPT" ]; then
        local tmp="${LOCAL_SCRIPT}.tmp"
        echo "首次运行，正在下载中央 VPS 管理脚本..."
        if ! curl -fsSL --connect-timeout 5 --max-time 30 "$SCRIPT_URL" -o "$tmp"; then
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
            echo "========================================"
            echo "          中央 VPS 管理脚本"
            echo "========================================"
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
                *)
                    echo "无效选择"
                    sleep 1
                    ;;
            esac
        done
        ;;
    *)
        main
        ;;
esac
