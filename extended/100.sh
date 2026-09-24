setup_vps_traffic_stats() {
    cat > /usr/local/bin/vps-traffic-stat <<'EOF'
#!/bin/bash
STATE_DIR="/var/lib/vps-traffic"
STATE_FILE="$STATE_DIR/state"
mkdir -p "$STATE_DIR" /run/lock
exec 9>/run/lock/vps-traffic.lock
flock -n 9 || exit 0
current=$(awk -F': *' '
NR > 2 {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
    if ($1 != "lo" && $1 != "") {
        n = split($2, a, /[[:space:]]+/)
        rx += a[1]
        tx += a[9]
    }
}
END {
    printf "%.0f %.0f\n", rx, tx
}' /proc/net/dev)
read -r curr_rx curr_tx <<< "$current"
cur_month=$(date -u "+%Y-%m")
last_month=""
last_rx=""
last_tx=""
month_rx=0
month_tx=0
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE" 2>/dev/null
fi
if ! [[ "$last_rx" =~ ^[0-9]+$ ]] || ! [[ "$last_tx" =~ ^[0-9]+$ ]]; then
    last_month="$cur_month"
    month_rx=0
    month_tx=0
    last_rx="$curr_rx"
    last_tx="$curr_tx"
elif [ "$last_month" = "$cur_month" ]; then
    delta_rx=$((curr_rx - last_rx))
    delta_tx=$((curr_tx - last_tx))
    [ "$delta_rx" -lt 0 ] && delta_rx=0
    [ "$delta_tx" -lt 0 ] && delta_tx=0
    month_rx=$((month_rx + delta_rx))
    month_tx=$((month_tx + delta_tx))
    last_rx="$curr_rx"
    last_tx="$curr_tx"
else
    delta_rx=$((curr_rx - last_rx))
    delta_tx=$((curr_tx - last_tx))
    [ "$delta_rx" -lt 0 ] && delta_rx=0
    [ "$delta_tx" -lt 0 ] && delta_tx=0
    last_month="$cur_month"
    month_rx="$delta_rx"
    month_tx="$delta_tx"
    last_rx="$curr_rx"
    last_tx="$curr_tx"
fi
tmp_file="${STATE_FILE}.tmp.$$"
cat > "$tmp_file" <<EOT
last_month="$last_month"
last_rx="$last_rx"
last_tx="$last_tx"
month_rx="$month_rx"
month_tx="$month_tx"
last_update="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
EOT
chmod 600 "$tmp_file"
mv -f "$tmp_file" "$STATE_FILE"
EOF

    chmod 700 /usr/local/bin/vps-traffic-stat
    cat > /etc/systemd/system/vps-traffic-stat.service <<'EOF'
[Unit]
Description=VPS Traffic Statistics
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-traffic-stat
EOF

    cat > /etc/systemd/system/vps-traffic-stat.timer <<'EOF'
[Unit]
Description=VPS Traffic Statistics Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps-traffic-stat.timer >/dev/null 2>&1
    systemctl start vps-traffic-stat.service >/dev/null 2>&1
}

vps_s() {
    ip_address    
    if [ "$(uname -m)" == "x86_64" ]; then
      cpu_info=$(cat /proc/cpuinfo | grep 'model name' | uniq | sed -e 's/model name[[:space:]]*: //')
    else
      cpu_info=$(lscpu | grep 'Model name' | sed -e 's/Model name[[:space:]]*: //')
    fi
    cpu_usage_percent=$(awk '/cpu /{u=$2+$4; d=$2+$4+$5; if(NR==2) {printf "%.2f%%", (u-lu)/(d-ld)*100} lu=u; ld=d}' <(grep 'cpu ' /proc/stat; sleep 0.2; grep 'cpu ' /proc/stat))
    
    cpu_cores=$(nproc)
    mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2f MB (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')
    disk_info=$(df -h | awk '$NF=="/"{printf "%d/%dGB (%s)", $3,$2,$5}')
    
    ip_api_res=$(curl -s --max-time 5 http://ip-api.com/json/?fields=status,country,city,isp)
    if echo "$ip_api_res" | grep -q '"success"'; then
        country=$(echo "$ip_api_res" | awk -F'"country":"' '{print $2}' | awk -F'"' '{print $1}')
        city=$(echo "$ip_api_res" | awk -F'"city":"' '{print $2}' | awk -F'"' '{print $1}')
        isp_info=$(echo "$ip_api_res" | awk -F'"isp":"' '{print $2}' | awk -F'"' '{print $1}')
    else
        country="未知"
        city="未知"
        isp_info="获取失败 (限流)"
    fi
    
    cpu_arch=$(uname -m)
    hostname=$(hostname)
    kernel_version=$(uname -r)
    congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control)
    queue_algorithm=$(sysctl -n net.core.default_qdisc)
    
    os_info=$(lsb_release -ds 2>/dev/null)
    if [ -z "$os_info" ]; then
      if [ -f "/etc/os-release" ]; then
        os_info=$(source /etc/os-release && echo "$PRETTY_NAME")
      elif [ -f "/etc/debian_version" ]; then
        os_info="Debian $(cat /etc/debian_version)"
      elif [ -f "/etc/redhat-release" ]; then
        os_info=$(cat /etc/redhat-release)
      else
        os_info="Unknown"
      fi
    fi
    clear 
	systemctl start vps-traffic-stat.service >/dev/null 2>&1
traffic_file="/var/lib/vps-traffic/state"
monthly_rx=0
monthly_tx=0
if [ -f "$traffic_file" ]; then
    source "$traffic_file" 2>/dev/null
    monthly_rx="${month_rx:-0}"
    monthly_tx="${month_tx:-0}"
fi
    monthly_output=$(awk -v rx="$monthly_rx" -v tx="$monthly_tx" '
        BEGIN {
            rx_units = "Bytes"; tx_units = "Bytes";
            if (rx > 1024) { rx /= 1024; rx_units = "KB"; }
            if (rx > 1024) { rx /= 1024; rx_units = "MB"; }
            if (rx > 1024) { rx /= 1024; rx_units = "GB"; }
            if (tx > 1024) { tx /= 1024; tx_units = "KB"; }
            if (tx > 1024) { tx /= 1024; tx_units = "MB"; }
            if (tx > 1024) { tx /= 1024; tx_units = "GB"; }
            printf("本月入站: %.2f %s\n本月出站: %.2f %s", rx, rx_units, tx, tx_units);
        }')

    current_time=$(date "+%Y-%m-%d %I:%M %p")
    swap_used=$(free -m | awk 'NR==3{print $3}')
    swap_total=$(free -m | awk 'NR==3{print $2}')

    if [ -z "$swap_total" ] || [ "$swap_total" -eq 0 ]; then
        swap_percentage=0
    else
        swap_percentage=$((swap_used * 100 / swap_total))
    fi
    swap_info="${swap_used:-0}MB/${swap_total:-0}MB (${swap_percentage}%)"
    runtime=$(cat /proc/uptime | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')
    
    echo ""
    echo -e "${white}系统信息详情${re}"
    echo "------------------------"
    echo -e "${white}主机名: ${purple}${hostname}${re}"
    echo -e "${white}运营商: ${purple}${isp_info}${re}"
    echo "------------------------"
    echo -e "${white}系统版本: ${purple}${os_info}${re}"
    echo -e "${white}Linux版本: ${purple}${kernel_version}${re}"
    echo "------------------------"
    echo -e "${white}CPU架构: ${purple}${cpu_arch}${re}"
    echo -e "${white}CPU型号: ${purple}${cpu_info}${re}"
    echo -e "${white}CPU核心数: ${purple}${cpu_cores}${re}"
    echo "------------------------"
    echo -e "${white}CPU占用: ${purple}${cpu_usage_percent}${re}"
    echo -e "${white}物理内存: ${purple}${mem_info}${re}"
    echo -e "${white}虚拟内存: ${purple}${swap_info}${re}"
    echo -e "${white}硬盘占用: ${purple}${disk_info}${re}"
    echo "------------------------"
    echo -e "${purple}$monthly_output${re}"
    echo "------------------------"
    echo -e "${white}网络拥堵算法: ${purple}${congestion_algorithm} ${queue_algorithm}${re}"
    echo "------------------------"
    echo -e "${white}公网IPv4地址: ${purple}${ipv4_address}${re}"
    echo -e "${white}公网IPv6地址: ${purple}${ipv6_address}${re}"
    echo "------------------------"
    echo -e "${white}地理位置: ${purple}${country} $city${re}"
    echo -e "${white}系统时间: ${purple}${current_time}${re}"
    echo "------------------------"
    echo -e "${white}系统运行时长: ${purple}${runtime}${re}"
    echo
}

# singbox 管理
manage_singbox() {
    # 检查sing-box状态
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?
    
    clear
    echo ""
    green "=== sing-box 管理 ===\n"
    printf "${purple}singbox 状态: %s${re}\n\n" "$(to_chinese "$singbox_status")"
    green "1. 启动sing-box服务"
    skyblue "-------------------"
    green "2. 停止sing-box服务"
    skyblue "-------------------"
    green "3. 重启sing-box服务"
    skyblue "-------------------"
    green "4. Tunnel 隧道连接 IP：自动"
    green "5. Tunnel 隧道连接 IP：仅IPv4"
    green "6. Tunnel 隧道连接 IP：仅IPv6"
	green "7. CDN IP同步管理"
	green "8. 检查sing-box"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox ;;  
        2) stop_singbox ;;
        3) restart_singbox ;;
		4)
           jq '.inbounds[] |= if .type == "cloudflared" then .edge_ip_version = 0 else . end' \
           /etc/sing-box/conf/cloudflared.json > /tmp/cloudflared.json &&
           mv /tmp/cloudflared.json /etc/sing-box/conf/cloudflared.json
           systemctl reload sing-box
           green "隧道连接 IP 已切换为：自动"
           ;;
5)
    jq '.inbounds[] |= if .type == "cloudflared" then .edge_ip_version = 4 else . end' \
        /etc/sing-box/conf/cloudflared.json > /tmp/cloudflared.json &&
    mv /tmp/cloudflared.json /etc/sing-box/conf/cloudflared.json
    systemctl reload sing-box
    green "隧道连接 IP 已切换为：仅IPv4"
    ;;
6)
    jq '.inbounds[] |= if .type == "cloudflared" then .edge_ip_version = 6 else . end' \
        /etc/sing-box/conf/cloudflared.json > /tmp/cloudflared.json &&
    mv /tmp/cloudflared.json /etc/sing-box/conf/cloudflared.json
    systemctl reload sing-box
    green "隧道连接 IP 已切换为：仅IPv6"
    ;;
