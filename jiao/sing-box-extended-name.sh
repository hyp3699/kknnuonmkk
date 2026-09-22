#!/bin/bash
export LANG=en_US.UTF-8
# --- 颜色和基础工具函数 ---
re="\033[0m"
red="\033[1;91m"
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

BASE_DIR="/etc/sing-box"
CONF_DIR="$BASE_DIR/conf"
DATA_DIR="$BASE_DIR/user_manager"
EXT_LIMITER_DIR="$DATA_DIR/extended_limiters"
EXT_TRAFFIC_LIMITER="$EXT_LIMITER_DIR/traffic-limiter.json"
EXT_BANDWIDTH_LIMITER="$EXT_LIMITER_DIR/bandwidth-limiter.json"

mkdir -p "$EXT_LIMITER_DIR"
BACKUP_DIR="$DATA_DIR/backups"
LIMIT_DIR="$DATA_DIR/limits"
TRAFFIC_DIR="$DATA_DIR/traffic"
DISABLED_USER_DIR="$DATA_DIR/disabled_users"
TRAFFIC_SCRIPT="$TRAFFIC_DIR/singbox_traffic.py"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
TRAFFIC_LOG="$TRAFFIC_DIR/traffic.log"
SINGBOX="$BASE_DIR/sing-box"
SERVICE="sing-box"
TRAFFIC_SERVICE="singbox-traffic.service"
PYTHON="$(command -v python3 2>/dev/null || true)"
CONFIG_LOCK="$DATA_DIR/.config.lock"
TRAFFIC_SCRIPT_CHANGED=0
INBOUND_TAG="${1:-}"
TRAFFIC_USER="${2:-}"

init_traffic() {
    mkdir -p "$TRAFFIC_DIR"
    mkdir -p "$LIMIT_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$EXT_LIMITER_DIR"

    # 初始化永久流量统计状态
    if [ ! -f "$TRAFFIC_STATE" ]; then
        cat > "$TRAFFIC_STATE" <<'EOF'
{
  "users": {},
  "connections": {},
  "stats_counters": {}
}
EOF
        chmod 600 "$TRAFFIC_STATE"
    fi

    # 初始化 Extended Traffic Limiter
    if [ ! -f "$EXT_TRAFFIC_LIMITER" ]; then
        cat > "$EXT_TRAFFIC_LIMITER" <<'EOF'
{
  "outbounds": [
    {
      "type": "traffic-limiter",
      "tag": "traffic-limiter",
      "strategy": "users",
      "users": []
    }
  ]
}
EOF
        chmod 600 "$EXT_TRAFFIC_LIMITER"
    fi

    # 初始化 Extended Bandwidth Limiter
    if [ ! -f "$EXT_BANDWIDTH_LIMITER" ]; then
        cat > "$EXT_BANDWIDTH_LIMITER" <<'EOF'
{
  "outbounds": [
    {
      "type": "bandwidth-limiter",
      "tag": "bandwidth-limiter",
      "strategy": "users",
      "flow_keys": [
        "user"
      ],
      "users": []
    }
  ]
}
EOF
        chmod 600 "$EXT_BANDWIDTH_LIMITER"
    fi
}

title() {
    clear
    echo
    echo -e "${green}╔════════════════════════════════════════════╗${re}"
    printf "${green}║${re} %-42s ${green}║${re}\n" "$1"
    echo -e "${green}╚════════════════════════════════════════════╝${re}"
    echo
}

backup_file() {
    local file="$1"
    local name
    name="$(basename "$file")"
    cp -a "$file" "$BACKUP_DIR/${name}.$(date +%Y%m%d_%H%M%S).bak"
}

cleanup_backups() {
    find "$BACKUP_DIR" -type f \( -name '*.bak' -o -name '*.json' \) -mtime +15 -delete 2>/dev/null
}

reload_singbox() {
    systemctl reload "$SERVICE" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        return 0
    fi
    systemctl restart "$SERVICE" >/dev/null 2>&1
    return $?
}

check_config() {
    "$SINGBOX" check -C "$CONF_DIR" >/dev/null 2>&1
    return $?
}

restore_file() {
    local file="$1"
    local backup="$2"
    cp -a "$backup" "$file"
}

