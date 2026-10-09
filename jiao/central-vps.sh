#!/bin/bash
# 注意：交互式菜单脚本不使用全局 set -e，否则任何一个返回非零的命令（如读取不存在的文件）
# 都会让整个菜单直接退出。关键步骤均有显式错误检查。
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
SSH_KEY_DIR="$BASE_DIR/ssh"
SSH_PRIVATE_KEY="$SSH_KEY_DIR/central_vps"
SSH_PUBLIC_KEY="$SSH_PRIVATE_KEY.pub"
SSH_KNOWN_HOSTS="$SSH_KEY_DIR/known_hosts"
VPS_LOCK="$DATA_DIR/.vps.lock"
SUB_DIR=/etc/central-vps-sub
NGINX_USERS_DIR=/etc/nginx/conf.d/central_vps_users
NGINX_OLD_MAIN_CONF=/etc/nginx/conf.d/central_vps_sub.conf
# sing-box 安装脚本（原 http://cfsb.133134.xyz 跳转到的 sing-box-cf08.sh 已 404，改为 HTTPS 直连仓库）
SINGBOX_INSTALL_URL="${SINGBOX_INSTALL_URL:-https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing-box-08.sh}"
mkdir -p "$BASE_DIR" "$DATA_DIR"
chmod 700 "$BASE_DIR" "$DATA_DIR"
[ -f "$VPS_FILE" ] || echo '{"vps":[]}' > "$VPS_FILE"
chmod 600 "$VPS_FILE"

