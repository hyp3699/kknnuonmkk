#!/bin/bash
# ==========================================
# Tunnel64 
# ==========================================

CONFIG_DIR="/etc/tunnel64"
T64_RESTORE_BIN="/usr/local/bin/tunnel64-restore"
T64_RESTORE_SERVICE="/etc/systemd/system/tunnel64-restore.service"
LOCK_FILE="/var/lock/tunnel64.lock"

umask 077
mkdir -p "$CONFIG_DIR"

[ "$(id -u)" != "0" ] && echo "[错误] 请使用 root 权限运行此脚本！" && exit 1

# ================= 工具与环境 =================

install_dep() {
    local cmds=("curl" "ip" "awk" "sed" "tr" "wg" "ping" "flock")
    local missing=0
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; break; fi
    done

    if [ "$missing" -eq 1 ]; then
        echo "[INFO] 检测到缺少必要依赖，正在自动安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y curl iproute2 gawk wireguard-tools iputils-ping util-linux
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl iproute gawk wireguard-tools iputils util-linux
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl iproute gawk wireguard-tools iputils util-linux
        elif command -v apk >/dev/null 2>&1; then
            apk add curl iproute2 gawk wireguard-tools iputils util-linux
        fi
    fi
}

# 自动开启并持久化内核转发
enable_forwarding() {
    local sysctl_file="/etc/sysctl.d/99-tunnel64-forwarding.conf"
    local changed=0

    if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        changed=1
    fi
    if [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" != "1" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1
        changed=1
    fi

    if [ "$changed" -eq 1 ] || [ ! -f "$sysctl_file" ]; then
        mkdir -p /etc/sysctl.d
        cat > "$sysctl_file" <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
        sysctl -p "$sysctl_file" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
    fi
}

load_tunnel_conf() {
    local conf="$1"
    [ -f "$conf" ] || return 1
    TYPE=$(awk -F'"' '/^TYPE=/{print $2}' "$conf")
    IFACE=$(awk -F'"' '/^IFACE=/{print $2}' "$conf")
    LOCAL_V4=$(awk -F'"' '/^LOCAL_V4=/{print $2}' "$conf")
    REMOTE_V4=$(awk -F'"' '/^REMOTE_V4=/{print $2}' "$conf")
    SERVER_IPV6=$(awk -F'"' '/^SERVER_IPV6=/{print $2}' "$conf")
    TUNNEL_IPV6=$(awk -F'"' '/^TUNNEL_IPV6=/{print $2}' "$conf")
    WG_IPV4=$(awk -F'"' '/^WG_IPV4=/{print $2}' "$conf")
    WG_IPV6=$(awk -F'"' '/^WG_IPV6=/{print $2}' "$conf")
    WG_ENDPOINT=$(awk -F'"' '/^WG_ENDPOINT=/{print $2}' "$conf")
    ROUTED_PREFIX=$(awk -F'"' '/^ROUTED_PREFIX=/{print $2}' "$conf")
    TABLE=$(awk -F'"' '/^TABLE=/{print $2}' "$conf")
    RULE_PREF=$(awk -F'"' '/^RULE_PREF=/{print $2}' "$conf")
    RULE_PREF_PREFIX=$(awk -F'"' '/^RULE_PREF_PREFIX=/{print $2}' "$conf")
    RULE_PREF_V4=$(awk -F'"' '/^RULE_PREF_V4=/{print $2}' "$conf")
    MTU=$(awk -F'"' '/^MTU=/{print $2}' "$conf")
    
    # 向后兼容
    [ -z "$RULE_PREF_PREFIX" ] && RULE_PREF_PREFIX="$RULE_PREF"
}

sanitize() { echo "$1" | tr -d '"'\''\\;`$<>|' ; }

is_valid_iface() {
    [[ "$1" =~ ^[a-zA-Z0-9_]{3,15}$ ]] || return 1
}

generate_ipv6() {
    local prefix_str="$1"
    local network="${prefix_str%/*}"
    local cidr="${prefix_str#*/}"
    
    network=$(echo "$network" | sed 's/:*$//')
    local hex=$(tr -d '-' < /proc/sys/kernel/random/uuid)
    
    if [ "$cidr" = "48" ]; then
        printf '%s:%s:%s:%s:%s:%s\n' "$network" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}"
    else
        printf '%s:%s:%s:%s:%s\n' "$network" "${hex:0:4}" "${hex:4:4}" "${hex:8:4}" "${hex:12:4}"
    fi
}

get_new_table_pref() {
    local max_table=200
    local min_pref=32765
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        local t_table=$(awk -F'"' '/^TABLE=/{print $2}' "$f")
        local t_pref=$(awk -F'"' '/^RULE_PREF=/{print $2}' "$f")
        local t_pref_prefix=$(awk -F'"' '/^RULE_PREF_PREFIX=/{print $2}' "$f")
        local t_pref_v4=$(awk -F'"' '/^RULE_PREF_V4=/{print $2}' "$f")
        
        [[ "$t_table" =~ ^[0-9]+$ ]] && [ "$t_table" -gt "$max_table" ] && max_table="$t_table"
        [[ "$t_pref" =~ ^[0-9]+$ ]] && [ "$t_pref" -lt "$min_pref" ] && min_pref="$t_pref"
        [[ "$t_pref_prefix" =~ ^[0-9]+$ ]] && [ "$t_pref_prefix" -lt "$min_pref" ] && min_pref="$t_pref_prefix"
        [[ "$t_pref_v4" =~ ^[0-9]+$ ]] && [ "$t_pref_v4" -lt "$min_pref" ] && min_pref="$t_pref_v4"
    done
    NEW_TABLE=$((max_table + 1))
    NEW_PREF=$((min_pref - 1))
    NEW_PREF_PREFIX=$((min_pref - 2))
    NEW_PREF_V4=$((min_pref - 3))
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

# ================= 核心网络逻辑 =================

setup_tunnel_runtime() {
    enable_forwarding
    
    ip link del "$IFACE" 2>/dev/null || true
    ip tunnel del "$IFACE" 2>/dev/null || true

    if [ "$TYPE" = "wg" ]; then
        ip link add dev "$IFACE" type wireguard || return 1
        wg setconf "$IFACE" "$CONFIG_DIR/$IFACE.wg" || { cleanup_tunnel_runtime "$IFACE" "wg"; return 1; }
        ip link set mtu "${MTU:-1420}" up dev "$IFACE" || { cleanup_tunnel_runtime "$IFACE" "wg"; return 1; }

        if [ -n "$WG_IPV6" ]; then
            ip -6 addr replace "$WG_IPV6" dev "$IFACE" || { cleanup_tunnel_runtime "$IFACE" "wg"; return 1; }
            ip -6 route replace "$WG_IPV6" dev "$IFACE" 2>/dev/null || true
            ip -6 route replace "$WG_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            
            ip -6 route replace default dev "$IFACE" table "$TABLE"
            while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
            local tun_ip6="${WG_IPV6%%/*}"
            ip -6 rule add pref "$RULE_PREF" from "$tun_ip6" lookup "$TABLE" || return 1
            
            if [ -n "$ROUTED_PREFIX" ]; then
                ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true
                ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
                while ip -6 rule del pref "$RULE_PREF_PREFIX" 2>/dev/null; do :; done
                ip -6 rule add pref "$RULE_PREF_PREFIX" from "$ROUTED_PREFIX" lookup "$TABLE"
            fi
        fi

        if [ -n "$WG_IPV4" ]; then
            ip -4 addr replace "$WG_IPV4" dev "$IFACE" || { cleanup_tunnel_runtime "$IFACE" "wg"; return 1; }
            ip -4 route replace "$WG_IPV4" dev "$IFACE" 2>/dev/null || true
            ip -4 route replace "$WG_IPV4" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            
            ip -4 route replace default dev "$IFACE" table "$TABLE"
            while ip -4 rule del pref "$RULE_PREF_V4" 2>/dev/null; do :; done
            local tun_ip4="${WG_IPV4%%/*}"
            ip -4 rule add pref "$RULE_PREF_V4" from "$tun_ip4" lookup "$TABLE" || return 1
        fi
    else
        ip tunnel add "$IFACE" mode sit remote "$REMOTE_V4" local "$LOCAL_V4" ttl 255 || return 1
        ip link set "$IFACE" up mtu "${MTU:-1400}"

        ip -6 addr replace "$TUNNEL_IPV6" dev "$IFACE" || { cleanup_tunnel_runtime "$IFACE" "sit"; return 1; }
        
        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true
        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null || true
        
        ip -6 route replace default dev "$IFACE" table "$TABLE"
        while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
        local tun_ip="${TUNNEL_IPV6%%/*}"
        ip -6 rule add pref "$RULE_PREF" from "$tun_ip" lookup "$TABLE" || return 1

        if [ -n "$ROUTED_PREFIX" ]; then
            ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true
            ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null || true
            while ip -6 rule del pref "$RULE_PREF_PREFIX" 2>/dev/null; do :; done
            ip -6 rule add pref "$RULE_PREF_PREFIX" from "$ROUTED_PREFIX" lookup "$TABLE"
        fi
    fi
    return 0
}

# ================= 自启与持久化 =================

update_systemd_restore() {
    cat > "$T64_RESTORE_BIN" << 'EOF'
#!/bin/bash
CONFIG_DIR="/etc/tunnel64"
[ -d "$CONFIG_DIR" ] || exit 0

load_conf() {
    TYPE=$(awk -F'"' '/^TYPE=/{print $2}' "$1")
    IFACE=$(awk -F'"' '/^IFACE=/{print $2}' "$1")
    LOCAL_V4=$(awk -F'"' '/^LOCAL_V4=/{print $2}' "$1")
    REMOTE_V4=$(awk -F'"' '/^REMOTE_V4=/{print $2}' "$1")
    TUNNEL_IPV6=$(awk -F'"' '/^TUNNEL_IPV6=/{print $2}' "$1")
    WG_IPV4=$(awk -F'"' '/^WG_IPV4=/{print $2}' "$1")
    WG_IPV6=$(awk -F'"' '/^WG_IPV6=/{print $2}' "$1")
    ROUTED_PREFIX=$(awk -F'"' '/^ROUTED_PREFIX=/{print $2}' "$1")
    TABLE=$(awk -F'"' '/^TABLE=/{print $2}' "$1")
    RULE_PREF=$(awk -F'"' '/^RULE_PREF=/{print $2}' "$1")
    RULE_PREF_PREFIX=$(awk -F'"' '/^RULE_PREF_PREFIX=/{print $2}' "$1")
    RULE_PREF_V4=$(awk -F'"' '/^RULE_PREF_V4=/{print $2}' "$1")
    MTU=$(awk -F'"' '/^MTU=/{print $2}' "$1")
    
    [ -z "$RULE_PREF_PREFIX" ] && RULE_PREF_PREFIX="$RULE_PREF"
}

for conf in "$CONFIG_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    TYPE="sit"
    load_conf "$conf"
    [ -n "$IFACE" ] || continue

    if [ "$TYPE" = "wg" ]; then
        [ -r "$CONFIG_DIR/$IFACE.wg" ] || { echo "Missing $IFACE.wg, skip."; continue; }
        ip link del "$IFACE" 2>/dev/null || true
        ip link add dev "$IFACE" type wireguard 2>/dev/null || continue
        wg setconf "$IFACE" "$CONFIG_DIR/$IFACE.wg" 2>/dev/null || continue
        ip link set mtu "${MTU:-1420}" up dev "$IFACE"
        if [ -n "$WG_IPV6" ]; then
            ip -6 addr replace "$WG_IPV6" dev "$IFACE"
            ip -6 route replace "$WG_IPV6" dev "$IFACE" 2>/dev/null
            ip -6 route replace "$WG_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null
            ip -6 route replace default dev "$IFACE" table "$TABLE"
            
            while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
            ip -6 rule add pref "$RULE_PREF" from "${WG_IPV6%%/*}" lookup "$TABLE" 2>/dev/null || true
            
            if [ -n "$ROUTED_PREFIX" ]; then
                ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null
                ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null
                while ip -6 rule del pref "$RULE_PREF_PREFIX" 2>/dev/null; do :; done
                ip -6 rule add pref "$RULE_PREF_PREFIX" from "$ROUTED_PREFIX" lookup "$TABLE" 2>/dev/null || true
            fi
        fi
        if [ -n "$WG_IPV4" ]; then
            ip -4 addr replace "$WG_IPV4" dev "$IFACE"
            ip -4 route replace "$WG_IPV4" dev "$IFACE" 2>/dev/null
            ip -4 route replace "$WG_IPV4" dev "$IFACE" table "$TABLE" 2>/dev/null
            ip -4 route replace default dev "$IFACE" table "$TABLE"
            
            while ip -4 rule del pref "$RULE_PREF_V4" 2>/dev/null; do :; done
            ip -4 rule add pref "$RULE_PREF_V4" from "${WG_IPV4%%/*}" lookup "$TABLE" 2>/dev/null || true
        fi
    else
        ip tunnel del "$IFACE" 2>/dev/null || true
        ip tunnel add "$IFACE" mode sit remote "$REMOTE_V4" local "$LOCAL_V4" ttl 255 2>/dev/null || continue
        ip link set "$IFACE" up mtu "${MTU:-1400}"
        ip -6 addr replace "$TUNNEL_IPV6" dev "$IFACE"
        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null
        ip -6 route replace "$TUNNEL_IPV6" dev "$IFACE" table "$TABLE" 2>/dev/null
        ip -6 route replace default dev "$IFACE" table "$TABLE"
        
        while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
        ip -6 rule add pref "$RULE_PREF" from "${TUNNEL_IPV6%%/*}" lookup "$TABLE" 2>/dev/null || true
        
        if [ -n "$ROUTED_PREFIX" ]; then
            ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null
            ip -6 route replace "$ROUTED_PREFIX" dev "$IFACE" table "$TABLE" 2>/dev/null
            while ip -6 rule del pref "$RULE_PREF_PREFIX" 2>/dev/null; do :; done
            ip -6 rule add pref "$RULE_PREF_PREFIX" from "$ROUTED_PREFIX" lookup "$TABLE" 2>/dev/null || true
        fi
    fi

    # 恢复附加 IP
    LIST_FILE="${CONFIG_DIR}/${IFACE}-ips.list"
    if [ -f "$LIST_FILE" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && ip -6 addr replace "$ip/128" dev lo 2>/dev/null || true
        done < "$LIST_FILE"
    fi
done
exit 0
EOF
    chmod +x "$T64_RESTORE_BIN"

    if pidof systemd >/dev/null 2>&1 || [ -d "/run/systemd/system" ]; then
        cat > "$T64_RESTORE_SERVICE" << EOF
[Unit]
Description=Tunnel64 Multi-Tunnel Restore
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$T64_RESTORE_BIN
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable tunnel64-restore.service >/dev/null 2>&1
    fi
}

remove_systemd_restore_if_empty() {
    if [ -z "$(ls -A "$CONFIG_DIR"/*.conf 2>/dev/null)" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable tunnel64-restore.service >/dev/null 2>&1 || true
            systemctl stop tunnel64-restore.service >/dev/null 2>&1 || true
        fi
        rm -f "$T64_RESTORE_SERVICE" "$T64_RESTORE_BIN"
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    fi
}

# ================= 业务功能 =================

add_sit_tunnel() {
    read -p "请输入隧道名称 (直接回车随机): " IFACE
    [ -z "$IFACE" ] && IFACE="sit$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    
    if ! is_valid_iface "$IFACE"; then echo "[错误] 接口名不合法"; return 1; fi
    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then echo "[错误] 接口已存在"; return 1; fi

    read -p "请输入服务端 IPv4 地址: " REMOTE_V4
    local default_local_v4=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
    [ -z "$default_local_v4" ] && default_local_v4=$(curl -4 -s ifconfig.me 2>/dev/null)
    read -p "请输入客户端 IPv4 地址 (本机) [$default_local_v4]: " LOCAL_V4
    [ -z "$LOCAL_V4" ] && LOCAL_V4="$default_local_v4"

    read -p "请输入服务端 IPv6 地址: " SERVER_IPV6
    read -p "请输入客户端 IPv6 地址: " TUNNEL_IPV6
    read -p "请输入 IPv6 路由前缀 (可选): " ROUTED_PREFIX

    IFACE=$(sanitize "$IFACE"); LOCAL_V4=$(sanitize "$LOCAL_V4"); REMOTE_V4=$(sanitize "$REMOTE_V4")
    SERVER_IPV6=$(sanitize "$SERVER_IPV6"); TUNNEL_IPV6=$(sanitize "$TUNNEL_IPV6"); ROUTED_PREFIX=$(sanitize "$ROUTED_PREFIX")

    if [ -z "$LOCAL_V4" ] || [ -z "$REMOTE_V4" ] || [ -z "$TUNNEL_IPV6" ]; then
        echo "[错误] 核心 IP 参数不能为空" && return 1
    fi

    exec 9> "$LOCK_FILE"
    flock -x 9
    get_new_table_pref
    local TABLE="$NEW_TABLE" RULE_PREF="$NEW_PREF" RULE_PREF_PREFIX="$NEW_PREF_PREFIX"
    flock -u 9

    local TYPE="sit" MTU="1400"
    if ! setup_tunnel_runtime; then
        echo "[错误] 隧道配置下发失败！" && return 1
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

    update_systemd_restore
    echo "✓ 隧道 $IFACE 添加成功并生效！"
}

add_wg_tunnel() {
    read -p "请输入隧道名称 (直接回车随机): " IFACE
    [ -z "$IFACE" ] && IFACE="wg$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
    
    if ! is_valid_iface "$IFACE"; then echo "[错误] 接口名不合法"; return 1; fi
    if [ -f "$CONFIG_DIR/$IFACE.conf" ]; then echo "[错误] 接口已存在"; return 1; fi

    echo -e "请粘贴 WireGuard 客户端配置内容 (连续按两次回车确认):"
    
    local tmp_conf=$(mktemp)
    trap 'rm -f "$tmp_conf"' EXIT INT TERM

    local wg_raw="" empty_count=0
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            empty_count=$((empty_count + 1))
            [ "$empty_count" -ge 2 ] && break
        else
            empty_count=0
        fi
        echo "$line" >> "$tmp_conf"
    done

    local WG_PRIVKEY=$(sed -n 's/^[[:space:]]*[Pp][Rr][Ii][Vv][Aa][Tt][Ee][Kk][Ee][Yy][[:space:]]*=[[:space:]]*//p' "$tmp_conf" | head -n 1 | tr -d '\r')
    local WG_PUBKEY=$(sed -n 's/^[[:space:]]*[Pp][Uu][Bb][Ll][Ii][Cc][Kk][Ee][Yy][[:space:]]*=[[:space:]]*//p' "$tmp_conf" | head -n 1 | tr -d '\r')
    local WG_ENDPOINT=$(sed -n 's/^[[:space:]]*[Ee][Nn][Dd][Pp][Oo][Ii][Nn][Tt][[:space:]]*=[[:space:]]*//p' "$tmp_conf" | head -n 1 | tr -d '\r')
    local WG_MTU=$(sed -n 's/^[[:space:]]*[Mm][Tt][Uu][[:space:]]*=[[:space:]]*//p' "$tmp_conf" | head -n 1 | tr -d '\r')
    local WG_PSK=$(sed -n 's/^[[:space:]]*[Pp][Rr][Ee][Ss][Hh][Aa][Rr][Ee][Dd][Kk][Ee][Yy][[:space:]]*=[[:space:]]*//p' "$tmp_conf" | head -n 1 | tr -d '\r')
    local WG_KEEPALIVE=$(sed -n 's/^[[:space:]]*[Pp][Ee][Rr][Ss][Ii][Ss][Tt][Ee][Nn][Tt][Kk][Ee][Ee][Pp][Aa][Ll][Ii][Vv][Ee][[:space:]]*=[[:space:]]*//p' "$tmp_conf" | head -n 1 | tr -d '\r')
    local WG_ADDRESS=$(awk -F'=' 'tolower($1) ~ /^[[:space:]]*address[[:space:]]*/ {sub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' "$tmp_conf" | tr '\n' ',' | sed 's/,$//' | tr -d '\r')
    local WG_ALLOWEDIPS=$(awk -F'=' 'tolower($1) ~ /^[[:space:]]*allowedips[[:space:]]*/ {sub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' "$tmp_conf" | tr '\n' ',' | sed 's/,$//' | tr -d '\r')
    
    rm -f "$tmp_conf"; trap - EXIT INT TERM

    local WG_IPV4=$(echo "$WG_ADDRESS" | awk -F',' '{for(i=1;i<=NF;i++) if($i~/\./ && $i!~/:/) {gsub(/^[ \t]+|[ \t]+$/,"",$i); print $i; exit}}')
    local WG_IPV6=$(echo "$WG_ADDRESS" | awk -F',' '{for(i=1;i<=NF;i++) if($i~/:/) {gsub(/^[ \t]+|[ \t]+$/,"",$i); print $i; exit}}')

    if [ -z "$WG_PRIVKEY" ] || { [ -z "$WG_IPV4" ] && [ -z "$WG_IPV6" ]; } || [ -z "$WG_PUBKEY" ] || [ -z "$WG_ENDPOINT" ]; then
        echo "[错误] 无法解析配置，核心参数缺失。"
        return 1
    fi

    read -p "请输入该隧道附带的 IPv6 路由前缀 (可选): " ROUTED_PREFIX
    ROUTED_PREFIX=$(sanitize "$ROUTED_PREFIX")

    exec 9> "$LOCK_FILE"
    flock -x 9
    get_new_table_pref
    local TABLE="$NEW_TABLE" RULE_PREF="$NEW_PREF" RULE_PREF_PREFIX="$NEW_PREF_PREFIX" RULE_PREF_V4="$NEW_PREF_V4"
    flock -u 9

    local TYPE="wg" MTU="${WG_MTU:-1420}"
    [ -z "$WG_ALLOWEDIPS" ] && WG_ALLOWEDIPS="::/0,0.0.0.0/0"
    WG_ALLOWEDIPS=$(echo "$WG_ALLOWEDIPS" | tr -d ' ')

    cat > "$CONFIG_DIR/$IFACE.wg" <<EOF
[Interface]
PrivateKey = $WG_PRIVKEY
[Peer]
PublicKey = $WG_PUBKEY
Endpoint = $WG_ENDPOINT
AllowedIPs = $WG_ALLOWEDIPS
EOF
    [ -n "$WG_PSK" ] && echo "PresharedKey = $WG_PSK" >> "$CONFIG_DIR/$IFACE.wg"
    [ -n "$WG_KEEPALIVE" ] && echo "PersistentKeepalive = $WG_KEEPALIVE" >> "$CONFIG_DIR/$IFACE.wg"

    chmod 600 "$CONFIG_DIR/$IFACE.wg"

    if ! setup_tunnel_runtime; then
        echo "[错误] WireGuard 隧道配置下发失败"
        rm -f "$CONFIG_DIR/$IFACE.wg"
        return 1
    fi

    cat > "$CONFIG_DIR/$IFACE.conf" <<EOF
TYPE="wg"
IFACE="$IFACE"
WG_IPV4="$WG_IPV4"
WG_IPV6="$WG_IPV6"
WG_ENDPOINT="$(sanitize "$WG_ENDPOINT")"
WG_ALLOWEDIPS="$WG_ALLOWEDIPS"
ROUTED_PREFIX="$ROUTED_PREFIX"
MTU="$MTU"
TABLE="$TABLE"
RULE_PREF="$RULE_PREF"
RULE_PREF_PREFIX="$RULE_PREF_PREFIX"
RULE_PREF_V4="$RULE_PREF_V4"
EOF
    chmod 600 "$CONFIG_DIR/$IFACE.conf"

    update_systemd_restore
    echo "✓ WG隧道 $IFACE 添加成功并生效！"
}

delete_tunnel() {
    local conf="$1" list_file="$2"
    load_tunnel_conf "$conf"
    
    echo "========== 删除隧道: $IFACE =========="
    read -p "确认删除该隧道及其所有附加 IP 吗? [y/N]: " OK
    [[ "$OK" != "y" && "$OK" != "Y" ]] && return

    [ -f "$list_file" ] && while IFS= read -r ip; do
        [ -n "$ip" ] && ip -6 addr del "$ip/128" dev lo 2>/dev/null || true
    done < "$list_file"

    while ip -6 rule del pref "$RULE_PREF" 2>/dev/null; do :; done
    [ -n "$RULE_PREF_PREFIX" ] && while ip -6 rule del pref "$RULE_PREF_PREFIX" 2>/dev/null; do :; done
    [ -n "$RULE_PREF_V4" ] && while ip -4 rule del pref "$RULE_PREF_V4" 2>/dev/null; do :; done
    
    ip -6 route flush table "$TABLE" 2>/dev/null || true
    ip -4 route flush table "$TABLE" 2>/dev/null || true

    [ -n "$ROUTED_PREFIX" ] && ip -6 route del "$ROUTED_PREFIX" dev "$IFACE" 2>/dev/null || true
    [ -n "$WG_IPV6" ] && ip -6 route del "$WG_IPV6" dev "$IFACE" 2>/dev/null || true
    [ -n "$WG_IPV4" ] && ip -4 route del "$WG_IPV4" dev "$IFACE" 2>/dev/null || true
    [ -n "$TUNNEL_IPV6" ] && ip -6 route del "$TUNNEL_IPV6" dev "$IFACE" 2>/dev/null || true

    cleanup_tunnel_runtime "$IFACE" "$TYPE"
    rm -f "$conf" "$list_file" "$CONFIG_DIR/$IFACE.wg"
    remove_systemd_restore_if_empty
    
    echo "✓ 隧道 $IFACE 已彻底删除"
    read -p "按回车键返回..."
}

add_ipv6() {
    load_tunnel_conf "$1"
    [ -z "$ROUTED_PREFIX" ] && echo "无路由前缀，无法生成附加 IP" && sleep 1 && return
    local NEW_IPV6=$(generate_ipv6 "$ROUTED_PREFIX")
    ip -6 addr add "$NEW_IPV6/128" dev lo || { echo "绑定失败"; sleep 1; return; }
    echo "$NEW_IPV6" >> "$2"
    echo "✓ 生成附加 IP: $NEW_IPV6"
    read -p "按回车键继续..."
}

tunnel_submenu() {
    while true; do
        [ -f "$1" ] || return
        load_tunnel_conf "$1"
        clear
        echo "=== 隧道: $IFACE [${TYPE^^}] ==="
        echo "1. 添加随机附加 IPv6"
        echo "2. 删除隧道"
        echo "0. 返回"
        read -p "选择: " sel
        case "$sel" in
            1) add_ipv6 "$1" "$CONFIG_DIR/$IFACE-ips.list" ;;
            2) delete_tunnel "$1" "$CONFIG_DIR/$IFACE-ips.list"; return ;;
            0) return ;;
        esac
    done
}

get_tunnel_file_by_index() {
    local idx=$1 i=1
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$i" -eq "$idx" ] && echo "$f" && return 0
        i=$((i + 1))
    done
    return 1
}

menu() {
    install_dep
    while true; do
        clear; echo "==== 隧道策略路由管理网关 ===="
        echo "a. 添加 SIT 隧道 | b. 添加 WG 隧道 | 0. 退出"
        echo "------------------------"
        local i=1 has=0
        for f in "$CONFIG_DIR"/*.conf; do
            [ -f "$f" ] || continue
            has=1; TYPE="sit"; load_tunnel_conf "$f"
            echo " [$i] [${TYPE^^}] $IFACE"
            i=$((i+1))
        done
        [ "$has" -eq 0 ] && echo " 暂无隧道"
        read -p "输入操作或编号: " ch
        case "$ch" in
            0) exit 0 ;;
            a|A) add_sit_tunnel ;;
            b|B) add_wg_tunnel ;;
            *) 
               if [[ "$ch" =~ ^[0-9]+$ ]]; then
                   local f=$(get_tunnel_file_by_index "$ch")
                   [ -n "$f" ] && tunnel_submenu "$f"
               fi ;;
        esac
    done
}

menu