find_backup() {
    local file="$1"
    local name
    name="$(basename "$file")"
    ls -1t "$BACKUP_DIR/${name}."*.bak 2>/dev/null | head -n1
}

list_nodes() {
    "$PYTHON" - "$CONF_DIR" <<'PY'
import sys
import json
import glob
import os

conf_dir = sys.argv[1]
for fn in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    try:
        with open(fn, "r", encoding="utf-8") as f:
            data = json.load(f)
    except:
        continue
    for inbound in data.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue
        tag = inbound.get("tag", "")
        typ = inbound.get("type", "")
        users = inbound.get("users", [])
        if tag and isinstance(users, list):
            print("{}\t{}\t{}\t{}\t{}".format(
                os.path.basename(fn),
                tag,
                typ,
                len(users),
                inbound.get("listen_port", "")
            ))
PY
}

get_node_info() {
    local file="$1"
    local tag="$2"
    "$PYTHON" - "$CONF_DIR/$file" "$tag" <<'PY'
import sys
import json

fn = sys.argv[1]
tag = sys.argv[2]
with open(fn, "r", encoding="utf-8") as f:
    data = json.load(f)
for inbound in data.get("inbounds", []):
    if inbound.get("tag") == tag:
        print(json.dumps(inbound, ensure_ascii=False))
        break
PY
}
sync_v2ray_stats_users() {
    "$PYTHON" - "$CONF_DIR" "$CONF_DIR/config.json" <<'PY'
import sys
import json
import glob
import os

conf_dir = sys.argv[1]
config_file = sys.argv[2]

names = []
seen = set()

for fn in sorted(glob.glob(os.path.join(conf_dir, "*.json"))):
    if os.path.abspath(fn) == os.path.abspath(config_file):
        continue
    try:
        with open(fn, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        continue

    for inbound in data.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue

        for user in inbound.get("users", []):
            if not isinstance(user, dict):
                continue

            name = str(user.get("name", "")).strip()
            if name and name not in seen:
                seen.add(name)
                names.append(name)

try:
    with open(config_file, "r", encoding="utf-8") as f:
        config = json.load(f)
except Exception as e:
    print(f"读取 config.json 失败: {e}", file=sys.stderr)
    raise SystemExit(1)

experimental = config.get("experimental")
if not isinstance(experimental, dict):
    print("config.json 缺少 experimental", file=sys.stderr)
    raise SystemExit(1)

v2ray_api = experimental.get("v2ray_api")
if not isinstance(v2ray_api, dict):
    print("config.json 缺少 experimental.v2ray_api", file=sys.stderr)
    raise SystemExit(1)

stats = v2ray_api.get("stats")
if not isinstance(stats, dict):
    print("config.json 缺少 experimental.v2ray_api.stats", file=sys.stderr)
    raise SystemExit(1)

if not stats.get("enabled"):
    print("experimental.v2ray_api.stats 未启用", file=sys.stderr)
    raise SystemExit(1)

stats["users"] = names

with open(config_file, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")

os.chmod(config_file, 0o600)
print(f"V2Ray Stats 用户已同步: {len(names)}")
PY
}
stop_traffic_service() {
    echo "正在停止流量统计服务..."
    systemctl stop "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    echo "流量统计服务已停止"
    pause
}
reset_traffic_script() {
    clear
    echo "========================================"
    echo "        重置流量统计脚本"
    echo "========================================"
    echo
    echo "此操作将删除流量统计模块创建的全部文件："
    echo
    echo "  $TRAFFIC_DIR"
    echo "  $LIMIT_DIR"
    echo "  $BACKUP_DIR"
    echo "  $TRAFFIC_SCRIPT"
    echo "  /etc/systemd/system/$TRAFFIC_SERVICE"
    echo
    read -r -p "确认重置并重新安装？输入 y 确认: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        pause
        return
    fi
    echo
    echo "正在停止流量统计服务..."
    systemctl stop "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    echo "正在删除流量统计模块..."
    rm -rf "$TRAFFIC_DIR"
    rm -rf "$LIMIT_DIR"
    rm -rf "$BACKUP_DIR"
    rm -f "$TRAFFIC_SCRIPT"
    rm -f "/etc/systemd/system/$TRAFFIC_SERVICE"
    systemctl daemon-reload
    rm -f "$CONFIG_LOCK"
    echo "正在重新创建流量统计模块..."
    init_traffic
    init_traffic_service
    echo
    if systemctl is-active --quiet "$TRAFFIC_SERVICE"; then
        echo "========================================"
        echo "重置并重新安装完成"
        echo "流量统计服务：运行中"
        echo "========================================"
    else
        echo "========================================"
        echo "重置完成，但流量统计服务启动失败"
        echo "========================================"
        echo
        systemctl status "$TRAFFIC_SERVICE" --no-pager -l 2>/dev/null || true
    fi
    pause
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

show_user_traffic_inline() {
    local user="$1"
    if [ ! -f "$TRAFFIC_STATE" ]; then
        echo -e "${yellow}未统计${re}"
        return
    fi
    local traffic
    traffic="$(get_user_traffic "$user")"
    local uplink
    local downlink
    local total
    local connections
    local period_uplink
    local period_downlink
    local period_total
    read -r uplink downlink total connections period_uplink period_downlink period_total <<< "$traffic"
    echo -e "上传 $(format_bytes "$uplink")"
    echo -e "下载 $(format_bytes "$downlink")"
    echo -e "总计 $(format_bytes "$total")"
    echo -e "本周期 $(format_bytes "$period_total")"
    echo -e "连接 $connections"
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

set_limit() {
    local username="$1"

    while true; do
        clear
        echo "========== 流量限制设置 =========="
        echo
        echo "用户：$username"
        echo
        echo "请输入限制流量："
        echo "例如：100GB"
        echo "例如：500MB"
        echo "输入 0 取消限制"
        echo

        read -rp "限制：" limit_input

        if [ "$limit_input" = "0" ]; then
            disable_limit "$username"
            return
        fi

        if [[ ! "$limit_input" =~ ^[0-9]+([KMGT]B|[kmgt]b)?$ ]]; then
            echo "格式错误，例如：100GB"
            sleep 2
            continue
        fi

        limit_input=$(echo "$limit_input" | tr '[:lower:]' '[:upper:]')

        local period="none"

        echo
        echo "请选择限制周期："
        echo "1. 一次性"
        echo "2. 每天"
        echo "3. 每月"
        echo "0. 取消"
        echo

        read -rp "请选择 [1-3]：" period_choice

        case "$period_choice" in
            1)
                period="none"
                ;;
            2)
                period="day"
                ;;
            3)
                period="month"
                ;;
            0)
                return
                ;;
            *)
                echo "选择错误"
                sleep 1
                continue
                ;;
        esac

        mkdir -p "$LIMIT_DIR"

        "$PYTHON" - "$username" "$limit_input" "$period" "$LIMIT_DIR/${username}.json" <<'PY'
