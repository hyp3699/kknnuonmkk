#!/bin/bash
set -e

CONF_DIR="/etc/he-ipv6"
CONF="$CONF_DIR/config"
mkdir -p "$CONF_DIR"

install_dep(){
PKG=""
command -v ip >/dev/null 2>&1 || PKG="$PKG iproute2"
command -v curl >/dev/null 2>&1 || PKG="$PKG curl"
command -v ifup >/dev/null 2>&1 || PKG="$PKG ifupdown"
if [ -n "$PKG" ];then
if command -v apt >/dev/null 2>&1;then
apt update
apt install -y $PKG
elif command -v apk >/dev/null 2>&1;then
apk add $PKG
elif command -v yum >/dev/null 2>&1;then
yum install -y $PKG
fi
fi
}

get_ipv4(){
curl -4 -s https://ip.sb
}

save_conf(){
cat > "$CONF" <<EOF
HE_SERVER=$HE_SERVER
LOCAL_IPV4=$LOCAL_IPV4
CLIENT_IPV6=$CLIENT_IPV6
GATEWAY_IPV6=$GATEWAY_IPV6
PREFIX=$PREFIX
EOF
}

load_conf(){
[ -f "$CONF" ] && source "$CONF"
}

add_tunnel(){
echo "HE服务器IPv4:"
read HE_SERVER
LOCAL_IPV4=$(get_ipv4)
echo "本机IPv4:$LOCAL_IPV4"
echo "客户端IPv6:"
read CLIENT_IPV6
echo "网关IPv6:"
read GATEWAY_IPV6
PREFIX=$(echo "$CLIENT_IPV6"|cut -d: -f1-4)
ip tunnel del he-ipv6 2>/dev/null || true
ip tunnel add he-ipv6 mode sit remote "$HE_SERVER" local "$LOCAL_IPV4"
ip link set he-ipv6 up
ip -6 addr add "$CLIENT_IPV6/64" dev he-ipv6
ip -6 route add default via "$GATEWAY_IPV6" dev he-ipv6 metric 100 2>/dev/null || true
save_conf
write_interfaces
echo "HE Tunnel完成"
}

write_interfaces(){
grep -q "auto he-ipv6" /etc/network/interfaces 2>/dev/null && return
cat >> /etc/network/interfaces <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
        address $CLIENT_IPV6
        netmask 64
        endpoint $HE_SERVER
        local $LOCAL_IPV4
        ttl 255
        gateway $GATEWAY_IPV6
EOF
}

random_ipv6(){
hex=$(tr -dc a-f0-9 </dev/urandom | head -c 4)
echo "${PREFIX}:${hex}"
}

add_ipv6(){
load_conf
if [ -z "$PREFIX" ];then
echo "请先添加Tunnel"
return
fi
IP=$(random_ipv6)
ip -6 addr add "$IP/64" dev he-ipv6
echo "$IP" >> "$CONF_DIR/ipv6.list"
echo "添加IPv6:$IP"
echo "重启恢复地址已保存"
cat >> /etc/network/interfaces <<EOF
up ip -6 addr add $IP/64 dev he-ipv6 || true
EOF
}

del_ipv6(){
load_conf
echo "当前IPv6:"
LIST=($(grep -v "^$" "$CONF_DIR/ipv6.list" 2>/dev/null))
if [ ${#LIST[@]} -eq 0 ];then
echo "没有添加的IPv6"
return
fi
i=1
for ip in "${LIST[@]}";do
echo "$i. $ip"
i=$((i+1))
done
echo "选择删除:"
read n
DEL=${LIST[$((n-1))]}
ip -6 addr del "$DEL/64" dev he-ipv6 2>/dev/null || true
sed -i "\|$DEL|d" "$CONF_DIR/ipv6.list"
sed -i "\|$DEL|d" /etc/network/interfaces
echo "已删除:$DEL"
}
status(){
echo "========== HE IPv6 =========="
ip tunnel show he-ipv6
echo
ip -6 addr show dev he-ipv6
echo
ip -6 route show
}

test_out(){
load_conf
echo "测试出口:"
curl -6 --connect-timeout 5 --interface "$CLIENT_IPV6" https://ip.sb
echo
}

delete_tunnel(){
ip tunnel del he-ipv6 2>/dev/null || true
sed -i '/auto he-ipv6/,+7d' /etc/network/interfaces 2>/dev/null || true
rm -rf "$CONF_DIR"
echo "HE Tunnel 已删除"
}

restore(){
load_conf
if [ -z "$HE_SERVER" ];then
echo "没有配置"
return
fi
ip tunnel show he-ipv6 >/dev/null 2>&1 && return
ip tunnel add he-ipv6 mode sit remote "$HE_SERVER" local "$LOCAL_IPV4"
ip link set he-ipv6 up
ip -6 addr add "$CLIENT_IPV6/64" dev he-ipv6
ip -6 route add default via "$GATEWAY_IPV6" dev he-ipv6 metric 100 2>/dev/null || true
}

menu(){
while true
do
echo "========== HE IPv6 =========="
echo "1. 添加HE Tunnel"
echo "2. 添加随机IPv6"
echo "3. 删除IPv6"
echo "4. 查看状态"
echo "5. 测试出口"
echo "6. 删除Tunnel"
echo "7. 恢复Tunnel"
echo "0.退出"
read -p "选择:" c
case $c in
1)add_tunnel;;
2)add_ipv6;;
3)del_ipv6;;
4)status;;
5)test_out;;
6)delete_tunnel;;
7)restore;;
0)exit;;
*)echo "错误";;
esac
done
}

install_dep
menu

