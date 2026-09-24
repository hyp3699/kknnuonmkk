# 自动检测并安装 nftables
check_and_install_nftables() {
    if ! command -v nft &> /dev/null; then
        echo -e "\033[0;33m[!] 检测到系统未安装 nftables，正在自动安装...\033[0m"
        if [ -f /etc/debian_version ]; then
            apt-get update -y && apt-get install -y nftables
        elif [ -f /etc/redhat-release ]; then
            yum install -y nftables 2>/dev/null || dnf install -y nftables
        else
            echo -e "\033[0;31m[-] 未知的 Linux 系统类型，请手动安装 nftables！\033[0m"
            return 1
        fi
        
        systemctl enable nftables >/dev/null 2>&1
        systemctl start nftables >/dev/null 2>&1
        echo -e "\033[0;32m[+] nftables 自动安装完成！\033[0m"
        sleep 1
    fi
}

fail2ban_manage() {
    while true; do
        clear
        echo "========== Fail2ban 管理 =========="
        if ! command -v fail2ban-client >/dev/null 2>&1; then
            red "Fail2ban 未安装"
            read -r -p "是否安装 Fail2ban? [Y/n]: " yn
            yn=${yn:-Y}
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get update && apt-get install -y fail2ban nftables
                elif command -v dnf >/dev/null 2>&1; then
                    dnf install -y fail2ban nftables
                elif command -v yum >/dev/null 2>&1; then
                    yum install -y epel-release 2>/dev/null || true
                    yum install -y fail2ban nftables
                elif command -v apk >/dev/null 2>&1; then
                    apk add fail2ban nftables
                else
                    red "不支持的系统"
                    return
                fi
                if ! command -v fail2ban-client >/dev/null 2>&1; then
                    red "Fail2ban 安装失败"
                    read -r -p "按回车继续..."
                    continue
                fi
                green "Fail2ban 安装完成"
            else
                return
            fi
        fi
        echo ""
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
            green "Fail2ban 状态: 运行中"
        elif command -v rc-service >/dev/null 2>&1 && rc-service fail2ban status >/dev/null 2>&1; then
            green "Fail2ban 状态: 运行中"
        else
            red "Fail2ban 状态: 未运行"
        fi
        echo ""
        echo "1. 查看状态"
        echo "2. 查看封禁IP"
        echo "3. 启动/配置Fail2ban"
        echo "4. 停止Fail2ban"
        echo "0. 返回"
        reading "请选择: " fb_choice
        case "$fb_choice" in
        1)
            echo "----------------------------------------"
            jail_count=$(fail2ban-client status 2>/dev/null | awk -F': ' '/Number of jail/{print $2; exit}')
            jail_list=$(fail2ban-client status 2>/dev/null | awk -F': ' '/Jail list/{print $2; exit}')
            echo "|- 监控项数量：${jail_count:-0}"
            echo "\`- 监控列表：${jail_list:-无}"
            echo "----------------------------------------"
            read -r -p "按回车继续..."
            ;;
        2)
            read -r -p "请输入要查看的监控项名称（默认 sshd）： " jail_name
            jail_name=${jail_name:-sshd}
            echo "----------------------------------------"
            fail2ban-client status "$jail_name" 2>/dev/null | sed \
                -e "s/Status for the jail/监控项状态/g" \
                -e "s/|- Filter/|- 过滤器/g" \
                -e "s/|- Actions/|- 动作/g" \
                -e "s/\`- Banned IP list/\`- 已封禁 IP 列表/g"
            echo "----------------------------------------"
            read -r -p "按回车继续..."
            ;;
        3)
            echo "----------------------------------------"
            if ! command -v nft >/dev/null 2>&1; then
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get update && apt-get install -y nftables
                elif command -v dnf >/dev/null 2>&1; then
                    dnf install -y nftables
                elif command -v yum >/dev/null 2>&1; then
                    yum install -y nftables
                elif command -v apk >/dev/null 2>&1; then
                    apk add nftables
                fi
            fi
            if ! command -v nft >/dev/null 2>&1; then
                red "未找到 nft 命令，无法配置 Fail2ban nftables 防护"
                read -r -p "按回车继续..."
                continue
            fi
            sshd_bin=$(command -v sshd 2>/dev/null)
            if [ -z "$sshd_bin" ]; then
                red "未找到 sshd，无法准确检测 SSH 端口"
                read -r -p "按回车继续..."
                continue
            fi
            ssh_cfg_ports=$("$sshd_bin" -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/ {print $2}' | sort -n -u | paste -sd, -)
            ssh_listen_ports=$(ss -lntpH 2>/dev/null | awk '/sshd/ {x=$4; sub(/^.*:/,"",x); if (x ~ /^[0-9]+$/) print x}' | sort -n -u | paste -sd, -)
            if [ -n "$ssh_listen_ports" ]; then
                ssh_port=$(printf '%s\n' "$ssh_listen_ports" | tr ',' '\n' | while read -r p; do
                    case ",${ssh_cfg_ports}," in
                        *",${p},"*) echo "$p" ;;
                    esac
                done | sort -n -u | paste -sd, -)
            else
                ssh_port="$ssh_cfg_ports"
            fi
            [ -z "$ssh_port" ] && ssh_port=22
            ssh_cfg_display=${ssh_cfg_ports:-未知}
            ssh_listen_display=${ssh_listen_ports:-未检测到}
            if command -v journalctl >/dev/null 2>&1; then
                if ! python3 -c 'import systemd.journal' >/dev/null 2>&1; then
                    if command -v apt-get >/dev/null 2>&1; then
                        apt-get install -y python3-systemd >/dev/null 2>&1 || true
                    elif command -v dnf >/dev/null 2>&1; then
                        dnf install -y python3-systemd >/dev/null 2>&1 || true
                    elif command -v yum >/dev/null 2>&1; then
                        yum install -y python3-systemd >/dev/null 2>&1 || true
                    fi
                fi
            fi
            backend="auto"
            if command -v journalctl >/dev/null 2>&1 && python3 -c 'import systemd.journal' >/dev/null 2>&1; then
                backend="systemd"
            fi
            current_findtime=$(grep -hE '^[[:space:]]*findtime[[:space:]]*=' /etc/fail2ban/jail.d/99-script-sshd-nftables.local 2>/dev/null | tail -1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' ')
            current_maxretry=$(grep -hE '^[[:space:]]*maxretry[[:space:]]=' /etc/fail2ban/jail.d/99-script-sshd-nftables.local 2>/dev/null | tail -1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' ')
            current_bantime=$(grep -hE '^[[:space:]]*bantime[[:space:]]=' /etc/fail2ban/jail.d/99-script-sshd-nftables.local 2>/dev/null | tail -1 | sed -E 's/.*=[[:space:]]*//' | tr -d ' ')
            current_findtime=${current_findtime:-10m}
            current_maxretry=${current_maxretry:-3}
            current_bantime=${current_bantime:-10m}
            current_findtime_num=$(printf '%s' "$current_findtime" | sed -E 's/[^0-9].*//')
            current_bantime_num=$(printf '%s' "$current_bantime" | sed -E 's/[^0-9].*//')
            current_findtime_num=${current_findtime_num:-10}
            current_bantime_num=${current_bantime_num:-10}
            while true; do
                read -r -p "统计时间（分钟，当前 ${current_findtime_num}）： " findtime_input
                findtime_input=${findtime_input:-$current_findtime_num}
                if [[ "$findtime_input" =~ ^[1-9][0-9]*$ ]]; then
                    break
                fi
                red "请输入大于 0 的整数"
            done
            while true; do
                read -r -p "失败次数（当前 ${current_maxretry}）： " maxretry_input
                maxretry_input=${maxretry_input:-$current_maxretry}
                if [[ "$maxretry_input" =~ ^[1-9][0-9]*$ ]]; then
                    break
                fi
                red "请输入大于 0 的整数"
            done
            while true; do
                read -r -p "封禁时间（分钟，当前 ${current_bantime_num}）： " bantime_input
                bantime_input=${bantime_input:-$current_bantime_num}
                if [[ "$bantime_input" =~ ^[1-9][0-9]*$ ]]; then
                    break
                fi
                red "请输入大于 0 的整数"
            done
            findtime="${findtime_input}m"
            bantime="${bantime_input}m"
            mkdir -p /etc/fail2ban/jail.d
            cat > /etc/fail2ban/jail.d/99-script-sshd-nftables.local <<EOF2
[sshd]
enabled = true
port = $ssh_port
filter = sshd
backend = $backend
findtime = $findtime
maxretry = $maxretry_input
bantime = $bantime
action = nftables-multiport[name=sshd, port="%(port)s", protocol="%(protocol)s", blocktype=drop]
EOF2
            if ! fail2ban-client -t >/dev/null 2>&1; then
                red "Fail2ban 配置检查失败，未重启服务"
                fail2ban-client -t 2>&1
                echo "----------------------------------------"
                read -r -p "按回车继续..."
                continue
            fi
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable fail2ban >/dev/null 2>&1 || true
                if ! systemctl restart fail2ban; then
                    red "Fail2ban 启动失败"
                    journalctl -u fail2ban -n 30 --no-pager 2>/dev/null
                    read -r -p "按回车继续..."
                    continue
                fi
            elif command -v rc-update >/dev/null 2>&1; then
                rc-update add fail2ban default >/dev/null 2>&1 || true
                if ! rc-service fail2ban restart; then
                    red "Fail2ban 启动失败"
                    rc-service fail2ban status 2>&1
                    read -r -p "按回车继续..."
                    continue
                fi
            else
                red "未找到 systemctl/rc-service，无法管理 Fail2ban 服务"
                read -r -p "按回车继续..."
                continue
            fi
            sleep 2
            if (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban) || (command -v rc-service >/dev/null 2>&1 && rc-service fail2ban status >/dev/null 2>&1); then
                green "Fail2ban 已启动"
                green "SSH 防护端口: $ssh_port"
                green "sshd 配置端口: $ssh_cfg_display"
                green "sshd 实际监听端口: $ssh_listen_display"
                green "后端: $backend"
                green "规则: ${findtime_input}分钟失败${maxretry_input}次，封禁${bantime_input}分钟"
                green "封禁方式: nftables / drop"
                echo ""
                echo "Fail2ban nftables 状态:"
                nft list table inet f2b-table 2>/dev/null || true
            else
                red "Fail2ban 启动失败"
                journalctl -u fail2ban -n 30 --no-pager 2>/dev/null || true
            fi
            echo "----------------------------------------"
            read -r -p "按回车继续..."
            ;;
        4)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop fail2ban 2>/dev/null || true
            elif command -v rc-service >/dev/null 2>&1; then
                rc-service fail2ban stop 2>/dev/null || true
            fi
            red "Fail2ban 已停止"
            read -r -p "按回车继续..."
            ;;
        0)
            break
            ;;
        *)
            red "输入错误"
            sleep 1
            ;;
        esac
    done
}
purge_port_rules() {
    local target_p="$1"
    [ -z "$target_p" ] && return

    for chain in "script_input" "input"; do
        local handles=$(nft -a list chain inet filter "$chain" 2>/dev/null | grep -E "\bdport $target_p\b|\bsport $target_p\b" | awk '{print $NF}')
        for h in $handles; do
            nft delete rule inet filter "$chain" handle "$h" 2>/dev/null
        done
    done
}