import sys
import json
import os
from pathlib import Path
from datetime import datetime, timezone

username = sys.argv[1]
limit_value = sys.argv[2]
period = sys.argv[3]
filename = sys.argv[4]

old = {}

if os.path.exists(filename):
    try:
        with open(filename, "r", encoding="utf-8") as f:
            old = json.load(f)
    except Exception:
        old = {}

data = {
    "user": username,
    "limit_value": limit_value,
    "limit_bytes": 0,
    "period": period,
    "enabled": True,
    "disabled_by_limit": False,
    "saved_user": old.get("saved_user"),
    "config_file": old.get("config_file"),
    "updated_at": datetime.now(timezone.utc).isoformat()
}

units = {
    "B": 1,
    "KB": 1024,
    "MB": 1024 ** 2,
    "GB": 1024 ** 3,
    "TB": 1024 ** 4
}

if limit_value.isdigit():
    data["limit_bytes"] = int(limit_value) * 1024 ** 3
else:
    number = ""
    unit = ""

    for c in limit_value:
        if c.isdigit():
            number += c
        else:
            unit += c

    if number and unit in units:
        data["limit_bytes"] = int(number) * units[unit]

Path(filename).write_text(
    json.dumps(data, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

os.chmod(filename, 0o600)
PY

        echo
        echo "流量限制已保存："
        echo "额度：$limit_input"

        case "$period" in
            none)  echo "周期：一次性" ;;
            day)   echo "周期：每天" ;;
            month) echo "周期：每月" ;;
        esac

        echo

        # 生成 Extended Traffic Limiter
        extended_update_traffic_limiter "$username" "$limit_input"

        read -rp "按回车继续..."
        return
    done
}


