#!/bin/bash
# ==========================================
# Tunnel64 多出口策略路由网关系统 (生产加固版)
# 修订：不改动服务器原有 IPv6（不开 IPv6 转发、不往主路由表加隧道路由、
#       地址用 noprefixroute、拒绝与本机原生 IPv6 重叠的前缀）
# ==========================================
export LANG=en_US.UTF-8
re="\033[0m"
purple="\e[1;35m"

CONFIG_DIR="/etc/tunnel64"
T64_RESTORE_BIN="/usr/local/bin/tunnel64-restore"
T64_RESTORE_SERVICE="/etc/systemd/system/tunnel64-restore.service"
LOCK_FILE="/var/lock/tunnel64.lock"
SYSCTL_FILE="/etc/sysctl.d/99-tunnel64-forwarding.conf"

[ "$(id -u)" != "0" ] && echo "[错误] 请使用 root 权限运行此脚本！" && exit 1

umask 077
mkdir -p "$CONFIG_DIR"

# ================= 工具与环境 =================

install_dep() {
    local cmds=("curl" "ip" "awk" "sed" "tr" "wg" "ping" "flock" "modprobe")
    local missing=0
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; break; fi
    done

    if [ "$missing" -eq 1 ]; then
        echo "[INFO] 检测到缺少必要依赖，正在自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y curl iproute2 gawk wireguard-tools iputils-ping util-linux kmod
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl iproute gawk wireguard-tools iputils util-linux kmod
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl iproute gawk wireguard-tools iputils util-linux kmod
        elif command -v apk >/dev/null 2>&1; then
            apk add curl iproute2 gawk wireguard-tools iputils util-linux kmod
        fi
    fi
    modprobe wireguard >/dev/null 2>&1 || true
}

# 只处理 IPv4：开 IPv4 转发、关 IPv4 rp_filter（WG IPv4 多出口需要）。
# IPv6 一律不动：开 IPv6 转发会让内核停止接收 RA，靠 SLAAC 的原生 IPv6 会掉线。
enable_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
    mkdir -p /etc/sysctl.d
    # 覆盖旧版本写入的文件（旧版含 IPv6 forwarding，这里去掉，但不改当前运行值）
    cat > "$SYSCTL_FILE" <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
    chmod 644 "$SYSCTL_FILE"
}

load_tunnel_conf() {
    local conf="$1" k
    [ -f "$conf" ] || return 1
    for k in TYPE IFACE LOCAL_V4 REMOTE_V4 SERVER_IPV6 TUNNEL_IPV6 WG_IPV4 WG_IPV6 WG_ENDPOINT \
             WG_ALLOWEDIPS WG_DNS ROUTED_PREFIX TABLE RULE_PREF RULE_PREF_PREFIX RULE_PREF_V4 MTU; do
        printf -v "$k" '%s' "$(awk -F'"' -v k="$k" '$0 ~ "^"k"=" {print $2; exit}' "$conf")"
    done
    [ -z "$TYPE" ] && TYPE="sit"
    [ -z "$RULE_PREF_PREFIX" ] && RULE_PREF_PREFIX="$RULE_PREF"
    return 0
}