# 辅助函数：初始化 nftables 基础环境
ensure_nft_env() {
    nft add table inet filter 2>/dev/null
    if ! nft list chain inet filter input &>/dev/null; then
        nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null
    fi
    local dirty_handles=""
    dirty_handles=$(nft -a list chain inet filter input 2>/dev/null | awk '
        /comment "ScriptManaged"/ {
            for (i=1;i<=NF;i++)
                if ($i=="handle") print $(i+1)
        }
    ')
    for h in $dirty_handles; do
        nft delete rule inet filter input handle "$h" 2>/dev/null
    done
    if ! nft list chain inet filter input 2>/dev/null | grep -q 'comment "System-lo"'; then
        nft insert rule inet filter input iif "lo" accept comment "System-lo" 2>/dev/null
    fi
    nft add chain inet filter script_blocked 2>/dev/null
    if ! nft list chain inet filter input 2>/dev/null | grep -q 'jump script_blocked'; then
        nft insert rule inet filter input jump script_blocked comment "Jump-to-Blocked" 2>/dev/null
    fi
    if ! nft list chain inet filter input 2>/dev/null | grep -q 'comment "System-State"'; then
        nft insert rule inet filter input ct state established,related accept comment "System-State" 2>/dev/null
    fi
    nft add chain inet filter script_input 2>/dev/null
    if ! nft list chain inet filter input 2>/dev/null | grep -q 'jump script_input'; then
        nft add rule inet filter input jump script_input comment "Jump-to-Script" 2>/dev/null
    fi
}

# 辅助函数：自动安装 conntrack 
ensure_conntrack_tool() {
    if command -v conntrack >/dev/null 2>&1; then return 0; fi
    yellow "检测到未安装 conntrack，正在自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y conntrack >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y conntrack-tools >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y conntrack-tools >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add conntrack-tools >/dev/null 2>&1
    else
        red "无法自动安装 conntrack：未识别的包管理器，跳过连接清理阶段。"
        return 1
    fi
    if command -v conntrack >/dev/null 2>&1; then
        green "conntrack 安装成功。"
        return 0
    else
        red "conntrack 安装失败，请检查网络或软件源！"
        return 1
    fi
}
# 辅助函数：确保 6in4 的 IPv4 Protocol 41 入站规则存在
ensure_he_protocol41() {
    ensure_nft_env
    if nft list chain inet filter input 2>/dev/null | grep -Eq 'ip protocol (41|ipv6) accept'; then
        return 0
    fi
    if nft list chain inet filter script_input 2>/dev/null | grep -Eq 'ip protocol (41|ipv6) accept'; then
        return 0
    fi
    if nft add rule inet filter script_input ip protocol 41 accept comment "HE-6in4" 2>/dev/null; then
        return 0
    fi
    return 1
}

flush_port_conntrack() {
    local target_p="$1"
    [ -z "$target_p" ] && return
    if ensure_conntrack_tool; then
        conntrack -D -p tcp --dport "$target_p" &>/dev/null
        conntrack -D -p udp --dport "$target_p" &>/dev/null
        conntrack -D -p tcp --sport "$target_p" &>/dev/null
        conntrack -D -p udp --sport "$target_p" &>/dev/null
    fi
}

# 添加规则
add_safe_rule() {
    local rule_spec="$1"
    [ -z "$rule_spec" ] && return 1
    ensure_nft_env
    # 全部存入 script_input 链，保持主链干净
    if ! nft insert rule inet filter script_input $rule_spec comment "ScriptManaged"; then
        red "添加 nft 规则失败，请检查语法或系统状态: $rule_spec"
        return 1
    fi
    return 0
}

check_rule_files() {
    local conf="/etc/nftables.conf"
    if ! command -v nft &> /dev/null; then return; fi
    if ! nft list table inet filter &>/dev/null; then
        cat > "$conf" << EOF
flush ruleset
table inet filter {
    chain script_blocked {
    }
    chain script_input {
    }
    chain input {
        type filter hook input priority 0; policy accept;
        iif "lo" accept comment "System-lo"
        ct state established,related accept comment "System-State"
        ip protocol icmp accept comment "System-ICMPv4"
        ip6 nexthdr icmpv6 icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, echo-request } accept comment "System-ICMPv6"
        jump script_blocked comment "Jump-to-Blocked"
        jump script_input comment "Jump-to-Script"
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
        nft -f "$conf" 2>/dev/null
    fi
}

save_nft_rules() {
    local conf="/etc/nftables.conf"
    local tmp_conf="/etc/nftables.conf.tmp"
    local rules_content
    rules_content=$(nft list ruleset 2>/dev/null | awk '
        BEGIN { skip=0 }
        /^table inet port_manager$/ { skip=1; next }
        /^table inet f2b-table$/ { skip=1; next }
        /^table / { skip=0 }
        !skip { print }
    ')
    if [ -z "$rules_content" ]; then
        return 1
    fi
    echo "flush ruleset" > "$tmp_conf"
    echo "$rules_content" >> "$tmp_conf"
    if nft -c -f "$tmp_conf" &>/dev/null; then
        mv "$tmp_conf" "$conf"
    else
        rm -f "$tmp_conf"
        return 1
    fi
}

# ============================================================
# CDN IP 管理
# Cloudflare / Gcore / AWS CloudFront Origin Facing
# ============================================================
CDN_DIR="/etc/sing-box"
CDN_UPDATE_SCRIPT="$CDN_DIR/cdn-ip-update"
CDN_AUTO_FILE="$CDN_DIR/cdn-ip-auto"
CDN_SYSTEMD_SERVICE="/etc/systemd/system/cdn-ip-update.service"
CDN_SYSTEMD_TIMER="/etc/systemd/system/cdn-ip-update.timer"
ensure_cdn_sets() {
    ensure_nft_env
    nft list set inet filter cf_ipv4 >/dev/null 2>&1 || \
        nft add set inet filter cf_ipv4 '{ type ipv4_addr; flags interval; }' 2>/dev/null
    nft list set inet filter cf_ipv6 >/dev/null 2>&1 || \
        nft add set inet filter cf_ipv6 '{ type ipv6_addr; flags interval; }' 2>/dev/null
    nft list set inet filter gcore_ipv4 >/dev/null 2>&1 || \
        nft add set inet filter gcore_ipv4 '{ type ipv4_addr; flags interval; }' 2>/dev/null
    nft list set inet filter gcore_ipv6 >/dev/null 2>&1 || \
        nft add set inet filter gcore_ipv6 '{ type ipv6_addr; flags interval; }' 2>/dev/null
    nft list set inet filter aws_ipv4 >/dev/null 2>&1 || \
        nft add set inet filter aws_ipv4 '{ type ipv4_addr; flags interval; }' 2>/dev/null
    nft list set inet filter aws_ipv6 >/dev/null 2>&1 || \
        nft add set inet filter aws_ipv6 '{ type ipv6_addr; flags interval; }' 2>/dev/null
}
install_cdn_update_script() {
    mkdir -p "$CDN_DIR"
    cat > "$CDN_UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NFT_FAMILY="inet"
NFT_TABLE="filter"
TMP_DIR=""
cleanup() {
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT
log() {
    echo "[CDN] $*"
}
error() {
    echo "[CDN] ERROR: $*" >&2
}
command -v nft >/dev/null 2>&1 || {
    error "未找到 nft"
    exit 1
}
command -v curl >/dev/null 2>&1 || {
    error "未找到 curl"
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    error "未找到 python3"
    exit 1
}
ensure_set() {
    local name="$1"
    local type="$2"
    nft list set "$NFT_FAMILY" "$NFT_TABLE" "$name" >/dev/null 2>&1 && return 0
    nft add set "$NFT_FAMILY" "$NFT_TABLE" "$name" \
        "{ type $type; flags interval; }" >/dev/null 2>&1
}
ensure_sets() {
    ensure_set "cf_ipv4" "ipv4_addr" || return 1
    ensure_set "cf_ipv6" "ipv6_addr" || return 1
    ensure_set "gcore_ipv4" "ipv4_addr" || return 1
    ensure_set "gcore_ipv6" "ipv6_addr" || return 1
    ensure_set "aws_ipv4" "ipv4_addr" || return 1
    ensure_set "aws_ipv6" "ipv6_addr" || return 1
}
TMP_DIR=$(mktemp -d /tmp/cdn-ip-update.XXXXXX) || exit 1
mkdir -p "$TMP_DIR"
log "下载 Cloudflare IPv4..."
curl -4 -fsSL \
    --connect-timeout 15 \
    --max-time 60 \
    "https://www.cloudflare.com/ips-v4" \
    -o "$TMP_DIR/cf_ipv4" || {
        error "Cloudflare IPv4 下载失败"
        exit 1
    }
log "下载 Cloudflare IPv6..."
curl -6 -fsSL \
    --connect-timeout 15 \
    --max-time 60 \
    "https://www.cloudflare.com/ips-v6" \
    -o "$TMP_DIR/cf_ipv6" || {
        error "Cloudflare IPv6 下载失败"
        exit 1
    }
log "下载 Gcore CDN IP..."
curl -fsSL \
    --connect-timeout 15 \
    --max-time 60 \
    "https://api.gcore.com/cdn/public-ip-list" \
    -o "$TMP_DIR/gcore.json" || {
        error "Gcore CDN IP 下载失败"
        exit 1
    }
python3 - "$TMP_DIR/gcore.json" "$TMP_DIR/gcore_ipv4" "$TMP_DIR/gcore_ipv6" <<'PY'
import json
import sys
import ipaddress
src = sys.argv[1]
out4 = sys.argv[2]
out6 = sys.argv[3]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
ipv4 = []
ipv6 = []
for value in data.get("addresses", []):
    try:
        net = ipaddress.ip_network(value, strict=False)
        if net.version == 4:
            ipv4.append(str(net))
    except Exception:
        pass
for value in data.get("addresses_v6", []):
    try:
        net = ipaddress.ip_network(value, strict=False)
        if net.version == 6:
            ipv6.append(str(net))
    except Exception:
        pass
ipv4 = sorted(set(ipv4), key=lambda x: (int(ipaddress.ip_network(x).network_address), ipaddress.ip_network(x).prefixlen))
ipv6 = sorted(set(ipv6), key=lambda x: (int(ipaddress.ip_network(x).network_address), ipaddress.ip_network(x).prefixlen))
with open(out4, "w", encoding="utf-8") as f:
    f.write("\n".join(ipv4))
    if ipv4:
        f.write("\n")
with open(out6, "w", encoding="utf-8") as f:
    f.write("\n".join(ipv6))
    if ipv6:
        f.write("\n")
if not ipv4:
    sys.exit(2)
if not ipv6:
    sys.exit(3)
PY
[ $? -ne 0 ] && {
    error "Gcore CDN IP 数据解析失败"
    exit 1
}
log "下载 AWS IP ranges..."
curl -fsSL \
    --connect-timeout 15 \
    --max-time 120 \
    "https://ip-ranges.amazonaws.com/ip-ranges.json" \
    -o "$TMP_DIR/aws.json" || {
        error "AWS IP ranges 下载失败"
        exit 1
    }
python3 - "$TMP_DIR/aws.json" "$TMP_DIR/aws_ipv4" "$TMP_DIR/aws_ipv6" <<'PY'
import json
import sys
import ipaddress
src = sys.argv[1]
out4 = sys.argv[2]
out6 = sys.argv[3]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)
ipv4 = []
ipv6 = []
for item in data.get("prefixes", []):
    if item.get("service") != "CLOUDFRONT_ORIGIN_FACING":
        continue
    value = item.get("ip_prefix")
    if value:
        try:
            net = ipaddress.ip_network(value, strict=False)
            if net.version == 4:
                ipv4.append(str(net))
        except Exception:
            pass
for item in data.get("ipv6_prefixes", []):
    if item.get("service") != "CLOUDFRONT_ORIGIN_FACING":
        continue
    value = item.get("ipv6_prefix")
    if value:
        try:
            net = ipaddress.ip_network(value, strict=False)
            if net.version == 6:
                ipv6.append(str(net))
        except Exception:
            pass
ipv4 = sorted(set(ipv4), key=lambda x: (int(ipaddress.ip_network(x).network_address), ipaddress.ip_network(x).prefixlen))
ipv6 = sorted(set(ipv6), key=lambda x: (int(ipaddress.ip_network(x).network_address), ipaddress.ip_network(x).prefixlen))
with open(out4, "w", encoding="utf-8") as f:
    f.write("\n".join(ipv4))
    if ipv4:
        f.write("\n")
with open(out6, "w", encoding="utf-8") as f:
    f.write("\n".join(ipv6))
    if ipv6:
        f.write("\n")
if not ipv4:
    sys.exit(2)
if not ipv6:
    sys.exit(3)
PY
[ $? -ne 0 ] && {
    error "AWS CloudFront Origin Facing IP 数据解析失败"
    exit 1
}
validate_file() {
    local file="$1"
    local family="$2"
    [ -s "$file" ] || return 1
    if [ "$family" = "ipv4" ]; then
        grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$file" || return 1
    else
        grep -Eq '^[0-9A-Fa-f:]+/[0-9]+$' "$file" || return 1
    fi
    return 0
}
validate_file "$TMP_DIR/cf_ipv4" ipv4 || {
    error "Cloudflare IPv4 数据验证失败"
    exit 1
}
validate_file "$TMP_DIR/cf_ipv6" ipv6 || {
    error "Cloudflare IPv6 数据验证失败"
    exit 1
}
validate_file "$TMP_DIR/gcore_ipv4" ipv4 || {
    error "Gcore IPv4 数据验证失败"
    exit 1
}
validate_file "$TMP_DIR/gcore_ipv6" ipv6 || {
    error "Gcore IPv6 数据验证失败"
    exit 1
}
validate_file "$TMP_DIR/aws_ipv4" ipv4 || {
    error "AWS CloudFront IPv4 数据验证失败"
    exit 1
}
validate_file "$TMP_DIR/aws_ipv6" ipv6 || {
    error "AWS CloudFront IPv6 数据验证失败"
    exit 1
}
ensure_sets || {
    error "创建 nftables CDN set 失败"
    exit 1
}
CF4=$(wc -l < "$TMP_DIR/cf_ipv4")
CF6=$(wc -l < "$TMP_DIR/cf_ipv6")
GC4=$(wc -l < "$TMP_DIR/gcore_ipv4")
GC6=$(wc -l < "$TMP_DIR/gcore_ipv6")
AWS4=$(wc -l < "$TMP_DIR/aws_ipv4")
AWS6=$(wc -l < "$TMP_DIR/aws_ipv6")
log "Cloudflare IPv4: $CF4"
log "Cloudflare IPv6: $CF6"
log "Gcore IPv4:      $GC4"
log "Gcore IPv6:      $GC6"
log "AWS CloudFront v4: $AWS4"
log "AWS CloudFront v6: $AWS6"
NFT_FILE="$TMP_DIR/update.nft"
cat > "$NFT_FILE" <<NFT_EOF
flush set inet filter cf_ipv4
add element inet filter cf_ipv4 { $(paste -sd, "$TMP_DIR/cf_ipv4") }
flush set inet filter cf_ipv6
add element inet filter cf_ipv6 { $(paste -sd, "$TMP_DIR/cf_ipv6") }
flush set inet filter gcore_ipv4
add element inet filter gcore_ipv4 { $(paste -sd, "$TMP_DIR/gcore_ipv4") }
flush set inet filter gcore_ipv6
add element inet filter gcore_ipv6 { $(paste -sd, "$TMP_DIR/gcore_ipv6") }
flush set inet filter aws_ipv4
add element inet filter aws_ipv4 { $(paste -sd, "$TMP_DIR/aws_ipv4") }
flush set inet filter aws_ipv6
add element inet filter aws_ipv6 { $(paste -sd, "$TMP_DIR/aws_ipv6") }
NFT_EOF
log "更新 nftables CDN IP..."
nft -f "$NFT_FILE" || {
    error "nftables 更新失败"
    error "原有 CDN IP 未被主动清空"
    exit 1
}
printf 'CF4=%s\nCF6=%s\nGC4=%s\nGC6=%s\nAWS4=%s\nAWS6=%s\n' \
    "$CF4" "$CF6" "$GC4" "$GC6" "$AWS4" "$AWS6" \
    > /etc/sing-box/cdn-ip-counts
date '+%Y-%m-%d %H:%M:%S' > "/etc/sing-box/cdn-ip-last-update"
log "CDN IP 更新成功"
EOF
    chmod +x "$CDN_UPDATE_SCRIPT"
}
install_cdn_auto_update() {
    mkdir -p /etc/sing-box
    cat > /etc/systemd/system/cdn-ip-update.service <<'EOF'
[Unit]
Description=CDN IP whitelist update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/sing-box/cdn-ip-update
EOF

    cat > /etc/systemd/system/cdn-ip-update.timer <<'EOF'
[Unit]
Description=Automatic CDN IP whitelist update

[Timer]
OnBootSec=5min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
}
cdn_auto_update_enable() {
    mkdir -p /etc/sing-box

    install_cdn_auto_update

    echo "1" > /etc/sing-box/cdn-ip-auto

    systemctl enable --now cdn-ip-update.timer >/dev/null 2>&1

    green "CDN IP 自动更新已开启"
    echo "更新周期：每 24 小时"
}
cdn_auto_update_disable() {
    echo "0" > /etc/sing-box/cdn-ip-auto

    systemctl disable --now cdn-ip-update.timer >/dev/null 2>&1

    yellow "CDN IP 自动更新已关闭"
}
cdn_auto_update_toggle() {
    if [ -f /etc/sing-box/cdn-ip-auto ] &&
       [ "$(cat /etc/sing-box/cdn-ip-auto 2>/dev/null)" = "1" ]; then
        cdn_auto_update_disable
    else
        cdn_auto_update_enable
    fi
}
cdn_ip_status() {
    echo ""
    echo "========================================"
    echo "           CDN IP 当前状态"
    echo "========================================"
    echo ""
    local CF4=0 CF6=0 GC4=0 GC6=0 AWS4=0 AWS6=0
    local count_file="/etc/sing-box/cdn-ip-counts"

    if [ -f "$count_file" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                CF4) CF4="$value" ;;
                CF6) CF6="$value" ;;
                GC4) GC4="$value" ;;
                GC6) GC6="$value" ;;
                AWS4) AWS4="$value" ;;
                AWS6) AWS6="$value" ;;
            esac
        done < "$count_file"
    fi

    echo "Cloudflare IPv4       : $CF4"
    echo "Cloudflare IPv6       : $CF6"
    echo "Gcore IPv4            : $GC4"
    echo "Gcore IPv6            : $GC6"
    echo "AWS CloudFront IPv4   : $AWS4"
    echo "AWS CloudFront IPv6   : $AWS6"

    echo ""
    if [ -f /etc/sing-box/cdn-ip-auto ] &&
       [ "$(cat /etc/sing-box/cdn-ip-auto 2>/dev/null)" = "1" ]; then
        green "自动更新：已开启"
    else
        yellow "自动更新：已关闭"
    fi

    if [ -f /etc/sing-box/cdn-ip-last-update ]; then
        echo "最后更新：$(cat /etc/sing-box/cdn-ip-last-update)"
    else
        echo "最后更新：从未更新"
    fi

    echo ""
}