# 在 vps.json 上加排他锁后执行一段 Python 修改，并原子写回。
# 用法: vps_json_update '<python 代码，操作变量 data，参数在 args 列表>' 参数...
# 与 API 服务端共用同一把锁，避免注册和菜单同时写文件导致丢数据。
vps_json_update() {
    local code="$1"
    shift
    python3 - "$VPS_FILE" "$VPS_LOCK" "$code" "$@" <<'PY'
import fcntl, json, os, sys, tempfile
path, lock, code = sys.argv[1:4]
args = sys.argv[4:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    env = {"data": data, "args": args, "sys": sys}
    exec(code, env)
    data = env["data"]
    d = os.path.dirname(path)
    tfd, tmp = tempfile.mkstemp(prefix=".vps.", dir=d)
    with os.fdopen(tfd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
PY
}

# 一次性读出所有 VPS 的常用字段：index\tname\twg_address(无掩码)\tagent_token\tipv4（空值为 -）
vps_list_tsv() {
    python3 - "$VPS_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        vps = json.load(f).get("vps", [])
except Exception:
    vps = []
for i, v in enumerate(vps):
    if not isinstance(v, dict):
        continue
    clean = lambda s: str(s or "").replace("\t", " ").replace("\n", " ")
    addr = clean(v.get("wg_address")).split("/")[0]
    # 空字段一律输出 "-"：bash 的 IFS=$'\t' 会把连续 tab 合并，空字段会导致错位
    print("\t".join([str(i), clean(v.get("name")) or "-", addr or "-", clean(v.get("agent_token")) or "-", clean(v.get("ipv4")) or "-"]))
PY
}
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
import urllib.request
import urllib.error
import threading
import time
import fcntl
import re
from contextlib import contextmanager
from datetime import datetime,timezone,timedelta
from http.server import HTTPServer,BaseHTTPRequestHandler

FILE=sys.argv[1]
PORT=int(sys.argv[2])
WG_PUBLIC_FILE=sys.argv[3]
WG_PORT=int(sys.argv[4])
WG_INTERFACE=sys.argv[5]
WG_NETWORK=sys.argv[6]
WG_CONFIG=sys.argv[7]
TRAFFIC_LOCK="/etc/central-vps/data/.traffic.lock"
VPS_LOCK=os.path.join(os.path.dirname(FILE),".vps.lock")

@contextmanager
def vps_lock():
    fd=os.open(VPS_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

@contextmanager
def traffic_lock():
    fd=os.open(TRAFFIC_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

def load():
    with open(FILE,"r",encoding="utf-8") as f:
        return json.load(f)

def save(data):
    tmp=FILE+".tmp.%d"%os.getpid()
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

def agent_command(address,token,command):
    if not address or not token:
        return False
    url="http://{}:18090/api/command".format(address)
    payload=json.dumps({"command":command},ensure_ascii=False).encode("utf-8")
    req=urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Authorization":"Bearer "+token,
            "Content-Type":"application/json"
        }
    )
    try:
        with urllib.request.urlopen(req,timeout=35) as response:
            result=json.loads(response.read().decode("utf-8"))
        return int(result.get("returncode",1))==0
    except Exception:
        return False

def delete_user_from_all_vps(username):
    db=load()
    vps_list=db.get("vps",[])
    if not isinstance(vps_list,list):
        return False
    if not username or not all(c.isalnum() or c in "._-" for c in username):
        return False
    failed=False
    command="export SB_LOAD_ONLY=1; source /etc/sing-box/sb.sh; delete_user \"{}\" 1 0".format(username)
    for item in vps_list:
        if not isinstance(item,dict):
            failed=True
            continue
        address=item.get("wg_address","")
        token=item.get("agent_token","")
        if address:
            address=address.split("/")[0]
        if not address or not token:
            failed=True
            continue
        if not agent_command(address,token,command):
            failed=True
    return not failed

def restore_user_to_all_vps(username):
    db=load()
    vps_list=db.get("vps",[])
    if not isinstance(vps_list,list):
        return False
    if not username or not all(c.isalnum() or c in "._-" for c in username):
        return False
    user_dir=os.path.join(os.path.dirname(FILE),"users",username)
    uuid_file=os.path.join(user_dir,"uuid")
    try:
        with open(uuid_file,"r",encoding="utf-8") as f:
            uuid=f.read().strip()
    except Exception:
        return False
    if not uuid:
        return False
    failed=False
    command="export SB_LOAD_ONLY=1; source /etc/sing-box/sb.sh; add_user_menu \"{}\" \"{}\" \"\" \"central\"".format(username,uuid)
    for item in vps_list:
        if not isinstance(item,dict):
            failed=True
            continue
        address=item.get("wg_address","")
        token=item.get("agent_token","")
        if address:
            address=address.split("/")[0]
        if not address or not token:
            failed=True
            continue
        if not agent_command(address,token,command):
            failed=True
    return not failed

def get_current_period(period):
    # 与菜单端统一使用系统本地时区（例如 Asia/Shanghai），周期在本地 0 点切换
    now=datetime.now().astimezone()
    if period=="day":
        start=now.replace(hour=0,minute=0,second=0,microsecond=0)
        end=start+timedelta(days=1)
        return start.isoformat(),end.isoformat()
    if period=="month":
        start=now.replace(day=1,hour=0,minute=0,second=0,microsecond=0)
        if start.month==12:
            end=start.replace(year=start.year+1,month=1)
        else:
            end=start.replace(month=start.month+1)
        return start.isoformat(),end.isoformat()
    return "",""

def parse_period_end(value):
    if not value:
        return None
    try:
        text=str(value)
        if text.endswith("Z"):
            text=text[:-1]+"+00:00"
        dt=datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt=dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return None

def check_expired_periods():
    with traffic_lock():
        users_dir=os.path.join(os.path.dirname(FILE),"users")
        if not os.path.isdir(users_dir):
            return
        now=datetime.now(timezone.utc)
        try:
            usernames=os.listdir(users_dir)
        except Exception:
            return
        for username in usernames:
            if not username or not all(c.isalnum() or c in "._-" for c in username):
                continue
            user_dir=os.path.join(users_dir,username)
            traffic_file=os.path.join(user_dir,"traffic.json")
            if not os.path.isfile(traffic_file):
                continue
            try:
                with open(traffic_file,"r",encoding="utf-8") as f:
                    traffic=json.load(f)
            except Exception:
                continue
            if not isinstance(traffic,dict):
                continue
            period=traffic.get("period","")
            if period not in ("day","month"):
                continue
            period_end=parse_period_end(traffic.get("period_end",""))
            if period_end is not None and now<period_end:
                continue
            period_start,period_end_text=get_current_period(period)
            if not period_start or not period_end_text:
                continue
            was_disabled=bool(traffic.get("disabled_by_limit",False))
            limit=traffic.get("limit",{})
            if not isinstance(limit,dict):
                limit={}
            traffic["period_upload"]=0
            traffic["period_download"]=0
            traffic["period_total"]=0
            restored=True
            if was_disabled and bool(limit.get("enabled",False)):
                restored=restore_user_to_all_vps(username)
            if restored:
                traffic["period_start"]=period_start
                traffic["period_end"]=period_end_text
                traffic["disabled_by_limit"]=False
            else:
                traffic["period_start"]=period_start
                traffic["disabled_by_limit"]=True
            tmp=traffic_file+".tmp"
            try:
                with open(tmp,"w",encoding="utf-8") as f:
                    json.dump(traffic,f,ensure_ascii=False,indent=2)
                    f.flush()
                    os.fsync(f.fileno())
                os.chmod(tmp,0o600)
                os.replace(tmp,traffic_file)
            except Exception:
                try:
                    os.unlink(tmp)
                except Exception:
                    pass

def check_user_limit(username,traffic):
    if not isinstance(traffic,dict):
        return
    limit=traffic.get("limit",{})
    if not isinstance(limit,dict):
        return
    if not bool(limit.get("enabled",False)):
        return
    try:
        limit_bytes=int(limit.get("limit_bytes",0) or 0)
    except Exception:
        limit_bytes=0
    if limit_bytes<=0:
        return
    try:
        period_total=int(traffic.get("period_total",0) or 0)
    except Exception:
        period_total=0
    disabled=bool(traffic.get("disabled_by_limit",False))
    if period_total<limit_bytes or disabled:
        return
    if not delete_user_from_all_vps(username):
        return
    traffic["disabled_by_limit"]=True
    traffic_file=os.path.join(
        os.path.dirname(FILE),
        "users",
        username,
        "traffic.json"
    )
    tmp=traffic_file+".tmp"
    try:
        with open(tmp,"w",encoding="utf-8") as f:
            json.dump(traffic,f,ensure_ascii=False,indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp,0o600)
        os.replace(tmp,traffic_file)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass

def save_traffic_report(source_address,traffic_data):
    with traffic_lock():
        if not isinstance(traffic_data,dict):
            return False,"invalid traffic data"
        db=load()
        vps_item=None
        for x in db.get("vps",[]):
            if not isinstance(x,dict):
                continue
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
            if not all(c.isalnum() or c in "._-" for c in username):
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
            vps_store=traffic.get("vps",{})
            if not isinstance(vps_store,dict):
                vps_store={}
            traffic["vps"]=vps_store
            try:
                current_upload=max(0,int(data.get("upload",0) or 0))
            except Exception:
                current_upload=0
            try:
                current_download=max(0,int(data.get("download",0) or 0))
            except Exception:
                current_download=0
            try:
                current_total=max(0,int(data.get("total",0) or 0))
            except Exception:
                current_total=0
            old_vps=vps_store.get(vps_name,{})
            if not isinstance(old_vps,dict):
                old_vps={}
            has_last_snapshot=(
                "last_upload" in old_vps
                and "last_download" in old_vps
                and "last_total" in old_vps
            )
            def as_int(v):
                try:
                    return max(0,int(v or 0))
                except Exception:
                    return 0
            def counter_delta(current,last):
                # sing-box 重启后计数器归零：current<last 时，本次增量就是 current 本身
                return current-last if current>=last else current
            if not has_last_snapshot:
                # 第一次上报只建立基线，不计入周期流量（与原逻辑一致）
                delta_upload=0
                delta_download=0
                delta_total=0
                acc_upload=current_upload
                acc_download=current_download
                acc_total=current_total
            else:
                delta_upload=counter_delta(current_upload,as_int(old_vps.get("last_upload")))
                delta_download=counter_delta(current_download,as_int(old_vps.get("last_download")))
                delta_total=counter_delta(current_total,as_int(old_vps.get("last_total")))
                # upload/download/total 保存累计值，计数器重置后不会倒退
                acc_upload=as_int(old_vps.get("upload"))+delta_upload
                acc_download=as_int(old_vps.get("download"))+delta_download
                acc_total=as_int(old_vps.get("total"))+delta_total
            vps_store[vps_name]={
                "wg_address":source_address,
                "upload":acc_upload,
                "download":acc_download,
                "total":acc_total,
                "last_upload":current_upload,
                "last_download":current_download,
                "last_total":current_total
            }
            total_upload=0
            total_download=0
            total=0
            for vps_data in vps_store.values():
                if not isinstance(vps_data,dict):
                    continue
                try:
                    total_upload+=max(0,int(vps_data.get("upload",0) or 0))
                except Exception:
                    pass
                try:
                    total_download+=max(0,int(vps_data.get("download",0) or 0))
                except Exception:
                    pass
                try:
                    total+=max(0,int(vps_data.get("total",0) or 0))
                except Exception:
                    pass
            traffic["upload"]=total_upload
            traffic["download"]=total_download
            traffic["total"]=total
            limit=traffic.get("limit",{})
            if not isinstance(limit,dict):
                limit={}
            if bool(limit.get("enabled",False)):
                try:
                    period_upload=max(0,int(traffic.get("period_upload",0) or 0))
                except Exception:
                    period_upload=0
                try:
                    period_download=max(0,int(traffic.get("period_download",0) or 0))
                except Exception:
                    period_download=0
                try:
                    period_total=max(0,int(traffic.get("period_total",0) or 0))
                except Exception:
                    period_total=0
                traffic["period_upload"]=period_upload+delta_upload
                traffic["period_download"]=period_download+delta_download
                traffic["period_total"]=period_total+delta_total
            else:
                try:
                    traffic["period_upload"]=max(0,int(traffic.get("period_upload",0) or 0))
                except Exception:
                    traffic["period_upload"]=0
                try:
                    traffic["period_download"]=max(0,int(traffic.get("period_download",0) or 0))
                except Exception:
                    traffic["period_download"]=0
                try:
                    traffic["period_total"]=max(0,int(traffic.get("period_total",0) or 0))
                except Exception:
                    traffic["period_total"]=0
            tmp=traffic_file+".tmp"
            try:
                with open(tmp,"w",encoding="utf-8") as f:
                    json.dump(traffic,f,ensure_ascii=False,indent=2)
                    f.flush()
                    os.fsync(f.fileno())
                os.chmod(tmp,0o600)
                os.replace(tmp,traffic_file)
            except Exception:
                try:
                    os.unlink(tmp)
                except Exception:
                    pass
                return False,"failed to save traffic"
            check_user_limit(username,traffic)
        return True,"ok"

class Handler(BaseHTTPRequestHandler):
    timeout=15

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
            # 公钥/agent token 会被写入 WireGuard 配置和 HTTP 头，必须校验格式，防止换行注入
            if not isinstance(wg_key,str) or not re.fullmatch(r"[A-Za-z0-9+/]{43}=",wg_key):
                self.send_json(400,{"ok":False,"error":"invalid wg_public_key"})
                return
            if not isinstance(agent_token,str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,128}",agent_token):
                self.send_json(400,{"ok":False,"error":"invalid agent_token"})
                return
            with vps_lock():
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
            subprocess.run(
                [
                    "wg",
                    "set",
                    WG_INTERFACE,
                    "peer",
                    wg_key,
                    "allowed-ips",
                    item["wg_address"]+"/32"
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False
            )
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
            self.send_json(
                200,
                {
                    "ok":True,
                    "wg_address":item["wg_address"],
                    "wg_server_public_key":server_key,
                    "wg_endpoint":endpoint+":"+str(WG_PORT)
                }
            )
        except Exception as e:
            self.send_json(500,{"ok":False,"error":str(e)})

def period_checker():
    while True:
        try:
            check_expired_periods()
        except Exception:
            pass
        time.sleep(180)

threading.Thread(target=period_checker,daemon=True).start()
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
    local ssh_public_key
    read -rp "请输入 VPS 名称: " name
    [ -n "$name" ] || return
    # 名称会被用作节点文件名，限制字符防止路径穿越
    if [[ "$name" == */* || "$name" == .* || "$name" =~ [[:cntrl:]] || "$name" =~ [[:space:]] || ${#name} -gt 64 ]]; then
        red "VPS 名称不能包含 / 、空格或控制字符，不能以 . 开头，最长 64 字符"
        read -rp "按 Enter 返回..." _
        return
    fi
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
    init_ssh_key
    ssh_public_key=$(cat "$SSH_PUBLIC_KEY")

    if [ -z "$ssh_public_key" ]; then
    red "获取SSH 公钥失败"
    read -rp "按 Enter 返回..." _
    return
    fi
    if ! vps_json_update '
name,token=args
data.setdefault("vps",[]).append({"name":name,"token":token,"agent_token":"","online":False,"ipv4":"","ipv6":"","country":"","hostname":"","os":"","arch":"","wg_address":"","wg_public_key":""})
' "$name" "$token"; then
        red "写入 VPS 列表失败"
        read -rp "按 Enter 返回..." _
        return
    fi
    init_wireguard
    echo
    green "========================================"
    green "中央 VPS IPv4: $central_ip"
    green "========================================"
    green "请在目标 VPS 执行："
    echo
    echo -e "\033[33mcurl -fsSL $AGENT_URL | bash -s -- \"$central_ip\" \"$token\" \"$ssh_public_key\"\033[0m"
    echo
    green "========================================"
    read -rp "按 Enter 返回..." _
}
set_vps_offline() {
    local name="$1"
    vps_json_update '
for x in data.get("vps",[]):
    if x.get("name")==args[0]:
        x["online"]=False
' "$name"
}
agent_request() {
    local address="$1"
    local token="$2"
    local method="$3"
    local path="$4"
    local command="${5:-}"
    local url="http://${address}:18090${path}"
    # token 和命令通过环境变量传给 Python，避免出现在 ps 能看到的命令行参数里
    AGENT_REQ_TOKEN="$token" AGENT_REQ_COMMAND="$command" AGENT_REQ_URL="$url" AGENT_REQ_METHOD="$method" \
    python3 - <<'PY'
import json
import os
import urllib.request
import urllib.error
token=os.environ.get("AGENT_REQ_TOKEN","")
command=os.environ.get("AGENT_REQ_COMMAND","")
url=os.environ.get("AGENT_REQ_URL","")
method=os.environ.get("AGENT_REQ_METHOD","GET")
headers={"Authorization":f"Bearer {token}"}
if method=="GET":
    req=urllib.request.Request(url,method="GET",headers=headers)
    timeout=10
else:
    headers["Content-Type"]="application/json"
    payload=json.dumps({"command":command},ensure_ascii=False).encode("utf-8")
    req=urllib.request.Request(url,data=payload,method="POST",headers=headers)
    timeout=35
try:
    with urllib.request.urlopen(req,timeout=timeout) as response:
        print(response.read().decode("utf-8"))
except urllib.error.HTTPError as e:
    body=e.read().decode("utf-8",errors="replace")
    print(json.dumps({"ok":False,"error":f"HTTP {e.code}","detail":body},ensure_ascii=False))
except Exception as e:
    print(json.dumps({"ok":False,"error":str(e)},ensure_ascii=False))
PY
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
    local subscription_url=""
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
    subscription_url=$(cat "$user_dir/subscription_url" 2>/dev/null || true)
    echo
    green "---------------- 用户订阅 ----------------"
    if [ -n "$subscription_url" ]; then
        purple "$subscription_url"
    else
        yellow "该用户暂无订阅链接"
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

open_vps_menu() {
    local name="$1"
    local address="$2"
    if [ -z "$address" ]; then
        red "VPS WireGuard 地址为空"
        sleep 1
        return
    fi
    if [ ! -f "$SSH_PRIVATE_KEY" ]; then
        red "中央 VPS SSH 私钥不存在"
        sleep 1
        return
    fi
    clear
    green "========================================"
    green "       正在连接 $name ..."
    green "========================================"
    echo
    yellow "连接地址：$address"
    echo
    ssh \
        -tt \
        -i "$SSH_PRIVATE_KEY" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        root@"$address" sb || true
    echo
    green "已退出 $name 管理菜单"
    read -rp "按 Enter 返回..." _
}
open_vps_ssh() {
    local name="$1"
    local address="$2"
    if [ -z "$address" ]; then
        red "VPS WireGuard 地址为空"
        sleep 1
        return
    fi
    if [ ! -f "$SSH_PRIVATE_KEY" ]; then
        red "中央 VPS SSH 私钥不存在"
        sleep 1
        return
    fi
    clear
    green "========================================"
    green "       正在连接 $name ..."
    green "========================================"
    echo
    yellow "连接地址：$address"
    echo
    ssh \
        -tt \
        -i "$SSH_PRIVATE_KEY" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        root@"$address"  || true
    echo
    green "已退出 $name 管理菜单"
    read -rp "按 Enter 返回..." _
}
init_ssh_key() {
    mkdir -p "$SSH_KEY_DIR"
    chmod 700 "$SSH_KEY_DIR"

    if [ ! -f "$SSH_PRIVATE_KEY" ] || [ ! -f "$SSH_PUBLIC_KEY" ]; then
        ssh-keygen -t ed25519 \
            -f "$SSH_PRIVATE_KEY" \
            -N "" \
            -C "central-vps" >/dev/null 2>&1
    fi
    chmod 600 "$SSH_PRIVATE_KEY"
    chmod 644 "$SSH_PUBLIC_KEY"
}

manage_single_vps() {
    local index="$1"
    local info name address token agent_token ipv4 action confirm
    
    local idx
    # 读取该 VPS 字段（空值为 -），注意 IFS=tab 会合并空字段，所以 vps_list_tsv 不输出空值
    while IFS=$'\t' read -r idx name address agent_token ipv4; do
        [ "$idx" = "$index" ] && break
        name=""
    done < <(vps_list_tsv)
    [ "$address" = "-" ] && address=""
    [ "$agent_token" = "-" ] && agent_token=""
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
        green "4. 打开 VPS sing-box菜单"
        green "5. 打开 VPS SSH"
        green "s. 删除 VPS"
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
                open_vps_menu "$name" "$address"
                ;;
            5)
                clear
                open_vps_ssh "$name" "$address"
                ;;
            s|S)
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

create_shortcut() {
    if [ ! -f "$LOCAL_SCRIPT" ]; then
        return 1
    fi
    chmod 700 "$LOCAL_SCRIPT"
    ln -sfn "$LOCAL_SCRIPT" /usr/bin/y
    if [ -L /usr/bin/y ] && [ "$(readlink -f /usr/bin/y)" = "$(readlink -f "$LOCAL_SCRIPT")" ]; then
        return 0
    fi
    return 1
}

delete_vps() {
    local name="$1"
    local users_dir="$DATA_DIR/users"
    local subscription_dir="$SUB_DIR"
    local central_user_dir
    local idx vname vaddr vtoken vipv4 address="" token=""
    while IFS=$'\t' read -r idx vname vaddr vtoken vipv4; do
        if [ "$vname" = "$name" ]; then
            address="$vaddr"; token="$vtoken"
            break
        fi
    done < <(vps_list_tsv)
    # 尽力从该 VPS 上删除中央用户（VPS 可能已经失联，失败只提示不阻塞）
    if [ -d "$users_dir" ] && [ -n "$address" ] && [ "$address" != "-" ] && [ -n "$token" ] && [ "$token" != "-" ]; then
        for central_user_dir in "$users_dir"/*; do
            [ -f "$central_user_dir/nodes/$name" ] || continue
            local u
            u=$(basename "$central_user_dir")
            if agent_request "$address" "$token" POST "/api/command" \
                "SB_LOAD_ONLY=1 source /etc/sing-box/sb.sh && delete_user \"$u\" 1 0" | grep -q '"returncode": *0'; then
                green "已从 $name 删除用户 $u"
            else
                yellow "未能从 $name 删除用户 $u（VPS 可能已离线）"
            fi
        done
    fi
    if ! vps_json_update '
data["vps"]=[v for v in data.get("vps",[]) if v.get("name")!=args[0]]
' "$name"; then
        red "更新 VPS 列表失败"
        return 1
    fi
    if [ -d "$users_dir" ]; then
        for central_user_dir in "$users_dir"/*; do
            [ -d "$central_user_dir" ] || continue
            local username
            username=$(basename "$central_user_dir")
            local node_file="$central_user_dir/nodes/$name"
            [ -f "$node_file" ] || continue
            rm -f "$node_file"
            local merged_file="$central_user_dir/merged_nodes.txt"
            local subscription_file="$subscription_dir/$username"
            local remaining_node
            local node_count=0
            mkdir -p "$subscription_dir"
            chmod 700 "$subscription_dir"
            : > "$merged_file"
            for remaining_node in "$central_user_dir"/nodes/*; do
                [ -f "$remaining_node" ] || continue
                cat "$remaining_node" >> "$merged_file"
                node_count=$((node_count + 1))
            done
            sed -i '/^[[:space:]]*$/d' "$merged_file"
            chmod 600 "$merged_file"
            if ! base64 -w 0 "$merged_file" > "$subscription_file"; then
                red "用户 $username 订阅重新生成失败"
                continue
            fi
            if [ ! -s "$subscription_file" ]; then
                red "用户 $username 订阅生成为空"
                continue
            fi
            chmod 600 "$subscription_file"
        done
    fi
    rebuild_wg_config
}
delete_vps_menu() {
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
    green "VPS 已删除"
    sleep 1
}

singbox_remote_check() {
    # 输出 INSTALLED / NOT_INSTALLED / OFFLINE（agent 不可达或返回异常）
    local address="$1"
    local token="$2"
    local result status
    if [ -z "$address" ] || [ "$address" = "-" ] || [ -z "$token" ] || [ "$token" = "-" ]; then
        echo "OFFLINE"
        return 1
    fi
    result=$(agent_request "$address" "$token" POST "/api/command" 'if [ -x /etc/sing-box/sing-box ] || [ -x /usr/local/bin/sing-box ] || [ -x /usr/bin/sing-box ] || systemctl list-unit-files 2>/dev/null | grep -q "^sing-box.service"; then echo INSTALLED; else echo NOT_INSTALLED; fi')
    status=$(printf '%s' "$result" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("stdout","").strip() if d.get("ok") else "OFFLINE")
except Exception:
    print("OFFLINE")' 2>/dev/null)
    case "$status" in
        INSTALLED|NOT_INSTALLED) echo "$status" ;;
        *) echo "OFFLINE"; return 1 ;;
    esac
}
# 在远程 VPS 后台运行 sing-box 安装/卸载脚本并轮询结果。
# agent 单条命令只有 30 秒超时，安装必然超时被杀，所以改为 nohup 后台执行 + 轮询。
# 用法: singbox_remote_job <address> <token> <install|uninstall> <log_file>
singbox_remote_job() {
    local address="$1"
    local token="$2"
    local action="$3"
    local log_file="$4"
    local menu_input
    local job="central-sb-$action"
    local start_cmd poll_cmd result rc waited=0
    case "$action" in
        # 末尾的 "x" 用来响应“按任意键返回”，"0" 退出菜单，避免脚本在 EOF 上死循环
        install) menu_input='1\nx0\n' ;;
        uninstall) menu_input='2\ny\nn\nx0\n' ;;
        *) return 1 ;;
    esac
    start_cmd="set -e; d=/var/log/central-vps; mkdir -p \$d; f=/root/.central-sb-installer.sh; \
rm -f \$d/$job.rc; \
curl -fsSL --proto '=https' --connect-timeout 10 --max-time 120 '$SINGBOX_INSTALL_URL' -o \$f.new; \
bash -n \$f.new; mv -f \$f.new \$f; chmod 700 \$f; \
nohup setsid bash -c \"printf '$menu_input' | timeout 1800 bash \$f > \$d/$job.log 2>&1; echo \\\$? > \$d/$job.rc\" >/dev/null 2>&1 < /dev/null & \
echo JOB_STARTED"
    result=$(agent_request "$address" "$token" POST "/api/command" "$start_cmd")
    if ! printf '%s' "$result" | grep -q "JOB_STARTED"; then
        printf '%s\n' "$result" > "$log_file"
        return 1
    fi
    poll_cmd="cat /var/log/central-vps/$job.rc 2>/dev/null || echo RUNNING"
    while [ "$waited" -lt 1800 ]; do
        sleep 10
        waited=$((waited + 10))
        rc=$(agent_request "$address" "$token" POST "/api/command" "$poll_cmd" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("stdout","").strip())
except Exception:
    print("RUNNING")' 2>/dev/null)
        printf '.'
        [ "$rc" = "RUNNING" ] || [ -z "$rc" ] && continue
        echo
        agent_request "$address" "$token" POST "/api/command" "tail -c 60000 /var/log/central-vps/$job.log" > "$log_file" 2>&1
        [ "$rc" = "0" ]
        return
    done
    echo
    return 1
}
singbox_install_remote() {
    singbox_remote_job "$1" "$2" install "${3:-/dev/null}"
}
singbox_uninstall_remote() {
    singbox_remote_job "$1" "$2" uninstall "${3:-/dev/null}"
}
# 刷新所有 VPS 的 sing-box 状态（每台只读一次 JSON、只请求一次 agent）
# 结果保存在全局数组 SB_IDX/SB_NAME/SB_ADDR/SB_TOKEN/SB_IPV4/SB_STATUS 中
singbox_refresh_status() {
    SB_IDX=(); SB_NAME=(); SB_ADDR=(); SB_TOKEN=(); SB_IPV4=(); SB_STATUS=()
    local i name address token ipv4
    while IFS=$'\t' read -r i name address token ipv4; do
        [ -n "$i" ] || continue
        SB_IDX+=("$i"); SB_NAME+=("$name"); SB_ADDR+=("$address"); SB_TOKEN+=("$token"); SB_IPV4+=("$ipv4")
        SB_STATUS+=("$(singbox_remote_check "$address" "$token" 2>/dev/null)")
    done < <(vps_list_tsv)
}
singbox_show_status() {
    local k n
    green "========================================"
    green "            Sing-box 管理"
    green "========================================"
    echo
    yellow "正在检测各 VPS 状态..."
    singbox_refresh_status
    clear
    green "========================================"
    green "            Sing-box 管理"
    green "========================================"
    echo
    local label status_want
    for status_want in INSTALLED NOT_INSTALLED OFFLINE; do
        case "$status_want" in
            INSTALLED) label="已安装 VPS" ;;
            NOT_INSTALLED) label="未安装 VPS" ;;
            OFFLINE) label="无法连接的 VPS" ;;
        esac
        green "$label"
        n=0
        for k in "${!SB_STATUS[@]}"; do
            [ "${SB_STATUS[$k]}" = "$status_want" ] || continue
            n=$((n+1))
            green "$(printf '%-4s %-20s %s' "$n." "${SB_NAME[$k]}" "${SB_IPV4[$k]}")"
        done
        [ "$n" -eq 0 ] && yellow "无"
        echo
    done
    green "1. 安装 Sing-box"
    green "2. 卸载 Sing-box"
    green "3. 更新 Sing-box"
    green "0. 返回"
    echo
}

central_restore_user_to_all_vps() {
    local username="$1"
    local user_dir="$DATA_DIR/users/$username"
    local uuid=""
    local count=0
    local i=0
    local name=""
    local address=""
    local token=""
    local result=""
    local returncode=0
    local failed=0

    [ -n "$username" ] || return 1
    [ -d "$user_dir" ] || return 1

    uuid=$(cat "$user_dir/uuid" 2>/dev/null)
    [ -n "$uuid" ] || return 1

    count=$(get_vps_count)

    for ((i=0; i<count; i++)); do
        name=$(get_vps_field "$i" "name")
        address=$(get_vps_field "$i" "wg_address")
        token=$(get_vps_field "$i" "agent_token")

        [ -n "$address" ] || {
            failed=1
            continue
        }

        [ -n "$token" ] || {
            failed=1
            continue
        }

        result=$(agent_request \
            "$address" \
            "$token" \
            POST \
            "/api/command" \
            "export SB_LOAD_ONLY=1; source /etc/sing-box/sb.sh; add_user_menu \"$username\" \"$uuid\" \"\" \"central\"") || {
                failed=1
                continue
            }

        returncode=$(echo "$result" | python3 -c '
import json
import sys
try:
    d=json.load(sys.stdin)
    print(int(d.get("returncode",1)))
except Exception:
    print(1)
' 2>/dev/null)

        if [ "$returncode" -ne 0 ]; then
            failed=1
        fi
    done

    [ "$failed" -eq 0 ]
}



central_user_set_limit() {
    local username="$1"
    local user_dir="$DATA_DIR/users/$username"
    local traffic_file="$user_dir/traffic.json"
    local input=""
    local value=""
    local unit=""
    local limit_bytes=0
    local was_disabled=""

    if [ -z "$username" ] || [ ! -d "$user_dir" ]; then
        red "用户不存在"
        sleep 1
        return 1
    fi

    if [ ! -f "$traffic_file" ]; then
        red "流量数据不存在"
        sleep 1
        return 1
    fi

    echo
    green "================ 流量限制 ================"
    echo
    green "当前用户：$username"
    echo
    green "支持："
    green "纯数字默认 GB，例如：1"
    green "MB，例如：512mb"
    green "GB，例如：1gb、1.5gb"
    green "输入 0 解除流量限制"
    echo
    read -rp "请输入流量限制: " input

    input="${input// /}"
    input=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')

    if [ "$input" = "0" ]; then
        was_disabled=$(python3 - "$traffic_file" <<'PY'
import json
import sys

path=sys.argv[1]

try:
    with open(path,"r",encoding="utf-8") as f:
        d=json.load(f)
except Exception:
    print("false")
    sys.exit(0)

print("true" if d.get("disabled_by_limit",False) else "false")
PY
)

        if ! python3 - "$traffic_file" <<'PY'
import json
import os
import sys
import tempfile

path=sys.argv[1]

with open(path,"r",encoding="utf-8") as f:
    data=json.load(f)

data["limit"]={
    "enabled":False,
    "limit_value":0,
    "limit_unit":"GB",
    "limit_bytes":0
}

data["period_upload"]=0
data["period_download"]=0
data["period_total"]=0
data["disabled_by_limit"]=False

directory=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix=".traffic.",dir=directory)

try:
    with os.fdopen(fd,"w",encoding="utf-8") as f:
        json.dump(data,f,ensure_ascii=False,indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())

    os.chmod(tmp,0o600)
    os.replace(tmp,path)
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    raise
PY
        then
            red "解除流量限制失败"
            sleep 1
            return 1
        fi

        if [ "$was_disabled" = "true" ]; then
            if central_restore_user_to_all_vps "$username"; then
                green "VPS 用户已恢复"
            else
                red "VPS 用户恢复失败"
                sleep 1
                return 1
            fi
        fi

        green "流量限制已解除"
        green "周期使用流量已清零"
        sleep 1
        return 0
    fi

    if [[ "$input" =~ ^([0-9]+([.][0-9]+)?)(mb|gb)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
    elif [[ "$input" =~ ^([0-9]+([.][0-9]+)?)$ ]]; then
        value="${BASH_REMATCH[1]}"
        unit="gb"
    else
        red "输入格式错误"
        yellow "示例：1、1gb、512mb、1.5gb"
        sleep 1
        return 1
    fi

    if ! limit_bytes=$(python3 - "$value" "$unit" <<'PY'
import sys
from decimal import Decimal, InvalidOperation

value=sys.argv[1]
unit=sys.argv[2]

try:
    number=Decimal(value)
except InvalidOperation:
    sys.exit(1)

if number <= 0:
    sys.exit(1)

if unit=="mb":
    multiplier=1024**2
elif unit=="gb":
    multiplier=1024**3
else:
    sys.exit(1)

result=int(number*multiplier)

if result <= 0:
    sys.exit(1)

print(result)
PY
    ); then
        red "流量限制无效"
        sleep 1
        return 1
    fi

    was_disabled=$(python3 - "$traffic_file" <<'PY'
import json
import sys

path=sys.argv[1]

try:
    with open(path,"r",encoding="utf-8") as f:
        d=json.load(f)
except Exception:
    print("false")
    sys.exit(0)

print("true" if d.get("disabled_by_limit",False) else "false")
PY
)

    if ! python3 - "$traffic_file" "$value" "$unit" "$limit_bytes" <<'PY'
import json
import os
import sys
import tempfile

path=sys.argv[1]
value=sys.argv[2]
unit=sys.argv[3].upper()
limit_bytes=int(sys.argv[4])

with open(path,"r",encoding="utf-8") as f:
    data=json.load(f)

data["limit"]={
    "enabled":True,
    "limit_value":value,
    "limit_unit":unit,
    "limit_bytes":limit_bytes
}

data["period_upload"]=0
data["period_download"]=0
data["period_total"]=0
data["disabled_by_limit"]=False

directory=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix=".traffic.",dir=directory)

try:
    with os.fdopen(fd,"w",encoding="utf-8") as f:
        json.dump(data,f,ensure_ascii=False,indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())

    os.chmod(tmp,0o600)
    os.replace(tmp,path)
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    raise
PY
    then
        red "设置流量限制失败"
        sleep 1
        return 1
    fi

    if [ "$was_disabled" = "true" ]; then
        if central_restore_user_to_all_vps "$username"; then
            green "VPS 用户已恢复"
        else
            red "VPS 用户恢复失败"
            sleep 1
            return 1
        fi
    fi

    green "流量限制设置成功"
    green "限制：${value}${unit^^}"
    green "限制大小：$(format_bytes "$limit_bytes")"
    green "周期使用流量已清零"
    sleep 1
    return 0
}


central_user_set_period() {
    local username="$1"
    local user_dir="$DATA_DIR/users/$username"
    local traffic_file="$user_dir/traffic.json"
    local choice=""
    local period=""
    local period_start=""
    local period_end=""

    if [ -z "$username" ] || [ ! -d "$user_dir" ]; then
        red "用户不存在"
        sleep 1
        return 1
    fi

    if [ ! -f "$traffic_file" ]; then
        red "流量数据不存在"
        sleep 1
        return 1
    fi

    echo
    green "================ 流量周期 ================"
    echo
    green "当前用户：$username"
    echo
    green "1. 每日"
    green "2. 每月"
    green "0. 不设置周期"
    echo
    read -rp "请输入数字: " choice

    case "$choice" in
        1)
            period="day"
            ;;
        2)
            period="month"
            ;;
        0)
            python3 - "$traffic_file" <<'PY'
import json
import os
import sys
import tempfile

path=sys.argv[1]

with open(path,"r",encoding="utf-8") as f:
    data=json.load(f)

data["period"]=""
data["period_start"]=""
data["period_end"]=""
data["period_upload"]=0
data["period_download"]=0
data["period_total"]=0

directory=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix=".traffic.",dir=directory)

try:
    with os.fdopen(fd,"w",encoding="utf-8") as f:
        json.dump(data,f,ensure_ascii=False,indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())

    os.chmod(tmp,0o600)
    os.replace(tmp,path)
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    raise
PY

        if [ "$?" -ne 0 ]; then
            red "取消流量周期失败"
            sleep 1
            return 1
        fi

        green "流量周期已取消"
        sleep 1
        return 0
        ;;
        *)
            red "输入无效"
            sleep 1
            return 1
            ;;
    esac

    read -r period_start period_end < <(
        python3 - "$period" <<'PY'
import sys
from datetime import datetime,timedelta

period=sys.argv[1]
now=datetime.now().astimezone()

if period=="day":
    start=now.replace(
        hour=0,
        minute=0,
        second=0,
        microsecond=0
    )
    end=start+timedelta(days=1)
else:
    start=now.replace(
        day=1,
        hour=0,
        minute=0,
        second=0,
        microsecond=0
    )

    if start.month==12:
        end=start.replace(
            year=start.year+1,
            month=1,
            day=1
        )
    else:
        end=start.replace(
            month=start.month+1,
            day=1
        )

print(start.isoformat(),end.isoformat())
PY
    )

    if [ -z "$period_start" ] || [ -z "$period_end" ]; then
        red "生成流量周期失败"
        sleep 1
        return 1
    fi

    if ! python3 - "$traffic_file" "$period" "$period_start" "$period_end" <<'PY'
import json
import os
import sys
import tempfile

path=sys.argv[1]
period=sys.argv[2]
period_start=sys.argv[3]
period_end=sys.argv[4]

with open(path,"r",encoding="utf-8") as f:
    data=json.load(f)

data["period"]=period
data["period_start"]=period_start
data["period_end"]=period_end
data["period_upload"]=0
data["period_download"]=0
data["period_total"]=0

directory=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix=".traffic.",dir=directory)

try:
    with os.fdopen(fd,"w",encoding="utf-8") as f:
        json.dump(data,f,ensure_ascii=False,indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())

    os.chmod(tmp,0o600)
    os.replace(tmp,path)
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    raise
PY
    then
        red "设置流量周期失败"
        sleep 1
        return 1
    fi

    if [ "$period" = "day" ]; then
        green "流量周期已设置：每日"
    else
        green "流量周期已设置：每月"
    fi

    green "周期开始：$period_start"
    green "周期结束：$period_end"

    sleep 1
    return 0
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
    local limit_enabled="false"
    local limit_bytes=0
    local limit_value=0
    local limit_unit="GB"
    local remaining=0
    local traffic_status="正常"
    local disabled_by_limit="False"

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
        remaining=0
        traffic_status="正常"
        disabled_by_limit="False"

        if [ -f "$traffic_file" ]; then
            eval "$(
                python3 - "$traffic_file" <<'PY'
import json
import sys

traffic_file=sys.argv[1]

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

# 所有值都经过 shlex.quote，eval 时不会执行文件里的任何内容
import shlex
limit=d.get("limit",{})
if not isinstance(limit,dict):
    limit={}
out={
    "upload":n(d.get("upload")),
    "download":n(d.get("download")),
    "total":n(d.get("total")),
    "period_upload":n(d.get("period_upload")),
    "period_download":n(d.get("period_download")),
    "period_total":n(d.get("period_total")),
    "period":str(d.get("period","")),
    "period_start":str(d.get("period_start","")),
    "period_end":str(d.get("period_end","")),
    "limit_enabled":str(bool(limit.get("enabled",False))),
    "limit_bytes":n(limit.get("limit_bytes")),
    "limit_value":str(limit.get("limit_value",0)),
    "limit_unit":str(limit.get("limit_unit","GB")),
    "disabled_by_limit":str(bool(d.get("disabled_by_limit",False))),
}
for k,v in out.items():
    print("%s=%s" % (k,shlex.quote(str(v))))
PY
)" 2>/dev/null
        fi

        if [ "$limit_enabled" = "True" ]; then
            remaining=$((limit_bytes-period_total))
            [ "$remaining" -lt 0 ] && remaining=0
        fi

        if [ "${disabled_by_limit:-False}" = "True" ]; then
            traffic_status="已停用"
        else
            traffic_status="正常"
        fi

        clear
        echo
        green "用户名：$username"
        green "UUID：$uuid"
        green "订阅路径：$path"
        green "-------------- 流量统计 ----------------"
        printf "%-6s %-16s %-6s %s\n" "上传流量" "$(format_bytes "$upload")" "总计流量" "$(format_bytes "$total")"
        printf "%-6s %-16s %-6s %s\n" "下载流量" "$(format_bytes "$download")" "周期流量" "$(format_bytes "$period_total")"
        green "-------------- 流量限制 ----------------"
        if [ "$limit_enabled" = "True" ]; then
            printf "%-6s %-16s %-6s %s\n" "限制流量" "$(format_bytes "$limit_bytes")" "限制周期" "$(
                case "$period" in
                    day) echo "每天" ;;
                    month) echo "每月" ;;
                    *) echo "未设置" ;;
                esac
            )"
            printf "%-6s %-16s %-6s " "剩余流量" "$(format_bytes "$remaining")" "流量状态"
            if [ "$traffic_status" = "正常" ]; then
                green "正常"
            else
                red "已停用"
            fi
        else
            printf "%-6s %-16s %-6s %s\n" "限制流量" "无限制" "限制周期" "$(
                case "$period" in
                    day) echo "每天" ;;
                    month) echo "每月" ;;
                    *) echo "未设置" ;;
                esac
            )"
            printf "%-6s %-16s %-6s " "剩余流量" "无限制" "流量状态"
            if [ "$traffic_status" = "正常" ]; then
                green "正常"
            else
                red "已停用"
            fi
        fi
        printf "%-6s %s\n" "周期开始" "${period_start:-无}"
        printf "%-6s %s\n" "周期结束" "${period_end:-无}"
        green "----------------------------------------"
        green "1. 设置流量"
        green "2. 周期设置"
        green "3. 更新用户"
        green "4. 查看链接"
        red "s. 删除用户"
        green "0. 返回"
        echo
        read -rp "请输入数字: " choice

        case "$choice" in
            1)
                central_user_set_limit "$username" || true
                ;;
            2)
                central_user_set_period "$username" || true
                ;;
            3)
                update_central_user "$username"
                ;;
            4)
                show_namess_url "$username"
                ;;
            s|S)
                if delete_central_user "$username"; then
                    return
                fi
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


# ---------- Nginx：每个证书域名一个 server 块，用户 location 放在 central_vps_users/<域名>/ ----------
nginx_domain_conf_path() {
    printf '/etc/nginx/conf.d/central_vps_sub_%s.conf\n' "$1"
}
nginx_write_domain_conf() {
    local domain="$1" cert_file="$2" key_file="$3"
    mkdir -p "$NGINX_USERS_DIR/$domain"
    cat > "$(nginx_domain_conf_path "$domain")" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $domain;
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    include $NGINX_USERS_DIR/$domain/*.conf;
    location / {
        return 404;
    }
}
EOF
}
nginx_write_user_conf() {
    local domain="$1" username="$2" user_path="$3"
    mkdir -p "$NGINX_USERS_DIR/$domain"
    cat > "$NGINX_USERS_DIR/$domain/$username.conf" <<EOF
location = /$user_path {
    proxy_pass http://127.0.0.1:18088/$user_path;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
    proxy_cache off;
}
EOF
}
# 旧版本只有一个 central_vps_sub.conf，所有用户共用最后一次选择的域名。
# 这里把旧的平铺用户配置迁移到按域名分组的新布局。
nginx_migrate_layout() {
    [ -f "$NGINX_OLD_MAIN_CONF" ] || return 0
    local conf u d c k
    for conf in "$NGINX_USERS_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        u=$(basename "$conf" .conf)
        d=$(cat "$DATA_DIR/users/$u/domain" 2>/dev/null || true)
        c=$(cat "$DATA_DIR/users/$u/cert_file" 2>/dev/null || true)
        k=$(cat "$DATA_DIR/users/$u/key_file" 2>/dev/null || true)
        if [ -z "$d" ] || [ -z "$c" ] || [ -z "$k" ] || ! [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]]; then
            yellow "用户 $u 缺少证书信息，跳过迁移（保留旧配置文件 ${conf}.bak）"
            mv -f "$conf" "$conf.bak"
            continue
        fi
        mkdir -p "$NGINX_USERS_DIR/$d"
        mv -f "$conf" "$NGINX_USERS_DIR/$d/$u.conf"
        nginx_write_domain_conf "$d" "$c" "$k"
    done
    mv -f "$NGINX_OLD_MAIN_CONF" "$NGINX_OLD_MAIN_CONF.bak"
    green "已迁移旧版 Nginx 订阅配置（旧主配置备份为 ${NGINX_OLD_MAIN_CONF}.bak）"
}
nginx_apply() {
    nginx -t || return 1
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
}

# 从用户的 nodes/ 重新生成合并文件和 base64 订阅文件，输出节点文件数量
rebuild_user_subscription() {
    local username="$1"
    local central_user_dir="$DATA_DIR/users/$username"
    local merged_file="$central_user_dir/merged_nodes.txt"
    local subscription_file="$SUB_DIR/$username"
    local node_file node_count=0
    mkdir -p "$SUB_DIR"
    chmod 700 "$SUB_DIR"
    : > "$merged_file"
    for node_file in "$central_user_dir"/nodes/*; do
        [ -f "$node_file" ] || continue
        cat "$node_file" >> "$merged_file"
        node_count=$((node_count + 1))
    done
    sed -i '/^[[:space:]]*$/d' "$merged_file"
    chmod 600 "$merged_file"
    [ -s "$merged_file" ] || return 1
    base64 -w 0 "$merged_file" > "$subscription_file.tmp" || { rm -f "$subscription_file.tmp"; return 1; }
    [ -s "$subscription_file.tmp" ] || { rm -f "$subscription_file.tmp"; return 1; }
    chmod 600 "$subscription_file.tmp"
    mv -f "$subscription_file.tmp" "$subscription_file"
    echo "$node_count"
}

add_central_user() {
    local mode="${1:-add}"
    local username="${2:-}"
    local users_root="$DATA_DIR/users"
    local central_user_dir=""
    local uuid="" user_path="" cert_domain="" cert_file="" key_file=""
    local idx name address token ipv4 result output nodes
    local failed=0 vps_count=0 node_count=0
    local temp_dir=""
    local -a ok_addr=() ok_token=()
    local action_label="添加"
    [ "$mode" = "update" ] && action_label="更新"
    mkdir -p "$users_root"
    chmod 700 "$BASE_DIR" "$DATA_DIR" "$users_root"
    echo
    if [ "$mode" = "update" ]; then
        green "================ 更新用户 ================"
    else
        green "================ 添加用户 ================"
        echo
        read -rp "请输入用户名: " username
    fi
    echo
    if [ -z "$username" ]; then
        red "用户名不能为空"; sleep 1; return 1
    fi
    if ! [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$username" == .* ]]; then
        red "用户名只能包含字母、数字、点、下划线和横线，且不能以点开头"; sleep 1; return 1
    fi
    central_user_dir="$users_root/$username"

    if [ "$mode" = "update" ]; then
        if [ ! -d "$central_user_dir" ]; then
            red "用户不存在：$username"; sleep 1; return 1
        fi
        uuid=$(cat "$central_user_dir/uuid" 2>/dev/null || true)
        user_path=$(cat "$central_user_dir/path" 2>/dev/null || true)
        cert_domain=$(cat "$central_user_dir/domain" 2>/dev/null || true)
        cert_file=$(cat "$central_user_dir/cert_file" 2>/dev/null || true)
        key_file=$(cat "$central_user_dir/key_file" 2>/dev/null || true)
        if [ -z "$uuid" ] || [ -z "$user_path" ]; then
            red "用户 UUID 或订阅路径不存在"; sleep 1; return 1
        fi
        if [ -z "$cert_domain" ] || [ -z "$cert_file" ] || [ -z "$key_file" ]; then
            red "原用户证书信息不完整"; sleep 1; return 1
        fi
    else
        if [ -e "$central_user_dir" ]; then
            red "用户已存在"; sleep 1; return 1
        fi
        uuid=$(cat /proc/sys/kernel/random/uuid)
        user_path=$(generate_token)
        # 先选证书再去各 VPS 创建用户，避免 VPS 上已建好用户后才发现没有证书
        green "================ 选择证书 ================"
        echo
        local -a cert_dirs=()
        local cert_dir cert_index=1 cert_choice
        for cert_dir in /root/cert/* /etc/nginx/cert/*; do
            [ -d "$cert_dir" ] || continue
            [ -f "$cert_dir/fullchain.pem" ] || continue
            [ -f "$cert_dir/privkey.pem" ] || continue
            [[ "$(basename "$cert_dir")" =~ ^[A-Za-z0-9.-]+$ ]] || continue
            cert_dirs+=("$cert_dir")
            echo "$cert_index. $(basename "$cert_dir")"
            cert_index=$((cert_index + 1))
        done
        if [ "${#cert_dirs[@]}" -eq 0 ]; then
            red "没有找到有效证书（/root/cert/<域名>/ 或 /etc/nginx/cert/<域名>/ 下需有 fullchain.pem 和 privkey.pem）"
            read -rp "按回车返回..." _
            return 1
        fi
        echo
        while true; do
            read -rp "请选择证书 [1-${#cert_dirs[@]}]: " cert_choice
            if [[ "$cert_choice" =~ ^[0-9]+$ ]] && [ "$cert_choice" -ge 1 ] && [ "$cert_choice" -le "${#cert_dirs[@]}" ]; then
                break
            fi
            red "输入错误，请重新选择"
        done
        cert_dir="${cert_dirs[$((cert_choice - 1))]}"
        cert_file="$cert_dir/fullchain.pem"
        key_file="$cert_dir/privkey.pem"
        cert_domain="$(basename "$cert_dir")"
        green "证书：$cert_dir"
        echo
    fi

    green "用户名：$username"
    green "UUID：$uuid"
    echo
    temp_dir=$(mktemp -d "$users_root/.tmp.XXXXXX") || { red "创建临时目录失败"; return 1; }
    mkdir -p "$temp_dir/nodes"
    while IFS=$'\t' read -r idx name address token ipv4; do
        [ -n "$idx" ] || continue
        vps_count=$((vps_count + 1))
        if [ "$address" = "-" ] || [ "$token" = "-" ]; then
            red "$name：VPS信息不完整"
            failed=1
            continue
        fi
        green "正在添加：$name"
        result=$(agent_request "$address" "$token" POST "/api/command" \
            "SB_LOAD_ONLY=1 source /etc/sing-box/sb.sh && add_user_menu '$username' '$uuid' '' 'central'")
        output=$(printf '%s' "$result" | python3 -c '
import json
import sys
try:
    d=json.load(sys.stdin)
    print(d.get("stdout",""), end="")
except Exception:
    pass
' 2>/dev/null)
        if printf '%s\n' "$output" | grep -q "CENTRAL_USER_OK"; then
            nodes=$(printf '%s\n' "$output" | sed -n '/^NODE_BEGIN$/,/^NODE_END$/p' | sed '1d;$d')
            printf '%s\n' "$nodes" > "$temp_dir/nodes/$name"
            ok_addr+=("$address"); ok_token+=("$token")
            green "$name：添加成功"
        else
            red "$name：添加失败"
            [ -n "$output" ] && echo "$output"
            [ -z "$output" ] && echo "$result"
            failed=1
        fi
    done < <(vps_list_tsv)

    if [ "$vps_count" -eq 0 ]; then
        rm -rf "$temp_dir"
        red "当前没有已添加的 VPS"
        sleep 1
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        rm -rf "$temp_dir"
        echo
        if [ "$mode" = "add" ] && [ "${#ok_addr[@]}" -gt 0 ]; then
            yellow "正在回滚已成功添加的 VPS..."
            local k
            for k in "${!ok_addr[@]}"; do
                agent_request "${ok_addr[$k]}" "${ok_token[$k]}" POST "/api/command" \
                    "SB_LOAD_ONLY=1 source /etc/sing-box/sb.sh && delete_user \"$username\" 1 0" >/dev/null
            done
            red "用户添加失败，已回滚，未创建用户目录"
        else
            red "用户${action_label}失败"
        fi
        echo
        read -rp "按回车返回..." _
        return 1
    fi

    if [ "$mode" = "update" ]; then
        rm -rf "$central_user_dir/nodes.old"
        [ -d "$central_user_dir/nodes" ] && mv "$central_user_dir/nodes" "$central_user_dir/nodes.old"
        if ! mv "$temp_dir/nodes" "$central_user_dir/nodes"; then
            [ -d "$central_user_dir/nodes.old" ] && mv "$central_user_dir/nodes.old" "$central_user_dir/nodes"
            rm -rf "$temp_dir"
            red "更新节点目录失败"
            return 1
        fi
        rm -rf "$central_user_dir/nodes.old" "$temp_dir"
    else
        # 新用户：一次性写好所有元数据再原子 mv，订阅服务、流量统计、限额都依赖这些文件
        printf '%s\n' "$username" > "$temp_dir/username"
        printf '%s\n' "$uuid" > "$temp_dir/uuid"
        printf '%s\n' "$user_path" > "$temp_dir/path"
        printf '%s\n' "$cert_domain" > "$temp_dir/domain"
        printf '%s\n' "$cert_file" > "$temp_dir/cert_file"
        printf '%s\n' "$key_file" > "$temp_dir/key_file"
        cat > "$temp_dir/traffic.json" <<'EOF'
{
  "upload": 0,
  "download": 0,
  "total": 0,
  "vps": {},
  "period": "",
  "period_start": "",
  "period_end": "",
  "period_upload": 0,
  "period_download": 0,
  "period_total": 0,
  "limit": {
    "enabled": false,
    "limit_value": 0,
    "limit_unit": "GB",
    "limit_bytes": 0
  },
  "disabled_by_limit": false
}
EOF
        chmod 600 "$temp_dir"/username "$temp_dir"/uuid "$temp_dir"/path "$temp_dir"/domain \
            "$temp_dir"/cert_file "$temp_dir"/key_file "$temp_dir"/traffic.json
        if ! mv "$temp_dir" "$central_user_dir"; then
            rm -rf "$temp_dir"
            red "创建中央用户目录失败"
            read -rp "按回车返回..." _
            return 1
        fi
    fi
    chmod 700 "$central_user_dir" "$central_user_dir/nodes"

    green "================ 生成订阅 ================"
    echo
    if ! node_count=$(rebuild_user_subscription "$username"); then
        red "没有找到 VPS 节点，订阅生成失败"
        read -rp "按回车返回..." _
        return 1
    fi
    local subscription_url="https://$cert_domain/$user_path"
    printf '%s\n' "$subscription_url" > "$central_user_dir/subscription_url"
    chmod 600 "$central_user_dir/subscription_url"
    green "节点数量：$node_count"
    echo

    green "================ 配置 Nginx ================"
    echo
    nginx_migrate_layout
    local domain_conf
    domain_conf=$(nginx_domain_conf_path "$cert_domain")
    local domain_conf_existed=0
    [ -f "$domain_conf" ] && domain_conf_existed=1
    nginx_write_domain_conf "$cert_domain" "$cert_file" "$key_file"
    nginx_write_user_conf "$cert_domain" "$username" "$user_path"
    if ! nginx_apply; then
        red "Nginx 配置检查或重载失败"
        rm -f "$NGINX_USERS_DIR/$cert_domain/$username.conf"
        [ "$domain_conf_existed" -eq 0 ] && rm -f "$domain_conf"
        read -rp "按回车返回..." _
        return 1
    fi

    install_central_subscription_service

    echo
    green "========================================"
    green "           用户${action_label}完成"
    green "========================================"
    green "用户名：$username"
    green "UUID：$uuid"
    green "订阅地址：$subscription_url"
    green "节点数量：$node_count"
    echo
    read -rp "按回车返回..." _
    return 0
}

update_central_user() {
    local username="$1"
    if [ ! -d "$DATA_DIR/users/$username" ]; then
        red "用户不存在：$username"
        sleep 1
        return 1
    fi
    if ! delete_central_user "$username" update; then
        return 1
    fi
    if ! add_central_user update "$username"; then
        red "用户更新失败"
        return 1
    fi
    return 0
}

install_central_subscription_service() {
cat > /usr/local/bin/central-vps-subscription.py <<'PY'
#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
BASE_DIR=Path("/etc/central-vps")
USER_DIR=BASE_DIR/"data"/"users"
SUB_DIR=Path("/etc/central-vps-sub")
HOST="127.0.0.1"
PORT=18088
def find_user(request_path):
    request_path=request_path.strip("/")
    if not request_path:
        return None
    try:
        for user_dir in USER_DIR.iterdir():
            if not user_dir.is_dir():
                continue
            path_file=user_dir/"path"
            if not path_file.is_file():
                continue
            try:
                user_path=path_file.read_text(encoding="utf-8").strip()
            except Exception:
                continue
            if user_path == request_path:
                return user_dir.name
    except Exception:
        return None
    return None
def load_traffic(username):
    traffic_file=USER_DIR/username/"traffic.json"
    try:
        with traffic_file.open("r",encoding="utf-8") as f:
            data=json.load(f)
    except Exception:
        return None
    return data
def format_userinfo(data):
    period_upload=int(data.get("period_upload",0) or 0)
    period_download=int(data.get("period_download",0) or 0)
    limit=data.get("limit")
    if isinstance(limit,dict) and limit.get("enabled") and int(limit.get("limit_bytes",0) or 0)>0:
        total=int(limit.get("limit_bytes",0) or 0)
        return f"upload={period_upload}; download={period_download}; total={total}"
    return f"upload={period_upload}; download={period_download}; total=0"
class Handler(BaseHTTPRequestHandler):
    server_version="CentralVPSSubscription/1.0"
    def log_message(self,format,*args):
        return

    def do_GET(self):
        username = find_user(self.path.split("?", 1)[0])
        if not username:
            self.send_error(404)
            return
        subscription_file = SUB_DIR / username
        if not subscription_file.is_file():
            self.send_error(404)
            return
        try:
            raw = subscription_file.read_bytes()
            decoded = __import__("base64").b64decode(raw).decode("utf-8")
        except Exception:
            self.send_error(500)
            return
        traffic = load_traffic(username)
        if traffic is not None:
            traffic_node = build_traffic_node(traffic)
            decoded = traffic_node + "\n" + decoded.lstrip()
        content = __import__("base64").b64encode(decoded.encode("utf-8"))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        if traffic is not None:
            self.send_header("Subscription-Userinfo", format_userinfo(traffic))
        self.end_headers()
        self.wfile.write(content)
def format_size(value):
    value=float(value or 0)
    units=["B","KB","MB","GB","TB","PB"]
    for unit in units:
        if value < 1024 or unit == "PB":
            if unit == "B":
                return f"{int(value)}{unit}"
            if value >= 100:
                return f"{value:.0f}{unit}"
            if value >= 10:
                return f"{value:.1f}{unit}"
            return f"{value:.2f}{unit}"
        value /= 1024
    return "0B"
def build_traffic_node(data):
    period_total=int(data.get("period_total",0) or 0)
    limit=data.get("limit")
    if isinstance(limit,dict) and limit.get("enabled") and int(limit.get("limit_bytes",0) or 0)>0:
        limit_bytes=int(limit.get("limit_bytes",0) or 0)
        remaining=max(0,limit_bytes-period_total)
        remark=f"📊 周期流量: {format_size(limit_bytes)} | 已用流量: {format_size(period_total)} | 剩余流量: {format_size(remaining)}"
    else:
        remark=f"📊 总流量: 无限 | 已用流量: {format_size(period_total)} | 剩余流量: 无限制"
    return f"vless://00000000-0000-0000-0000-000000000000@0.0.0.0:0?encryption=none&security=tls&sni=e.c&type=tcp#{remark}"
if __name__=="__main__":
    SUB_DIR.mkdir(parents=True,exist_ok=True)
    os.chmod(SUB_DIR,0o700)
    server=ThreadingHTTPServer((HOST,PORT),Handler)
    server.serve_forever()
PY
chmod 700 /usr/local/bin/central-vps-subscription.py
cat > /etc/systemd/system/central-vps-subscription.service <<'EOF'
[Unit]
Description=Central VPS Subscription Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/central-vps-subscription.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

if ! systemctl is-enabled --quiet central-vps-subscription.service; then
    systemctl enable central-vps-subscription.service >/dev/null 2>&1 || true
fi
if ! systemctl is-active --quiet central-vps-subscription.service; then
    systemctl start central-vps-subscription.service
fi
}


delete_central_user() {
    local username="$1"
    local mode="${2:-delete}"
    local count=0
    local i=0
    local name=""
    local address=""
    local token=""
    local result=""
    local output=""
    local returncode=0
    local failed=0
    local user_dir="$DATA_DIR/users/$username"
    local nodes_dir="$user_dir/nodes"
    local node_file=""

    if [ -z "$username" ]; then
        red "用户名不能为空"
        sleep 1
        return 1
    fi

    if [ ! -d "$user_dir" ]; then
        red "用户不存在"
        sleep 1
        return 1
    fi

    if [ "$mode" = "update" ]; then
        echo
        yellow "正在更新用户：$username"
        echo
    else
        echo
        red "确定删除用户：$username？"
        yellow "将从所有 VPS 的所有入站中删除该用户。"
        echo
        read -rp "输入 y 确认删除: " confirm
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] || return 1
    fi

    count=$(get_vps_count)

    if [ -d "$nodes_dir" ]; then
        for node_file in "$nodes_dir"/*; do
            [ -f "$node_file" ] || continue

            name=$(basename "$node_file")
            address=""
            token=""

            for ((i=0; i<count; i++)); do
                local vps_name
                vps_name=$(get_vps_field "$i" "name")

                if [ "$vps_name" = "$name" ]; then
                    address=$(get_vps_field "$i" "wg_address")
                    token=$(get_vps_field "$i" "agent_token")
                    break
                fi
            done

            [ -n "$address" ] || continue
            [ -n "$token" ] || continue

            green "正在删除：$name"

            result=$(agent_request \
                "$address" \
                "$token" \
                POST \
                "/api/command" \
                "SB_LOAD_ONLY=1 source /etc/sing-box/sb.sh && delete_user \"$username\" 1 0") || {
                    red "$name：请求失败"
                    failed=1
                    continue
                }

            returncode=$(echo "$result" | python3 -c '
import json
import sys
try:
    d=json.load(sys.stdin)
    print(int(d.get("returncode",1)))
except Exception:
    print(1)
' 2>/dev/null)

            output=$(echo "$result" | python3 -c '
import json
import sys
try:
    d=json.load(sys.stdin)
    print(d.get("stdout",""),end="")
    err=d.get("stderr","")
    if err:
        print(err,end="")
except Exception:
    pass
' 2>/dev/null)

            if [ "$returncode" -eq 0 ]; then
                green "$name：删除成功"
            else
                red "$name：删除失败"
                [ -n "$output" ] && echo "$output"
                yellow "$name：远程返回码 $returncode"
                failed=1
            fi
        done
    fi

    if [ "$failed" -ne 0 ]; then
        echo
        red "部分 VPS 删除失败"
        echo
        read -rp "按回车返回..." _
        return 1
    fi

    if [ "$mode" = "update" ]; then
        echo
        green "========================================"
        green " 用户更新"
        green " 用户：$username"
        green "========================================"
        echo
        return 0
    fi

    rm -f "$NGINX_USERS_DIR/$username.conf" "$NGINX_USERS_DIR"/*/"$username.conf"
    rm -f "$SUB_DIR/$username"
    rm -rf "$user_dir"
    systemctl reload nginx >/dev/null 2>&1 || true

    echo
    green "========================================"
    green " 用户已删除：$username"
    green "========================================"
    echo

    sleep 1
    return 0
}

manage_singbox() {
    local choice confirm k name address token ipv4 status log
    local log_dir="$DATA_DIR/logs"
    mkdir -p "$log_dir"
    chmod 700 "$log_dir"
    while true; do
        clear
        singbox_show_status
        read -rp "请选择: " choice
        case "$choice" in
            1|2|3) ;;
            0) return ;;
            *) red "无效选择"; sleep 1; continue ;;
        esac
        if [ "${#SB_IDX[@]}" -eq 0 ]; then
            yellow "当前没有 VPS"
            read -n 1 -s -r -p "按任意键返回..."
            continue
        fi
        if [ "$choice" != "1" ]; then
            echo
            if [ "$choice" = "2" ]; then
                read -rp "确定卸载所有 VPS 的 Sing-box？(y/n): " confirm
            else
                read -rp "确定更新所有 VPS 的 Sing-box？将先卸载再重新安装。(y/n): " confirm
            fi
            case "$confirm" in
                y|Y) ;;
                *) yellow "已取消"; read -n 1 -s -r -p "按任意键返回..."; continue ;;
            esac
        fi
        echo
        for k in "${!SB_IDX[@]}"; do
            name="${SB_NAME[$k]}"; address="${SB_ADDR[$k]}"; token="${SB_TOKEN[$k]}"
            ipv4="${SB_IPV4[$k]}"; status="${SB_STATUS[$k]}"
            log="$log_dir/singbox-$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
            if [ "$status" = "OFFLINE" ]; then
                red "$name $ipv4 无法连接 agent，跳过"
                continue
            fi
            case "$choice" in
                1)
                    if [ "$status" = "INSTALLED" ]; then
                        yellow "$name $ipv4 已安装，跳过"
                        continue
                    fi
                    green "$name $ipv4 开始安装（后台执行，最长 30 分钟）"
                    ;;
                2)
                    if [ "$status" != "INSTALLED" ]; then
                        yellow "$name $ipv4 未安装，跳过"
                        continue
                    fi
                    green "$name $ipv4 开始卸载"
                    if singbox_uninstall_remote "$address" "$token" "$log-uninstall.log" \
                        && [ "$(singbox_remote_check "$address" "$token")" = "NOT_INSTALLED" ]; then
                        green "$name $ipv4 卸载成功"
                    else
                        red "$name $ipv4 卸载失败，日志：$log-uninstall.log"
                    fi
                    continue
                    ;;
                3)
                    if [ "$status" = "INSTALLED" ]; then
                        green "$name $ipv4 卸载旧版本"
                        if ! singbox_uninstall_remote "$address" "$token" "$log-uninstall.log"; then
                            red "$name $ipv4 卸载失败，跳过安装，日志：$log-uninstall.log"
                            continue
                        fi
                        sleep 2
                    else
                        yellow "$name $ipv4 未安装，直接安装"
                    fi
                    green "$name $ipv4 安装新版本"
                    ;;
            esac
            if singbox_install_remote "$address" "$token" "$log-install.log" \
                && [ "$(singbox_remote_check "$address" "$token")" = "INSTALLED" ]; then
                green "$name $ipv4 安装成功"
            else
                red "$name $ipv4 安装失败，日志：$log-install.log"
            fi
        done
        echo
        read -n 1 -s -r -p "操作完成，按任意键返回..."
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
    # 可选完整性校验：仓库里若有 central-vps.sh.sha256（内容为 sha256 值），则必须匹配
    local expected actual
    expected=$(curl -fsSL --connect-timeout 5 --max-time 15 "${SCRIPT_URL}.sha256" 2>/dev/null | awk '{print $1}' | head -n 1)
    actual=$(sha256sum "$tmp" | awk '{print $1}')
    if [ -n "$expected" ]; then
        if [ "$expected" != "$actual" ]; then
            rm -f "$tmp"
            red "SHA256 校验失败，已拒绝更新"
            yellow "期望：$expected"
            yellow "实际：$actual"
            read -rp "按 Enter 返回..." _
            return
        fi
        green "SHA256 校验通过"
    else
        yellow "未找到 ${SCRIPT_URL}.sha256，跳过完整性校验（SHA256：$actual）"
    fi
    mv -f "$tmp" "$LOCAL_SCRIPT"
    chmod 700 "$LOCAL_SCRIPT"
