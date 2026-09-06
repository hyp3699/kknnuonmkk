#!/bin/bash

set -e

CONF_DIR="/etc/he-ipv6"
CONF_FILE="$CONF_DIR/config"

mkdir -p $CONF_DIR


get_ipv4(){

curl -4 -s https://ip.sb

}


detect(){

if [ -f /etc/network/interfaces ];then
    NET="ifupdown"
elif ls /etc/netplan/*.yaml >/dev/null 2>&1;then
    NET="netplan"
elif [ -d /etc/systemd/network ];then
    NET="networkd"
else
    NET="manual"
fi

echo "网络模式: $NET"

}


save(){

cat > $CONF_FILE <<EOF
HE_SERVER=$HE_SERVER
LOCAL_IPV4=$LOCAL_IPV4
CLIENT_IPV6=$CLIENT_IPV6
GATEWAY_IPV6=$GATEWAY_IPV6
IFACE=he-ipv6
EOF

}


add_tunnel(){


echo "HE服务器IPv4:"
read HE_SERVER


LOCAL_IPV4=$(get_ipv4)

echo "检测本机IPv4:"
echo $LOCAL_IPV4


echo "客户端IPv6:"
read CLIENT_IPV6


echo "网关IPv6:"
read GATEWAY_IPV6



ip tunnel del he-ipv6 2>/dev/null || true


ip tunnel add he-ipv6 \
mode sit \
remote $HE_SERVER \
local $LOCAL_IPV4


ip link set he-ipv6 up


ip -6 addr add $CLIENT_IPV6 dev he-ipv6


ip -6 route add ::/0 via $GATEWAY_IPV6 dev he-ipv6 metric 100 2>/dev/null || true



save


persist


echo "HE Tunnel 创建完成"

}



persist(){


detect


if [ "$NET" = "ifupdown" ];then


cat >> /etc/network/interfaces <<EOF


# HE IPv6 Tunnel
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address $CLIENT_IPV6
    netmask 64
    endpoint $HE_SERVER
    local $LOCAL_IPV4
    ttl 255
    gateway $GATEWAY_IPV6

EOF


echo "已写入 /etc/network/interfaces"


elif [ "$NET" = "netplan" ];then


FILE=$(ls /etc/netplan/*.yaml | head -1)


cat >> $FILE <<EOF


# HE IPv6 Tunnel
network:
  tunnels:
    he-ipv6:
      mode: sit
      local: $LOCAL_IPV4
      remote: $HE_SERVER

EOF


echo "已写入 $FILE"



else

cat >/etc/systemd/network/99-he-ipv6.netdev <<EOF
[NetDev]
Name=he-ipv6
Kind=sit

[Tunnel]
Local=$LOCAL_IPV4
Remote=$HE_SERVER
EOF



cat >/etc/systemd/network/99-he-ipv6.network <<EOF
[Match]
Name=he-ipv6

[Network]
Address=$CLIENT_IPV6
Gateway=$GATEWAY_IPV6
EOF


systemctl restart systemd-networkd

fi


}



add_ip(){


echo "输入IPv6地址:"
read IP


ip -6 addr add $IP/64 dev he-ipv6


echo "添加完成"


}



del_ip(){


ip -6 addr show dev he-ipv6


echo
echo "输入删除的完整IPv6:"
read IP


ip -6 addr del $IP dev he-ipv6


}



status(){


ip tunnel show

echo

ip -6 addr show dev he-ipv6

echo

ip -6 route


}



test_out(){


echo "测试当前出口"

curl -6 https://ip.sb --interface $(grep CLIENT_IPV6 $CONF_FILE|cut -d= -f2)


}



delete(){


ip tunnel del he-ipv6 2>/dev/null || true


sed -i '/# HE IPv6 Tunnel/,+8d' /etc/network/interfaces 2>/dev/null || true


rm -f $CONF_FILE


echo "Tunnel 已删除"


}



menu(){

while true
do

echo
echo "========== HE IPv6 =========="
echo "1. 添加HE Tunnel"
echo "2. 添加IPv6"
echo "3. 删除IPv6"
echo "4. 查看状态"
echo "5. 测试出口"
echo "6. 删除Tunnel"
echo "7. 设置开机恢复"
echo "0.退出"


read -p "选择:" c


case $c in

1)add_tunnel;;

2)add_ip;;

3)del_ip;;

4)status;;

5)test_out;;

6)delete;;

7)persist;;

0)exit;;

esac


done

}


menu