extended_update_traffic_limiter() {
    local username="$1"
    local limit="$2"

    mkdir -p "$EXT_LIMITER_DIR"

    "$PYTHON" - "$EXT_TRAFFIC_LIMITER" "$username" "$limit" <<'PY'
import sys
import json
from pathlib import Path

filename = sys.argv[1]
username = sys.argv[2]
limit = sys.argv[3]

data = {
    "outbounds": [
        {
            "type": "traffic-limiter",
            "tag": "traffic-limiter",
            "strategy": "users",
            "users": []
        }
    ]
}

path = Path(filename)

if path.exists():
    try:
        old = json.loads(path.read_text(encoding="utf-8"))

        if isinstance(old, dict):
            data = old
    except Exception:
        pass

outbound = None

for item in data.get("outbounds", []):
    if item.get("type") == "traffic-limiter":
        outbound = item
        break

if outbound is None:
    outbound = {
        "type": "traffic-limiter",
        "tag": "traffic-limiter",
        "strategy": "users",
        "users": []
    }
    data.setdefault("outbounds", []).append(outbound)

users = outbound.setdefault("users", [])

users = [
    x for x in users
    if x.get("name") != username
]

users.append({
    "name": username,
    "strategy": "global",
    "mode": "bidirectional",
    "total": limit
})

outbound["users"] = users
outbound["strategy"] = "users"

path.write_text(
    json.dumps(data, ensure_ascii=False, indent=2),
    encoding="utf-8"
)
PY

    chmod 600 "$EXT_TRAFFIC_LIMITER"

    echo "Extended Traffic Limiter 已更新"
}

extended_remove_traffic_limiter() {
    local username="$1"

    [ -f "$EXT_TRAFFIC_LIMITER" ] || return 0

    "$PYTHON" - "$EXT_TRAFFIC_LIMITER" "$username" <<'PY'
import sys
import json
from pathlib import Path

filename = sys.argv[1]
username = sys.argv[2]

path = Path(filename)

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    exit(0)

for outbound in data.get("outbounds", []):
    if outbound.get("type") != "traffic-limiter":
        continue

    outbound["users"] = [
        x for x in outbound.get("users", [])
        if x.get("name") != username
    ]

path.write_text(
    json.dumps(data, ensure_ascii=False, indent=2),
    encoding="utf-8"
)
PY
}