7)
    cdn_ip_manager
    ;;
8) 
    clear
    bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing-boxjc.sh)
    ;;
        0) menu ;;
        *) red "无效的选项！" && sleep 1 && manage_singbox;;
    esac
}            

# cf 管理
manage_cf() {
clear
skyblue "请选择 Cloudflare 验证方式："
echo -e " ${green}1)${re} Cloudflare API Token"
echo -e " ${green}2)${re} Cloudflare Global API Key"
local auth_choice
reading "请输入选择 [1-2]（默认 1）: " auth_choice
[[ -z "$auth_choice" ]] && auth_choice=1
case "$auth_choice" in
    1)
        cf_auth_token || return 1
        ;;
    2)
        cf_auth_global || return 1
        ;;
    *)
        red "无效选择！"
        return 1
        ;;
esac
while true; do
    echo -e "${skyblue}==========================================${re}"
    echo -e "${skyblue}        Cloudflare ${re}"
    echo -e "${skyblue}==========================================${re}"
    green "1. 查看隧道"
    green "2. 添加隧道路由"
    green "3. 添加dns解析"
    green "4. 删除dns解析"
    green "5. 新建回源规则"
    green "6. 删除回源规则"
    echo -e "  ${red}0)${re} 返回"
    echo -e "${skyblue}==========================================${re}"
    local cf_tunnel_choice
    reading "请输入选择 [0-7]: " cf_tunnel_choice
    case "$cf_tunnel_choice" in
        1)
            clear
            if ! cf_get_account_id; then
                red "获取 Cloudflare Account ID 失败！"
            else
                cf_list_tunnels
            fi
            echo
            reading "按回车返回..." _
            clear
            ;;
        2)
            cf_add_tunnel_route
            ;;
        3)
            cf_auth_token || return 1
            cf_select_zone || return 1
            local subdomain domain raw_ip server_ip
            server_ip=$(get_realip)
            echo
            green "检测到本机公网 IP: $server_ip"
            reading "请输入主机记录（例如 www，直接回车表示根域名）: " subdomain
            reading "请输入 IP 地址（直接回车使用本机 IP）: " raw_ip
            [[ -z "$raw_ip" ]] && raw_ip="$server_ip"
            if [[ -z "$subdomain" || "$subdomain" == "@" ]]; then
                domain="$zone_domain"
            else
                domain="${subdomain}.${zone_domain}"
            fi
            cf_upsert_dns "$zone_id" "$domain" "$raw_ip"
            green "DNS 解析添加成功"
            green "$domain → $raw_ip"
            ;;
        4)
            while true; do
                cf_select_zone || break
                cf_select_dns_record_menu
            done
            ;;
        5)
            clear
            cf_add_origin_rule_menu
            echo
            reading "按回车返回..." _
            clear
            ;;
        6)
            clear
            cf_delete_origin_rule_menu
            echo
            reading "按回车返回..." _
            clear
            ;;
        0)
            break
            ;;
        *)
            red "无效的选项！"
            ;;
    esac