cdn_ip_manager() {
    mkdir -p /etc/sing-box
    ensure_cdn_sets
    if [ ! -x "$CDN_UPDATE_SCRIPT" ]; then
        install_cdn_update_script
    fi
    while true; do
        clear
        echo "========================================"
        echo "             CDN IP 管理"
        echo "========================================"
        echo ""
        if [ -f /etc/sing-box/cdn-ip-auto ] &&
           [ "$(cat /etc/sing-box/cdn-ip-auto 2>/dev/null)" = "1" ]; then
            echo "自动更新：已开启"
        else
            echo "自动更新：已关闭"
        fi
        echo ""
        if [ -f /etc/sing-box/cdn-ip-last-update ]; then
            echo "最后更新：$(cat /etc/sing-box/cdn-ip-last-update)"
        else
            echo "最后更新：从未更新"
        fi

        echo ""
        echo " 1. 手动更新 CDN IP"
        echo " 2. 开启/关闭自动更新"
        echo " 3. 查看 CDN IP 数量"
        echo " 0. 返回"
        echo ""

        reading "请选择: " cdn_menu

        case "$cdn_menu" in
            1)
    clear
    if [ ! -x "$CDN_UPDATE_SCRIPT" ]; then
        echo "正在初始化 CDN IP 更新程序..."
        install_cdn_update_script || {
            red "CDN IP 更新程序创建失败"
            echo ""
            read -r -p "按 Enter 返回..."
            continue
        }
    fi
    "$CDN_UPDATE_SCRIPT"
    echo ""
    read -r -p "按 Enter 返回..."
    ;;
            2)
                cdn_auto_update_toggle
                echo ""
                read -r -p "按 Enter 返回..."
                ;;
            3)
                clear
                cdn_ip_status
                read -r -p "按 Enter 返回..."
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
#vps秘钥登录
setup_ssh_key_only() {
    clear
    echo "========================================"
    echo "       VPS SSH 密钥登录一键重置"
    echo "========================================"
    echo ""
    if [ "$(id -u)" != "0" ]; then
        echo "错误：必须使用 root 执行"
        return 1
    fi
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo "正在安装 ssh-keygen..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y openssh-client >/dev/null 2>&1 || {
                echo "错误：ssh-keygen 安装失败"
                return 1
            }
        else
            echo "错误：仅支持 Debian / Ubuntu"
            return 1
        fi
    fi
    local ssh_dir="/root/.ssh"
    local key_file="$ssh_dir/id_ed25519"
    local pub_file="$key_file.pub"
    local auth_file="$ssh_dir/authorized_keys"
    local config_dir="/etc/ssh/sshd_config.d"
    local config_file="$config_dir/99-key-only.conf"
    local backup_dir="/root/ssh-config-backup"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$ssh_dir" "$config_dir" "$backup_dir"
    chmod 700 "$ssh_dir"
    echo "[1/8] 生成全新 ED25519 密钥..."
    [ -f "$key_file" ] && mv -f "$key_file" "$key_file.bak.$timestamp"
    [ -f "$pub_file" ] && mv -f "$pub_file" "$pub_file.bak.$timestamp"
    if ! ssh-keygen -t ed25519 -f "$key_file" -N "" -C "root@$(hostname)-$timestamp" >/dev/null 2>&1; then
        echo "错误：密钥生成失败"
        return 1
    fi
    chmod 600 "$key_file"
    chmod 644 "$pub_file"
    echo "[2/8] 安装新公钥..."
    cat "$pub_file" > "$auth_file"
    chmod 600 "$auth_file"
    if ! grep -qxF "$(cat "$pub_file")" "$auth_file"; then
        echo "错误：公钥写入失败"
        return 1
    fi
    echo "[3/8] 备份全部 SSH 配置..."
    cp -a /etc/ssh/sshd_config "$backup_dir/sshd_config.$timestamp"
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        cp -a "$f" "$backup_dir/$(basename "$f").$timestamp"
    done
    echo "[4/8] 扫描所有 SSH 配置..."
    grep -RniE '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || true
    echo ""
    echo "[5/8] 关闭所有密码/交互式认证..."
    find /etc/ssh/sshd_config.d -type f -name '*.conf' -print0 2>/dev/null | while IFS= read -r -d '' f; do
        sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' "$f"
        sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/' "$f"
        sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/' "$f"
    done
    sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
    sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    cat > "$config_file" <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
    echo "[6/8] 检查 SSH 配置..."
    if ! sshd -t 2>/dev/null; then
        echo "错误：SSH 配置检查失败"
        return 1
    fi
    echo ""
    echo "最终生效配置："
    sshd -T | grep -Ei 'pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods'
    echo ""
    if sshd -T | grep -q '^passwordauthentication yes'; then
        echo "错误：密码登录仍然开启"
        return 1
    fi
    if sshd -T | grep -q '^kbdinteractiveauthentication yes'; then
        echo "错误：键盘交互登录仍然开启"
        return 1
    fi
    echo "[7/8] 重新加载 SSH..."
    local ssh_service=""
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh.service'; then
        ssh_service="ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd.service'; then
        ssh_service="sshd"
    fi
    if [ -n "$ssh_service" ]; then
        if ! systemctl reload "$ssh_service" 2>/dev/null; then
            systemctl restart "$ssh_service" || {
                echo "错误：SSH 服务重启失败"
                return 1
            }
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sshd reload || {
            echo "错误：SSH reload 失败"
            return 1
        }
    else
        echo "错误：无法找到 SSH 服务"
        return 1
    fi
    echo "[8/8] 再次验证..."
    local final_config
    final_config="$(sshd -T 2>/dev/null)"
    echo "$final_config" | grep -Ei 'pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods'
    if ! echo "$final_config" | grep -q '^pubkeyauthentication yes$' || ! echo "$final_config" | grep -q '^passwordauthentication no$' || ! echo "$final_config" | grep -q '^kbdinteractiveauthentication no$'; then
        echo ""
        echo "错误：SSH 最终配置验证失败"
        return 1
    fi
    echo ""
    echo "========================================"
    echo "       SSH 密钥重置成功"
    echo "========================================"
    echo ""
    echo "========================================"
    echo "        ★★★ 请复制下面的私钥 ★★★"
    echo "========================================"
    echo ""
    cat "$key_file"
    echo ""
    echo "========================================"
    echo "        ★★★ 私钥复制结束 ★★★"
    echo "========================================"
    echo ""
    echo "密码登录：已关闭"
    echo "键盘交互登录：已关闭"
    echo "密钥登录：已开启"
    echo ""
    echo "每次执行此函数 = 重新生成全新密钥"
    echo ""
}