set_upload_limit() {
    local username="$1"

    clear
    echo "========== 上传限速 =========="
    echo
    echo "用户：$username"
    echo
    echo "例如：1MB"
    echo "例如：10MB"
    echo "输入 0 取消上传限速"
    echo

    read -rp "上传速度：" speed

    if [ "$speed" = "0" ]; then
        extended_remove_bandwidth_limiter "$username" "upload"
        echo "上传限速已关闭"
        sleep 1
        return
    fi

    if [[ ! "$speed" =~ ^[0-9]+([KMGT]B|[kmgt]b)$ ]]; then
        echo "格式错误，例如 10MB"
        sleep 2
        return
    fi

    speed=$(echo "$speed" | tr '[:lower:]' '[:upper:]')

    extended_update_bandwidth_limiter "$username" "upload" "$speed"

    echo
    echo "上传限速：$speed"
    sleep 1
}
set_download_limit() {
    local username="$1"

    clear
    echo "========== 下载限速 =========="
    echo
    echo "用户：$username"
    echo
    echo "例如：1MB"
    echo "例如：20MB"
    echo "输入 0 取消下载限速"
    echo

    read -rp "下载速度：" speed

    if [ "$speed" = "0" ]; then
        extended_remove_bandwidth_limiter "$username" "download"
        echo "下载限速已关闭"
        sleep 1
        return
    fi

    if [[ ! "$speed" =~ ^[0-9]+([KMGT]B|[kmgt]b)$ ]]; then
        echo "格式错误，例如 20MB"
        sleep 2
        return
    fi

    speed=$(echo "$speed" | tr '[:lower:]' '[:upper:]')

    extended_update_bandwidth_limiter "$username" "download" "$speed"

    echo
    echo "下载限速：$speed"
    sleep 1
}
extended_update_bandwidth_limiter() {
    local username="$1"
    local mode="$2"
    local speed="$3"

    mkdir -p "$EXT_LIMITER_DIR"

    "$PYTHON" - "$EXT_BANDWIDTH_LIMITER" "$username" "$mode" "$speed" <<'PY'
import sys
import json
from pathlib import Path

filename = sys.argv[1]
username = sys.argv[2]
mode = sys.argv[3]
speed = sys.argv[4]

path = Path(filename)

data = {
    "outbounds": [
        {
            "type": "bandwidth-limiter",
            "tag": "bandwidth-limiter",
            "strategy": "users",
            "flow_keys": ["user"],
            "users": []
        }
    ]
}

if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        pass

outbound = None

for item in data.get("outbounds", []):
    if item.get("type") == "bandwidth-limiter":
        outbound = item
        break

if outbound is None:
    outbound = {
        "type": "bandwidth-limiter",
        "tag": "bandwidth-limiter",
        "strategy": "users",
        "flow_keys": ["user"],
        "users": []
    }
    data.setdefault("outbounds", []).append(outbound)

users = [
    x for x in outbound.get("users", [])
    if not (
        x.get("name") == username
        and x.get("mode") == mode
    )
]

users.append({
    "name": username,
    "strategy": "global",
    "mode": mode,
    "speed": speed
})

outbound["users"] = users
outbound["strategy"] = "users"
outbound["flow_keys"] = ["user"]

path.write_text(
    json.dumps(data, ensure_ascii=False, indent=2),
    encoding="utf-8"
)
PY

    chmod 600 "$EXT_BANDWIDTH_LIMITER"

    echo "Extended Bandwidth Limiter 已更新"
}

extended_remove_bandwidth_limiter() {
    local username="$1"
    local mode="$2"

    [ -f "$EXT_BANDWIDTH_LIMITER" ] || return 0

    "$PYTHON" - "$EXT_BANDWIDTH_LIMITER" "$username" "$mode" <<'PY'
import sys
import json
from pathlib import Path

filename = sys.argv[1]
username = sys.argv[2]
mode = sys.argv[3]

path = Path(filename)

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    exit(0)

for outbound in data.get("outbounds", []):
    if outbound.get("type") != "bandwidth-limiter":
        continue

    outbound["users"] = [
        x for x in outbound.get("users", [])
        if not (
            x.get("name") == username
            and x.get("mode") == mode
        )
    ]

path.write_text(
    json.dumps(data, ensure_ascii=False, indent=2
    ),
    encoding="utf-8"
)
PY
}


disable_limit() {
    local username="$1"

    mkdir -p "$LIMIT_DIR"

    "$PYTHON" - "$LIMIT_DIR/${username}.json" <<'PY'
import sys
import json
import os
from pathlib import Path

filename = sys.argv[1]

data = {}

if os.path.exists(filename):
    try:
        data = json.loads(
            Path(filename).read_text(encoding="utf-8")
        )
    except Exception:
        data = {}

data["enabled"] = False
data["disabled_by_limit"] = False
data["limit_bytes"] = 0

Path(filename).write_text(
    json.dumps(data, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

os.chmod(filename, 0o600)
PY

    extended_remove_traffic_limiter "$username"

    echo
    echo "用户 $username 的流量限制已关闭"
    sleep 1
}

set_limit_period() {
    local user="$1"
    if [ -z "$user" ]; then
        red "错误：未获取到用户名"
        pause
        return 1
    fi
    local lf="$LIMIT_DIR/${user}.json"
    title "设置时间周期"
    if [ ! -f "$lf" ]; then
        red "请先设置流量限制"
        pause
        return
    fi
    echo "1) 每天重置"
    echo "2) 每月重置"
    echo "3) 不重置"
    echo "0) 返回"
    local choice
    read -rp "$(green "请选择: ")" choice
    local period=""
    case "$choice" in
        1) period="day" ;;
        2) period="month" ;;
        3) period="none" ;;
        0) return ;;
        *) red "无效选择"; pause; return ;;
    esac
    local result
    result="$("$PYTHON" - "$lf" "$period" "$TRAFFIC_STATE" <<'PY'
