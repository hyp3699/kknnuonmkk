#!/bin/bash

# ==========================================
# HE IPv6 隧道管理器
# 支持：
# - 直接导入 HE ifupdown 配置
# - /64 /48 Routed Prefix
# - 多 IPv6 地址管理
# ==========================================


IFACE="he-ipv6"

CONFIG_RECORD="/etc/he-ipv6.conf"
LIST_FILE="/etc/he-ipv6-ips.list"

PUBLIC_V4=""


# root检查
if [ "$(id -u)" != "0" ]; then
    echo "错误: 请使用 root 运行"
    exit 1
fi


install_dep(){

    if command -v apt >/dev/null; then

        for pkg in curl iproute2 gawk grep sed; do

            command -v "$pkg" >/dev/null || {
                apt update -y
                apt install -y "$pkg"
            }

        done

    fi
}



load_record(){

    [ -f "$CONFIG_RECORD" ] && source "$CONFIG_RECORD"

}



save_record(){

cat > "$CONFIG_RECORD" <<EOF
HE_SERVER_V4="$HE_SERVER_V4"
HE_SERVER_V6="$HE_SERVER_V6"
CLIENT_IPV6="$CLIENT_IPV6"
PUBLIC_V4="$PUBLIC_V4"
ROUTED_PREFIX="$ROUTED_PREFIX"
EOF

}



detect_public_ipv4(){

    if [ -z "$PUBLIC_V4" ]; then

        PUBLIC_V4=$(curl -4 -s --connect-timeout 5 https://ip.sb)

    fi


    if [ -z "$PUBLIC_V4" ]; then

        echo "无法获取公网IPv4"
        return 1

    fi

}



#############################################
# 导入 HE Tunnelbroker 配置
#############################################

add_he(){


echo
echo "========== 导入 HE IPv6 配置 =========="
echo
echo "请粘贴 HE ifupdown 配置"
echo "输入 END 结束"
echo


TMP="/tmp/he-import.conf"

rm -f "$TMP"


while true
do

    read line

    [ "$line" = "END" ] && break

    echo "$line" >> "$TMP"

done



CLIENT_IPV6=$(grep -E "^[[:space:]]*address " "$TMP" | awk '{print $2}')

HE_SERVER_V4=$(grep -E "^[[:space:]]*endpoint " "$TMP" | awk '{print $2}')

PUBLIC_V4=$(grep -E "^[[:space:]]*local " "$TMP" | awk '{print $2}')

HE_SERVER_V6=$(grep -E "^[[:space:]]*gateway " "$TMP" | awk '{print $2}')



if [ -z "$CLIENT_IPV6" ] ||
   [ -z "$HE_SERVER_V4" ] ||
   [ -z "$HE_SERVER_V6" ]; then


    echo
    echo "配置解析失败"
    echo "必须包含:"
    echo "address"
    echo "endpoint"
    echo "gateway"

    return 1

fi



echo
echo "解析结果:"
echo "----------------------"
echo "本机IPv4 : $PUBLIC_V4"
echo "HE IPv4  : $HE_SERVER_V4"
echo "本机IPv6 : $CLIENT_IPV6"
echo "网关IPv6 : $HE_SERVER_V6"
echo "----------------------"



read -p "确认创建隧道? [y/N]: " OK


[ "$OK" != "y" ] && return



save_record


rm -f "$LIST_FILE"



apply_config



echo
echo "HE IPv6 隧道创建完成"

read -p "按回车继续..."

}





#############################################
# 创建/刷新隧道
#############################################

apply_config(){


load_record


if [ -z "$HE_SERVER_V4" ] ||
   [ -z "$CLIENT_IPV6" ]; then

    echo "没有HE配置"
    return 1

fi



echo "清理旧隧道..."



while ip -6 rule list 2>/dev/null | grep -q "table 200"
do
    ip -6 rule del table 200
done



ip link set "$IFACE" down 2>/dev/null || true

ip tunnel del "$IFACE" 2>/dev/null || true



echo "创建 SIT 隧道..."



ip tunnel add "$IFACE" \
mode sit \
local "$PUBLIC_V4" \
remote "$HE_SERVER_V4" \
ttl 255



if [ $? != 0 ]; then

    echo "创建隧道失败"
    return 1

fi



ip link set "$IFACE" up


# HE推荐MTU
ip link set "$IFACE" mtu 1480



# 添加Tunnel IPv6

ip -6 addr add \
"$CLIENT_IPV6/64" \
dev "$IFACE" 2>/dev/null || true




# 默认IPv6路由

ip -6 route replace default \
via "$HE_SERVER_V6" \
dev "$IFACE" \
metric 2048




# policy routing

ip -6 route replace default \
via "$HE_SERVER_V6" \
dev "$IFACE" \
table 200



ip -6 rule add \
pref 100 \
from "$CLIENT_IPV6/128" \
table 200 2>/dev/null || true



# 如果有地址池

if [ -n "$ROUTED_PREFIX" ]; then


ip -6 rule add \
pref 101 \
from "${ROUTED_PREFIX}::/48" \
table 200 2>/dev/null || true


fi



# 开启IPv6转发

cat >/etc/sysctl.d/99-he-ipv6.conf <<EOF
net.ipv6.conf.all.forwarding=1
EOF


sysctl --system >/dev/null 2>&1



echo
echo "HE隧道启动完成"

}

#############################################
# IPv6 前缀生成地址
#############################################

generate_ipv6(){


PREFIX="$1"


HEX=$(cat /proc/sys/kernel/random/uuid | tr -d '-')


# 去掉末尾冒号
PREFIX=$(echo "$PREFIX" | sed 's/::$//')


COUNT=$(echo "$PREFIX" | awk -F: '{print NF}')



case "$COUNT" in


3)
    # /48

    echo "${PREFIX}:${HEX:0:4}:${HEX:4:4}:${HEX:8:4}:${HEX:12:4}"

;;


4)
    # /64

    echo "${PREFIX}:${HEX:0:4}:${HEX:4:4}:${HEX:8:4}:${HEX:12:4}"

