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
    TRAFFIC_SCRIPT_CHANGED=0
    mkdir -p "$TRAFFIC_DIR" "$LIMIT_DIR" "$BACKUP_DIR"
    chmod 700 "$TRAFFIC_DIR" "$LIMIT_DIR" "$BACKUP_DIR"
        local traffic_grpcurl="$TRAFFIC_DIR/grpcurl"
    local traffic_proto="$TRAFFIC_DIR/stats.proto"
    local grpcurl_version="1.9.3"
    local grpcurl_url="https://github.com/fullstorydev/grpcurl/releases/download/v${grpcurl_version}/grpcurl_${grpcurl_version}_linux_x86_64.tar.gz"
    if [ ! -x "$traffic_grpcurl" ]; then
        echo "正在安装 grpcurl..."
        local grpcurl_tmp
        local grpcurl_dir
        grpcurl_tmp="$(mktemp)"
        grpcurl_dir="$(mktemp -d)"
        if command -v curl >/dev/null 2>&1; then
            if ! curl -fL --retry 3 --connect-timeout 15 --max-time 120 "$grpcurl_url" -o "$grpcurl_tmp"; then
                rm -f "$grpcurl_tmp"
                rm -rf "$grpcurl_dir"
                echo "错误：下载 grpcurl v${grpcurl_version} 失败"
                return 1
            fi
        elif command -v wget >/dev/null 2>&1; then
            if ! wget -q --timeout=30 --tries=3 -O "$grpcurl_tmp" "$grpcurl_url"; then
                rm -f "$grpcurl_tmp"
                rm -rf "$grpcurl_dir"
                echo "错误：下载 grpcurl v${grpcurl_version} 失败"
                return 1
            fi
        else
            rm -f "$grpcurl_tmp"
            rm -rf "$grpcurl_dir"
            echo "错误：系统没有 curl 或 wget，无法安装 grpcurl"
            return 1
        fi
        if ! tar -xzf "$grpcurl_tmp" -C "$grpcurl_dir" grpcurl; then
            rm -f "$grpcurl_tmp"
            rm -rf "$grpcurl_dir"
            echo "错误：解压 grpcurl 失败"
            return 1
        fi
        if [ ! -f "$grpcurl_dir/grpcurl" ]; then
            rm -f "$grpcurl_tmp"
            rm -rf "$grpcurl_dir"
            echo "错误：解压后找不到 grpcurl"
            return 1
        fi
        if ! install -m 755 "$grpcurl_dir/grpcurl" "$traffic_grpcurl"; then
            rm -f "$grpcurl_tmp"
            rm -rf "$grpcurl_dir"
            echo "错误：安装 grpcurl 失败"
            return 1
        fi
        rm -f "$grpcurl_tmp"
        rm -rf "$grpcurl_dir"
        echo "grpcurl 安装完成"
    fi
    if [ ! -f "$traffic_proto" ]; then
        echo "正在生成 stats.proto..."
        local tmp_proto
        tmp_proto="$(mktemp)"
        cat > "$tmp_proto" <<'PROTO'
syntax = "proto3";
package v2ray.core.app.stats.command;
option go_package = "github.com/sagernet/sing-box/experimental/v2rayapi";
message GetStatsRequest {
  string name = 1;
  bool reset = 2;
}
message Stat {
  string name = 1;
  int64 value = 2;
}
message GetStatsResponse {
  Stat stat = 1;
}
message QueryStatsRequest {
  string pattern = 1;
  bool reset = 2;
  repeated string patterns = 3;
  bool regexp = 4;
}
message QueryStatsResponse {
  repeated Stat stat = 1;
}
message GetSysStatsRequest {}
message SysStatsResponse {
  uint32 NumGoroutine = 1;
  uint32 NumGC = 2;
  uint64 Alloc = 3;
  uint64 TotalAlloc = 4;
  uint64 Sys = 5;
  uint64 Mallocs = 6;
  uint64 Frees = 7;
  uint64 LiveObjects = 8;
  uint64 PauseTotalNs = 9;
  uint32 Uptime = 10;
}
service StatsService {
  rpc GetStats(GetStatsRequest) returns (GetStatsResponse) {}
  rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse) {}
  rpc GetSysStats(GetSysStatsRequest) returns (SysStatsResponse) {}
}
PROTO
        if ! install -m 600 "$tmp_proto" "$traffic_proto"; then
            rm -f "$tmp_proto"
            echo "错误：安装 stats.proto 失败"
            return 1
        fi
        rm -f "$tmp_proto"
        echo "stats.proto 安装完成"
    fi
    if [ ! -f "$TRAFFIC_STATE" ]; then
        cat > "$TRAFFIC_STATE" <<'JSON'
{
  "users": {},
  "connections": {},
  "stats_counters": {}
}
JSON
        chmod 600 "$TRAFFIC_STATE"
    fi
    local tmp_script
    tmp_script="$(mktemp)"
    cat > "$tmp_script" <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import time