# Iptables简单管理
ipt_msg() { echo -e "${1}${2}\033[0m"; }
iptables_ssl() {
    check_and_install_nftables
    clear
    check_rule_files
    local tag="ScriptManaged"
    
    local status_text=""
    local mode_text=""
    local svc_status=$(systemctl is-active nftables 2>/dev/null)
    local pm_status=$(systemctl is-active port_manager 2>/dev/null)
    
    local policy=$(nft list chain inet filter input 2>/dev/null | awk '/policy/ {print $NF}' | tr -d ';')
    local rule_count=$(nft list ruleset 2>/dev/null | grep -vE "^table|^chain|^}" | wc -l)

    if ! command -v nft &> /dev/null; then
        status_text="\033[0;31m未安装\033[0m"
        mode_text="\033[0;37m未知\033[0m"
    elif [ "$rule_count" -gt 0 ] || [ "$svc_status" == "active" ]; then
        status_text="\033[0;32m运行中\033[0m"
        if [ "$policy" == "drop" ]; then
            mode_text="\033[0;32m开启\033[0m"
        else
            mode_text="\033[0;31m关闭\033[0m"
        fi
    else
        status_text="\033[0;31m已停止\033[0m"
        mode_text="\033[0;37m未拦截\033[0m"
    fi
	
	local ssh_p=""
    if command -v sshd &>/dev/null; then
    ssh_p=$(sshd -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/ {print $2}')
    fi
    if [ -z "$ssh_p" ]; then
    ssh_p=$(grep -iE "^[[:space:]]*Port[[:space:]]+" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '$2 ~ /^[0-9]+$/ {print $2}')
    fi
    [ -z "$ssh_p" ] && ssh_p="22"

    local nat_rules=$(nft list ruleset 2>/dev/null | awk '/dnat to/ {
        port=""; to="";
        for(i=1;i<=NF;i++){
            if($i=="dport") port=$(i+1);
            if($i=="to") to=$(i+1);
        }
        if(port != "") { print " 端口:" port " -> 转发至:" to }
    }')
    [ -z "$nat_rules" ] && nat_rules="  暂无转发规则"
	
    echo ""
    green "=== 防火墙与流量管理面板 ==="
    echo -e "防火墙状态: $status_text"
    echo -e "拦截模式: $mode_text"
    
    # 联动显示选项 8 流量管控服务状态
    if [ "$pm_status" == "active" ]; then
        local pm_cnt=$(ls -1 /etc/port_manager/*.conf 2>/dev/null | wc -l)
        echo -e "流量管控: \033[0;32m运行中\033[0m (已设置 $pm_cnt 个端口)"
    else
        echo -e "流量管控: \033[0;37m未启用\033[0m"
    fi
    
    ipt_msg "\033[0;36m" "系统当前 SSH 端口: ${ssh_p}"
    echo -e "\033[0;33m$nat_rules\033[0m"
    skyblue "---------------------------"

    ipt_msg "\033[0;33m" "已在防火墙放行的端口:"
    printf "%-13s %-19s %-15s\n" "端口号" "所属服务" "说明"   

        local allowed_ports=""
    if command -v nft &> /dev/null; then
        allowed_ports=$(nft list chain inet filter script_input 2>/dev/null | awk '/dport.*accept/ {
            for(i=1;i<=NF;i++) if($i=="dport") { print $(i+1); break; }
        }' | tr -d '{};' | tr ',' '\n' | grep -E "^[0-9]+$" | sort -un)
        
        for port in $allowed_ports; do
            local is_script=$(nft list chain inet filter script_input 2>/dev/null | grep -E "dport.*$port.*$tag")
            local note="系统/手动"
            [ -n "$is_script" ] && note="脚本放行"
            
            if [ -f "/etc/port_manager/${port}.conf" ]; then
                note="${note}[限速中]"
            fi
            
            local name="未运行"
            local ss_line=$(ss -tunlp | grep ":$port " | head -n1)
            if [[ "$ss_line" =~ \"([^\"]+)\" ]]; then
                name="${BASH_REMATCH[1]}"
            fi
            printf "\033[0;32m%-10s %-15s %-10s\033[0m\n" "$port" "$name" "$note"
        done
    fi
    
    echo -e "\033[0;36m---------------------------\033[0m"
    ipt_msg "\033[0;35m" "检测到正在运行但【未放行】的端口"
    printf "%-13s %-19s %-15s\n" "端口号"    "所属服务"    "监听IP/状态"    
    ss -tunlp | awk 'NR>1 {
        addr = $5; n = split(addr, a, ":"); port = a[n];
        ip = ""; for(i=1; i<n; i++) ip = (ip == "" ? a[i] : ip ":" a[i]);
        if (ip ~ /:/ || ip ~ /\[/) next;
        if (ip == "" || ip == "*") ip = "0.0.0.0";
        name = "未知服务"; if ($NF ~ /"/) { split($NF, s, "\""); name = s[2] }
        if (port ~ /^[0-9]+$/ && port > 0) print port, name, ip}' | sort -un | sort -n -k1,1 | while read -r p_port p_name p_ip; do
        if ! echo "$allowed_ports" | grep -qw "$p_port"; then
            local warn_extra=""
            if [ -f "/etc/port_manager/${p_port}.conf" ]; then
                warn_extra=" (已限速但未放行!)"
            fi
            printf "\033[0;31m%-10s %-15s %-10s\033[0m\n" "$p_port" "$p_name" "${p_ip}${warn_extra}"
        fi
    done
    skyblue "---------------------------"
    green "1. 开启端口"
    green "2. 管理端口"
    green "3. 开启拦截"
    green "4. 关闭拦截"
    green "5. 安装更新"
    green "6. 停止运行"
    green "7. 程序重启"
    red   "8. 端口流量网速设置"
    green "9. 清理未运行端口"
	green "10. 修改SSH连接端口"	
	green "11. VPS开启秘钥登录"	
	green "12. fail2ban"	
    purple "0. 回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " ipt_choice
    case "${ipt_choice}" in
                  1)
            read -p "请输入要开放的端口号: " o_port
            if [ -z "$o_port" ]; then
                yellow "未输入端口号，操作已取消。"
            elif ! [[ "$o_port" =~ ^[0-9]+$ ]] || [ "$o_port" -le 0 ] || [ "$o_port" -gt 65535 ]; then
                red "错误：请输入有效的端口号 (1-65535)"
            else
                echo -e "\n请选择放行协议:"
                echo -e " 1. TCP"
                echo -e " 2. UDP"
                echo -e " 3. TCP + UDP (默认)"
                read -p "请输入选择 [1-3] (默认 3): " proto_choice
                local proto_list=()
                case "${proto_choice}" in
                    1) proto_list=("tcp") ;;
                    2) proto_list=("udp") ;;
                    *) proto_list=("tcp" "udp") ;;
                esac
                echo -e "\n请选择允许访问的 IP 模式:"
                echo -e " 1. 特定 IP 访问 (支持输入多个，空格分隔)"
                echo -e " 2. 仅允许所有 IPv4 访问"
                echo -e " 3. 仅允许所有 IPv6 访问"
                read -p "请输入选择 [1-3] (默认不限制 IP): " ip_choice
                local custom_ips=""
                if [ "${ip_choice}" == "1" ]; then
                    read -p "请输入允许连接的 IP (多个 IP 请用空格分隔): " custom_ips
                fi
                nft add chain inet filter script_blocked 2>/dev/null
                if ! nft list chain inet filter input 2>/dev/null | grep -q 'jump script_blocked'; then
                    nft insert rule inet filter input jump script_blocked 2>/dev/null
                fi
                for proto in "${proto_list[@]}"; do
                    while read -r h; do
                        [ -z "$h" ] && continue
                        nft delete rule inet filter script_blocked handle "$h" 2>/dev/null
                    done < <(
                        nft -a list chain inet filter script_blocked 2>/dev/null |
                        awk -v proto="$proto" -v port="$o_port" '
                            $0 ~ proto " dport " port " drop" {
                                for (i=1;i<=NF;i++)
                                    if ($i=="handle") print $(i+1)
                            }
                        '
                    )
                done
                purge_port_rules "$o_port"
                local add_failed=0
                case "${ip_choice}" in
                    1)
                        if [ -z "$custom_ips" ]; then
                            for proto in "${proto_list[@]}"; do
                                add_safe_rule "$proto dport $o_port accept" || add_failed=1
                            done
                        else
                            for proto in "${proto_list[@]}"; do
                                for ip in $custom_ips; do
                                    if [[ "$ip" == *:* ]]; then
                                        add_safe_rule "ip6 saddr $ip $proto dport $o_port accept" || add_failed=1
                                    else
                                        add_safe_rule "ip saddr $ip $proto dport $o_port accept" || add_failed=1
                                    fi
                                done
                            done
                        fi
                        ;;
                    2)
                        for proto in "${proto_list[@]}"; do
                            add_safe_rule "meta nfproto ipv4 $proto dport $o_port accept" || add_failed=1
                        done
                        ;;
                    3)
                        for proto in "${proto_list[@]}"; do
                            add_safe_rule "meta nfproto ipv6 $proto dport $o_port accept" || add_failed=1
                        done
                        ;;
                    *)
                        for proto in "${proto_list[@]}"; do
                            add_safe_rule "$proto dport $o_port accept" || add_failed=1
                        done
                        ;;
                esac
                if [ "$add_failed" -eq 0 ]; then
                    save_nft_rules
                    flush_port_conntrack "$o_port"
                    green "成功：端口 $o_port 已重新放行 (${proto_list[*]})"
                else
                    red "错误：放行端口失败！请检查 IP 格式或 nftables 语法。"
                fi
            fi
            sleep 1 && iptables_ssl ;;
                        2)
            clear
            local raw_rules=$(nft -a list chain inet filter script_input 2>/dev/null | grep 'dport')
            if [ -z "$raw_rules" ]; then
                green "=== 当前防火墙端口规则列表 ==="
                yellow "当前没有检测到任何已放行的端口规则。"
                echo ""
                reading "按回车键返回主菜单..." dummy_var
            else
                green "=== 当前防火墙端口规则列表 ==="
                printf "${green}%-8s %-12s %-12s %-25s${re}\n" "序号" "端口号" "协议" "允许的 IP"
                skyblue "------------------------------------------------------------"
                local rule_handles=()
                local rule_port=()
                local rule_proto=()
                local rule_ip=()
                local rule_count=0
                while read -r line; do
                    [ -z "$line" ] && continue
                    local h=$(echo "$line" | grep -oE 'handle [0-9]+' | awk '{print $2}')
                    local p=$(echo "$line" | grep -oE 'dport [0-9]+' | awk '{print $2}')
                    [ -z "$h" ] || [ -z "$p" ] && continue
                    local proto="tcp"
                    if echo "$line" | grep -qw "udp"; then
                        proto="udp"
                    fi
                    local ip_limit="所有 IP"
                    if echo "$line" | grep -q "saddr @gcore_ipv4"; then
                    ip_limit="Gcore IPv4"
                    elif echo "$line" | grep -q "saddr @gcore_ipv6"; then
                    ip_limit="Gcore IPv6"
                    elif echo "$line" | grep -q "saddr @aws_ipv4"; then
                    ip_limit="CloudFront IPv4"
                    elif echo "$line" | grep -q "saddr @aws_ipv6"; then
                    ip_limit="CloudFront IPv6"
                    elif echo "$line" | grep -q "saddr @cf_ipv4"; then
                    ip_limit="Cloudflare IPv4"
                    elif echo "$line" | grep -q "saddr @cf_ipv6"; then
                    ip_limit="Cloudflare IPv6"
                    elif echo "$line" | grep -q "meta nfproto ipv4" || echo "$line" | grep -q "saddr 0.0.0.0/0"; then
                    ip_limit="仅 IPv4"
                    elif echo "$line" | grep -q "meta nfproto ipv6" || echo "$line" | grep -q "saddr ::/0"; then
                    ip_limit="仅 IPv6"
                    elif echo "$line" | grep -q "saddr"; then
                    ip_limit=$(echo "$line" | grep -oE 'saddr [0-9a-fA-F:./]+' | awk '{print $2}')
                    fi
                    ((rule_count++))
                    rule_handles[$rule_count]="$h"
                    rule_port[$rule_count]="$p"
                    rule_proto[$rule_count]="$proto"
                    rule_ip[$rule_count]="$ip_limit"
                done <<< "$raw_rules"
                for ((i=1; i<=rule_count; i++)); do
                    printf "${green}%-8s %-12s %-12s %-25s${re}\n" "[$i]" "${rule_port[$i]}" "${rule_proto[$i]}" "${rule_ip[$i]}"
                done
                skyblue "------------------------------------------------------------"
                green " [0] 返回主菜单"
                echo -e "操作提示：输入${green}数字${re}(修改规则) | 输入 ${red}d+数字${re}(删除规则, 如 ${red}d1${re}) | 输入 ${green}0${re}(返回)"
                reading "请输入指令: " input_cmd
                input_cmd=$(echo "$input_cmd" | xargs)
                if [ -z "$input_cmd" ] || [ "$input_cmd" == "0" ]; then
                    :
                elif [[ "$input_cmd" =~ ^[dD]\ *([0-9]+)$ ]]; then
                    local sel_idx="${BASH_REMATCH[1]}"
                    if [ "$sel_idx" -ge 1 ] && [ "$sel_idx" -le "$rule_count" ]; then
                        local target_port="${rule_port[$sel_idx]}"
                        local target_proto="${rule_proto[$sel_idx]}"
                        local target_handle="${rule_handles[$sel_idx]}"
                        nft add chain inet filter script_blocked 2>/dev/null
                        if ! nft list chain inet filter input 2>/dev/null | grep -q 'jump script_blocked'; then
                            nft insert rule inet filter input jump script_blocked 2>/dev/null
                        fi
                        if [ -n "$target_handle" ]; then
                            nft delete rule inet filter script_input handle "$target_handle" 2>/dev/null
                        fi
                        while read -r h; do
                            [ -z "$h" ] && continue
                            nft delete rule inet filter input handle "$h" 2>/dev/null
                        done < <(
                            nft -a list chain inet filter input 2>/dev/null |
                            awk -v proto="$target_proto" -v port="$target_port" '
                                $0 ~ proto " dport " port " accept" && $0 ~ /comment "ScriptManaged"/ {
                                    for (i=1;i<=NF;i++)
                                        if ($i=="handle") print $(i+1)
                                }
                            '
                        )
                        local remain_rule=0
                        if nft list chain inet filter script_input 2>/dev/null |
                            grep -qE '(^| )'"$target_proto"' dport '"$target_port"' .*accept.*comment "ScriptManaged"'; then
                            remain_rule=1
                        fi
                        while read -r h; do
                            [ -z "$h" ] && continue
                            nft delete rule inet filter script_blocked handle "$h" 2>/dev/null
                        done < <(
                            nft -a list chain inet filter script_blocked 2>/dev/null |
                            awk -v proto="$target_proto" -v port="$target_port" '
                                $0 ~ proto " dport " port " drop" {
                                    for (i=1;i<=NF;i++)
                                        if ($i=="handle") print $(i+1)
                                }
                            '
                        )
                        if [ "$remain_rule" -eq 0 ]; then
                            nft add rule inet filter script_blocked "$target_proto" dport "$target_port" drop 2>/dev/null
                        fi
                        flush_port_conntrack "$target_port"
                        save_nft_rules
                        green "成功：已删除 $target_proto/$target_port 这条规则"
                    else
                        red "错误：找不到序号为 [$sel_idx] 的规则！"
                    fi
                elif [[ "$input_cmd" =~ ^[0-9]+$ ]]; then
                    local sel_idx="$input_cmd"
                    if [ "$sel_idx" -ge 1 ] && [ "$sel_idx" -le "$rule_count" ]; then
                        local curr_port="${rule_port[$sel_idx]}"
                        local curr_proto="${rule_proto[$sel_idx]}"
                        green "\n正在修改序号 [$sel_idx] 的规则 (当前: 端口 $curr_port / $curr_proto):"
                        echo ""
                        echo "请选择放行协议:"
                        echo " 1. TCP"
                        echo " 2. UDP"
                        echo " 3. TCP + UDP (默认)"
                        reading "请输入选择 [1-3] (默认 3): " proto_choice
                        local proto_list=()
                        case "${proto_choice}" in
                            1) proto_list=("tcp") ;;
                            2) proto_list=("udp") ;;
                            *) proto_list=("tcp" "udp") ;;
                        esac
                        echo ""
                        echo " 1. 特定 IP 访问 (支持输入多个，空格分隔)"
                        echo " 2. 仅允许所有 IPv4 访问"
                        echo " 3. 仅允许所有 IPv6 访问"
                        echo " 4. 仅允许 CDN IP 访问"
                        reading "请输入选择 [1-4] (默认不限制 IP): " ip_choice
local custom_ips=""
if [ -z "$ip_choice" ]; then
    ip_choice="0"
fi
if [[ ! "$ip_choice" =~ ^[0-4]$ ]]; then
    red "错误：IP 类型选择无效，请输入 1-4"
    sleep 1
    iptables_ssl
    return
fi
if [ "${ip_choice}" == "1" ]; then
    reading "请输入允许连接的 IP (多个 IP 请用空格分隔): " custom_ips
fi
local cdn_choice=""
if [ "${ip_choice}" == "4" ]; then
    local cdn_set_count=0
    for cdn_set in cf_ipv4 cf_ipv6 gcore_ipv4 gcore_ipv6 aws_ipv4 aws_ipv6; do
        local set_count=0
        set_count=$(nft list set inet filter "$cdn_set" 2>/dev/null |
            awk '/elements = \{/{flag=1; next} flag{gsub(/[{},;]/,""); for(i=1;i<=NF;i++) if($i!="") count++} END{print count+0}')
        cdn_set_count=$((cdn_set_count + set_count))
    done
    if [ "$cdn_set_count" -eq 0 ]; then
        yellow "检测到 CDN IP 尚未同步，正在打开 CDN IP 管理..."
        sleep 1
        cdn_ip_manager
        cdn_set_count=0
        for cdn_set in cf_ipv4 cf_ipv6 gcore_ipv4 gcore_ipv6 aws_ipv4 aws_ipv6; do
            local set_count=0
            set_count=$(nft list set inet filter "$cdn_set" 2>/dev/null |
                awk '/elements = \{/{flag=1; next} flag{gsub(/[{},;]/,""); for(i=1;i<=NF;i++) if($i!="") count++} END{print count+0}')
            cdn_set_count=$((cdn_set_count + set_count))
        done
        if [ "$cdn_set_count" -eq 0 ]; then
            red "CDN IP 尚未同步，已取消本次 CDN 规则修改。"
            sleep 1
            iptables_ssl
            return
        fi
    fi
    echo ""
    echo "请选择 CDN 来源（可多选）："
    echo ""
    echo " 1. Cloudflare"
    echo " 2. Gcore"
    echo " 3. AWS"
    echo ""
    reading "请输入选择（可输入多个数字，例如 13，直接回车默认全部）: " cdn_choice
    cdn_choice=$(echo "$cdn_choice" | tr -d '[:space:]')
    [ -z "$cdn_choice" ] && cdn_choice="123"
    if [[ ! "$cdn_choice" =~ ^[123]+$ ]]; then
        red "错误：CDN 选择无效，只能输入 1、2、3，例如 13 或 123"
        sleep 1
        iptables_ssl
        return
    fi
fi
nft add chain inet filter script_blocked 2>/dev/null
if ! nft list chain inet filter input 2>/dev/null | grep -q 'jump script_blocked'; then
    nft insert rule inet filter input jump script_blocked 2>/dev/null
fi
purge_port_rules "$curr_port"
for proto in tcp udp; do
    while read -r h; do
        [ -z "$h" ] && continue
        nft delete rule inet filter script_blocked handle "$h" 2>/dev/null
    done < <(
        nft -a list chain inet filter script_blocked 2>/dev/null |
        awk -v proto="$proto" -v port="$curr_port" '
            $0 ~ proto " dport " port " drop" {
                for (i=1;i<=NF;i++)
                    if ($i=="handle") print $(i+1)
            }
        '
    )
done
local add_failed=0
                        case "${ip_choice}" in
                            1)
                                if [ -z "$custom_ips" ]; then
                                    for proto in "${proto_list[@]}"; do
                                        add_safe_rule "$proto dport $curr_port accept" || add_failed=1
                                    done
                                else
                                    for proto in "${proto_list[@]}"; do
                                        for ip in $custom_ips; do
                                            if [[ "$ip" == *:* ]]; then
                                                add_safe_rule "ip6 saddr $ip $proto dport $curr_port accept" || add_failed=1
                                            else
                                                add_safe_rule "ip saddr $ip $proto dport $curr_port accept" || add_failed=1
                                            fi
                                        done
                                    done
                                fi
                                ;;
                            2)
                                for proto in "${proto_list[@]}"; do
                                    add_safe_rule "meta nfproto ipv4 $proto dport $curr_port accept" || add_failed=1
                                done
                                ;;
                            3)
                                for proto in "${proto_list[@]}"; do
                                    add_safe_rule "meta nfproto ipv6 $proto dport $curr_port accept" || add_failed=1
                                done
                                ;;
						    4)
    for proto in "${proto_list[@]}"; do
        for cdn in $(echo "$cdn_choice" | grep -o .); do
            case "$cdn" in
                1)
                    add_safe_rule "ip saddr @cf_ipv4 $proto dport $curr_port accept" || add_failed=1
                    add_safe_rule "ip6 saddr @cf_ipv6 $proto dport $curr_port accept" || add_failed=1
                    ;;
                2)
                    add_safe_rule "ip saddr @gcore_ipv4 $proto dport $curr_port accept" || add_failed=1
                    add_safe_rule "ip6 saddr @gcore_ipv6 $proto dport $curr_port accept" || add_failed=1
                    ;;
                3)
                    add_safe_rule "ip saddr @aws_ipv4 $proto dport $curr_port accept" || add_failed=1
                    add_safe_rule "ip6 saddr @aws_ipv6 $proto dport $curr_port accept" || add_failed=1
                    ;;
            esac
        done
    done
    ;;
                        esac
                        if [ "$add_failed" -eq 0 ]; then
                            local has_tcp=0
                            local has_udp=0
                            for proto in "${proto_list[@]}"; do
                                [ "$proto" = "tcp" ] && has_tcp=1
                                [ "$proto" = "udp" ] && has_udp=1
                            done
                            if [ "$has_tcp" -eq 0 ]; then
                                nft add rule inet filter script_blocked tcp dport "$curr_port" drop 2>/dev/null
                            fi
                            if [ "$has_udp" -eq 0 ]; then
                                nft add rule inet filter script_blocked udp dport "$curr_port" drop 2>/dev/null
                            fi
                            save_nft_rules
                            flush_port_conntrack "$curr_port"
                            green "成功：已重新配置端口 $curr_port (${proto_list[*]})"
                        else
                            red "错误：添加新规则失败！请检查 IP 格式或 nftables 语法。"
                        fi
                    else
                        red "错误：找不到序号为 [$sel_idx] 的规则！"
                    fi
                else
                    red "错误：指令无效，请输入数字(修改) | ${red}d+数字${re}(删除) | 0(返回)"
                fi
            fi
            sleep 1 && iptables_ssl ;;
                3)
            yellow "正在开启拦截模式..."
            ensure_nft_env
		    ensure_he_protocol41
            nft add chain inet filter script_blocked 2>/dev/null
            if ! nft list chain inet filter input 2>/dev/null | grep -q 'jump script_blocked'; then
                nft insert rule inet filter input jump script_blocked comment "Jump-to-Blocked" 2>/dev/null
            fi
            local ssh_ports=""
            if command -v sshd &>/dev/null; then
                ssh_ports=$(sshd -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/ {print $2}')
            fi
            if [ -z "$ssh_ports" ]; then
                ssh_ports=$(grep -iE "^[[:space:]]*Port[[:space:]]+" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+$')
            fi
            [ -z "$ssh_ports" ] && ssh_ports="22"
            local old_auto_rules=$(nft -a list chain inet filter script_input 2>/dev/null | grep -E 'comment "(SSH_Port|PortManager)"')
            while read -r line; do
                [ -z "$line" ] && continue
                local h=$(echo "$line" | grep -oE 'handle [0-9]+' | awk '{print $2}')
                [ -n "$h" ] && nft delete rule inet filter script_input handle "$h" 2>/dev/null
            done <<< "$old_auto_rules"
            for port in $ssh_ports; do
                while read -r h; do
                    [ -z "$h" ] && continue
                    nft delete rule inet filter script_blocked handle "$h" 2>/dev/null
                done < <(
                    nft -a list chain inet filter script_blocked 2>/dev/null |
                    awk -v port="$port" '
                        $0 ~ "tcp dport " port " drop" {
                            for (i=1;i<=NF;i++)
                                if ($i=="handle") print $(i+1)
                        }
                    '
                )
                nft insert rule inet filter script_input tcp dport "$port" accept comment "SSH_Port" 2>/dev/null
            done
            for conf in /etc/port_manager/*.conf; do
                [ -e "$conf" ] || continue
                local pm_p=$(basename "$conf" .conf)
                if [ -n "$pm_p" ] && [ "$pm_p" -gt 0 ] 2>/dev/null; then
                    nft insert rule inet filter script_input tcp dport $pm_p accept comment "PortManager" 2>/dev/null
                    nft insert rule inet filter script_input udp dport $pm_p accept comment "PortManager" 2>/dev/null
                fi
            done
            if ! nft list chain inet filter input 2>/dev/null | grep -q 'comment "System-ICMPv6"'; then
                nft insert rule inet filter input ip6 nexthdr icmpv6 icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, echo-request } accept comment "System-ICMPv6" 2>/dev/null
            fi
            if ! nft list chain inet filter input 2>/dev/null | grep -q 'comment "System-ICMPv4"'; then
                nft insert rule inet filter input ip protocol icmp accept comment "System-ICMPv4" 2>/dev/null
            fi
            nft chain inet filter input '{ policy drop; }' 2>/dev/null
            ensure_he_protocol41
            save_nft_rules
            green "开启拦截成功！(已自动放行 SSH[端口: $ssh_ports])" && sleep 1
            iptables_ssl ;;
        4)
            yellow "正在关闭拦截模式..."
            ensure_nft_env

            # 切换默认策略为 accept
            nft chain inet filter input '{ policy accept; }' 2>/dev/null
            save_nft_rules

            green "已关闭拦截 (默认放行所有入站流量)" && sleep 1
            iptables_ssl ;;

        5)
            yellow "正在配置环境..."
            [[ $EUID -ne 0 ]] && red "请使用 root 用户运行此脚本！" && exit 1      
            if [ -f /etc/debian_version ]; then
                apt-get update -y
                apt-get install -y nftables
            elif [ -f /etc/redhat-release ]; then
                yum install -y nftables
            fi
            systemctl enable nftables 2>/dev/null
            systemctl start nftables 2>/dev/null
            check_rule_files
            save_nft_rules
            green "环境配置完成。" 
            sleep 1 && iptables_ssl ;;
            
        6)
            yellow "正在停止防火墙并清空规则..."
            systemctl stop nftables 2>/dev/null
            systemctl stop port_manager 2>/dev/null
            nft flush ruleset
            green "防火墙及流量限制服务已停止，规则已清空。"
            sleep 1 && iptables_ssl ;;
            
        7)
            yellow "正在重载并激活防火墙与流量限制规则..."  
			systemctl enable nftables >/dev/null 2>&1
            systemctl start nftables >/dev/null 2>&1
            if [ -f "/etc/nftables.conf" ]; then
               nft -f /etc/nftables.conf && green " (/etc/nftables.conf) 防火墙规则已重载。"
            fi
            if ensure_he_protocol41; then
               save_nft_rules
            else
            red "警告：HE Protocol 41 放行规则添加失败！"
            fi
            if [ -f "/usr/local/bin/port_menu.sh" ]; then
              systemctl restart port_manager >/dev/null 2>&1 && green " (port_manager) 流量限制服务已同步重启。"
            fi
            green "重载操作执行完毕。"
            sleep 1 && iptables_ssl ;;
            
        8)  
            clear
            yellow "正在初始化"
            if ! command -v tc &> /dev/null; then
                yellow "检测到系统缺少 tc 工具，正在自动安装"
                if [ -f /etc/debian_version ]; then
                    apt-get update -y && apt-get install -y iproute2
                elif [ -f /etc/redhat-release ]; then
                    yum install -y iproute 2>/dev/null || dnf install -y iproute
                fi
            fi

            cat << 'EOF' > /usr/local/bin/port_menu.sh
#!/bin/bash
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
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONF_DIR="/etc/port_manager"
TARGET_PATH="/usr/local/bin/port_menu.sh"

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m[-] 错误: 请使用 root 权限运行此脚本\033[0m"
    exit 1
fi

mkdir -p "$CONF_DIR"

get_interface() {
    local dev
    dev=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    if [ -z "$dev" ]; then
        dev=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1)
    fi
    echo "$dev"
}
INTERFACE=$(get_interface)

get_bj_time() {
    TZ='Asia/Shanghai' date "+%Y %m %d %H %M"
}

init_nft_table() {
    nft add table inet port_manager 2>/dev/null || true
    nft 'add chain inet port_manager prerouting { type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager postrouting { type filter hook postrouting priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager output { type filter hook output priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager input { type filter hook input priority 0; policy accept; }' 2>/dev/null || true
}

check_and_block() {
    init_nft_table
    read -r BJ_YEAR BJ_MONTH BJ_DAY BJ_HOUR BJ_MINUTE <<< "$(get_bj_time)"
    local CURRENT_MONTH_STR="${BJ_YEAR}${BJ_MONTH}"
    
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        
        [ -z "$STORED_TOTAL" ] && STORED_TOTAL=0
        [ -z "$LAST_IPT_BYTES" ] && LAST_IPT_BYTES=0
        [ -z "$RATE" ] && RATE="UNLIMITED"
        [ -z "$LAST_RESET_MONTH" ] && LAST_RESET_MONTH=""
        
        if [ "$RESET_MODE" == "MONTHLY" ]; then
            local should_reset=0
            if [ "$CURRENT_MONTH_STR" != "$LAST_RESET_MONTH" ]; then
                if [ "$BJ_DAY" -gt 1 ]; then
                    should_reset=1
                elif [ "$BJ_DAY" -eq 1 ]; then
                    if [ "$BJ_HOUR" -gt 0 ] || { [ "$BJ_HOUR" -eq 0 ] && [ "$BJ_MINUTE" -ge 1 ]; }; then
                        should_reset=1
                    fi
                fi
            fi
            
            if [ "$should_reset" -eq 1 ]; then
                nft flush chain inet port_manager "$CHAIN_NAME" 2>/dev/null
                nft add rule inet port_manager "$CHAIN_NAME" counter accept 2>/dev/null
                STORED_TOTAL=0
                LAST_IPT_BYTES=0
                sed -i "s/LAST_RESET_MONTH=.*/LAST_RESET_MONTH=\"$CURRENT_MONTH_STR\"/" "$conf"
                sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"0\"/" "$conf"
                sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"0\"/" "$conf"
                continue
            fi
        fi
        
        local NFT_BYTES
        NFT_BYTES=$(nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | awk '/bytes/ {for(i=1;i<=NF;i++) if($i=="bytes") {print $(i+1); exit}}')
        [ -z "$NFT_BYTES" ] && NFT_BYTES=0
        
        local DIFF=0
        if [ "$NFT_BYTES" -ge "$LAST_IPT_BYTES" ]; then
            DIFF=$(( NFT_BYTES - LAST_IPT_BYTES ))
        else
            DIFF="$NFT_BYTES"
        fi
        
        STORED_TOTAL=$(( STORED_TOTAL + DIFF ))
        LAST_IPT_BYTES="$NFT_BYTES"
        
        sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"$STORED_TOTAL\"/" "$conf"
        sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"$LAST_IPT_BYTES\"/" "$conf"

        if [ "$QUOTA" == "UNLIMITED" ]; then
            continue
        fi
        
        local LIMIT_BYTES=$(( QUOTA * 1048576 ))
        if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
            if ! nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
    done
}

rebuild_tc_filters() {
    tc filter del dev "$INTERFACE" parent 1:0 prio 1 2>/dev/null
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        
        if [ "$RATE" != "UNLIMITED" ]; then
            local HEX=$(printf "%x" "$p")
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dport "$p" 0xffff flowid 1:$HEX 2>/dev/null
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip sport "$p" 0xffff flowid 1:$HEX 2>/dev/null
        fi
    done
}

restore_rules_func() {
    modprobe nf_tables 2>/dev/null || true
    
    while [ -z "$INTERFACE" ]; do
        sleep 2
        INTERFACE=$(get_interface)
    done

    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30 2>/dev/null
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null
    tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit 2>/dev/null

    init_nft_table

    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        local HEX=$(printf "%x" "$p")
        local CHAIN_NAME="LIMIT_P_${p}"

        if [ "$RATE" != "UNLIMITED" ]; then
            tc class add dev "$INTERFACE" parent 1:1 classid 1:$HEX htb rate "$RATE" ceil "$RATE" 2>/dev/null || true
        fi

        nft add chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
        nft flush chain inet port_manager "$CHAIN_NAME"
        nft add rule inet port_manager "$CHAIN_NAME" counter accept

        nft add rule inet port_manager input tcp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager input udp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager output tcp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager output udp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true

        if [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
    done
    rebuild_tc_filters
}

if [ "$1" == "daemon" ]; then
    restore_rules_func
    while true; do
        if ! nft list table inet port_manager &>/dev/null; then
            restore_rules_func
        fi
        check_and_block
        sleep 3
    done
    exit 0
fi

apply_limit() {
    local p=$1
    local r=$2
    local q=$3
    local rm=$4
    read -r lm_y lm_m _ _ _ <<< "$(get_bj_time)"
    local lm="${lm_y}${lm_m}"
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    echo -e "RATE=\"$r\"\nQUOTA=\"$q\"\nRESET_MODE=\"$rm\"\nLAST_RESET_MONTH=\"$lm\"\nSTORED_TOTAL=\"0\"\nLAST_IPT_BYTES=\"0\"" > "$CONF_DIR/${p}.conf"

    tc class del dev "$INTERFACE" classid 1:$HEX 2>/dev/null
    if [ "$r" != "UNLIMITED" ]; then
        if ! tc qdisc show dev "$INTERFACE" | grep -q "htb"; then
            tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
            tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate 1000mbit
            tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit
        fi
        tc class add dev "$INTERFACE" parent 1:1 classid 1:$HEX htb rate "$r" ceil "$r"
    fi
    rebuild_tc_filters

    init_nft_table
    nft add chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
    nft flush chain inet port_manager "$CHAIN_NAME"
    nft add rule inet port_manager "$CHAIN_NAME" counter accept

    nft add rule inet port_manager input tcp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager input udp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager output tcp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager output udp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
}

remove_limit() {
    local p=$1
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    tc class del dev "$INTERFACE" classid 1:$HEX 2>/dev/null
    rm -f "$CONF_DIR/${p}.conf"
    rebuild_tc_filters

    nft flush chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
    nft delete chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
}

show_ports() {
    check_and_block
    echo -e "\033[36m当前网卡: $INTERFACE \033[0m"
    echo "---------------------------------------------"
    printf " %-6s | %-8s | %-8s | %-8s | %-8s | %b\n" "端口" "流量上限" "网速上限" "已用流量" "周期" "状态"
    echo "---------------------------------------------"
    
    local count=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        count=$((count+1))
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        local COLOR_STATUS="\033[32m正常\033[0m"
        
        [ -z "$STORED_TOTAL" ] && STORED_TOTAL=0
        
        if [ "$STORED_TOTAL" -eq 0 ]; then
            local LIVE_BYTES
            LIVE_BYTES=$(nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | awk '/bytes/ {for(i=1;i<=NF;i++) if($i=="bytes") {print $(i+1); exit}}')
            [ -n "$LIVE_BYTES" ] && [ "$LIVE_BYTES" -gt 0 ] && STORED_TOTAL="$LIVE_BYTES"
        fi
        
        local USED_MB=$(awk "BEGIN {printf \"%.2f\", $STORED_TOTAL / 1048576}")
        
        local is_dropped=0
        if nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
            is_dropped=1
        elif [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ] && is_dropped=1
        fi

        if [ "$is_dropped" -eq 1 ]; then
            COLOR_STATUS="\033[31m阻断\033[0m"
            if ! nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
        
        local Q_DISP="无限制"
        [ "$QUOTA" != "UNLIMITED" ] && Q_DISP="${QUOTA}MB"
        
        local R_DISP="无限制"
        [ "$RATE" != "UNLIMITED" ] && R_DISP="${RATE/mbit/Mbps}"

        local M_DISP="一次性"
        [ "$RESET_MODE" == "MONTHLY" ] && M_DISP="每月(1日00:01)"
        
		printf " \033[31m%-6s\033[0m | %-8s | %-8s | %-8s | %-8s | %b\n" "$PORT" "$Q_DISP" "$R_DISP" "${USED_MB}MB" "$M_DISP" "$COLOR_STATUS"
    done
    
    if [ "$count" -eq 0 ]; then
        echo -e "                   \033[33m当前暂未设置任何端口限制\033[0m"
    fi
    echo "---------------------------------------------"
}

while true; do
    clear
    echo "============================================="
    echo "     端口网速与流量限制"
    echo "============================================="
    green "  1. 新增 端口限制"
    green "  2. 修改 端口限制 (会清零当前已用流量)"
    green "  3. 删除 端口限制"
    green "  4. 刷新 流量状态"
    green "  0. 返回 上级菜单"
    echo "============================================="
    echo -e "已设置的端口:\n"
    show_ports
    
	reading "请输入选项 [0-4]: " choice
    case $choice in
        1|2)
            if [ "$choice" == "2" ]; then
                read -p "请输入要【修改】的端口号: " port
                if [ ! -f "$CONF_DIR/${port}.conf" ]; then
                    echo -e "\033[31m[-] 未找到该端口的配置！\033[0m"
                    read -p "按回车键继续..."
                    continue
                fi
                remove_limit "$port"
            else
                read -p "请输入要【限制】的端口号 (如 443): " port
            fi
            
            if [ -z "$port" ]; then
                echo -e "\033[31m[-] 端口号不能为空！\033[0m"
                read -p "按回车键继续..."
                continue
            fi

            echo -e "\n\033[36m>>> 直接按回车跳过流量限制 <<<\033[0m"
            read -p "请输入流量上限(MB): " quota
            if [ -z "$quota" ]; then
                quota="UNLIMITED"
                echo -e " -> \033[33m已设为: 不限制流量\033[0m"
            fi

            echo -e "\n\033[36m>>> 直接输入数字即可 (默认单位 Mbps)，直接按回车跳过网速限制 <<<\033[0m"
            read -p "请输入网速上限(如输入 5 代表 5Mbps): " rate_num
            if [ -z "$rate_num" ]; then
                rate="UNLIMITED"
                echo -e " -> \033[33m已设为: 不限制网速\033[0m"
            else
                rate="${rate_num}mbit"
                echo -e " -> \033[32m已设为: ${rate_num} Mbps\033[0m"
            fi

            echo -e "\n\033[36m>>> 直接按回车默认为一次性限制 <<<\033[0m"
            read -p "是否按月自动重置流量？(输入 y 开启，每月北京时间1日00:01重置): " is_monthly
            if [[ "$is_monthly" == "y" || "$is_monthly" == "Y" ]]; then
                reset_mode="MONTHLY"
                echo -e " -> \033[32m已设为: 每月重置 (北京时间1日00:01)\033[0m"
            else
                reset_mode="ONCE"
                echo -e " -> \033[33m已设为: 一次性限制 (用完即永久阻断)\033[0m"
            fi
            
            apply_limit "$port" "$rate" "$quota" "$reset_mode"
            echo -e "\n\033[32m[+] 端口 $port 限制配置成功！\033[0m"
            read -p "按回车键继续..."
            ;;
        3)
            read -p "请输入要删除限制的端口号: " port
            if [ -f "$CONF_DIR/${port}.conf" ]; then
                remove_limit "$port"
                echo -e "\033[32m[+] 端口 $port 限制已彻底移除！\033[0m"
            else
                echo -e "\033[31m[-] 未找到该端口的配置！\033[0m"
            fi
            read -p "按回车键继续..."
            ;;
		4)
            echo -e "\n\033[36m[+] 正在刷新端口流量统计与拦截状态...\033[0m"
            check_and_block
            restore_rules_func
            echo -e "\n\033[32m[+] 刷新完成！当前数据已更新。\033[0m"
            sleep 1
            ;;
        0)
            echo -e "\033[32m返回防火墙。\033[0m"
            break
            ;;
        *)
            red "无效选项，请重新输入。"
            sleep 1
            ;;
    esac