;;


*)
    echo ""

;;

esac

}





#############################################
# 添加随机IPv6
#############################################

add_ipv6(){


load_record



if [ -z "$CLIENT_IPV6" ]; then

    echo "请先导入HE配置"
    read -p "回车继续..."
    return

fi



if [ -z "$ROUTED_PREFIX" ]; then


echo
echo "请输入 HE Routed Prefix"
echo
echo "支持:"
echo "/48:"
echo "2001:470:abcd"
echo
echo "/64:"
echo "2001:470:abcd:1234"
echo


read -p "Prefix: " ROUTED_PREFIX



if [ -z "$ROUTED_PREFIX" ]; then

    echo "取消"
    return

fi



ROUTED_PREFIX=$(echo "$ROUTED_PREFIX" \
| sed -E 's|/.*||;s/::$//')



save_record


fi




NEW_IPV6=$(generate_ipv6 "$ROUTED_PREFIX")



if [ -z "$NEW_IPV6" ]; then

    echo "Prefix格式错误"
    return

fi



echo "$NEW_IPV6" >> "$LIST_FILE"



echo
echo "生成IPv6:"
echo "$NEW_IPV6"



apply_config



echo
echo "添加完成"


read -p "回车继续..."

}





#############################################
# 查看IPv6列表
#############################################

list_ipv6(){


if [ ! -f "$LIST_FILE" ] ||
   [ ! -s "$LIST_FILE" ]; then


    echo "暂无额外IPv6"

    return


fi



echo "========== IPv6列表 =========="


nl -w2 -s ". " "$LIST_FILE"



}





#############################################
# 删除IPv6
#############################################

delete_ipv6(){


if [ ! -f "$LIST_FILE" ] ||
   [ ! -s "$LIST_FILE" ]; then


    echo "没有IPv6"

    read -p "回车继续..."

    return


fi



list_ipv6


echo


read -p "删除编号: " NUM



if ! [[ "$NUM" =~ ^[0-9]+$ ]]; then

    echo "输入错误"

    return

fi



DEL=$(sed -n "${NUM}p" "$LIST_FILE")



if [ -z "$DEL" ]; then

    echo "不存在"

    return

fi



sed -i "${NUM}d" "$LIST_FILE"



echo
echo "删除:"
echo "$DEL"



apply_config



read -p "回车继续..."

}





#############################################
# 显示当前IPv6
#############################################

show_ipv6(){


echo
echo "========== HE IPv6 状态 =========="


ip link show "$IFACE"



echo
echo "IPv6地址:"
ip -6 addr show dev "$IFACE" \
| grep global



echo
echo "路由:"
ip -6 route show dev "$IFACE"



echo
echo "策略:"
ip -6 rule



echo

list_ipv6


read -p "回车返回..."

}

#############################################
# 测试IPv6出口
#############################################

test_ipv6(){


echo
echo "正在测试IPv6出口..."


TEST_IP=$(ip -6 addr show dev "$IFACE" 2>/dev/null \
| grep "scope global" \
| grep -v fe80 \
| grep -oP 'inet6 \K[^/ ]+' \
| head -1)



if [ -z "$TEST_IP" ]; then

    echo "没有可用IPv6地址"

    read -p "回车继续..."
    return

fi



echo
echo "使用源地址:"
echo "$TEST_IP"


echo

curl -6 \
--interface "$TEST_IP" \
--connect-timeout 8 \
https://ip.sb



echo

read -p "回车继续..."

}





#############################################
# 删除HE隧道
#############################################

delete_he(){


echo
echo "正在删除HE隧道..."



while ip -6 rule list 2>/dev/null | grep -q "table 200"
do

    ip -6 rule del table 200

done



ip link set "$IFACE" down 2>/dev/null || true


ip tunnel del "$IFACE" 2>/dev/null || true



rm -f "$CONFIG_RECORD"
rm -f "$LIST_FILE"


rm -f /etc/sysctl.d/99-he-ipv6.conf


sysctl --system >/dev/null 2>&1



echo
echo "HE IPv6 已删除"


read -p "回车继续..."

}





#############################################
# 重载HE
#############################################

reload_he(){


apply_config


read -p "回车继续..."

}





#############################################
# 主菜单
#############################################

menu(){


while true
do


clear


echo "================================="
echo "       HE IPv6 隧道管理器"
echo "================================="
echo

echo "1. 导入HE配置并创建隧道"

echo "2. 删除HE隧道"

echo "3. 添加随机IPv6"

echo "4. 删除IPv6"

echo "5. 查看状态"

echo "6. 测试IPv6出口"

echo "7. 重载隧道"

echo "0. 退出"


echo
echo "================================="


read -p "选择 [0-7]: " CHOOSE



case "$CHOOSE" in


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

    show_ipv6

;;


6)

    test_ipv6

;;


7)

    reload_he

;;


0)

    exit 0

;;


*)

    echo "错误选择"

    sleep 1

;;

esac


done


}




#############################################
# 自动启动
#############################################


install_dep


load_record


# 如果已有配置，启动隧道

if [ -n "$HE_SERVER_V4" ] &&
   [ -n "$CLIENT_IPV6" ]; then


    echo "检测到已有HE配置"

    apply_config


fi



menu


