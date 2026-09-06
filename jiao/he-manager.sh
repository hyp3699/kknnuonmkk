#!/bin/bash

# ==========================================
# HE IPv6 隧道一键管理脚本 (公网纯净版)
# ==========================================

CONF_DIR="/etc/network/interfaces.d"
CONF_FILE="$CONF_DIR/he-ipv6"
NETPLAN_FILE="/etc/netplan/99-he-ipv6.yaml"
CONFIG_RECORD="/etc/he-ipv6.conf"
LIST_FILE="/etc/he-ipv6-ips.list"
IFACE="he-ipv6"
PUBLIC_V4=""

# 检查 Root 权限
[ "$(id -u)" != "0" ] && echo "错误: 请使用 root 权限运行此脚本！" && exit 1

install_dep(){
    if command -v apt >/dev/null; then
        command -v curl >/dev/null || (apt update -y && apt install curl iproute2 gawk -y)
    fi
}

detect_public_ipv4(){
    PUBLIC_V4=$(curl -4 -s --connect-timeout 5 https://ip.sb)

    if [ -z "$PUBLIC_V4" ]; then
        echo "无法获取公网 IPv4"
        exit 1
    fi

    echo "检测到公网 IPv4: $PUBLIC_V4"
}

detect_mode(){
    if command -v netplan >/dev/null || [ -d /etc/netplan ]; then
        MODE="netplan"
    elif command -v ifup >/dev/null || [ -d /etc/network ]; then
        MODE="ifupdown"
        command -v ifup >/dev/null || apt install ifupdown -y
    else
        echo "错误: 未检测到支持的网络配置环境 (Netplan 或 ifupdown)"
        exit 1
    fi
}

load_record(){
    if [ -f "$CONFIG_RECORD" ]; then
        source "$CONFIG_RECORD"
    fi
}

fix_interfaces_file(){
    if [ "$MODE" = "ifupdown" ]; then
        mkdir -p "$CONF_DIR"
        local MAIN_FILE="/etc/network/interfaces"
        if [ ! -f "$MAIN_FILE" ]; then
            cat > "$MAIN_FILE" <<EOF
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*
EOF
        else
            if ! grep -qE '^\s*source(-directory)?\s+/etc/network/interfaces\.d' "$MAIN_FILE"; then
                echo -e "\n# 自动添加子目录加载指令以支持 HE IPv6\nsource /etc/network/interfaces.d/*" >> "$MAIN_FILE"
            fi
        fi
    fi
}

rebuild_and_apply(){
    load_record
    if [ -z "$HE_SERVER_V4" ] || [ -z "$CLIENT_IPV6" ]; then
        echo "错误: 缺少核心配置记录，请重新添加 HE 隧道。"
        return 1
    fi

    if [ "$MODE" = "ifupdown" ]; then
        fix_interfaces_file
        
        # 移除 local 参数，完全由内核根据公网路由自动匹配
        cat > "$CONF_FILE" <<EOF
auto $IFACE
iface $IFACE inet6 v4tunnel
        address $CLIENT_IPV6
        netmask 64
        endpoint $HE_SERVER_V4
        ttl 255
        gateway $HE_SERVER_V6
EOF
        if [ -f "$LIST_FILE" ]; then
            while read -r ip; do
                [ -n "$ip" ] && echo "        up ip -6 addr add $ip/64 dev $IFACE || true" >> "$CONF_FILE"
            done < "$LIST_FILE"
        fi
        
        echo "        post-up ip -6 route add default via $HE_SERVER_V6 dev $IFACE metric 2048 || true" >> "$CONF_FILE"
        echo "        post-up ip -6 route add default via $HE_SERVER_V6 dev $IFACE table 200 || true" >> "$CONF_FILE"
        echo "        post-up ip -6 rule add from $CLIENT_IPV6/128 table 200 || true" >> "$CONF_FILE"
        if [ -n "$ROUTED_PREFIX" ]; then
            echo "        post-up ip -6 rule add from ${ROUTED_PREFIX}::/64 table 200 || true" >> "$CONF_FILE"
        fi

    else
        mkdir -p /etc/netplan
        # 移除 netplan 中的 local 字段
        cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  tunnels:
    $IFACE:
      mode: sit
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
          metric: 2048
        - to: default
          via: "$HE_SERVER_V6"
          table: 200
      routing-policy:
        - from: "$CLIENT_IPV6/128"
          table: 200
EOF
        if [ -n "$ROUTED_PREFIX" ]; then
            cat >> "$NETPLAN_FILE" <<EOF
        - from: "${ROUTED_PREFIX}::/64"
          table: 200
EOF
        fi
    fi

    apply_config
}

apply_config(){
    echo "正在应用网络配置..."
    # 清理旧路由规则和隧道
    while ip -6 rule list 2>/dev/null | grep -q '200'; do ip -6 rule del table 200 2>/dev/null; done
    ip link set "$IFACE" down 2>/dev/null || true
    ip tunnel del "$IFACE" 2>/dev/null || true

    if [ "$MODE" = "ifupdown" ]; then
        ifdown "$IFACE" 2>/dev/null || true
    else
        netplan apply 2>/dev/null || true
    fi

    # 底层强制拉起：完全省略 local 参数，由内核自动匹配公网网卡，根治缓冲区报错
    detect_public_ipv4

ip tunnel add "$IFACE" mode sit \
local "$PUBLIC_V4" \
remote "$HE_SERVER_V4" \
ttl 255 || {
        echo "错误: 创建隧道失败！请检查 HE Server IPv4 (endpoint) 是否填写正确。"
        return 1
    }
    ip link set "$IFACE" up
    ip link set "$IFACE" mtu 1480
    ip -6 addr add "$CLIENT_IPV6/64" dev "$IFACE" 2>/dev/null || true

    if [ -f "$LIST_FILE" ]; then
        while read -r ip; do
            [ -n "$ip" ] && ip -6 addr add "$ip/64" dev "$IFACE" 2>/dev/null || true
        done < "$LIST_FILE"
    fi

    ip -6 route add default via "$HE_SERVER_V6" dev "$IFACE" metric 2048 || true
    ip -6 route add default via "$HE_SERVER_V6" dev "$IFACE" table 200 || true
    ip -6 rule add pref 100 from "$CLIENT_IPV6/128" table 200 || true
    if [ -n "$ROUTED_PREFIX" ]; then
    ip -6 rule add pref 101 from "${ROUTED_PREFIX}::/64" table 200 || true
    fi

    echo "配置应用完成！"
}

add_he(){
    echo "========== 添加 HE IPv6 隧道 =========="
    read -p "HE Server IPv4 Address (endpoint): " HE_SERVER_V4
    read -p "HE Server IPv6 Address (gateway, 例: 2001:470:xx:xx::1): " HE_SERVER_V6
    read -p "Client IPv6 Address (address, 例: 2001:470:xx:xx::2): " CLIENT_IPV6
    read -p "Routed /64 Prefix (可选, 用于生成多IP，直接按回车跳过): " ROUTED_PREFIX

    if [ -n "$ROUTED_PREFIX" ]; then
        ROUTED_PREFIX=$(echo "$ROUTED_PREFIX" | sed -E 's|/.*||; s/::$//')
    fi

    cat > "$CONFIG_RECORD" <<EOF
HE_SERVER_V4="$HE_SERVER_V4"
HE_SERVER_V6="$HE_SERVER_V6"
CLIENT_IPV6="$CLIENT_IPV6"
ROUTED_PREFIX="$ROUTED_PREFIX"
EOF

    rm -f "$LIST_FILE"
    rebuild_and_apply
    echo "HE 隧道添加完成并已配置为开机自启！"
}

delete_he(){
    echo "正在删除 HE 隧道..."
    while ip -6 rule list 2>/dev/null | grep -q '200'; do ip -6 rule del table 200 2>/dev/null; done
    if [ "$MODE" = "ifupdown" ]; then
        ifdown "$IFACE" 2>/dev/null || true
        rm -f "$CONF_FILE"
    else
        rm -f "$NETPLAN_FILE"
        netplan apply 2>/dev/null || true
    fi
    ip link set "$IFACE" down 2>/dev/null || true
    ip tunnel del "$IFACE" 2>/dev/null || true
    rm -f "$CONFIG_RECORD" "$LIST_FILE"
    echo "HE 隧道已彻底清理完成！"
}

add_ipv6(){
    load_record
    if [ -z "$CLIENT_IPV6" ]; then
        echo "请先通过选项 1 添加 HE 隧道！"
        read -p "按回车键继续..."
        return
    fi

    BASE_PREFIX="$ROUTED_PREFIX"
    if [ -z "$BASE_PREFIX" ]; then
        read -p "未检测到预存的 Routed /64，请输入 (例: 2001:470:yy:yy): " INPUT_PREFIX
        [ -z "$INPUT_PREFIX" ] && echo "未提供前缀，取消添加" && return
        BASE_PREFIX=$(echo "$INPUT_PREFIX" | sed -E 's|/.*||; s/:+$//')
        echo "ROUTED_PREFIX=\"$BASE_PREFIX\"" >> "$CONFIG_RECORD"
        ROUTED_PREFIX="$BASE_PREFIX"
    fi

    HEX=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
    RAND="${HEX:0:4}:${HEX:4:4}:${HEX:8:4}:${HEX:12:4}"
    NEW_IPV6="${BASE_PREFIX}:${RAND}"

    echo "$NEW_IPV6" >> "$LIST_FILE"
    rebuild_and_apply
    echo "成功添加并启用 IPv6 地址: $NEW_IPV6"
    read -p "按回车键继续..."
}

list_ipv6(){
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "(暂无额外的附加 IPv6 地址)"
        return
    fi

    awk '{print NR ". " $0}' "$LIST_FILE"
}

delete_ipv6(){
    if [ ! -f "$LIST_FILE" ] || [ ! -s "$LIST_FILE" ]; then
        echo "没有可删除的额外 IPv6 地址"
        read -p "按回车键继续..."
        return
    fi
    echo "========== 当前配置的额外 IPv6 地址 =========="
    list_ipv6
    echo
    read -p "输入要删除的编号: " NUM
    [ -z "$NUM" ] && return
    
    DEL_IP=$(sed -n "${NUM}p" "$LIST_FILE")
    if [ -z "$DEL_IP" ]; then
        echo "输入的编号无效！"
        read -p "按回车键继续..."
        return
    fi

    sed -i "${NUM}d" "$LIST_FILE"
    echo "已移除记录: $DEL_IP"
    rebuild_and_apply
    read -p "按回车键继续..."
}

status(){
    clear
    echo "========== HE IPv6 设备状态 =========="
    ip link show "$IFACE" 2>/dev/null || echo "隧道设备未启动"
    echo
    echo "========== 已绑定的全局 IPv6 地址 =========="
    ip -6 addr show dev "$IFACE" 2>/dev/null | grep 'scope global' | awk '{print $2}' || echo "无"
    echo
    echo "========== IPv6 路由表与策略 =========="
    ip -6 route show table 200 2>/dev/null | grep "$IFACE" || echo "无专用路由"
    ip -6 rule list 2>/dev/null | grep '200' || echo "无路由策略"
    echo
    echo "========== 额外附加的 IPv6 地址清单 =========="
    list_ipv6
    echo
    read -p "按回车键返回主菜单..."
}

test_ipv6(){
    echo "正在测试 HE IPv6 连通性及出口 IP..."
    TEST_IP=$(ip -6 addr show dev "$IFACE" 2>/dev/null \
| grep 'scope global' \
| grep -v fe80 \
| grep -oP 'inet6 \K[^/]+' \
| head -n 1)
    
    if [ -n "$TEST_IP" ]; then
        echo "使用指定源 IP: $TEST_IP 发起请求..."
        curl -6 --interface "$TEST_IP" --connect-timeout 8 https://ip.sb || echo "IPv6 连接失败，请检查防火墙或隧道状态！"
    else
        echo "未找到可用的 HE IPv6 地址，请先确保选项 1 隧道已成功添加。"
    fi
    read -p "按回车键继续..."
}

menu(){
    while true
    do
        clear
        echo "========== HE IPv6 隧道管理 ($MODE 模式) =========="
        echo "1. 添加/重置 HE 隧道"
        echo "2. 删除 HE 隧道"
        echo "3. 随机添加附加 IPv6 地址"
        echo "4. 删除指定附加 IPv6 地址"
        echo "5. 查看网卡与路由状态"
        echo "6. 测试 IPv6 出口连通性"
        echo "0. 退出"
        echo "=================================================="
        read -p "选择 [0-6]: " CHOOSE
        case $CHOOSE in
            1) add_he; read -p "按回车键继续..." ;;
            2) delete_he; read -p "按回车键继续..." ;;
            3) add_ipv6 ;;
            4) delete_ipv6 ;;
            5) status ;;
            6) test_ipv6 ;;
            0) exit 0 ;;
            *) echo "输入错误，请重新选择！"; sleep 1 ;;
        esac
    done
}

install_dep
detect_mode
menu