import signal
import tempfile
import sys
from pathlib import Path
from datetime import datetime, timedelta
BASE_DIR = Path("/etc/sing-box")
CONF_DIR = BASE_DIR / "conf"
DATA_DIR = BASE_DIR / "user_manager"
LIMIT_DIR = DATA_DIR / "limits"
TRAFFIC_DIR = DATA_DIR / "traffic"
STATE_FILE = TRAFFIC_DIR / "state.json"
LOG_FILE = TRAFFIC_DIR / "traffic.log"
BACKUP_DIR = DATA_DIR / "backups"
LOCK_FILE = DATA_DIR / ".config.lock"
SINGBOX = BASE_DIR / "sing-box"
SERVICE = "sing-box"
GRPC_HOST = "127.0.0.1"
GRPC_PORT = 9094
GRPCURL = str(TRAFFIC_DIR / "grpcurl")
PROTO_FILE = str(TRAFFIC_DIR / "stats.proto")
CONFIG_FILE = CONF_DIR / "config.json"
SAVE_INTERVAL = 5
POLL_INTERVAL = 5
RECONNECT_INTERVAL = 3
running = True
def log(msg):
    try:
        TRAFFIC_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(datetime.now().astimezone().isoformat() + " " + str(msg) + "\n")
    except Exception:
        pass
def atomic_write_json(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    fd = None
    tmp = None

    try:
        fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))

        with os.fdopen(fd, "w", encoding="utf-8") as f:
            fd = None
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())

        os.chmod(tmp, mode)
        os.replace(tmp, path)

        return True

    except Exception as e:
        log(f"写入JSON失败 {path}: {e}")
        return False

    finally:
        if fd is not None:
            try:
                os.close(fd)
            except Exception:
                pass

        if tmp:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default
def save_state(state):
    atomic_write_json(STATE_FILE, state, 0o600)
def period_window(period, now=None):
    if now is None:
        now = datetime.now().astimezone()
    if period == "day":
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        end = start + timedelta(days=1)
        return start, end
    if period == "month":
        start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        if start.month == 12:
            end = start.replace(year=start.year + 1, month=1, day=1)
        else:
            end = start.replace(month=start.month + 1, day=1)
        return start, end
    return None, None
def period_name(meta):
    if not isinstance(meta, dict):
        return "none"
    period = meta.get("period")
    if period in ("day", "daily"):
        return "day"
    if period in ("month", "monthly"):
        return "month"
    return "none"
def limit_files():
    try:
        return sorted(LIMIT_DIR.glob("*.json"))
    except Exception:
        return []
def config_files():
    try:
        return sorted(CONF_DIR.glob("*.json"))
    except Exception:
        return []
def get_limit_meta_for_user(username):
    for path in limit_files():
        data = load_json(path, {})
        if not isinstance(data, dict):
            continue
        if data.get("user") == username:
            return path, data
    return None, None
def get_user_period(username):
    _, meta = get_limit_meta_for_user(username)
    if meta:
        return period_name(meta)
    return "month"
