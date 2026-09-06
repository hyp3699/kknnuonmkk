#!/bin/bash
CONF_DIR="/etc/network/interfaces.d"
CONF_FILE="$CONF_DIR/he-ipv6"
NETPLAN_FILE="/etc/netplan/99-he-ipv6.yaml"
LIST_FILE="/etc/he-ipv6.list"
IFACE="he-ipv6"

[ "$(id -u)" != "0" ] && echo "请使用root运行" && exit 1

install_dep(){
if command -v apt >/dev/null; then
command -v curl >/dev/null || apt update && apt install curl -y
fi
}

get_ipv4(){
curl -4 -s --connect-timeout 5 https://ip.sb
}

detect_mode(){
if command -v ifup >/dev/null && [ -d /etc/network ]; then
MODE="ifupdown"
elif command -v netplan >/dev/null || [ -d /etc/netplan ]; then
MODE="netplan"
else
echo "未检测到网络配置环境"
exit 1
fi
echo "当前网络模式:$MODE"
}

calc_ipv6(){
HE_IPV6="$1"
CLIENT_IPV6=$(python3 - <<EOF
import ipaddress
ip=ipaddress.IPv6Address("$HE_IPV6")
print(ipaddress.IPv6Address(int(ip)+1))
EOF
)
ROUTED_IPV6=$(python3 - <<EOF
import ipaddress
ip=ipaddress.IPv6Address("$HE_IPV6")
s=str(ip)
p=s.split(":")
p[2]="24"
print(":".join(p).replace(":::","::")+"1")
EOF
)
}

write_ifupdown(){
mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<EOF
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
}

write_netplan(){
mkdir -p /etc/netplan
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  tunnels:
    he-ipv6:
      mode: sit
      local: $LOCAL_IPV4
      remote: $HE_SERVER
      addresses:
        - $CLIENT_IPV6/64
      routes:
        - to: ::/0
          via: $HE_IPV6
EOF
}

apply_config(){
if [ "$MODE" = "ifupdown" ]; then
ifup "$IFACE" 2>/dev/null || true
else
netplan apply
fi
}

add_he(){
read -p "HE服务器IPv4: " HE_SERVER
read -p "HE服务器IPv6: " HE_IPV6
LOCAL_IPV4=$(get_ipv4)
calc_ipv6 "$HE_IPV6"
echo "本机IPv4:$LOCAL_IPV4"
echo "客户端IPv6:$CLIENT_IPV6"
echo "Routed IPv6:$ROUTED_IPV6"
if [ "$MODE" = "ifupdown" ]; then
write_ifupdown
else
write_netplan
fi
echo "$ROUTED_IPV6" > "$LIST_FILE"
apply_config
echo "HE隧道添加完成"
}

delete_he(){
if [ "$MODE" = "ifupdown" ]; then
ifdown "$IFACE" 2>/dev/null
rm -f "$CONF_FILE"
else
rm -f "$NETPLAN_FILE"
netplan apply
fi
ip tunnel del "$IFACE" 2>/dev/null
rm -f "$LIST_FILE"
echo "HE隧道删除完成"
}
add_ipv6(){
if [ ! -f "$LIST_FILE" ]; then
echo "请先添加HE隧道"
return
fi
PREFIX=$(cat "$LIST_FILE")
RAND=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
NEW_IPV6="${PREFIX%::*}:${RAND:0:4}:${RAND:4:4}:${RAND:8:4}:${RAND:12:4}"
echo "添加IPv6:$NEW_IPV6"
if [ "$MODE" = "ifupdown" ]; then
sed -i "/up ip -6 addr add/a\\        up ip -6 addr add $NEW_IPV6/64 dev he-ipv6 || true" "$CONF_FILE"
else
sed -i "/addresses:/a\        - $NEW_IPV6/64" "$NETPLAN_FILE"
fi
apply_config
echo "$NEW_IPV6" >> "$LIST_FILE"
echo "IPv6添加完成"
}

list_ipv6(){
if [ ! -f "$LIST_FILE" ]; then
echo "没有记录"
return
fi
echo "========== 已添加IPv6 =========="
nl -w2 -s'. ' "$LIST_FILE"
}

delete_ipv6(){
if [ ! -f "$LIST_FILE" ]; then
echo "没有IPv6"
return
fi
list_ipv6
echo
read -p "输入删除编号:" NUM
DEL=$(sed -n "${NUM}p" "$LIST_FILE")
[ -z "$DEL" ] && echo "编号错误" && return
if [ "$MODE" = "ifupdown" ]; then
sed -i "/$DEL/d" "$CONF_FILE"
else
sed -i "/$DEL/d" "$NETPLAN_FILE"
fi
sed -i "/$DEL/d" "$LIST_FILE"
apply_config
echo "删除完成:$DEL"
}

status(){
echo "========== HE IPv6状态 =========="
ip link show "$IFACE" 2>/dev/null
echo
ip -6 addr show dev "$IFACE" 2>/dev/null
echo
ip -6 route show
echo
list_ipv6
}

test_ipv6(){
echo "IPv6出口:"
curl -6 --connect-timeout 5 https://ip.sb
}

menu(){
while true
do
echo
echo "========== HE IPv6 =========="
echo "1. 添加HE隧道"
echo "2. 删除HE隧道"
echo "3. 添加IPv6"
echo "4. 删除IPv6"
echo "5. 查看状态"
echo "6. 测试IPv6出口"
echo "0. 退出"
read -p "选择:" CHOOSE
case $CHOOSE in
1)
add_he
;;
2)
delete_he
;;
3)
add_ipv6
;;
4)
delete_ipv6
;;
5)
status
;;
6)
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
}

install_dep
detect_mode
menu
