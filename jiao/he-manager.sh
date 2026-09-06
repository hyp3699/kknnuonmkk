#!/bin/bash

# ==========================================
# HE IPv6 隧道一键管理脚本 (支持 Netplan & ifupdown)
# ==========================================

CONF_DIR="/etc/network/interfaces.d"
CONF_FILE="$CONF_DIR/he-ipv6"
NETPLAN_FILE="/etc/netplan/99-he-ipv6.yaml"
CONFIG_RECORD="/etc/he-ipv6.conf"
LIST_FILE="/etc/he-ipv6-ips.list"
IFACE="he-ipv6"

# 检查 Root 权限
[ "$(id -u)" != "0" ] && echo "错误: 请使用 root 权限运行此脚本！" && exit 1

install_dep(){
    if command -v apt >/dev/null; then
        command -v curl >/dev/null || (apt update -y && apt install curl iproute2 -y)
    fi
}

detect_mode(){
    if command -v netplan >/dev/null || [ -d /etc/netplan ]; then
        MODE="netplan"
    elif command -v ifup >/dev/null && [ -d /etc/network ]; then
        MODE="ifupdown"
    else
        echo "错误: 未检测到支持的网络配置环境 (Netplan 或 ifupdown)"
        exit 1
    fi
}

get_local_ipv4(){
    # 优先获取主网卡实际绑定的 IP（适用于 NAT 架构如 AWS/阿里云/腾讯云）
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(curl -4 -s --connect-timeout 5 https://ip.sb)
    fi
    echo "$LOCAL_IP"
}

load_record(){
    if [ -f "$CONFIG_RECORD" ]; then
        source "$CONFIG_RECORD"
    fi
}

# 重新生成配置文件并应用（彻底避免 sed 修改导致的 YAML 格式错乱）
rebuild_and_apply(){
    load_record
    if [ -z "$HE_SERVER_V4" ] || [ -z "$CLIENT_IPV6" ]; then
        echo "错误: 缺少核心配置记录，请重新添加 HE 隧道。"
        return 1
    fi

    if [ "$MODE" = "ifupdown" ]; then
        mkdir -p "$CONF_DIR"
        cat > "$CONF_FILE" <<EOF
auto $IFACE
iface $IFACE inet6 v4tunnel
        address $CLIENT_IPV6
        netmask 64
        endpoint $HE_SERVER_V4
        local $LOCAL_IPV4
        ttl 255
        gateway $HE_SERVER_V6
EOF
        # 追加额外的 IPv6 地址
        if [ -f "$LIST_FILE" ]; then
            while read -r ip; do
                [ -n "$ip" ] && echo "        up ip -6 addr add $ip/64 dev $IFACE || true" >> "$CONF_FILE"
            done < "$LIST_FILE"
        fi
        echo "        post-up ip -6 route add default via $HE_SERVER_V6 dev $IFACE metric 100 || true" >> "$CONF_FILE"

    else
        # Netplan 模式
        mkdir -p /etc/netplan
        cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  tunnels:
    $IFACE:
      mode: sit
      local: $LOCAL_IPV4
      remote: $HE_SERVER_V4
      addresses:
        - "$CLIENT_IPV6/64"
EOF
        if [ -f "$LIST_FILE" ]; then
            while read -r ip; do
                [ -n "$ip" ] && echo "        - \"$ip/64\"" >> "$NETPLAN_FILE"
            done < "$LIST_FILE"
        fi

        cat >> "$NETPLAN_FILE" <<EOF
      routes:
        - to: default
          via: "$HE_SERVER_V6"
EOF
    fi

    # 应用网络配置
    apply_config
}

apply_config(){
    echo "正在应用网络配置..."
    if [ "$MODE" = "ifupdown" ]; then
        ifdown "$IFACE" 2>/dev/null || true
        ip tunnel del "$IFACE" 2>/dev/null || true
        ifup "$IFACE" 2>/dev/null || true
    else
        netplan apply
    fi
    echo "配置应用完成！"
}

add_he(){
    echo "========== 添加 HE IPv6 隧道 =========="
    read -p "HE Server IPv4 Address (endpoint): " HE_SERVER_V4
    read -p "HE Server IPv6 Address (gateway, 例: 2001:470:xx:xx::1): " HE_SERVER_V6
    read -p "Client IPv6 Address (address, 例: 2001:470:xx:xx::2): " CLIENT_IPV6
    read -p "Routed /64 Prefix (可选, 用于生成多IP，直接按回车跳过): " ROUTED_PREFIX

    DETECTED_IPV4=$(get_local_ipv4)
    read -p "本机 IPv4 [$DETECTED_IPV4]: " INPUT_LOCAL_IPV4
    LOCAL_IPV4=${INPUT_LOCAL_IPV4:-$DETECTED_IPV4}

    # 处理 Routed Prefix 前缀格式
    if [ -n "$ROUTED_PREFIX" ]; then
        ROUTED_PREFIX=$(echo "$ROUTED_PREFIX" | sed -E 's|/.*||; s/:+$//')
    fi

    # 保存配置记录
    cat > "$CONFIG_RECORD" <<EOF
HE_SERVER_V4="$HE_SERVER_V4"
HE_SERVER_V6="$HE_SERVER_V6"
CLIENT_IPV6="$CLIENT_IPV6"
LOCAL_IPV4="$LOCAL_IPV4"
ROUTED_PREFIX="$ROUTED_PREFIX"
EOF

    # 清空之前的额外 IP 列表
    rm -f "$LIST_FILE"

    rebuild_and_apply
    echo "HE 隧道添加完成！"
}

delete_he(){
    echo "正在删除 HE 隧道..."
    if [ "$MODE" = "ifupdown" ]; then
        ifdown "$IFACE" 2>/dev/null || true
        rm -f "$CONF_FILE"
    else
        rm -f "$NETPLAN_FILE"
        netplan apply 2>/dev/null || true
    fi
    ip tunnel del "$IFACE" 2>/dev/null || true
    rm -f "$CONFIG_RECORD" "$LIST_FILE"
    echo "HE 隧道已彻底清理完成！"
}

add_ipv6(){
    load_record
    if [ -z "$CLIENT_IPV6" ]; then
        echo "请先添加 HE 隧道！"
        return
    fi

    BASE_PREFIX="$ROUTED_PREFIX"
    if [ -z "$BASE_PREFIX" ]; then
        read -p "未检测到预存的 Routed /64，请输入 (例: 2001:470:yy:yy): " INPUT_PREFIX
        [ -z "$INPUT_PREFIX" ] && echo "未提供前缀，取消添加" && return
        BASE_PREFIX=$(echo "$INPUT_PREFIX" | sed -E 's|/.*||; s/:+$//')
    fi

    # 生成随机 64 位后缀 (16 位十六进制)
    HEX=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
    RAND="${HEX:0:4}:${HEX:4:4}:${HEX:8:4}:${HEX:12:4}"
    NEW_IPV6="${BASE_PREFIX}:${RAND}"

    echo "生成新 IPv6 地址: $NEW_IPV6"
    echo "$NEW_IPV6" >> "$LIST_FILE"

    rebuild_and_apply
    echo "成功添加 IPv6 地址: $NEW_IPV6"
}

list_ipv6(){
    echo "========== 当前配置的额外 IPv6 地址 =========="
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "(暂无额外的附加 IPv6 地址)"
        return
    fi
    nl -w2 -s'. ' "$LIST_FILE"
}

delete_ipv6(){
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "没有可删除的额外 IPv6 地址"
        return
    fi
    list_ipv6
    echo
    read -p "输入要删除的编号: " NUM
    [ -z "$NUM" ] && return
    
    DEL_IP=$(sed -n "${NUM}p" "$LIST_FILE")
    if [ -z "$DEL_IP" ]; then
        echo "输入的编号无效！"
        return
    fi

    # 从列表中删除指定行
    sed -i "${NUM}d" "$LIST_FILE"
    echo "已移除记录: $DEL_IP"

    rebuild_and_apply
}

status(){
    echo "========== HE IPv6 设备状态 =========="
    ip link show "$IFACE" 2>/dev/null || echo "隧道设备未启动"
    echo
    echo "========== 已绑定的 IPv6 地址 =========="
    ip -6 addr show dev "$IFACE" 2>/dev/null
    echo
    echo "========== IPv6 路由表 =========="
    ip -6 route show | grep "$IFACE"
    echo
    list_ipv6
}

test_ipv6(){
    echo "正在测试 IPv6 连通性及出口 IP..."
    curl -6 --connect-timeout 8 https://ip.sb || echo "IPv6 连接失败，请检查防火墙或 HE 隧道状态！"
}

menu(){
    while true
    do
        echo
        echo "========== HE IPv6 隧道管理 ($MODE 模式) =========="
        echo "1. 添加/重置 HE 隧道"
        echo "2. 删除 HE 隧道"
        echo "3. 随机添加附加 IPv6 地址"
        echo "4. 删除指定附加 IPv6 地址"
        echo "5. 查看网卡与路由状态"
        echo "6. 测试 IPv6 出口连通性"
        echo "0. 退出"
        read -p "选择 [0-6]: " CHOOSE
        case $CHOOSE in
            1) add_he ;;
            2) delete_he ;;
            3) add_ipv6 ;;
            4) delete_ipv6 ;;
            5) status ;;
            6) test_ipv6 ;;
            0) exit 0 ;;
            *) echo "输入错误，请重新选择！" ;;
        esac
    done
}

install_dep
detect_mode
menu
