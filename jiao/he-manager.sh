#!/bin/bash
# HE IPv6 Tunnel 管理脚本

CONF_NAME="he-ipv6"
IFACE_CONF="/etc/network/interfaces.d/he-ipv6"
NETPLAN_CONF="/etc/systemd/network/99-he-ipv6.network"
NM_CONF="he-ipv6"

check_root(){
[ "$(id -u)" != "0" ] && echo "请使用root运行" && exit 1
}

get_ipv4(){
curl -4 -s --connect-timeout 5 https://ip.sb
}

install_dep(){
if command -v apt >/dev/null; then
    if ! command -v curl >/dev/null; then
        apt update && apt install curl -y
    fi
    if ! command -v ifup >/dev/null && ! command -v networkctl >/dev/null && ! command -v nmcli >/dev/null; then
        apt update
        apt install ifupdown -y
    fi
fi
if command -v yum >/dev/null; then
    if ! command -v curl >/dev/null; then
        yum install curl -y
    fi
fi
}

detect_net(){
if command -v nmcli >/dev/null; then
    NET_TYPE="nm"
elif command -v ifup >/dev/null && [ -d /etc/network ]; then
    NET_TYPE="ifupdown"
elif command -v networkctl >/dev/null; then
    NET_TYPE="networkd"
else
    echo "没有检测到网络管理工具"
    exit 1
fi
echo "网络模式:$NET_TYPE"
}

generate_ip(){
HE_SERVER="$1"
HE_IPV6="$2"
LOCAL_IPV4=$(get_ipv4)
CLIENT_IPV6=$(echo "$HE_IPV6" | sed 's/::1$/::2/')
ROUTED_IPV6=$(echo "$HE_IPV6" | sed 's/:23:/:24/')
}

add_ifupdown(){
mkdir -p /etc/network/interfaces.d
cat > "$IFACE_CONF" <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
        address $CLIENT_IPV6
        netmask 64
        endpoint $HE_SERVER
        local $LOCAL_IPV4
        ttl 255
        gateway $HE_IPV6
        up ip -6 addr add $ROUTED_IPV6/64 dev he-ipv6 || true
        post-up ip -6 route add default via $HE_IPV6 dev he-ipv6 metric 100 || true
EOF
echo "配置文件:$IFACE_CONF"
ifup he-ipv6 2>/dev/null || true
}

add_networkd(){
mkdir -p /etc/systemd/network
cat > "$NETPLAN_CONF" <<EOF
[NetDev]
Name=he-ipv6
Kind=sit
[Tunnel]
Local=$LOCAL_IPV4
Remote=$HE_SERVER
TTL=255
[Network]
Address=$CLIENT_IPV6/64
Gateway=$HE_IPV6
EOF
cat > /etc/systemd/network/100-he-ipv6-route.network <<EOF
[Match]
Name=he-ipv6
[Network]
Address=$ROUTED_IPV6/64
EOF
systemctl restart systemd-networkd
}

add_nm(){
nmcli connection delete "$NM_CONF" 2>/dev/null
nmcli connection add type ip-tunnel \
mode sit \
con-name "$NM_CONF" \
ifname he-ipv6 \
local "$LOCAL_IPV4" \
remote "$HE_SERVER"
nmcli connection modify "$NM_CONF" \
ipv6.method manual \
ipv6.addresses "$CLIENT_IPV6/64" \
ipv6.gateway "$HE_IPV6"
nmcli connection up "$NM_CONF"
ip -6 addr add "$ROUTED_IPV6/64" dev he-ipv6 2>/dev/null || true
}

add_he(){
read -p "HE服务器IPv4: " HE_SERVER
read -p "HE服务器IPv6: " HE_IPV6
generate_ip "$HE_SERVER" "$HE_IPV6"
echo "本机IPv4:$LOCAL_IPV4"
echo "客户端IPv6:$CLIENT_IPV6"
echo "Routed IPv6:$ROUTED_IPV6"
case "$NET_TYPE" in
ifupdown)
add_ifupdown
;;
networkd)
add_networkd
;;
nm)
add_nm
;;
esac
echo "HE Tunnel 添加完成"
}

delete_he(){
if command -v ifdown >/dev/null; then
ifdown he-ipv6 2>/dev/null
fi
if command -v nmcli >/dev/null; then
nmcli connection delete "$NM_CONF" 2>/dev/null
fi
rm -f "$IFACE_CONF"
rm -f "$NETPLAN_CONF"
rm -f /etc/systemd/network/100-he-ipv6-route.network
ip tunnel del he-ipv6 2>/dev/null
echo "HE Tunnel 删除完成"
}

status_he(){
echo "========== IPv6状态 =========="
ip link show he-ipv6
echo
ip -6 addr show dev he-ipv6
echo
ip -6 route show
}

test_ipv6(){
curl -6 --connect-timeout 5 https://ip.sb
}

check_root
install_dep
detect_net

while true
do
echo
echo "========== HE IPv6 =========="
echo "1. 添加HE Tunnel"
echo "2. 删除IPv6"
echo "3. 查看状态"
echo "4. 测试IPv6出口"
echo "0. 退出"
read -p "选择:" num
case $num in
1)
add_he
;;
2)
delete_he
;;
3)
status_he
;;
4)
test_ipv6
;;
0)
exit
;;
*)
echo "错误"
;;
esac
done