done
}

# 查看节点信息和订阅链接
check_nodes() {
    local sub_file="${work_dir}/sub.txt"
    if [ -f "$sub_file" ]; then
        green "================ sub.txt ================"
        echo
		echo
		purple "$(cat "$sub_file")"
        echo
        echo
        green "=========================================="
    else
        red "sub.txt 文件不存在：$sub_file"
    fi
    local nginx_conf="/etc/nginx/conf.d/sing-box.conf"
    local domain_conf="/etc/nginx/conf.d/sing-box1.conf"
    local found_any=false
    if [ -f "$domain_conf" ]; then
        local sub_domain=$(sed -n 's/^\s*server_name\s\+\([^;]\+\);.*/\1/p' "$domain_conf" | tr -d ' ')
        local sub_port=$(sed -n 's/^\s*listen\s\+\([0-9]\+\).*/\1/p' "$domain_conf" | head -n 1)
        local sub_path=$(sed -n 's|.*location = /\([^ {]*\).*|\1|p' "$domain_conf")
        if [ -n "$sub_domain" ] && [ "$sub_domain" != "_" ]; then
            local domain_url="https://${sub_domain}:${sub_port}/${sub_path}"
            green "订阅链接: ${purple}${domain_url}${re}"
            found_any=true
        fi
    fi
    if [ -f "$nginx_conf" ]; then
        server_ip=$(get_realip)
        lujing=$(sed -n 's|.*location = /\([^ ]*\).*|\1|p' "$nginx_conf")
        sub_port=$(sed -n 's/^\s*listen \([0-9]\+\);/\1/p' "$nginx_conf")
        base64_url="http://${server_ip}:${sub_port}/${lujing}"
        green "订阅链接: ${purple}${base64_url}${re}"
        found_any=true
    fi
    if [ "$found_any" = false ]; then
        red "订阅服务未配置或订阅已关闭"
    fi
}