def find_user(tag, username):
    for fn in config_files():
        try:
            with open(fn, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            continue
        for inbound in cfg.get("inbounds", []):
            if inbound.get("tag") != tag:
                continue
            for user in inbound.get("users", []):
                if user.get("name") == username:
                    return fn, user
    return None, None
def backup_config(fn, reason):
    try:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
        target = BACKUP_DIR / f"{fn.stem}__{reason}__{stamp}.json"
        with open(fn, "rb") as src, open(target, "wb") as dst:
            dst.write(src.read())
        os.chmod(target, 0o600)
        return target
    except Exception as e:
        log(f"备份配置失败 {fn}: {e}")
        return None
def check_config():
    try:
        r = subprocess.run([str(SINGBOX), "check", "-C", str(CONF_DIR)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        if r.returncode != 0:
            log("sing-box check失败: " + r.stdout[-3000:])
            return False
        return True
    except Exception as e:
        log(f"sing-box check异常: {e}")
        return False
def reload_singbox():
    try:
        r = subprocess.run(["systemctl", "reload", SERVICE], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        if r.returncode == 0:
            return True
        r = subprocess.run(["systemctl", "restart", SERVICE], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        if r.returncode != 0:
            log("sing-box restart失败: " + r.stdout[-3000:])
            return False
        return True
    except Exception as e:
        log(f"reload/restart异常: {e}")
        return False
def acquire_lock():
    try:
        import fcntl
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        fp = open(LOCK_FILE, "w")
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX)
        return fp
    except Exception as e:
        log(f"获取配置锁失败: {e}")
        return None
def disable_user(username):
    if not username:
        return False
    lock = acquire_lock()
    if lock is None:
        return False
    backup_root = Path(DATA_DIR) / "disabled_users" / username
    changed_files = []
    def rollback_changes():
        for fn in changed_files:
            backup_file = backup_root / fn.name
            if not backup_file.exists():
                continue
            try:
                backup_data = load_json(backup_file, None)
                current_cfg = load_json(fn, None)
                if not isinstance(backup_data, dict) or not isinstance(current_cfg, dict):
                    continue
                for saved in backup_data.get("users", []):
                    if not isinstance(saved, dict):
                        continue
                    inbound_index = saved.get("inbound_index")
                    saved_user = saved.get("user")
                    if not isinstance(inbound_index, int) or not isinstance(saved_user, dict):
                        continue
                    inbounds = current_cfg.get("inbounds", [])
                    if inbound_index < 0 or inbound_index >= len(inbounds):
                        continue
                    inbound = inbounds[inbound_index]
                    if not isinstance(inbound, dict):
                        continue
                    users = inbound.setdefault("users", [])
                    if not isinstance(users, list):
                        continue
                    if not any(isinstance(u, dict) and u.get("name") == username for u in users):
                        users.append(saved_user)
                atomic_write_json(fn, current_cfg, 0o600)
            except Exception as e:
                log(f"恢复用户失败: {username} -> {fn}: {e}")
    try:
        backup_root.mkdir(parents=True, exist_ok=True)
        found = False
        for fn in config_files():
            if fn.name == "config.json":
                continue
            cfg = load_json(fn, None)
            if not isinstance(cfg, dict):
                continue
            file_backup = []
            file_changed = False
            for inbound_index, inbound in enumerate(cfg.get("inbounds", [])):
                users = inbound.get("users")
                if not isinstance(users, list):
                    continue
                new_users = []
                removed_users = []
                for u in users:
                    if isinstance(u, dict) and u.get("name") == username:
                        removed_users.append({
                            "inbound_index": inbound_index,
                            "user": u
                        })
                        file_changed = True
                        found = True
                    else:
                        new_users.append(u)
                if removed_users:
                    inbound["users"] = new_users
                    file_backup.extend(removed_users)
            if not file_changed:
                continue
            backup_file = backup_root / fn.name
            backup_data = {
                "config_file": str(fn),
                "users": file_backup
            }
            if not atomic_write_json(backup_file, backup_data, 0o600):
                log(f"备份用户失败，未修改配置: {username} -> {fn}")
                return False
            if not atomic_write_json(fn, cfg, 0o600):
                log(f"删除用户后保存配置失败: {username} -> {fn}")
                return False
            changed_files.append(fn)
        if not found:
            existing_backup = list(backup_root.glob("*.json"))
            if existing_backup:
                return True
            log(f"达到流量限制，但找不到用户: {username}")
            return False
        if not check_config():
            log(f"达到流量限制后配置检查失败，恢复用户: {username}")
            rollback_changes()
            return False
        if not reload_singbox():
            log(f"达到流量限制后sing-box重载失败，恢复用户: {username}")
            rollback_changes()
            reload_singbox()
            return False
        log(f"用户已因流量达到限制而停用: {username}")
        return True
    finally:
        try:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        lock.close()

def restore_user(username):
    if not username:
        return False
    lock = acquire_lock()
    if lock is None:
        return False
    backup_root = Path(DATA_DIR) / "disabled_users" / username
    try:
        backup_files = sorted(backup_root.glob("*.json"))
        if not backup_files:
            log(f"周期恢复用户失败，找不到备份: {username}")
            return False
        restored_any = False
        changed_files = []
        for backup_file in backup_files:
            backup_data = load_json(backup_file, None)
            if not isinstance(backup_data, dict):
                continue
            config_file = backup_data.get("config_file")
            saved_users = backup_data.get("users", [])
            if not config_file or not isinstance(saved_users, list):
                continue
            fn = Path(config_file)
            if not fn.exists():
                log(f"恢复用户失败，配置文件不存在: {fn}")
                continue
            cfg = load_json(fn, None)
            if not isinstance(cfg, dict):
                continue
            inbounds = cfg.get("inbounds", [])
            if not isinstance(inbounds, list):
                continue
            changed = False
            for saved in saved_users:
                if not isinstance(saved, dict):
                    continue
                inbound_index = saved.get("inbound_index")
                saved_user = saved.get("user")
                if not isinstance(inbound_index, int) or not isinstance(saved_user, dict):
                    continue
                if inbound_index < 0 or inbound_index >= len(inbounds):
                    log(f"恢复用户失败，入站索引无效: {username} -> {fn} [{inbound_index}]")
                    continue
                inbound = inbounds[inbound_index]
                if not isinstance(inbound, dict):
                    continue
                users = inbound.setdefault("users", [])
                if not isinstance(users, list):
                    continue
                if any(isinstance(u, dict) and u.get("name") == username for u in users):
                    restored_any = True
                    continue
                users.append(saved_user)
                changed = True
                restored_any = True
            if changed:
                if not atomic_write_json(fn, cfg, 0o600):
                    log(f"恢复用户保存配置失败: {username} -> {fn}")
                    return False
                changed_files.append(fn)
        if not restored_any:
            log(f"恢复用户失败，备份中没有有效用户: {username}")
            return False
        if not check_config():
            log(f"恢复用户后配置检查失败: {username}")
            return False
        if not reload_singbox():
            log(f"恢复用户后sing-box重载失败: {username}")
            return False
        import shutil
        shutil.rmtree(backup_root, ignore_errors=True)
        log(f"用户已恢复并清理停用备份: {username}")
        return True
    finally:
        try:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        lock.close()
        
def update_limit_file(fn, data):
    atomic_write_json(fn, data, 0o600)
def ensure_user(state, username):
    if not username:
        return None
    users = state.setdefault("users", {})
    current_period = get_user_period(username)
    if username not in users:
        start, end = period_window(current_period)
        users[username] = {
            "uplink": 0,
            "downlink": 0,
            "total": 0,
            "connections": 0,
            "period": current_period,
            "period_uplink": 0,
            "period_downlink": 0,
            "period_total": 0,
            "period_start": start.isoformat() if start else None,
            "period_end": end.isoformat() if end else None
        }
    else:
        u = users[username]
        u.setdefault("uplink", 0)
        u.setdefault("downlink", 0)
        u.setdefault("total", 0)
        u.setdefault("connections", 0)
        u.setdefault("period", current_period)
        u.setdefault("period_uplink", 0)
        u.setdefault("period_downlink", 0)
        u.setdefault("period_total", 0)
        u.setdefault("period_start", None)
        u.setdefault("period_end", None)
    return users[username]
def add_traffic(state, username, uplink=0, downlink=0):
    if not username:
        return
    uplink = max(0, int(uplink or 0))
    downlink = max(0, int(downlink or 0))
    if uplink == 0 and downlink == 0:
        return
    u = ensure_user(state, username)
    u["uplink"] = int(u.get("uplink", 0)) + uplink
    u["downlink"] = int(u.get("downlink", 0)) + downlink
    u["total"] = int(u.get("uplink", 0)) + int(u.get("downlink", 0))
    u["period_uplink"] = int(u.get("period_uplink", 0) or 0) + uplink
    u["period_downlink"] = int(u.get("period_downlink", 0) or 0) + downlink
    u["period_total"] = u["period_uplink"] + u["period_downlink"]
def sync_periods(state):
    changed = False
    now = datetime.now().astimezone()
    users = state.setdefault("users", {})
    for username, u in users.items():
        current_period = get_user_period(username)
        start, end = period_window(current_period, now)
        start_iso = start.isoformat() if start else None
        end_iso = end.isoformat() if end else None
        stored_period = u.get("period")
        stored_start = u.get("period_start")
        stored_end = u.get("period_end")
        if stored_period != current_period:
            u["period"] = current_period
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            changed = True
            continue
        if current_period in ("day", "month") and (not stored_start or not stored_end):
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            changed = True
            continue
        try:
            stored_end_dt = datetime.fromisoformat(stored_end)
        except Exception:
            stored_end_dt = None
        if current_period in ("day", "month") and (stored_end_dt is None or now >= stored_end_dt):
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            changed = True
    for lf in limit_files():
        data = load_json(lf, {})
        if not isinstance(data, dict):
            continue
        username = data.get("user")
        if not username:
            continue
        period = period_name(data)
        start, end = period_window(period, now)
        start_iso = start.isoformat() if start else None
        end_iso = end.isoformat() if end else None
        if period in ("day", "month") and data.get("period_start") != start_iso:
            if data.get("disabled_by_limit"):
                if not restore_user(username):
                    log(f"周期已到但恢复用户失败: {username}")
                    continue
            data["period_start"] = start_iso
            data["period_end"] = end_iso
            data["disabled_by_limit"] = False
            update_limit_file(lf, data)
            changed = True
    return changed
def check_limits(state):
    for lf in limit_files():
        data = load_json(lf, {})
        if not isinstance(data, dict):
            continue
        username = data.get("user")
        if not username:
            continue
        if not data.get("enabled"):
            if data.get("disabled_by_limit"):
                if restore_user(username):
                    data["disabled_by_limit"] = False
                    update_limit_file(lf, data)
            continue
        try:
            limit_bytes = int(data.get("limit_bytes", 0) or 0)
        except Exception:
            limit_bytes = 0
        if limit_bytes <= 0:
            continue
        u = state.get("users", {}).get(username, {})
        current_total = int(u.get("period_total", 0) or 0)
        used = current_total
        if data.get("disabled_by_limit"):
            continue
        if used >= limit_bytes:
            if disable_user(username):
                data["disabled_by_limit"] = True
                update_limit_file(lf, data)
def get_stats():
    if not os.path.exists(GRPCURL):
        log(f"找不到grpcurl: {GRPCURL}")
        return None
    if not os.path.exists(PROTO_FILE):
        log(f"找不到Stats proto: {PROTO_FILE}")
        return None
    cmd = [
        GRPCURL,
        "-plaintext",
        "-import-path",
        str(Path(PROTO_FILE).parent),
        "-proto",
        PROTO_FILE,
        "-d",
        '{"pattern":"user>>>.*>>>traffic>>>.*","reset":false,"regexp":true}',
        f"{GRPC_HOST}:{GRPC_PORT}",
        "v2ray.core.app.stats.command.StatsService/QueryStats"
    ]
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    except Exception as e:
        log(f"QueryStats执行异常: {e}")
        return None
    if r.returncode != 0:
        log(f"QueryStats失败: {r.stderr[-2000:]}")
        return None
    try:
        result = json.loads(r.stdout)
    except Exception as e:
        log(f"QueryStats返回JSON解析失败: {e}; output={r.stdout[-2000:]}")
        return None
    stats = {}
    for item in result.get("stat", []):
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", ""))
        value = item.get("value", 0)
        try:
            value = int(value)
        except Exception:
            continue
        parts = name.split(">>>")
        if len(parts) != 4:
            continue
        if parts[0] != "user" or parts[2] != "traffic":
            continue
        username = parts[1]
        direction = parts[3]
        if direction not in ("uplink", "downlink"):
            continue
        if username not in stats:
            stats[username] = {"uplink": 0, "downlink": 0}
        stats[username][direction] = max(0, value)
    return stats
def process_stats(state, current_stats):
    if not isinstance(current_stats, dict):
        return False
    changed = False
    counters = state.setdefault("stats_counters", {})
    seen_users = set()
    for username, current in current_stats.items():
        if not username:
            continue
        seen_users.add(username)
        current_uplink = max(0, int(current.get("uplink", 0) or 0))
        current_downlink = max(0, int(current.get("downlink", 0) or 0))
        previous = counters.get(username)
        if not isinstance(previous, dict):
            delta_uplink = current_uplink
            delta_downlink = current_downlink
        else:
            previous_uplink = max(0, int(previous.get("uplink", 0) or 0))
            previous_downlink = max(0, int(previous.get("downlink", 0) or 0))
            if current_uplink >= previous_uplink:
                delta_uplink = current_uplink - previous_uplink
            else:
                delta_uplink = current_uplink
            if current_downlink >= previous_downlink:
                delta_downlink = current_downlink - previous_downlink
            else:
                delta_downlink = current_downlink
        if delta_uplink or delta_downlink:
            add_traffic(state, username, delta_uplink, delta_downlink)
            changed = True
        counters[username] = {"uplink": current_uplink, "downlink": current_downlink}
    return changed
def update_connection_count(state):
    for username, data in state.setdefault("users", {}).items():
        data["connections"] = 0
def initialize_periods(state):
    changed = False
    now = datetime.now().astimezone()
    users = state.setdefault("users", {})
    for username, u in users.items():
        period = get_user_period(username)
        start, end = period_window(period, now)
        start_iso = start.isoformat() if start else None
        end_iso = end.isoformat() if end else None
        if u.get("period") != period:
            u["period"] = period
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            changed = True
            continue
        if period in ("day", "month") and (not u.get("period_start") or not u.get("period_end")):
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            changed = True
            continue
        try:
            stored_end = datetime.fromisoformat(u["period_end"])
        except Exception:
            stored_end = None
        if stored_end is None or now >= stored_end:
            u["period_uplink"] = 0
            u["period_downlink"] = 0
            u["period_total"] = 0
            u["period_start"] = start_iso
            u["period_end"] = end_iso
            changed = True
    for lf in limit_files():
        data = load_json(lf, {})
        if not isinstance(data, dict):
            continue
        username = data.get("user")
        if not username:
            continue
        period = period_name(data)
        start, end = period_window(period, now)
        start_iso = start.isoformat() if start else None
        end_iso = end.isoformat() if end else None
        if period in ("day", "month") and data.get("period_start") != start_iso:
            data["period_start"] = start_iso
            data["period_end"] = end_iso
            update_limit_file(lf, data)
    return changed
def signal_handler(signum, frame):
    global running
    running = False
signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)
def main():
    TRAFFIC_DIR.mkdir(parents=True, exist_ok=True)
    LIMIT_DIR.mkdir(parents=True, exist_ok=True)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    state = load_json(STATE_FILE, {"users": {}, "connections": {}, "stats_counters": {}})
    if not isinstance(state, dict):
        state = {"users": {}, "connections": {}, "stats_counters": {}}
    state.setdefault("users", {})
    state.setdefault("connections", {})
    state.setdefault("stats_counters", {})
    initialize_periods(state)
    update_connection_count(state)
    save_state(state)
    log("singbox traffic collector started (V2Ray Stats API)")
    last_save = time.monotonic()
    while running:
        try:
            sync_periods(state)
            update_connection_count(state)
            check_limits(state)
            current_stats = get_stats()
            if current_stats is not None:
                process_stats(state, current_stats)
                update_connection_count(state)
                check_limits(state)
            now = time.monotonic()
            if now - last_save >= SAVE_INTERVAL:
                sync_periods(state)
                update_connection_count(state)
                check_limits(state)
                save_state(state)
                last_save = now
            if current_stats is None:
                time.sleep(RECONNECT_INTERVAL)
            else:
                time.sleep(POLL_INTERVAL)
        except Exception as e:
            log(f"collector异常: {type(e).__name__}: {e}")
            try:
                save_state(state)
            except Exception:
                pass
            time.sleep(RECONNECT_INTERVAL)
    try:
        update_connection_count(state)
        save_state(state)
    except Exception:
        pass
    log("singbox traffic collector stopped")
if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "restore_user":
        username = sys.argv[2]
        if restore_user(username):
            print("OK")
            raise SystemExit(0)
        print("FAIL")
        raise SystemExit(1)
    main()
PY
    chmod 700 "$tmp_script"
    if [ ! -f "$TRAFFIC_SCRIPT" ] || ! cmp -s "$tmp_script" "$TRAFFIC_SCRIPT"; then
        install -m 700 "$tmp_script" "$TRAFFIC_SCRIPT"
        TRAFFIC_SCRIPT_CHANGED=1
    fi
    rm -f "$tmp_script"
}
init_traffic_service() {
    local service_file="/etc/systemd/system/$TRAFFIC_SERVICE"
    local tmp_service
    tmp_service="$(mktemp)"
    cat > "$tmp_service" <<EOF
[Unit]
Description=sing-box Traffic Collector
After=network-online.target sing-box.service
Wants=network-online.target
Requires=sing-box.service
[Service]
Type=simple
ExecStart=$PYTHON $TRAFFIC_SCRIPT
Restart=always
RestartSec=3
User=root
Group=root
UMask=0077
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
    local service_changed=0
    if [ ! -f "$service_file" ] || ! cmp -s "$tmp_service" "$service_file"; then
        install -m 644 "$tmp_service" "$service_file"
        service_changed=1
    fi
    rm -f "$tmp_service"
    if [ "$service_changed" -eq 1 ]; then
        systemctl daemon-reload
    fi
    systemctl enable "$TRAFFIC_SERVICE" >/dev/null 2>&1
    if [ "$TRAFFIC_SCRIPT_CHANGED" -eq 1 ] || [ "$service_changed" -eq 1 ]; then
        systemctl restart "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    elif ! systemctl is-active --quiet "$TRAFFIC_SERVICE"; then
        systemctl start "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
    fi
}

mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$LIMIT_DIR"

if [ -z "$PYTHON" ]; then
    red "错误：系统没有 python3"
    exit 1
fi

if [ ! -x "$SINGBOX" ]; then
    red "错误：未找到 $SINGBOX"
    exit 1
fi

if [ ! -d "$CONF_DIR" ]; then
    red "错误：未找到 $CONF_DIR"
    exit 1
fi

init_traffic
init_traffic_service
if [ "${1:-}" = "--init" ]; then
    exit 0
fi

pause() {
    echo
    read -rp "$(yellow "按回车继续...")" _
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
    find "$BACKUP_DIR" -type f -name '*.bak' -mtime +30 -delete 2>/dev/null
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
    local user="$1"
    if [ -z "$user" ]; then
        red "错误：未获取到用户名"
        pause
        return 1
    fi
    local lf="$LIMIT_DIR/${user}.json"
    title "流量限制"
    show_limit "$user"
    echo
    echo -e "${skyblue}支持:${re}"
    echo -e "  100MB   = 100MB"
    echo -e "  1GB     = 1GB"
    echo -e "  0       = 关闭流量限制"
    echo
    local input
    read -rp "$(green "请输入流量限制: ")" input
    input="$(echo "$input" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    if [ "$input" = "0" ]; then
        disable_limit "$user"
        return
    fi
    local number
    local unit
    if [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        number="$input"
        unit="GB"
    elif [[ "$input" =~ ^[0-9]+([.][0-9]+)?MB$ ]]; then
        number="${input%MB}"
        unit="MB"
    elif [[ "$input" =~ ^[0-9]+([.][0-9]+)?GB$ ]]; then
        number="${input%GB}"
        unit="GB"
    else
        red "格式错误"
        echo "例如：2、100MB、1GB、500MB"
        pause
        return
    fi
    if ! "$PYTHON" - "$number" "$unit" "$lf" "$user" "$TRAFFIC_STATE" <<'PY'
import sys
import json
import os
number = float(sys.argv[1])
unit = sys.argv[2]
fn = sys.argv[3]
user = sys.argv[4]
state_file = sys.argv[5]
if number <= 0:
    raise SystemExit("限制必须大于 0")
if unit == "GB":
    limit_bytes = int(number * 1024 * 1024 * 1024)
else:
    limit_bytes = int(number * 1024 * 1024)
old = {}
if os.path.exists(fn):
    try:
        with open(fn, "r", encoding="utf-8") as f:
            old = json.load(f)
    except Exception:
        pass
try:
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    state = {}
users = state.setdefault("users", {})
u = users.get(user, {})
if not isinstance(u, dict):
    u = {}
u["period_uplink"] = 0
u["period_downlink"] = 0
u["period_total"] = 0
users[user] = u
tmp_state = state_file + ".tmp"
with open(tmp_state, "w", encoding="utf-8") as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp_state, 0o600)
os.replace(tmp_state, state_file)
data = {
    "user": user,
    "limit_value": number,
    "limit_unit": unit,
    "limit_bytes": limit_bytes,
    "period": old.get("period", "none"),
    "period_start": old.get("period_start"),
    "period_end": old.get("period_end"),
    "enabled": True,
    "disabled_by_limit": False,
    "saved_user": old.get("saved_user"),
    "config_file": old.get("config_file")
}
with open(fn, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(fn, 0o600)
PY
    then
        red "流量限制保存失败"
        pause
        return
    fi
    local user_exists
    user_exists="$("$PYTHON" - "$user" "$CONF_DIR" <<'PY'
import sys
import json
from pathlib import Path
user = sys.argv[1]
conf_dir = Path(sys.argv[2])
found = False
for fn in conf_dir.glob("*.json"):
    try:
        with open(fn, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        continue
    for inbound in cfg.get("inbounds", []):
        for u in inbound.get("users", []):
            if isinstance(u, dict) and u.get("name") == user:
                found = True
                break
        if found:
            break
    if found:
        break
print("YES" if found else "NO")
PY
)"
        if [ "$user_exists" = "NO" ]; then
        if /usr/bin/python3 /etc/sing-box/user_manager/traffic/singbox_traffic.py restore_user "$user" >/dev/null 2>&1; then
            green "用户已恢复到入站"
        fi
    fi
    green "流量限制已设置：${number}${unit}"
    echo
    echo "当前时间周期："
    case "$("$PYTHON" - "$lf" <<'PY'
import sys
import json
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        print(json.load(f).get("period", "none"))
except:
    print("none")
PY
)" in
        day)
            echo "每天重置"
            ;;
        month)
            echo "每月重置"
            ;;
        *)
            echo "不重置"
            ;;
    esac
    echo
    echo "本次限制从当前已使用流量之后开始计算。"
    pause
}