import sys
import json
import os
from pathlib import Path
from datetime import datetime, timedelta
fn = Path(sys.argv[1])
period = sys.argv[2]
state_file = Path(sys.argv[3])
try:
    with open(fn, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
user = data.get("user")
if not user:
    print("ERROR")
    raise SystemExit(1)
now = datetime.now().astimezone()
if period == "day":
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=1)
elif period == "month":
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if start.month == 12:
        end = start.replace(year=start.year + 1, month=1, day=1)
    else:
        end = start.replace(month=start.month + 1, day=1)
else:
    start = None
    end = None
start_iso = start.isoformat() if start else None
end_iso = end.isoformat() if end else None
data["period"] = period
data["period_start"] = start_iso
data["period_end"] = end_iso
data["enabled"] = True
with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(fn, 0o600)
try:
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    state = {"users": {}, "connections": {}}
users = state.setdefault("users", {})
u = users.setdefault(user, {})
u["period"] = period
u["period_uplink"] = 0
u["period_downlink"] = 0
u["period_total"] = 0
u["period_start"] = start_iso
u["period_end"] = end_iso
tmp = state_file.with_name(state_file.name + ".tmp")
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, state_file)
print("OK")
PY
)"
    if [ $? -ne 0 ] || [ "$result" != "OK" ]; then
        red "时间周期设置失败"
        pause
        return
    fi
    if ! sync_v2ray_stats_users >/dev/null; then
        red "V2Ray Stats 用户同步失败"
        pause
        return
    fi
    case "$period" in
        day)
            green "时间周期已设置：每天重置"
            ;;
        month)
            green "时间周期已设置：每月重置"
            ;;
        none)
            green "时间周期已设置：不重置"
            ;;
    esac
    echo "本次设置会从当前时间重新计算本周期流量。"
    pause
}

show_bandwidth_limit() {
    local username="$1"

    clear
    echo "========== 用户限速 =========="
    echo
    echo "用户：$username"
    echo

    if [ ! -f "$EXT_BANDWIDTH_LIMITER" ]; then
        echo "上传限速：未设置"
        echo "下载限速：未设置"
        read -rp "按回车继续..."
        return
    fi

    "$PYTHON" - "$EXT_BANDWIDTH_LIMITER" "$username" <<'PY'
import sys
import json
from pathlib import Path

filename = sys.argv[1]
username = sys.argv[2]

try:
    data = json.loads(
        Path(filename).read_text(encoding="utf-8")
    )
except Exception:
    print("配置读取失败")
    sys.exit(0)

found = {
    "upload": None,
    "download": None
}

for outbound in data.get("outbounds", []):
    if outbound.get("type") != "bandwidth-limiter":
        continue

    for item in outbound.get("users", []):
        if item.get("name") != username:
            continue

        mode = item.get("mode")
        speed = item.get("speed")

        if mode in found:
            found[mode] = speed

print("上传限速：" + (found["upload"] or "不限速"))
print("下载限速：" + (found["download"] or "不限速"))
PY

    echo
    read -rp "按回车继续..."
}

main_menu() {
    local username="$1"

    while true; do
        clear
        echo "========== 用户流量管理 =========="
        echo
        echo "用户：$username"
        echo

        show_user_traffic_inline "$username"

        echo
        show_limit "$username"

        echo
        echo "========== 管理 =========="
        echo "1) 流量设置"
        echo "2) 时间设置"
        echo "3) 关闭流量限制"
        echo "4) 上传限速"
        echo "5) 下载限速"
        echo "6) 查看限速"
        echo "0) 返回"
        echo

        read -rp "请选择：" choice

        case "$choice" in
            1)
                set_limit "$username"
                ;;
            2)
                set_limit_period "$username"
                ;;
            3)
                disable_limit "$username"
                ;;
            4)
                set_upload_limit "$username"
                ;;
            5)
                set_download_limit "$username"
                ;;
            6)
                show_bandwidth_limit "$username"
                ;;
            0)
                return
                ;;
        esac
    done
}

main_menu "$@"
