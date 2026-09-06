#!/bin/bash

BASE="/etc/he-ipv6"
CONF="$BASE/config"

mkdir -p $BASE


detect_net(){

if command -v nmcli >/dev/null 2>&1; then
    NET="nmcli"

elif ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    NET="netplan"

elif [ -f /etc/network/interfaces ]; then
    NET="ifupdown"

elif [ -f /etc/alpine-release ]; then
    NET="alpine"

else
    NET="manual"
fi

echo "检测网络管理: $NET"

}


save_conf(){

cat > $CONF <<EOF
SERVER4=$SERVER4
LOCAL4=$LOCAL4
CLIENT6=$CLIENT6
GATE6=$GATE6
EOF

}


load_conf(){

[ -f $CONF ] && source $CONF

}


create_tunnel(){

load_conf

if [ -z "$SERVER4" ];then

read -p "HE服务器IPv4: " SERVER4
read -p "本机IPv4: " LOCAL4
read -p "客户端IPv6: " CLIENT6
read -p "网关IPv6: " GATE6

save_conf

fi


ip tunnel del he-ipv6 2>/dev/null


ip tunnel add he-ipv6 \
mode sit \
remote $SERVER4 \
local $LOCAL4


ip link set he-ipv6 up


ip -6 addr add $CLIENT6/64 dev he-ipv6


ip -6 route add $GATE6 dev he-ipv6 2>/dev/null


ip -6 route add default via $GATE6 dev he-ipv6 metric 100 2>/dev/null



echo "HE Tunnel 创建完成"


persist

}



persist(){

case $NET in


ifupdown)

cat >/etc/network/interfaces.d/he-ipv6 <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address $CLIENT6
    netmask 64
    endpoint $SERVER4
    local $LOCAL4
    ttl 255
    gateway $GATE6
EOF

;;


netplan)

cat >/etc/netplan/99-he-ipv6.yaml <<EOF
network:
 version: 2
 tunnels:
  he-ipv6:
   mode: sit
   remote: $SERVER4
   local: $LOCAL4
   addresses:
    - $CLIENT6/64
   routes:
    - to: default
      via: $GATE6
EOF

netplan apply 2>/dev/null

;;


nmcli)

nmcli connection delete he-ipv6 2>/dev/null

nmcli connection add \
type ip-tunnel \
mode sit \
ifname he-ipv6 \
remote $SERVER4 \
local $LOCAL4


nmcli connection modify he-ipv6 \
ipv6.method manual \
ipv6.address $CLIENT6/64 \
ipv6.gateway $GATE6


nmcli connection up he-ipv6

;;


esac

}



add_ipv6(){

load_conf

read -p "输入IPv6地址: " IP6


ip -6 addr add $IP6/64 dev he-ipv6


cat >> $BASE/routes <<EOF
$IP6
EOF


echo "添加成功"

}



del_ipv6(){

read -p "删除IPv6地址: " IP6

ip -6 addr del $IP6/64 dev he-ipv6 2>/dev/null


sed -i "/$IP6/d" $BASE/routes


}



restore_ipv6(){

[ ! -f $BASE/routes ] && return


while read ip
do

ip -6 addr add $ip/64 dev he-ipv6 2>/dev/null

done < $BASE/routes


}



delete_tunnel(){

ip link set he-ipv6 down 2>/dev/null

ip tunnel del he-ipv6 2>/dev/null


rm -rf $BASE


rm -f /etc/netplan/99-he-ipv6.yaml
rm -f /etc/network/interfaces.d/he-ipv6


echo "删除完成"

}



status(){

echo "====== Tunnel ======"

ip tunnel show


echo


echo "====== IPv6 ======"

ip -6 addr show dev he-ipv6


echo


echo "====== Route ======"

ip -6 route


}



test_ipv6(){

read -p "测试IPv6地址(空默认): " IP


if [ -z "$IP" ];then

curl -6 https://ip.sb

else

curl -6 --interface $IP https://ip.sb

fi

}



boot_restore(){

cat >/etc/systemd/system/he-ipv6.service <<EOF
[Unit]
Description=HE IPv6 Tunnel

After=network.target


[Service]
Type=oneshot
ExecStart=/root/he-manager.sh restore
RemainAfterExit=yes


[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload
systemctl enable he-ipv6.service


}



case "$1" in

restore)

detect_net
load_conf
create_tunnel
restore_ipv6
;;

esac



detect_net


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

1)
create_tunnel
;;

2)
add_ipv6
;;

3)
del_ipv6
;;

4)
status
;;

5)
test_ipv6
;;

6)
delete_tunnel
;;

7)
boot_restore
;;

0)
exit
;;

esac

done