if systemctl list-unit-files | grep -q '^central-vps-subscription.service'; then
    green "正在更新订阅服务..."
    systemctl stop central-vps-subscription.service >/dev/null 2>&1 || true
    rm -f /usr/local/bin/central-vps-subscription.py
    rm -f /etc/systemd/system/central-vps-subscription.service
    systemctl daemon-reload
    if install_central_subscription_service; then
        systemctl enable central-vps-subscription.service >/dev/null 2>&1 || true

        if systemctl start central-vps-subscription.service; then
            green "订阅服务已重新生成并启动"
        else
            red "订阅服务启动失败"
        fi
    else
        red "订阅服务文件生成失败"
    fi
fi
    green "脚本更新成功"
    systemctl restart central-vps 2>/dev/null || true
    green "API 已重新加载最新脚本"
    green "正在加载新版本..."
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
    systemctl stop central-vps-subscription.service >/dev/null 2>&1 || true
    systemctl disable central-vps-subscription.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/central-vps-subscription.service
    rm -f /usr/local/bin/central-vps-subscription.py
    systemctl stop "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@$WG_INTERFACE.service" >/dev/null 2>&1 || true
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        ip link set "$WG_INTERFACE" down >/dev/null 2>&1 || true
        ip link del "$WG_INTERFACE" >/dev/null 2>&1 || true
    fi
    rm -f /usr/bin/y
    rm -f /etc/systemd/system/central-vps.service
    systemctl daemon-reload
    systemctl reset-failed central-vps.service >/dev/null 2>&1 || true
    rm -f "$WG_CONFIG" "$WG_PRIVATE_KEY" "$WG_PUBLIC_KEY"
    rm -rf /etc/nginx/conf.d/central_vps_users
    rm -rf /etc/central-vps-sub
    rm -rf "$BASE_DIR"
    rm -f "$LOCAL_SCRIPT"
    rm -f /run/central-vps-server.lock
    rm -f /etc/nginx/conf.d/central_vps_sub.conf /etc/nginx/conf.d/central_vps_sub_*.conf
    systemctl reload nginx >/dev/null 2>&1 || true
    green "VPS 管理系统已删除"
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
    init_ssh_key
    create_shortcut
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
            green "          VPS 管理脚本101"
            green "========================================"
            echo
            green "1. 添加 VPS"
            green "2. 管理 VPS"
            green "3. Sing-box"
            green "4. 更新脚本"
            red "s. 删除脚本"
            echo
            green "5. 添加用户"
            green "6. 管理用户"
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
                4)
                    update_script
                    ;;
                s|S)
                    delete_script
                    ;;
                5)
                    add_central_user
                   ;;
                6)
                   show_central_users
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