sanitize() { echo "$1" | tr -d '"'\''\\;`$<>|&(){}' | tr -d '[:space:]'; }
sanitize_list() { echo "$1" | tr -d '"'\''\\;`$<>|&(){}'; }

is_valid_iface() { [[ "$1" =~ ^[a-zA-Z0-9_]{3,15}$ ]]; }

# ---------- IPv6 计算（纯 bash） ----------

# 展开为 8 段 16 进制数（空格分隔，十进制数值）；非法返回 1
expand6() {
    local a="${1%%/*}" left right i n
    [[ "$a" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    local -a L=() R=() G=()
    if [[ "$a" == *::* ]]; then
        left="${a%%::*}"; right="${a#*::}"
        [[ "$right" == *::* ]] && return 1
        [ -n "$left" ] && IFS=':' read -ra L <<< "$left"
        [ -n "$right" ] && IFS=':' read -ra R <<< "$right"
        n=$(( 8 - ${#L[@]} - ${#R[@]} ))
        [ "$n" -lt 1 ] && return 1
        G=("${L[@]}"); for ((i=0; i<n; i++)); do G+=(0); done; G+=("${R[@]}")
    else
        IFS=':' read -ra G <<< "$a"
    fi
    [ "${#G[@]}" -eq 8 ] || return 1
    local out=""
    for i in "${G[@]}"; do
        [[ "$i" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        out+="$((16#$i)) "
    done
    echo "$out"
}

valid_ipv6_cidr() {   # 例如 2001:db8::1/64 或不带长度
    local c="${1#*/}"
    expand6 "$1" >/dev/null || return 1
    if [[ "$1" == */* ]]; then [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le 128 ] || return 1; fi
    return 0
}

group_mask() {   # 第 i 段在前缀长度 cidr 下的掩码
    local b=$(( $2 - 16 * $1 ))
    [ "$b" -le 0 ] && { echo 0; return; }
    [ "$b" -ge 16 ] && { echo 65535; return; }
    echo $(( (0xffff << (16 - b)) & 0xffff ))
}

# 地址 $1 是否在前缀 $2 内
in_prefix6() {
    local -a A P
    A=($(expand6 "$1")) || return 1
    P=($(expand6 "$2")) || return 1
    local cidr="${2#*/}" i m
    [[ "$2" == */* ]] || cidr=128
    for ((i=0; i<8; i++)); do
        m=$(group_mask "$i" "$cidr")
        [ $(( A[i] & m )) -eq $(( P[i] & m )) ] || return 1
    done
    return 0
}

# 两个前缀是否重叠（任一包含另一）
overlap6() { in_prefix6 "${1%%/*}" "$2" || in_prefix6 "${2%%/*}" "$1"; }

# 在前缀内随机生成一个地址（支持任意前缀长度，如 /48 /56 /60 /64）
generate_ipv6() {
    local prefix="$1" cidr="${1#*/}"
    [[ "$prefix" == */* ]] || cidr=64
    local -a P
    P=($(expand6 "$prefix")) || return 1
    local hex i m r g out="" allzero=1
    hex=$(tr -d '-' < /proc/sys/kernel/random/uuid)$(tr -d '-' < /proc/sys/kernel/random/uuid)
    for ((i=0; i<8; i++)); do
        m=$(group_mask "$i" "$cidr")
        r=$((16#${hex:$((i*4)):4}))
        g=$(( (P[i] & m) | (r & ~m & 0xffff) ))
        [ $(( r & ~m & 0xffff )) -ne 0 ] && allzero=0
        out+="$(printf '%x' "$g")"
        [ "$i" -lt 7 ] && out+=":"
    done
    [ "$allzero" -eq 1 ] && return 1   # 避开子网路由器任播地址
    echo "$out"
}

# 本机原生（非 Tunnel64 管理）全局 IPv6 地址
native_ipv6_list() {
    local mine=" lo " f
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        mine+="$(awk -F'"' '/^IFACE=/{print $2; exit}' "$f") "
    done
    ip -6 -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | while read -r dev addr; do
        [[ "$mine" == *" $dev "* ]] && continue
        echo "$addr"
    done
}

# 检查要用的地址/前缀与原生 IPv6 是否冲突；冲突返回 1
check_no_native_conflict() {
    local item="$1" a
    [ -z "$item" ] && return 0
    while IFS= read -r a; do
        [ -z "$a" ] && continue
        if overlap6 "$item" "$a"; then
            echo "[错误] $item 与本机原有 IPv6 $a 重叠，为避免影响原有 IPv6 已拒绝。"
            return 1
        fi
    done < <(native_ipv6_list)
    return 0
}

get_new_table_pref() {
    local max_table=200 min_pref=32765 f v
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        v=$(awk -F'"' '/^TABLE=/{print $2; exit}' "$f")
        [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt "$max_table" ] && max_table="$v"
        for v in $(awk -F'"' '/^RULE_PREF(_PREFIX|_V4)?=/{print $2}' "$f"); do
            [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -lt "$min_pref" ] && min_pref="$v"
        done
    done
    NEW_TABLE=$((max_table + 1))
    NEW_PREF=$((min_pref - 1))
    NEW_PREF_PREFIX=$((min_pref - 2))
    NEW_PREF_V4=$((min_pref - 3))
}

# ================= 核心网络逻辑 =================

# 只删本隧道自己的规则（按 pref / 来源 / 表），不碰其他规则
clear_tunnel_rules() {
    [ -n "$RULE_PREF" ] && while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
    [ -n "$RULE_PREF_PREFIX" ] && while ip -6 rule del pref "$RULE_PREF_PREFIX" 2>/dev/null; do :; done
    [ -n "$RULE_PREF_V4" ] && while ip -4 rule del pref "$RULE_PREF_V4" 2>/dev/null; do :; done
    [ -n "$WG_IPV6" ] && while ip -6 rule del from "${WG_IPV6%%/*}" 2>/dev/null; do :; done
    [ -n "$TUNNEL_IPV6" ] && while ip -6 rule del from "${TUNNEL_IPV6%%/*}" 2>/dev/null; do :; done
    [ -n "$WG_IPV4" ] && while ip -4 rule del from "${WG_IPV4%%/*}" 2>/dev/null; do :; done
    [ -n "$ROUTED_PREFIX" ] && while ip -6 rule del from "$ROUTED_PREFIX" 2>/dev/null; do :; done
    if [ -n "$TABLE" ]; then
        while ip -6 rule del table "$TABLE" 2>/dev/null; do :; done
        while ip -4 rule del table "$TABLE" 2>/dev/null; do :; done
        ip -6 route flush table "$TABLE" 2>/dev/null || true
        ip -4 route flush table "$TABLE" 2>/dev/null || true
    fi
    return 0
}

cleanup_tunnel_runtime() {
    local iface="$1" type="$2"
    ip link set "$iface" down 2>/dev/null || true
    if [ "$type" = "wg" ]; then
        ip link del "$iface" 2>/dev/null || true
    else
        ip tunnel del "$iface" 2>/dev/null || true
    fi
}

# 失败时把本隧道留下的接口和规则全部清掉
setup_fail() {
    clear_tunnel_rules
    cleanup_tunnel_runtime "$IFACE" "$TYPE"
    return 1
}

# 说明：所有隧道路由只进自定义表 $TABLE；地址加 noprefixroute，主路由表不出现隧道路由，
# 原有 IPv6 的默认路由、地址、RA 都不受影响。
setup_tunnel_runtime() {
    enable_forwarding
    modprobe wireguard >/dev/null 2>&1 || true

    # 防误删：接口存在但不属于 Tunnel64，拒绝
    if ip link show "$IFACE" >/dev/null 2>&1 && [ ! -f "$CONFIG_DIR/$IFACE.conf" ]; then
        echo "[错误] 系统已存在网卡接口 $IFACE 且不属于 Tunnel64 管理，阻止删除！"
        return 1
    fi

    clear_tunnel_rules
    ip link del "$IFACE" 2>/dev/null || true
    ip tunnel del "$IFACE" 2>/dev/null || true

    if [ "$TYPE" = "wg" ]; then
        ip link add dev "$IFACE" type wireguard || return 1
        wg setconf "$IFACE" "$CONFIG_DIR/$IFACE.wg" || { setup_fail; return 1; }
        ip link set mtu "${MTU:-1420}" dev "$IFACE" || { setup_fail; return 1; }
        ip link set up dev "$IFACE" || { setup_fail; return 1; }

        if [ -n "$WG_IPV6" ]; then
            ip -6 addr replace "$WG_IPV6" dev "$IFACE" noprefixroute || { setup_fail; return 1; }
            ip -6 route replace default dev "$IFACE" table "$TABLE" || { setup_fail; return 1; }
            ip -6 rule add pref "$RULE_PREF" from "${WG_IPV6%%/*}" lookup "$TABLE" || { setup_fail; return 1; }
        elif [ -n "$ROUTED_PREFIX" ]; then
            ip -6 route replace default dev "$IFACE" table "$TABLE" || { setup_fail; return 1; }
        fi

        if [ -n "$WG_IPV4" ]; then
            ip -4 addr replace "$WG_IPV4" dev "$IFACE" noprefixroute || { setup_fail; return 1; }
            ip -4 route replace default dev "$IFACE" table "$TABLE" || { setup_fail; return 1; }
            if [ -n "$RULE_PREF_V4" ]; then
                ip -4 rule add pref "$RULE_PREF_V4" from "${WG_IPV4%%/*}" lookup "$TABLE" || { setup_fail; return 1; }
            fi
        fi
    else
        ip tunnel add "$IFACE" mode sit remote "$REMOTE_V4" local "$LOCAL_V4" ttl 255 || return 1
        ip link set "$IFACE" up mtu "${MTU:-1400}" || { setup_fail; return 1; }
        ip -6 addr replace "$TUNNEL_IPV6" dev "$IFACE" noprefixroute || { setup_fail; return 1; }
        ip -6 route replace default dev "$IFACE" table "$TABLE" || { setup_fail; return 1; }
        ip -6 rule add pref "$RULE_PREF" from "${TUNNEL_IPV6%%/*}" lookup "$TABLE" || { setup_fail; return 1; }
    fi

    if [ -n "$ROUTED_PREFIX" ]; then
        ip -6 rule add pref "$RULE_PREF_PREFIX" from "$ROUTED_PREFIX" lookup "$TABLE" || { setup_fail; return 1; }
    fi
    return 0
}

restore_extra_ips() {
    local list="$CONFIG_DIR/$IFACE-ips.list" a
    [ -f "$list" ] || return 0
    while IFS= read -r a; do
        [ -n "$a" ] && ip -6 addr replace "$a/128" dev lo 2>/dev/null
    done < "$list"
    return 0
}

# 开机恢复（由 restore 脚本调用）
restore_all() {
    [ -d "$CONFIG_DIR" ] || return 0
    local retry=0 conf ok try fail=0
    # 等到真的有默认路由（最多 60 秒）
    while [ $retry -lt 60 ]; do
        [ -n "$(ip -4 route show default 2>/dev/null)$(ip -6 route show default 2>/dev/null)" ] && break
        sleep 1; retry=$((retry + 1))
    done
    modprobe wireguard >/dev/null 2>&1 || true

    for conf in "$CONFIG_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        load_tunnel_conf "$conf" || continue
        [ -n "$IFACE" ] || continue
        [ "$TYPE" = "wg" ] && [ ! -r "$CONFIG_DIR/$IFACE.wg" ] && continue
        ok=0
        # Endpoint 是域名时开机 DNS 可能还没好，重试几次
        for try in 1 2 3 4 5 6; do
            if setup_tunnel_runtime >/dev/null 2>&1; then ok=1; break; fi
            sleep 5
        done
        if [ "$ok" -eq 1 ]; then
            restore_extra_ips
            echo "tunnel64: $IFACE 已恢复"
        else
            echo "tunnel64: $IFACE 恢复失败" >&2
            fail=1
        fi
    done
    return $fail
}

# ================= 自启与持久化 =================

update_systemd_restore() {
    {
        echo '#!/bin/bash'
        echo '# 由 Tunnel64 自动生成，请勿手改'
        printf 'CONFIG_DIR=%q\nSYSCTL_FILE=%q\n' "$CONFIG_DIR" "$SYSCTL_FILE"
        declare -f enable_forwarding load_tunnel_conf clear_tunnel_rules cleanup_tunnel_runtime \
                   setup_fail setup_tunnel_runtime restore_extra_ips restore_all
        echo 'restore_all'
        echo 'exit 0'
    } > "$T64_RESTORE_BIN"
    chmod 700 "$T64_RESTORE_BIN"

    if pidof systemd >/dev/null 2>&1 || [ -d "/run/systemd/system" ]; then
        cat > "$T64_RESTORE_SERVICE" <<EOF
[Unit]
Description=Tunnel64 Multi-Tunnel Restore
After=network-online.target network.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$T64_RESTORE_BIN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$T64_RESTORE_SERVICE"
        systemctl daemon-reload
        systemctl enable tunnel64-restore.service >/dev/null 2>&1
    elif [ -d /etc/local.d ]; then
        # Alpine / OpenRC
        printf '#!/bin/sh\n%s >/dev/null 2>&1 &\n' "$T64_RESTORE_BIN" > /etc/local.d/tunnel64.start
        chmod 755 /etc/local.d/tunnel64.start
        command -v rc-update >/dev/null 2>&1 && rc-update add local default >/dev/null 2>&1
    fi
}

remove_systemd_restore_if_empty() {
    if [ -z "$(ls -A "$CONFIG_DIR"/*.conf 2>/dev/null)" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable tunnel64-restore.service >/dev/null 2>&1 || true
        fi
        rm -f "$T64_RESTORE_SERVICE" "$T64_RESTORE_BIN" /etc/local.d/tunnel64.start
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    fi
}

# ================= 业务功能 =================

add_sit_tunnel() {
    echo "========== 添加 SIT 隧道 =========="
    local IFACE LOCAL_V4 REMOTE_V4 SERVER_IPV6 TUNNEL_IPV6 ROUTED_PREFIX TYPE MTU TABLE RULE_PREF RULE_PREF_PREFIX
    local WG_IPV4="" WG_IPV6="" RULE_PREF_V4=""
    read -p "请输入隧道名称 (直接回车随机): " IFACE
    [ -z "$IFACE" ] && IFACE="sit$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    if ! is_valid_iface "$IFACE"; then echo "[错误] 接口名不合法"; return 1; fi
    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then echo "[错误] 接口配置已存在"; return 1; fi

    echo
    read -p "请输入服务端 IPv4 地址: " REMOTE_V4
    local default_local_v4
    default_local_v4=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [ -z "$default_local_v4" ] && default_local_v4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    read -p "请输入客户端 IPv4 地址 (本机) [$default_local_v4]: " LOCAL_V4
    [ -z "$LOCAL_V4" ] && LOCAL_V4="$default_local_v4"

    echo
    read -p "请输入服务端 IPv6 地址: " SERVER_IPV6
    read -p "请输入客户端 IPv6 地址 (如 2001:470:1f0a::2/64): " TUNNEL_IPV6
    read -p "请输入 IPv6 路由前缀 (可选，如 2001:470:abcd::/48 或 /64): " ROUTED_PREFIX

    LOCAL_V4=$(sanitize "$LOCAL_V4"); REMOTE_V4=$(sanitize "$REMOTE_V4")
    SERVER_IPV6=$(sanitize "$SERVER_IPV6"); TUNNEL_IPV6=$(sanitize "$TUNNEL_IPV6"); ROUTED_PREFIX=$(sanitize "$ROUTED_PREFIX")

    if [ -z "$LOCAL_V4" ] || [ -z "$REMOTE_V4" ] || [ -z "$TUNNEL_IPV6" ]; then
        echo "[错误] 核心 IP 参数不能为空"; return 1
    fi
    [[ "$TUNNEL_IPV6" == */* ]] || TUNNEL_IPV6="$TUNNEL_IPV6/64"
    valid_ipv6_cidr "$TUNNEL_IPV6" || { echo "[错误] 客户端 IPv6 格式错误"; return 1; }
    if [ -n "$ROUTED_PREFIX" ]; then
        [[ "$ROUTED_PREFIX" == */* ]] || ROUTED_PREFIX="$ROUTED_PREFIX/64"
        valid_ipv6_cidr "$ROUTED_PREFIX" || { echo "[错误] 路由前缀格式错误"; return 1; }
    fi
    check_no_native_conflict "$TUNNEL_IPV6" || return 1
    check_no_native_conflict "$ROUTED_PREFIX" || return 1

    exec 9> "$LOCK_FILE"; flock -x 9
    get_new_table_pref
    TABLE="$NEW_TABLE"; RULE_PREF="$NEW_PREF"; RULE_PREF_PREFIX="$NEW_PREF_PREFIX"
    TYPE="sit"; MTU="1400"
    if ! setup_tunnel_runtime; then
        flock -u 9; echo "[错误] 隧道配置下发失败！"; return 1
    fi
    cat > "$CONFIG_DIR/$IFACE.conf" <<EOF
TYPE="sit"
IFACE="$IFACE"
LOCAL_V4="$LOCAL_V4"
REMOTE_V4="$REMOTE_V4"
SERVER_IPV6="$SERVER_IPV6"
TUNNEL_IPV6="$TUNNEL_IPV6"
ROUTED_PREFIX="$ROUTED_PREFIX"
MTU="$MTU"
TABLE="$TABLE"
RULE_PREF="$RULE_PREF"
RULE_PREF_PREFIX="$RULE_PREF_PREFIX"
EOF
    flock -u 9

    update_systemd_restore
    echo "✓ 隧道 $IFACE 添加成功并生效！"

    local server_gw="${SERVER_IPV6%%/*}"
    if [ -n "$server_gw" ]; then
        echo "=========================================="
        echo "正在测试与上游网关 ($server_gw) 的连通性 (Ping 5次)..."
        ping -6 -c 5 -I "${TUNNEL_IPV6%%/*}" "$server_gw"
        echo "=========================================="
    fi
}

add_wg_tunnel() {
    echo "========== 添加 WireGuard 隧道 =========="
    local IFACE ROUTED_PREFIX TYPE MTU TABLE RULE_PREF RULE_PREF_PREFIX RULE_PREF_V4
    local TUNNEL_IPV6="" LOCAL_V4="" REMOTE_V4="" SERVER_IPV6=""
    read -p "请输入隧道名称 (直接回车随机): " IFACE
    [ -z "$IFACE" ] && IFACE="wg$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    if ! is_valid_iface "$IFACE"; then echo "[错误] 接口名不合法"; return 1; fi
    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then echo "[错误] 接口配置已存在"; return 1; fi

    echo -e "请粘贴 WireGuard 客户端配置内容 (连续按两次回车确认):"
    local tmp_conf line empty_count=0
    tmp_conf=$(mktemp)
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [ -z "$line" ]; then
            empty_count=$((empty_count + 1))
            [ "$empty_count" -ge 2 ] && break
        else
            empty_count=0
        fi
        echo "$line" >> "$tmp_conf"
    done

    getv() { awk -v k="$1" -F'=' 'tolower($1) ~ "^[[:space:]]*"k"[[:space:]]*$" {sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print}' "$tmp_conf"; }
    local WG_PRIVKEY WG_PUBKEY WG_ENDPOINT WG_MTU WG_ADDRESS WG_ALLOWEDIPS WG_DNS WG_IPV4 WG_IPV6
    WG_PRIVKEY=$(getv privatekey | head -n1)
    WG_PUBKEY=$(getv publickey | head -n1)
    WG_ENDPOINT=$(getv endpoint | head -n1)
    WG_MTU=$(getv mtu | head -n1)
    WG_ADDRESS=$(getv address | tr '\n' ',' | sed 's/,$//')
    WG_ALLOWEDIPS=$(getv allowedips | tr '\n' ',' | sed 's/,$//')
    WG_DNS=$(getv dns | tr '\n' ',' | sed 's/,$//')

    # 只保留 wg setconf 认识的字段（支持多个 [Peer]；去掉 Address/DNS/MTU 等 wg-quick 字段）
    local wg_body
    wg_body=$(awk -F'=' '
        /^[[:space:]]*\[/ { print; next }
        { k=tolower($1); gsub(/[[:space:]]/, "", k) }
        k=="privatekey"||k=="listenport"||k=="fwmark"||k=="publickey"||k=="presharedkey"||k=="allowedips"||k=="endpoint"||k=="persistentkeepalive" { print }
    ' "$tmp_conf")
    rm -f "$tmp_conf"

    if [ -n "$WG_PRIVKEY" ] && ! echo "$WG_PRIVKEY" | wg pubkey >/dev/null 2>&1; then
        echo "[错误] 解析到的 WireGuard PrivateKey 格式无效！"; return 1
    fi

    WG_IPV4=$(echo "$WG_ADDRESS" | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i~/\./ && $i!~/:/){print $i; exit}}}')
    WG_IPV6=$(echo "$WG_ADDRESS" | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i~/:/){print $i; exit}}}')
    WG_IPV4=$(sanitize "$WG_IPV4"); WG_IPV6=$(sanitize "$WG_IPV6")

    if [ -z "$WG_PRIVKEY" ] || { [ -z "$WG_IPV4" ] && [ -z "$WG_IPV6" ]; } || [ -z "$WG_PUBKEY" ] || [ -z "$WG_ENDPOINT" ]; then
        echo "[错误] 无法解析配置，核心参数 (PrivateKey/Address/PublicKey/Endpoint) 缺失。"; return 1
    fi
    if [ -n "$WG_IPV6" ]; then
        [[ "$WG_IPV6" == */* ]] || WG_IPV6="$WG_IPV6/128"
        valid_ipv6_cidr "$WG_IPV6" || { echo "[错误] WG IPv6 地址格式错误"; return 1; }
        check_no_native_conflict "$WG_IPV6" || return 1
    fi
    [ -n "$WG_IPV4" ] && [[ "$WG_IPV4" != */* ]] && WG_IPV4="$WG_IPV4/32"

    echo
    read -p "请输入该隧道附带的 IPv6 路由前缀 (可选): " ROUTED_PREFIX
    ROUTED_PREFIX=$(sanitize "$ROUTED_PREFIX")
    if [ -n "$ROUTED_PREFIX" ]; then
        [[ "$ROUTED_PREFIX" == */* ]] || ROUTED_PREFIX="$ROUTED_PREFIX/64"
        valid_ipv6_cidr "$ROUTED_PREFIX" || { echo "[错误] 路由前缀格式错误"; return 1; }
        check_no_native_conflict "$ROUTED_PREFIX" || return 1
    fi

    TYPE="wg"
    MTU="${WG_MTU:-1420}"; [[ "$MTU" =~ ^[0-9]+$ ]] || MTU=1420
    [ -z "$WG_ALLOWEDIPS" ] && WG_ALLOWEDIPS="0.0.0.0/0, ::/0"
    WG_ALLOWEDIPS=$(sanitize_list "$WG_ALLOWEDIPS"); WG_DNS=$(sanitize_list "$WG_DNS")

    exec 9> "$LOCK_FILE"; flock -x 9
    get_new_table_pref
    TABLE="$NEW_TABLE"; RULE_PREF="$NEW_PREF"; RULE_PREF_PREFIX="$NEW_PREF_PREFIX"; RULE_PREF_V4="$NEW_PREF_V4"

    printf '%s\n' "$wg_body" > "$CONFIG_DIR/$IFACE.wg"
    chmod 600 "$CONFIG_DIR/$IFACE.wg"

    if ! setup_tunnel_runtime; then
        rm -f "$CONFIG_DIR/$IFACE.wg"; flock -u 9
        echo "[错误] WireGuard 隧道配置下发失败"; return 1
    fi

    cat > "$CONFIG_DIR/$IFACE.conf" <<EOF
TYPE="wg"
IFACE="$IFACE"
WG_IPV4="$WG_IPV4"
WG_IPV6="$WG_IPV6"
WG_ENDPOINT="$(sanitize "$WG_ENDPOINT")"
WG_ALLOWEDIPS="$WG_ALLOWEDIPS"
WG_DNS="$WG_DNS"
ROUTED_PREFIX="$ROUTED_PREFIX"
MTU="$MTU"
TABLE="$TABLE"
RULE_PREF="$RULE_PREF"
RULE_PREF_PREFIX="$RULE_PREF_PREFIX"
RULE_PREF_V4="$RULE_PREF_V4"
EOF
    chmod 600 "$CONFIG_DIR/$IFACE.conf"
    flock -u 9

    update_systemd_restore
    echo "✓ WG 隧道 $IFACE 添加成功并生效！"
}

delete_tunnel() {
    local conf="$1" list_file="$2" OK a
    load_tunnel_conf "$conf"

    echo "========== 删除隧道: $IFACE =========="
    read -p "确认删除该隧道及其所有附加 IP 吗? [y/N]: " OK
    [[ "$OK" != "y" && "$OK" != "Y" ]] && return

    if [ -f "$list_file" ]; then
        while IFS= read -r a; do
            [ -n "$a" ] && ip -6 addr del "$a/128" dev lo 2>/dev/null
        done < "$list_file"
    fi

    clear_tunnel_rules
    cleanup_tunnel_runtime "$IFACE" "$TYPE"
    rm -f "$conf" "$list_file" "$CONFIG_DIR/$IFACE.wg"
    remove_systemd_restore_if_empty

    echo "✓ 隧道 $IFACE 已彻底删除"
    read -p "按回车键返回..."
}

add_ipv6() {
    local config_file="$1" list_file="$2"
    load_tunnel_conf "$config_file"

    if [ -z "$ROUTED_PREFIX" ]; then
        echo "错误: 该隧道未配置路由前缀，无法生成附加 IPv6。"
        read -p "按回车键继续..."; return
    fi
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        echo "错误: 接口不存在"
        read -p "按回车键继续..."; return
    fi

    local RETRY=0 MAX_RETRY=10 NEW_IPV6=""
    while [ "$RETRY" -lt "$MAX_RETRY" ]; do
        NEW_IPV6=$(generate_ipv6 "$ROUTED_PREFIX")
        if [ -z "$NEW_IPV6" ] || grep -qsxF "$NEW_IPV6" "$list_file" || \
           ip -6 addr show | grep -qsF " $NEW_IPV6/"; then
            RETRY=$((RETRY + 1))
        else
            break
        fi
    done
    if [ "$RETRY" -ge "$MAX_RETRY" ]; then
        echo "错误: 未能生成唯一 IPv6"; read -p "按回车键继续..."; return
    fi

    if ! ip -6 addr add "$NEW_IPV6/128" dev lo 2>/dev/null; then
        echo "错误: IPv6 绑定到 lo 失败"; read -p "按回车键继续..."; return
    fi

    echo "$NEW_IPV6" >> "$list_file"
    echo "✓ 附加 IPv6 添加成功: $NEW_IPV6"

    if ip -6 route get 2606:4700:4700::1111 from "$NEW_IPV6" 2>/dev/null | grep -qs "dev $IFACE"; then
        echo "✓ 路由校验通过: 成功匹配策略路由表 $TABLE"
    else
        echo "⚠️ 警告: 策略路由匹配异常，该 IP 流量可能未走隧道"
    fi
    read -p "按回车键继续..."
}

delete_ipv6() {
    local config_file="$1" list_file="$2" a i=1 NUM DEL_IP
    load_tunnel_conf "$config_file"

    if [ ! -s "$list_file" ]; then
        echo "没有可删除的附加 IPv6"; read -p "按回车键继续..."; return
    fi
    sed -i '/^[[:space:]]*$/d' "$list_file"   # 去掉空行，保证编号与行号一致

    echo "========== 附加 IPv6 列表 ($IFACE) =========="
    while IFS= read -r a; do
        echo -e "${purple}$i. $a${re}"
        i=$((i + 1))
    done < "$list_file"
    echo "============================================="

    read -p "输入要删除的编号: " NUM
    if ! [[ "$NUM" =~ ^[1-9][0-9]*$ ]]; then
        echo "错误: 输入无效"; read -p "按回车键继续..."; return
    fi
    DEL_IP=$(sed -n "${NUM}p" "$list_file")
    if [ -z "$DEL_IP" ]; then
        echo "错误: 编号不存在"; read -p "按回车键继续..."; return
    fi

    ip -6 addr del "$DEL_IP/128" dev lo 2>/dev/null || true
    sed -i "${NUM}d" "$list_file"
    echo "✓ IPv6 已删除: $DEL_IP"
    read -p "按回车键继续..."
}

status_tunnel() {
    local config_file="$1" list_file="$2" a v
    load_tunnel_conf "$config_file"

    clear
    echo "========== 隧道状态: $IFACE =========="
    echo "类型          : ${TYPE^^}"
    ip link show "$IFACE" >/dev/null 2>&1 || echo "⚠️ 隧道设备未启动"
    if [ "$TYPE" = "wg" ]; then
        [ -n "$WG_IPV4" ] && echo "Client IPv4   : $WG_IPV4"
        [ -n "$WG_IPV6" ] && echo "Client IPv6   : $WG_IPV6"
        echo "Endpoint      : ${WG_ENDPOINT:-未配置}"
        [ -n "$WG_DNS" ] && echo "DNS           : $WG_DNS"
        v=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
        if [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null; then
            echo "最近握手      : $(( $(date +%s) - v )) 秒前"
        else
            echo "最近握手      : 无"
        fi
    else
        v=$(ip -6 addr show dev "$IFACE" 2>/dev/null | awk '/scope global/{print $2}' | paste -sd ' ' -)
        echo "Client IPv6   : ${v:-无}"
        echo "Server IPv6   : ${SERVER_IPV6:-未配置}"
    fi
    echo "Routed Prefix : ${ROUTED_PREFIX:-未配置}"
    v=$(ip -6 route show table "$TABLE" 2>/dev/null | paste -sd ';' -)
    echo "策略路由表 $TABLE (v6): ${v:-无}"
    if [ "$TYPE" = "wg" ] && [ -n "$WG_IPV4" ]; then
        v=$(ip -4 route show table "$TABLE" 2>/dev/null | paste -sd ';' -)
        echo "策略路由表 $TABLE (v4): ${v:-无}"
    fi

    echo
    echo "========== lo 附加 IPv6 =========="
    if [ -s "$list_file" ]; then
        while IFS= read -r a; do
            [ -z "$a" ] && continue
            ip -6 addr show dev lo | grep -qsF " $a/" && echo "✓ $a" || echo "✗ $a (未绑定)"
        done < "$list_file"
    else
        echo "无附加记录"
    fi
    echo
    read -p "按回车键返回..."
}

test_ipv6() {
    local list_file="$1" TEST_IP RESULT rc total=0 success=0 failed=0
    if [ ! -s "$list_file" ]; then
        echo "未找到附加 IPv6 列表"; read -p "按回车键继续..."; return
    fi

    echo "========== IPv6 出口测试 =========="
    while IFS= read -r TEST_IP; do
        [ -z "$TEST_IP" ] && continue
        total=$((total + 1))
        RESULT=$(curl -6 --interface "$TEST_IP" --connect-timeout 5 --max-time 8 -sS https://ip.sb 2>/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$RESULT" ]; then
            success=$((success + 1))
            echo "✓ [$TEST_IP] 成功 -> 出口: $RESULT"
        else
            failed=$((failed + 1))
            echo "✗ [$TEST_IP] 失败 (curl 返回 $rc)"
        fi
    done < "$list_file"

    echo "测试完成: 总计 $total | 成功 $success | 失败 $failed"
    read -p "按回车键继续..."
}

test_route() {
    local config_file="$1" TEST_IP
    load_tunnel_conf "$config_file"
    read -p "请输入测试用的源 IP 地址 (IPv4 或 IPv6): " TEST_IP
    TEST_IP=$(sanitize "$TEST_IP")
    [ -z "$TEST_IP" ] && return

    if [[ "$TEST_IP" =~ : ]]; then
        echo "========== route get (检查 IPv6 策略) =========="
        ip -6 route get 2606:4700:4700::1111 from "$TEST_IP"
        ping -6 -I "$TEST_IP" -c 3 -W 3 2606:4700:4700::1111
    else
        echo "========== route get (检查 IPv4 策略) =========="
        ip -4 route get 1.1.1.1 from "$TEST_IP"
        ping -4 -I "$TEST_IP" -c 3 -W 3 1.1.1.1
    fi
    read -p "按回车键继续..."
}

get_tunnel_file_by_index() {
    local target_idx=$1 i=1 f
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        if [ "$i" -eq "$target_idx" ]; then echo "$f"; return 0; fi
        i=$((i + 1))
    done
    return 1
}

tunnel_submenu() {
    local config_file="$1" list_file SUB_CHOOSE
    while true; do
        [ -f "$config_file" ] || return
        load_tunnel_conf "$config_file"
        list_file="$CONFIG_DIR/$IFACE-ips.list"

        clear
        echo "========== 隧道管理: $IFACE [${TYPE^^}] (表: $TABLE) =========="
        echo "1. 随机添加附加 IPv6 地址"
        echo "2. 删除指定附加 IPv6 地址"
        echo "3. 查看当前隧道与 IP 状态"
        echo "4. 批量测试所有附加 IPv6 的出口"
        echo "5. 测试单 IP 路由与外网连通性"
        echo "6. 删除该隧道"
        echo "0. 返回上级菜单"
        echo "==========================================================="
        read -p "选择 [0-6]: " SUB_CHOOSE
        case "$SUB_CHOOSE" in
            1) add_ipv6 "$config_file" "$list_file" ;;
            2) delete_ipv6 "$config_file" "$list_file" ;;
            3) status_tunnel "$config_file" "$list_file" ;;
            4) test_ipv6 "$list_file" ;;
            5) test_route "$config_file" ;;
            6) delete_tunnel "$config_file" "$list_file"; return ;;
            0) return ;;
            *) echo "输入错误！"; sleep 1 ;;
        esac
    done
}

menu() {
    install_dep
    local i has_tunnel f CHOOSE selected_file
    while true; do
        clear
        echo "========== 通用隧道管理网关 =========="
        echo "0. 退出脚本"
        echo "a. 添加 SIT 隧道"
        echo "b. 添加 WG 隧道"
        echo "----------------------------------------"
        echo "已添加的隧道列表："
        i=1; has_tunnel=0
        for f in "$CONFIG_DIR"/*.conf; do
            [ -f "$f" ] || continue
            has_tunnel=1
            load_tunnel_conf "$f"
            if [ "$TYPE" = "wg" ]; then
                echo -e "   [\033[32m$i\033[0m] [WG]  接口: \033[32m$IFACE\033[0m | 节点: $WG_ENDPOINT | 路由前缀: ${ROUTED_PREFIX:-无}"
            else
                echo -e "   [\033[32m$i\033[0m] [SIT] 接口: \033[32m$IFACE\033[0m | 远端IPv4: $REMOTE_V4 | 路由前缀: ${ROUTED_PREFIX:-无}"
            fi
            i=$((i + 1))
        done
        [ "$has_tunnel" -eq 0 ] && echo "   (暂无隧道，请选择 a 或 b 添加)"

        echo "----------------------------------------"
        read -p "请输入选项 (a/b 添加, 0 退出, 或输入编号进入管理): " CHOOSE
        case "$CHOOSE" in
            0) exit 0 ;;
            a|A) add_sit_tunnel; read -p "按回车键继续..." ;;
            b|B) add_wg_tunnel; read -p "按回车键继续..." ;;
            *)
                if [[ "$CHOOSE" =~ ^[1-9][0-9]*$ ]]; then
                    selected_file=$(get_tunnel_file_by_index "$CHOOSE")
                    if [ -n "$selected_file" ] && [ -f "$selected_file" ]; then
                        tunnel_submenu "$selected_file"
                    else
                        echo "错误: 无效的隧道编号！"; sleep 1
                    fi
                else
                    echo "输入错误！"; sleep 1
                fi
                ;;
        esac
    done
}

case "$1" in
    --restore) restore_all; exit $? ;;
    *) menu ;;
esac