disable_limit() {
    local user="$1"
    if [ -z "$user" ]; then
        red "错误：未获取到用户名"
        pause
        return 1
    fi
    local lf="$LIMIT_DIR/${user}.json"
    if [ ! -f "$lf" ]; then
        yellow "当前没有设置流量限制"
        pause
        return
    fi
    local result
    result="$("$PYTHON" - "$lf" <<'PY'
import sys
import json
from pathlib import Path
lf = Path(sys.argv[1])
try:
    with open(lf, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("ERROR")
    raise SystemExit(1)
user = data.get("user")
if not user:
    print("ERROR")
    raise SystemExit(1)
data["enabled"] = False
data["limit_value"] = 0
data["limit_unit"] = "GB"
data["limit_bytes"] = 0
data["disabled_by_limit"] = False
with open(lf, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(lf, 0o600)
print("OK")
PY
)"
    if [ $? -ne 0 ] || [ "$result" != "OK" ]; then
        red "解除流量限制失败"
        pause
        return
    fi
    if ! sync_v2ray_stats_users >/dev/null; then
        red "V2Ray Stats 用户同步失败"
        pause
        return
    fi
        if /usr/bin/python3 /etc/sing-box/user_manager/traffic/singbox_traffic.py restore_user "$user" >/dev/null 2>&1; then
        green "流量限制已解除"
    else
        green "流量限制已解除"
        echo "用户当前未恢复，可能没有可用的停用备份。"
    fi
    pause
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
main_menu() {
    cleanup_backups
    local user="$1"
    while true; do
        title "流量设置"
        echo -e "  ${red}a)${re} 停止流量统计"
        echo -e "  ${red}b)${re} 重置流量统计脚本"
        echo
        show_limit "$user"
        echo
        echo -e "  ${green}1)${re} 流量设置"
        echo -e "  ${green}2)${re} 时间设置"
        echo -e "  ${green}3)${re} 关闭流量限制"
        echo -e "  ${yellow}0)${re} 返回"
        echo

        if ! read -rp "$(green "请选择: ")" choice; then
            return
        fi

        case "$choice" in
            a|A)
                systemctl stop "$TRAFFIC_SERVICE" >/dev/null 2>&1 || true
                green "流量统计服务已停止"
                pause
                ;;
            b|B)
                reset_traffic_script
                ;;
            1)
                set_limit "$user"
                ;;
            2)
                set_limit_period "$user"
                ;;
            3)
                disable_limit "$user"
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

main_menu "$@"