done
EOF

            chmod +x /usr/local/bin/port_menu.sh
            cat << 'SRVEOF' > /etc/systemd/system/port_manager.service
[Unit]
Description=Port Traffic Manager Background Service (nftables)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/port_menu.sh daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SRVEOF

            systemctl daemon-reload >/dev/null 2>&1
            systemctl enable port_manager.service >/dev/null 2>&1
            systemctl restart port_manager.service >/dev/null 2>&1
            systemctl stop restore_iptables.service >/dev/null 2>&1
            systemctl disable restore_iptables.service >/dev/null 2>&1
            rm -f /etc/systemd/system/restore_iptables.service
            bash /usr/local/bin/port_menu.sh menu
            sleep 1 && iptables_ssl
            ;;                  
9)
        yellow "正在扫描所有 nftables 端口规则..."
    yellow "Hysteria2 端口跳跃规则将自动排除。"

    local cleaned=0

    # 1. 预先一次性获取所有正在监听的 TCP/UDP 端口 (格式: proto:port，例如 tcp:80 或 udp:53)
    local listening_ports
    listening_ports=$(ss -H -lntu 2>/dev/null | awk '{
        proto=$1
        addr=$5
        sub(/.*:/, "", addr)
        if (proto ~ /^(tcp|udp)$/ && addr ~ /^[0-9]+$/) {
            print proto ":" addr
        }
    }' | sort -u)

    local family table chain type port handle

    # 2. 解析并逐条比对 nftables 规则
    while read -r family table chain type port handle; do
        [[ "$family" =~ ^(ip|ip6|inet)$ ]] || continue
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        [[ "$handle" =~ ^[0-9]+$ ]] || continue

        # 排除 Hysteria2 NAT 表，避免误删 Hy2 端口跳跃规则
        if [[ "$table" == "hysteria_nat" ]]; then
            yellow "跳过 Hy2 端口跳跃规则: $family $table $chain $type $port"
            continue
        fi

        # 3. 精确校验该协议 (tcp/udp) 和端口是否在监听列表中
        if ! grep -q -x "${type}:${port}" <<< "$listening_ports"; then
            if nft delete rule "$family" "$table" "$chain" handle "$handle" 2>/dev/null; then
                green "已清理未运行规则: $family $table $chain $type $port (handle $handle)"
                cleaned=1
            fi
        fi
    done < <(
        nft -a -nn list ruleset 2>/dev/null |
        awk '
            # 匹配 table (允许行首包含缩进)
            /^[ \t]*table (ip|ip6|inet) / {
                family=$2
                table=$3
                gsub(/[{}]/, "", table)
                chain=""
                next
            }

            # 匹配 chain (允许行首包含缩进)
            /^[ \t]*chain / {
                sub(/^[ \t]*chain[ \t]+/, "")
                chain=$1
                gsub(/[{}]/, "", chain)
                next
            }

            # 匹配包含 tcp/udp dport 和 handle 的规则 (不限制 dport 的位置)
            /^[ \t]*(.*[ \t])?(tcp|udp)[ \t]+dport[ \t]+/ {
                type=""
                port=""
                handle=""

                for (i=1; i<=NF; i++) {
                    if ($i == "tcp" || $i == "udp") {
                        if ($(i+1) == "dport") {
                            type=$i
                            port=$(i+2)
                        }
                    }
                    if ($i == "handle") {
                        handle=$(i+1)
                    }
                }

                gsub(/[{},;]/, "", port)

                if (type != "" && port ~ /^[0-9]+$/ && handle ~ /^[0-9]+$/)
                    print family, table, chain, type, port, handle
            }
        '
    )
    if [[ "$cleaned" -eq 0 ]]; then
        green "没有发现需要清理的未运行端口规则。"
    fi
    save_nft_rules
    green "未运行端口规则清理完成！"
    sleep 1 && iptables_ssl
	;;
        10)
    clear
    current_port=$(grep -RniE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -n 1)
    [ -z "$current_port" ] && current_port=$(grep -E '^#\s*Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    [ -z "$current_port" ] && current_port=22
    ipt_msg "\033[0;36m" "当前的 SSH 端口号是: $current_port"
    skyblue "---------------------------"
    read -p $'\033[1;35m请输入新的 SSH 端口号 (1-65535): \033[0m' new_port
    if [ -z "$new_port" ]; then
        yellow "未输入端口号，操作取消"
        sleep 1 && iptables_ssl
    elif ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
        red "错误：请输入 1-65535 之间的有效端口号！"
        sleep 1 && iptables_ssl
    elif [ "$new_port" -eq "$current_port" ]; then
        yellow "新端口与当前端口相同，无需修改。"
        sleep 1 && iptables_ssl
    else
        cp -f /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        sed -i '/^\s*#\?\s*Port\s\+[0-9]\+/d' /etc/ssh/sshd_config
        if [ -d /etc/ssh/sshd_config.d ]; then
            find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i '/^\s*Port\s\+/d' {} +
        fi
        echo "Port $new_port" >> /etc/ssh/sshd_config
        if command -v getenforce &>/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
            if command -v semanage &>/dev/null; then
                semanage port -a -t ssh_port_t -p tcp "$new_port" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$new_port" 2>/dev/null
            else
                yellow "SELinux 处于开启状态，尝试临时设为 Permissive 模式以确保 SSH 放行..."
                setenforce 0
                sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
            fi
        fi
        if ! sshd -t 2>/dev/null; then
            red "错误：SSH 配置检查失败，正在恢复原配置..."
            cp -f /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            systemctl daemon-reload 2>/dev/null
            systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || systemctl restart ssh 2>/dev/null
            sleep 2
            iptables_ssl
        fi
        yellow "正在放行新端口 $new_port 防火墙规则..."
        if command -v ufw &>/dev/null && ufw status | grep -qw active; then
            ufw allow "$new_port"/tcp >/dev/null 2>&1
        elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --add-port="$new_port"/tcp --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        else
            if command -v nft &>/dev/null; then
                nft insert rule inet filter input tcp dport "$new_port" accept 2>/dev/null
                nft insert rule ip filter input tcp dport "$new_port" accept 2>/dev/null
                nft insert rule ip filter INPUT tcp dport "$new_port" accept 2>/dev/null
                if type save_nft_rules &>/dev/null; then
                    save_nft_rules
                fi
            fi
            
            if command -v iptables &>/dev/null; then
                iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null
            fi
        fi
        if command -v systemctl &>/dev/null; then
            systemctl daemon-reload
            if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
                systemctl stop ssh.socket 2>/dev/null
                systemctl disable ssh.socket 2>/dev/null
            fi
            systemctl enable ssh.service 2>/dev/null
            systemctl restart ssh.service 2>/dev/null || \
            systemctl restart sshd.service 2>/dev/null || \
            systemctl restart ssh 2>/dev/null || {
                red "SSH 服务重启失败！已尝试恢复原端口。"
                cp -f /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
                sleep 2
                iptables_ssl
            }
        else
            service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
        fi
        sleep 1
        if ss -tln 2>/dev/null | grep -qE "[:.]$new_port[[:space:]]"; then
            green "成功：SSH 当前正在监听端口 $new_port"
        else
            red "错误：SSH 未监听端口 $new_port"
            yellow "当前 SSH 监听情况："
            ss -tlnp 2>/dev/null | grep ssh
            yellow "正在尝试回退到旧配置..."
            cp -f /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
        fi       
        sleep 3 && iptables_ssl
    fi
    ;;
	    11) setup_ssh_key_only ;;
		12) fail2ban_manage ;;
        0) menu ;;
        *) iptables_ssl ;;
    esac
}
