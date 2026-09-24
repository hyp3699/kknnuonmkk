
is_cf_supported_port() {
    local port="$1"
    case "$port" in
        80|8080|8880|2052|2082|2086|2095|\
        443|2053|2083|2087|2096|8443)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 修改sing-box节点uuid
modify_inbound_uuid() {
    local config_file="$1"
    local inbound_type="$3"
    local inbound_number="$4"
    local username="$5"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local protocol=""
    local old_value=""
    local new_uuid=""
    local auth_type=""
    if [ ! -f "$config_file" ]; then
        red "配置文件不存在：$config_file"
        sleep 1
        return 1
    fi
    if [ -z "$username" ]; then
        red "未获取到指定用户名"
        sleep 1
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        red "未安装 jq，无法修改 UUID"
        sleep 1
        return 1
    fi
    protocol=$(jq -r '.inbounds[0].type // empty' "$config_file" 2>/dev/null)
    if [ -z "$protocol" ]; then
        red "无法读取入站类型"
        sleep 1
        return 1
    fi
    auth_type=$(jq -r --arg username "$username" '
        .inbounds[0].users[]? |
        select(.name == $username) |
        if (.uuid != null and .uuid != "") then
            "uuid"
        elif (.password != null and .password != "") then
            "password"
        else
            ""
        end
    ' "$config_file" 2>/dev/null | head -n 1)
    if [ -z "$auth_type" ]; then
        red "指定用户名不存在，或该用户没有 UUID / password"
        sleep 1
        return 1
    fi
    old_value=$(jq -r --arg username "$username" --arg auth_type "$auth_type" '
        .inbounds[0].users[]? |
        select(.name == $username) |
        if $auth_type == "uuid" then
            .uuid
        else
            .password
        end
    ' "$config_file" 2>/dev/null | head -n 1)
    if [ -z "$old_value" ] || [ "$old_value" = "null" ]; then
        red "当前用户没有可修改的 UUID"
        sleep 1
        return 1
    fi
    new_uuid=$(cat /proc/sys/kernel/random/uuid)
    jq --arg username "$username" --arg uuid "$new_uuid" --arg auth_type "$auth_type" '
        if (.inbounds[0].users? | type) == "array" then
            .inbounds[0].users |= map(
                if .name == $username then
                    if $auth_type == "uuid" then
                        .uuid = $uuid
                    else
                        .password = $uuid
                    end
                else
                    .
                end
            )
        else
            .
        end
    ' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
    if [ $? -ne 0 ]; then
        red "UUID 修改失败"
        rm -f "$config_file.tmp"
        sleep 1
        return 1
    fi
    if [ ! -f "$url_file" ]; then
        red "链接文件不存在：$url_file"
        systemctl reload sing-box
        sleep 1
        return 1
    fi
    case "$protocol" in
        tuic)
            sed -i "s#tuic://${old_value}:#tuic://${new_uuid}:#g" "$url_file"
            ;;
        vmess)
            while IFS= read -r line; do
                case "$line" in
                    vmess://*)
                        vmess_b64="${line#vmess://}"
                        vmess_json=$(printf '%s' "$vmess_b64" | base64 -d 2>/dev/null)
                        [ -z "$vmess_json" ] && continue
                        vmess_id=$(printf '%s' "$vmess_json" | jq -r '.id // empty' 2>/dev/null)
                        [ "$vmess_id" = "$old_value" ] || continue
                        new_vmess_json=$(printf '%s' "$vmess_json" | jq --arg uuid "$new_uuid" '.id = $uuid' 2>/dev/null)
                        [ -z "$new_vmess_json" ] && continue
                        new_vmess_b64=$(printf '%s' "$new_vmess_json" | base64 -w0)
                        sed -i "s#^vmess://.*#vmess://${new_vmess_b64}#" "$url_file"
                        break
                        ;;
                esac
            done < "$url_file"
            ;;
        *)
            for scheme in vless hysteria2 anytls trojan; do
                if grep -Fq "${scheme}://${old_value}@" "$url_file"; then
                    sed -i "s#${scheme}://${old_value}@#${scheme}://${new_uuid}@#g" "$url_file"
                    break
                fi
            done
            ;;
    esac
    update_sub_file
    green "==============================================="
    green " UUID 修改完成"
    green "用户名：${username}"
    green "入站：${inbound_type}-${inbound_number}"
    green "新 UUID：${new_uuid}"
    green "==============================================="
    echo
    systemctl reload sing-box
    sleep 2
    read -n 1 -s -r -p "按任意键返回..."
    echo
    return 0
}

#修改reality  sni
modify_reality_domain() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local new_sni
    if [ ! -f "$config_file" ]; then
        red "配置文件不存在：$config_file"
        sleep 1
        return 1
    fi
    if ! jq -e '.inbounds[0].tls.enabled == true and .inbounds[0].tls.reality.enabled == true' "$config_file" >/dev/null 2>&1; then
        red "当前入站不是 Reality 配置"
        sleep 1
        return 1
    fi
    clear
    green "================ 修改 Reality 域名 ================"
    echo
    green "1. www.joom.com"
    green "2. www.stengg.com"
    green "3. www.wedgehr.com"
    green "4. www.cerebrium.ai"
    green "5. www.nazhumi.com"
    green "6. addons.mozilla.org"
    green "7. www.iij.ad.jp"
    green "8. 自定义域名"
    echo
    reading "请输入新的Reality伪装域名序号(回车使用默认1): " new_sni
    case "$new_sni" in
        1|"") new_sni="www.joom.com" ;;
        2) new_sni="www.stengg.com" ;;
        3) new_sni="www.wedgehr.com" ;;
        4) new_sni="www.cerebrium.ai" ;;
        5) new_sni="www.nazhumi.com" ;;
        6) new_sni="addons.mozilla.org" ;;
        7) new_sni="www.iij.ad.jp" ;;
        8)
            reading "请输入自定义的伪装域名(例如 www.example.com): " new_sni
            [ -z "$new_sni" ] && new_sni="www.joom.com"
            ;;
        *)
            red "无效选项"
            sleep 1
            return 1
            ;;
    esac
    jq --arg sni "$new_sni" '
        .inbounds[0].tls.server_name = $sni |
        .inbounds[0].tls.reality.handshake.server = $sni
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    if [ $? -ne 0 ]; then
        red "Reality 域名修改失败"
        rm -f "${config_file}.tmp"
        sleep 1
        return 1
    fi
    if [ -f "$url_file" ]; then
        sed -i "s/sni=[^&]*/sni=$new_sni/g" "$url_file"
        update_sub_file
    else
        yellow "对应链接文件不存在：$url_file"
    fi    
    systemctl reload sing-box
    echo
    green "==============================================="
    green " Reality SNI 已修改"
    green "入站：${inbound_type}-${inbound_number}"
    green "新域名：${new_sni}"
    green "==============================================="
    echo
    sleep 1
    return 0
}
hy2_port_hopping() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local listen_port=""
    local min_port=""
    local max_port=""
    local ip=""
    local uuid=""
    local key_path=""
    local custom_sni=""
    local url_param=""
    local obfs_param=""
    local old_url=""
    local old_obfs=""
    local node_remark=""
    local hy2_link=""
    local hop_comment="Hysteria2_Hop_${inbound_number}"
    local check_cmds=("nft" "curl" "shuf" "python3")
    local install_pkgs=("nftables" "curl" "coreutils" "python3")
    local i
    if [ "$engine" != "sing-box" ] || [ "$inbound_type" != "hysteria2" ]; then
        red "当前入站不是 Hysteria2"
        sleep 1
        return 1
    fi
    if [ ! -f "$config_file" ]; then
        red "配置文件不存在：$config_file"
        sleep 1
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        red "未安装 jq，无法读取 Hysteria2 配置"
        sleep 1
        return 1
    fi
    listen_port=$(jq -r '.inbounds[0].listen_port // empty' "$config_file" 2>/dev/null)
    if [ -z "$listen_port" ] || [ "$listen_port" = "null" ]; then
        red "无法获取 Hysteria2 监听端口"
        sleep 1
        return 1
    fi
    if [ -f "$url_file" ]; then
        old_url=$(cat "$url_file")
        old_obfs=$(printf '%s' "$old_url" | grep -oP 'obfs=gecko&obfs-password=[^&#]+&obfs-min=[^&#]+&obfs-max=[^&#]+' | head -n1)
    fi
    clear
    green "================ Hysteria2 端口跳跃 ================"
    echo
    green "入站：${inbound_type}-${inbound_number}"
    green "配置：${config_file}"
    green "监听端口：${listen_port}"
    if [ -n "$old_obfs" ]; then
        green "检测到 Gecko 混淆：保留现有混淆参数"
    else
        yellow "未检测到 Gecko 混淆"
    fi
    echo
    purple "端口跳跃需确保跳跃区间的端口没有被占用，NAT机请注意可用端口范围。"
    echo
    for i in "${!check_cmds[@]}"; do
        if ! command -v "${check_cmds[$i]}" >/dev/null 2>&1; then
            yellow "检测到缺少依赖 ${install_pkgs[$i]}，正在安装..."
            if [ -f /etc/debian_version ]; then
                apt-get update && apt-get install -y "${install_pkgs[$i]}"
            elif [ -f /etc/redhat-release ]; then
                yum install -y "${install_pkgs[$i]}"
            elif [ -f /etc/alpine-release ]; then
                apk add --no-cache "${install_pkgs[$i]}"
            fi
        fi
    done
    for i in "${!check_cmds[@]}"; do
        if ! command -v "${check_cmds[$i]}" >/dev/null 2>&1; then
            red "缺少依赖：${check_cmds[$i]}"
            sleep 1
            return 1
        fi
    done
    reading "请输入跳跃起始端口: " min_port
    while [ -z "$min_port" ]; do
        red "不能为空，请重新输入: "
        read -r min_port
    done
    if ! [[ "$min_port" =~ ^[0-9]+$ ]] || [ "$min_port" -lt 1 ] || [ "$min_port" -gt 65535 ]; then
        red "起始端口无效"
        sleep 1
        return 1
    fi
    yellow "起始端口为：$min_port"
    reading "请输入跳跃结束端口 (需大于起始端口，回车默认+100): " max_port
    [ -z "$max_port" ] && max_port=$((min_port + 100))
    if ! [[ "$max_port" =~ ^[0-9]+$ ]] || [ "$max_port" -gt 65535 ] || [ "$max_port" -le "$min_port" ]; then
        red "结束端口无效，必须大于起始端口且不能超过 65535"
        sleep 1
        return 1
    fi
    yellow "结束端口为：$max_port"
    echo
    purple "正在设置 ${inbound_type}-${inbound_number} 端口跳跃规则..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    nft add table ip hysteria_nat 2>/dev/null
    nft 'add chain ip hysteria_nat prerouting { type nat hook prerouting priority -100; policy accept; }' 2>/dev/null
    if nft list chain ip hysteria_nat prerouting >/dev/null 2>&1; then
        for handle in $(nft -a list chain ip hysteria_nat prerouting 2>/dev/null | awk -v c="$hop_comment" '$0 ~ c {print $NF}'); do
            nft delete rule ip hysteria_nat prerouting handle "$handle" 2>/dev/null
        done
    fi
    nft add rule ip hysteria_nat prerouting udp dport "$min_port"-"$max_port" dnat to :"$listen_port" comment "$hop_comment" 2>/dev/null
    if [ -f /proc/net/if_inet6 ]; then
        nft add table ip6 hysteria_nat 2>/dev/null
        nft 'add chain ip6 hysteria_nat prerouting { type nat hook prerouting priority -100; policy accept; }' 2>/dev/null
        if nft list chain ip6 hysteria_nat prerouting >/dev/null 2>&1; then
            for handle in $(nft -a list chain ip6 hysteria_nat prerouting 2>/dev/null | awk -v c="$hop_comment" '$0 ~ c {print $NF}'); do
                nft delete rule ip6 hysteria_nat prerouting handle "$handle" 2>/dev/null
            done
        fi
        nft add rule ip6 hysteria_nat prerouting udp dport "$min_port"-"$max_port" dnat to :"$listen_port" comment "$hop_comment" 2>/dev/null
    fi
    nft list ruleset > /etc/nftables.conf 2>/dev/null
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables >/dev/null 2>&1
        systemctl start nftables >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add nftables default 2>/dev/null
    fi
    if [ -f "$url_file" ]; then
        uuid=$(grep -oP 'hysteria2://\K[^@]+' "$url_file" | head -n1)
    fi
    if [ -z "$uuid" ]; then
        uuid=$(jq -r '.inbounds[0].users[0].password // .inbounds[0].users[0].uuid // empty' "$config_file" 2>/dev/null)
    fi
    if [ -z "$uuid" ]; then
        red "无法获取 Hysteria2 UUID/密码"
        sleep 1
        return 1
    fi
    ip=$(get_realip)
    key_path=$(jq -r '.inbounds[0].tls.key_path // empty' "$config_file" 2>/dev/null)
    if [[ "$key_path" =~ /root/cert/([^/]+)/ ]]; then
        custom_sni="${BASH_REMATCH[1]}"
        url_param="sni=${custom_sni}"
    else
        custom_sni="www.bing.com"
        url_param="insecure=0&sni=www.bing.com"
    fi
    node_remark="${inbound_type}-${inbound_number}"
    if [ -n "$old_obfs" ]; then
        obfs_param="$old_obfs"
    fi
    if [ -n "$obfs_param" ]; then
        echo "hysteria2://${uuid}@${ip}:${listen_port}?${url_param}&alpn=h3&${obfs_param}&mport=${listen_port},${min_port}-${max_port}#${node_remark}" > "$url_file"
    else
        echo "hysteria2://${uuid}@${ip}:${listen_port}?${url_param}&alpn=h3&mport=${listen_port},${min_port}-${max_port}#${node_remark}" > "$url_file"
    fi
    update_sub_file
    systemctl reload sing-box
    hy2_link=$(cat "$url_file")
    echo
    green "Hysteria2-${inbound_number} 端口跳跃已开启"
    if [ -n "$obfs_param" ]; then
        green "已保留 Gecko 混淆参数"
    fi
    green "$hy2_link"
    green "=================================================="
    purple "跳跃区间：$min_port-$max_port"
    echo
    sleep 1
    return 0
}
disable_hy2_port_hopping() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local hop_comment="Hysteria2_Hop_${inbound_number}"
    local hy2_link=""
    if [ "$engine" != "sing-box" ] || [ "$inbound_type" != "hysteria2" ]; then
        red "当前入站不是 Hysteria2"
        sleep 1
        return 1
    fi
    if [ ! -f "$config_file" ]; then
        red "配置文件不存在：$config_file"
        sleep 1
        return 1
    fi
    clear
    green "================ 关闭端口跳跃 ================"
    echo
    green "入站：${inbound_type}-${inbound_number}"
    echo
    purple "正在清理 ${inbound_type}-${inbound_number} 端口跳跃规则..."
    if nft list chain ip hysteria_nat prerouting &>/dev/null; then
        for handle in $(nft -a list chain ip hysteria_nat prerouting 2>/dev/null | awk -v c="$hop_comment" '$0 ~ c {print $NF}'); do
            nft delete rule ip hysteria_nat prerouting handle "$handle" 2>/dev/null
        done
    fi
    if [ -f /proc/net/if_inet6 ] && nft list chain ip6 hysteria_nat prerouting &>/dev/null; then
        for handle in $(nft -a list chain ip6 hysteria_nat prerouting 2>/dev/null | awk -v c="$hop_comment" '$0 ~ c {print $NF}'); do
            nft delete rule ip6 hysteria_nat prerouting handle "$handle" 2>/dev/null
        done
    fi
    nft list ruleset > /etc/nftables.conf 2>/dev/null
    if [ -f "$url_file" ]; then
        sed -i -E 's/&mport=[^#&]*//g;s/[?&]mport=[^#&]*//g' "$url_file"
        update_sub_file
        hy2_link=$(cat "$url_file")
    fi
    systemctl reload sing-box
    echo
    green "[✔] ${inbound_type}-${inbound_number} 端口跳跃已关闭"
    if [ -n "$hy2_link" ]; then
        green "$hy2_link"
    fi
    echo
    sleep 1
}
modify_hy2_obfs() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local obfs_pwd=""
    local old_url=""
    local mport_param=""
    local hy2_link=""
    if [ "$engine" != "sing-box" ] || [ "$inbound_type" != "hysteria2" ]; then
        red "当前入站不是 Hysteria2"
        sleep 1
        return 1
    fi
    if [ ! -f "$config_file" ] || [ ! -f "$url_file" ]; then
        red "当前 Hysteria2 配置或链接文件不存在"
        sleep 1
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        yellow "检测到缺少依赖 python3，正在安装..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y python3
        elif [ -f /etc/redhat-release ]; then
            yum install -y python3
        elif [ -f /etc/alpine-release ]; then
            apk add --no-cache python3
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        red "python3 安装失败"
        sleep 1
        return 1
    fi
    old_url=$(cat "$url_file")
    mport_param=$(printf '%s' "$old_url" | grep -oP 'mport=[^#&]+' | head -n1)
    obfs_pwd=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 20)
    if ! python3 - "$config_file" "$obfs_pwd" <<'PY'
import json
import sys
path = sys.argv[1]
obfs_pwd = sys.argv[2]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get('inbounds'), list):
        sys.exit(1)
    found = False
    for ib in data['inbounds']:
        if isinstance(ib, dict) and ib.get('type') == 'hysteria2':
            ib['obfs'] = {
                'type': 'gecko',
                'password': obfs_pwd,
                'min_packet_size': 512,
                'max_packet_size': 1200
            }
            found = True
    if not found:
        sys.exit(1)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception:
    sys.exit(1)
PY
    then
        red "Hysteria2 Gecko 混淆配置失败"
        sleep 1
        return 1
    fi
    sed -i -E 's/&obfs=[^&#]+//g;s/&obfs-password=[^&#]+//g;s/&obfs-min=[^&#]+//g;s/&obfs-max=[^&#]+//g' "$url_file"
    if [ -n "$mport_param" ]; then
        sed -i -E "s/&alpn=h3/&obfs=gecko\&obfs-password=${obfs_pwd}\&obfs-min=512\&obfs-max=1200\&alpn=h3\&${mport_param}/" "$url_file"
    else
        sed -i -E "s/&alpn=h3/&obfs=gecko\&obfs-password=${obfs_pwd}\&obfs-min=512\&obfs-max=1200\&alpn=h3/" "$url_file"
    fi
    update_sub_file
    systemctl reload sing-box
    hy2_link=$(cat "$url_file")
    echo
    green "=================================================="
    green "${inbound_type}-${inbound_number} Hysteria2 Gecko 混淆已开启"
    green "=================================================="
    green "$hy2_link"
    green "=================================================="
    echo
    sleep 1
}
disable_hy2_obfs() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local hy2_link=""
    if [ "$engine" != "sing-box" ] || [ "$inbound_type" != "hysteria2" ]; then
        red "当前入站不是 Hysteria2"
        sleep 1
        return 1
    fi
    if [ ! -f "$config_file" ]; then
        red "配置文件不存在：$config_file"
        sleep 1
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        red "未安装 python3，无法修改配置"
        sleep 1
        return 1
    fi
    python3 - "$config_file" <<'PY'
import json
import sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get('inbounds'), list):
        sys.exit(1)
    found = False
    for ib in data['inbounds']:
        if isinstance(ib, dict) and ib.get('type') == 'hysteria2':
            ib.pop('obfs', None)
            found = True
    if not found:
        sys.exit(1)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception:
    sys.exit(1)
PY
    if [ $? -ne 0 ]; then
        red "关闭 Gecko 混淆失败"
        sleep 1
        return 1
    fi
    if [ -f "$url_file" ]; then
        sed -i -E 's/&obfs=[^&#]+//g;s/&obfs-password=[^&#]+//g;s/&obfs-min=[^&#]+//g;s/&obfs-max=[^&#]+//g' "$url_file"
        update_sub_file
        hy2_link=$(cat "$url_file")
    fi
    systemctl reload sing-box
    echo
    green "=================================================="
    green "${inbound_type}-${inbound_number} Hysteria2 Gecko 混淆已关闭"
    green "=================================================="
    if [ -n "$hy2_link" ]; then
        green "$hy2_link"
    fi
    green "=================================================="
    echo
    sleep 1
}
# 优化并设置 DNS 
optimize_dns() {
    local cloudflare_ipv4="1.1.1.1"
    local google_ipv4="8.8.8.8"
    local cloudflare_ipv6="2606:4700:4700::1111"
    local google_ipv6="2001:4860:4860::8888"

    local ipv6_available=0
    if [[ $(ip -6 addr | grep -c "inet6") -gt 0 ]]; then
        ipv6_available=1
    fi

    echo "nameserver $cloudflare_ipv4" > /etc/resolv.conf
    echo "nameserver $google_ipv4" >> /etc/resolv.conf

    if [[ $ipv6_available -eq 1 ]]; then
        echo "nameserver $cloudflare_ipv6" >> /etc/resolv.conf
        echo "nameserver $google_ipv6" >> /etc/resolv.conf
    fi
}






update_sub_file() {
    local url_file
    local tmp_file="/tmp/sing-box-sub.txt"
    mkdir -p "$URL_DIR"
    : > "$tmp_file"
    shopt -s nullglob
    for url_file in "$URL_DIR"/*.txt; do
        [ -f "$url_file" ] || continue
        cat "$url_file" >> "$tmp_file"
        echo >> "$tmp_file"
    done
    shopt -u nullglob
    base64 -w0 "$tmp_file" > "$SUB_FILE" 2>/dev/null
    rm -f "$tmp_file"
}
add_v2ray_api_user() {
    local username="$1"
    local config="/etc/sing-box/conf/config.json"
    local tmp="${config}.tmp"
    jq --arg username "$username" '.experimental.v2ray_api.stats.users += [$username] | .experimental.v2ray_api.stats.users |= unique' "$config" > "$tmp" && mv -f "$tmp" "$config"
}
delete_v2ray_api_user() {
    local username="$1"
    local config="/etc/sing-box/conf/config.json"
    local tmp="${config}.tmp"
    [ -n "$username" ] || return 0
    [ -f "$config" ] || return 0
    jq --arg username "$username" '.experimental.v2ray_api.stats.users |= map(select(. != $username))' "$config" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$config"
}
enable_ws_cdn() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local uuid=""
    local password=""
    local ws_path=""
    local origin_port=""
    local domain=""
    local zone_id=""
    local cf_ssl_mode="flexible"
    local cdn_url=""
    local node_remark_cdn=""
    local node_remark_enc=""
    local url_file=""
    if [ ! -f "$config_file" ]; then
        red "入站配置文件不存在：$config_file"
        sleep 1
        return 1
    fi
	generate_vars
    if ! server_ip=$(get_realip); then
    red "无法获取服务器公网 IP，请检查网络后重试"
    sleep 2
    return 1
    fi
    uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$config_file" 2>/dev/null)
    password=$(jq -r '.inbounds[0].users[0].password // empty' "$config_file" 2>/dev/null)
    ws_path=$(jq -r '.inbounds[0].transport.path // empty' "$config_file" 2>/dev/null)
    origin_port=$(jq -r '.inbounds[0].listen_port // empty' "$config_file" 2>/dev/null)
    case "$inbound_type" in
        vless-ws|vmess-ws|vless-xhttp)
            if [ -z "$uuid" ]; then
                red "无法读取 UUID"
                sleep 1
                return 1
            fi
            ;;
        trojan-ws)
            if [ -z "$password" ]; then
                red "无法读取 Trojan 密码"
                sleep 1
                return 1
            fi
            ;;
    esac
    if [ -z "$ws_path" ]; then
        red "无法读取 WebSocket Path"
        sleep 1
        return 1
    fi
    if [ -z "$origin_port" ]; then
        red "无法读取入站端口"
        sleep 1
        return 1
    fi
    if [[ -z "${CF_TOKEN:-}" && ( -z "${CF_EMAIL:-}" || -z "${CF_KEY:-}" ) ]]; then
    skyblue "请选择 Cloudflare 验证方式："
    green " 1) Cloudflare API Token"
    green " 2) Cloudflare Global API Key"
    local cf_auth_type
    reading "请输入选择 [1-2]（默认 1）: " cf_auth_type
    [[ -z "$cf_auth_type" ]] && cf_auth_type=1
    case "$cf_auth_type" in
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
fi
if [[ -z "${CF_TOKEN:-}" && ( -z "${CF_EMAIL:-}" || -z "${CF_KEY:-}" ) ]]; then
    yellow "未获得有效的 Cloudflare API 凭据"
    return 1
fi
cf_select_zone || return 1
reading "请输入域名前缀（留空使用 ${zone_domain}）: " prefix
prefix=$(echo "$prefix" | tr -d '[:space:]')
prefix="${prefix#.}"
prefix="${prefix%.}"
if [[ -n "$prefix" && ! "$prefix" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    red "域名前缀格式无效！"
    return 1
fi
if [[ -n "$prefix" ]]; then
    domain="${prefix}.${zone_domain}"
else
    domain="$zone_domain"
fi
if [ -z "$domain" ] || [ -z "$selected_zone_id" ]; then
    red "未获取到 Cloudflare 域名或 Zone ID"
    sleep 1
    return 1
fi
zone_id="$selected_zone_id"
green "Cloudflare 域名：$domain"
green "Cloudflare Zone：$zone_id"
if cf_upsert_dns "$zone_id" "$domain" "$server_ip"; then
    green "Cloudflare DNS 配置成功"
else
    yellow "警告：Cloudflare DNS 配置失败"
fi
if jq -e '.inbounds[0].tls' "$config_file" >/dev/null 2>&1; then
    cf_ssl_mode="full"
else
    cf_ssl_mode="flexible"
fi
if cf_set_ssl "$zone_id" "$cf_ssl_mode"; then
    green "Cloudflare SSL 模式已设置为：$cf_ssl_mode"
else
    yellow "警告：Cloudflare SSL 模式设置失败"
fi
if set_domain_origin_port "$zone_id" "$domain" "$origin_port"; then
    green "Cloudflare CDN 回源规则配置成功"
    green "回源端口：$origin_port"
else
    yellow "警告：Cloudflare CDN 回源规则配置失败"
fi
    node_remark_cdn="${isp}_${inbound_type}_cdn"
    node_remark_enc=$(printf '%s' "$node_remark_cdn" | jq -sRr @uri)
    case "$inbound_type" in
        vless-ws)
            cdn_url="vless://${uuid}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}?ed=2048#${node_remark_enc}"
            ;;
        vmess-ws)
            local vmess_json=""
            vmess_json="{ \"v\": \"2\", \"ps\": \"${node_remark_cdn}\", \"add\": \"${CFIP}\", \"port\": \"443\", \"id\": \"${uuid}\", \"aid\": \"0\", \"encryption\": \"auto\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"${domain}\", \"path\": \"${ws_path}?ed=2048\", \"tls\": \"tls\", \"sni\": \"${domain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": false }"
            cdn_url="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
            ;;
        trojan-ws)
            cdn_url="trojan://${password}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}?ed=2048#${node_remark_enc}"
            ;;
		vless-xhttp)
            cdn_url="vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain}&type=xhttp&host=${domain}&path=${ws_path}#${node_remark_enc}"
            ;;
        *)
            red "当前入站类型不支持 CDN：$inbound_type"
            return 1
            ;;
    esac
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    mkdir -p "$URL_DIR"
    if [ -f "$url_file" ]; then
        sed -i "/#${node_remark_enc}$/d" "$url_file"
    fi
    echo "$cdn_url" >> "$url_file"
    if [ -f "${work_dir}/url.txt" ]; then
        sed -i "/#${node_remark_enc}$/d" "${work_dir}/url.txt"
    fi
    echo "$cdn_url" >> "${work_dir}/url.txt"
    echo "" >> "${work_dir}/url.txt"
    base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt" 2>/dev/null
    green "============================================"
    green "CDN 配置完成"
    green "域名：${domain}"
    green "Cloudflare IP：${CFIP}"
    green "回源端口：${origin_port}"
    green "SSL 模式：${cf_ssl_mode}"
    green "CDN 节点链接："
	echo
    red "$cdn_url"
    echo
    green "============================================"
    read -rp "按回车返回..." _
}
enable_ws_argo() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local uuid password ws_path origin_port
    local node_remark node_remark_enc
    local argo_url url_file
    uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$config_file" 2>/dev/null)
    password=$(jq -r '.inbounds[0].users[0].password // empty' "$config_file" 2>/dev/null)
    ws_path=$(jq -r '.inbounds[0].transport.path // empty' "$config_file" 2>/dev/null)
    origin_port=$(jq -r '.inbounds[0].listen_port // empty' "$config_file" 2>/dev/null)
    if [ -z "$origin_port" ] || [ "$origin_port" = "null" ]; then
        red "未获取到入站端口！"
        read -rp "按回车返回..." _
        return 1
    fi
    if [ -z "$ws_path" ] || [ "$ws_path" = "null" ]; then
        ws_path="/"
    fi
    [[ "$ws_path" != /* ]] && ws_path="/$ws_path"
    skyblue "正在添加 Cloudflare Tunnel..."
    green "当前入站：${inbound_type}-${inbound_number}"
    green "本地端口：${origin_port}"
    green "WS Path：${ws_path}"
    echo
    if ! cf_add_tunnel_route "$origin_port" "$ws_path"; then
        red "Cloudflare Tunnel 路由添加失败！"
        read -rp "按回车返回..." _
        return 1
    fi
    domain="${ArgoDomain:-}"
    if [ -z "$domain" ]; then
        red "未获取到 Tunnel 域名！"
        read -rp "按回车返回..." _
        return 1
    fi
    case "$inbound_type" in
        vless-ws)
            if [ -z "$uuid" ]; then
                red "未获取到 UUID！"
                read -rp "按回车返回..." _
                return 1
            fi
            node_remark="${isp}_Tunnelvless_ws"
            node_remark_enc=$(echo -n "$node_remark" | jq -sRr @uri)
            argo_url="vless://${uuid}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}?ed=2048#${node_remark_enc}"
            ;;
        vmess-ws)
            if [ -z "$uuid" ]; then
                red "未获取到 UUID！"
                read -rp "按回车返回..." _
                return 1
            fi
            node_remark="${isp}_Tunnelvmess_ws"
            VMESS="{ \"v\": \"2\", \"ps\": \"${node_remark}\", \"add\": \"${CFIP}\", \"port\": \"443\", \"id\": \"${uuid}\", \"aid\": \"0\", \"encryption\": \"auto\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"${domain}\", \"path\": \"${ws_path}?ed=2048\", \"tls\": \"tls\", \"sni\": \"${domain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": false }"
            argo_url="vmess://$(echo -n "$VMESS" | base64 -w0)"
            ;;
        trojan-ws)
            if [ -z "$password" ]; then
                red "未获取到 Trojan password！"
                read -rp "按回车返回..." _
                return 1
            fi
            node_remark="${isp}_Tunneltrojan_ws"
            node_remark_enc=$(echo -n "$node_remark" | jq -sRr @uri)
            argo_url="trojan://${password}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}?ed=2048#${node_remark_enc}"
            ;;
        *)
            red "当前入站类型不支持 Tunnel：${inbound_type}"
            read -rp "按回车返回..." _
            return 1
            ;;
    esac
    url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    mkdir -p "$URL_DIR"
    if [ -f "$url_file" ]; then
        sed -i '/_Tunnelvless_ws\|_Tunnelvmess_ws\|_Tunneltrojan_ws/d' "$url_file"
    fi
    echo "$argo_url" >> "$url_file"
    update_sub_file
	systemctl reload sing-box
    green "============================================"
    green "Cloudflare Tunnel 添加成功！"
    green "入站：${inbound_type}-${inbound_number}"
    green "域名：${domain}"
    green "路径：${ws_path}"
    green "本地端口：127.0.0.1:${origin_port}"
    echo
    green "Tunnel 节点链接："
    echo "$argo_url"
    green "============================================"
    read -rp "按回车返回..." _
}
get_inbound_cdn_domain() {
    local inbound_type="$1"
    local inbound_number="$2"
    local url_file="$URL_DIR/${inbound_type}-${inbound_number}.txt"
    local cdn_domain=""
    local line=""
    local decoded=""
    [ -f "$url_file" ] || return 1
    case "$inbound_type" in
        vless-ws|trojan-ws)
            line=$(grep -m1 'sni=' "$url_file")
            if [ -n "$line" ]; then
                cdn_domain=$(echo "$line" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
            fi
            ;;
        vmess-ws)
            while IFS= read -r line; do
                [[ "$line" == vmess://* ]] || continue
                decoded=$(printf '%s' "${line#vmess://}" | base64 -d 2>/dev/null) || continue
                cdn_domain=$(echo "$decoded" | jq -r '.sni // empty' 2>/dev/null)
                [ -n "$cdn_domain" ] && break
            done < "$url_file"
            ;;
    esac
    [ -n "$cdn_domain" ] || return 1
    printf '%s\n' "$cdn_domain"
}
modify_inbound_port() {
    local config_file="$1"
    local engine="$2"
    local inbound_type="$3"
    local inbound_number="$4"
    local old_port=""
    local new_port=""
    if [ ! -f "$config_file" ]; then
        red "配置文件不存在：$config_file"
        sleep 1
        return 1
    fi
    old_port=$(jq -r '.inbounds[0].listen_port // empty' "$config_file" 2>/dev/null)
    if [ -z "$old_port" ]; then
        red "无法读取当前端口"
        sleep 1
        return 1
    fi
    echo
    green "当前端口：$old_port"
    reading "请输入新端口（直接回车随机生成）： " new_port
    if [ -z "$new_port" ]; then
        new_port=$(get_available_port)
        if [ -z "$new_port" ]; then
            red "无法获取可用端口"
            sleep 1
            return 1
        fi
        green "已随机选择可用端口：$new_port"
    else
        if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            red "端口无效，请输入 1-65535"
            sleep 1
            return 1
        fi
        if [ "$new_port" = "$old_port" ]; then
            yellow "新端口与当前端口相同"
            sleep 1
            return 0
        fi
        if ss -lntup 2>/dev/null | grep -Eq ":${new_port}([[:space:]]|$)"; then
            red "端口 ${new_port} 已被占用"
            sleep 1
            return 1
        fi
    fi
    if [ "$new_port" = "$old_port" ]; then
        yellow "新端口与当前端口相同"
        sleep 1
        return 0
    fi
    jq --argjson port "$new_port" '.inbounds[0].listen_port = $port' "$config_file" > "${config_file}.tmp" || {
        rm -f "${config_file}.tmp"
        red "修改端口失败"
        sleep 1
        return 1
        }
    mv -f "${config_file}.tmp" "$config_file"
    if ! /etc/sing-box/sing-box check -C /etc/sing-box/conf >/dev/null 2>&1; then
        red "配置检查失败，正在恢复原端口"
        jq --argjson port "$old_port" '.inbounds[0].listen_port = $port' "$config_file" > "${config_file}.tmp" &&
        mv -f "${config_file}.tmp" "$config_file"
        sleep 1
        return 1
    fi
    allow_port "$new_port/tcp" >/dev/null 2>&1
    allow_port "$new_port/udp" >/dev/null 2>&1
    systemctl reload sing-box
    green "新端口：${new_port}"
    sleep 3
}



#更新脚本
update_script() {
    local remote_url="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing-box-cf08.sh"
    local local_file="$work_dir/sb.sh"
    local traffic_url="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing-box-name.sh"
    local traffic_file="/etc/sing-box/sing-box-name.sh"
    if curl -Lss "$remote_url" -o "${local_file}.tmp"; then
        if [ -s "${local_file}.tmp" ]; then
            mv -f "${local_file}.tmp" "$local_file"
            chmod +x "$local_file"
            ln -sf "$local_file" /usr/bin/sb
            curl -Lss "$traffic_url" -o "${traffic_file}.tmp"
            if [ -s "${traffic_file}.tmp" ]; then
                mv -f "${traffic_file}.tmp" "$traffic_file"
            else
                rm -f "${traffic_file}.tmp"
            fi
            green "\n脚本已更新！"
            sleep 1
            exec bash "$local_file"
        else
            rm -f "${local_file}.tmp"
            red "\n更新失败：下载的文件为空"
        fi
    else
        red "\n更新失败：请检查网络连接"
    fi
}

bbr_menu() {
    local bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control)
    green "=== BBR ===\n"
    green "当前拥塞控制算法: $bbr_status\n"
    green "1. 开启 BBR"
    skyblue "------------"
    green "2. 关闭 BBR"
    skyblue "------------"
    green "0. 返回主菜单"
    skyblue "------------"
    read -rp "请选择操作 [0-2]: " choice
    case "$choice" in
        0)
            menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}无效的选项，请重新选择。${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${yellow}BBR 当前未处于开启状态。${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        rm -f /etc/sysctl.d/99-bbr-x-ui.conf
    fi

    if [ -f "/etc/sysctl.conf" ]; then
        sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
        sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
    fi

    sysctl -w net.core.default_qdisc=pfifo_fast > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}BBR 已成功替换为 CUBIC。${plain}"
    else
        echo -e "${red}未能将 BBR 替换为 CUBIC，请检查系统配置。${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${green}BBR 已经处于开启状态！${plain}"
        before_show_menu
		return
    fi

    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}BBR 已成功开启。${plain}"
    else
        echo -e "${red}开启 BBR 失败，请检查系统配置。${plain}"
    fi
}



edit_singbox_files() {
    local current_dir="/etc/sing-box"
    local choice=""
    local selected=""
    local items=()
    local file=""
    local content=""
    local result=""
    local errors=()
    local i=1
    while true; do
        clear
        green "================ 文件管理 ================"
        echo
        echo "当前目录：$current_dir"
        echo
        items=()
        i=1
        while IFS= read -r file; do
            items+=("$file")
        done < <(find "$current_dir" -mindepth 1 -maxdepth 1 -printf '%y|%f|%p\n' 2>/dev/null | sort -k1,1r -k2,2)
        if [ "${#items[@]}" -eq 0 ]; then
            green "当前目录为空"
        else
            for file in "${items[@]}"; do
                local type="${file%%|*}"
                local rest="${file#*|}"
                local name="${rest%%|*}"
                if [ "$type" = "d" ]; then
                    green "${i}. [目录] $name"
                else
                    green "${i}. [文件] $name"
                fi
                ((i++))
            done
        fi
        echo
        green "c. 检查全部 JSON 配置"
        green "0. 返回"
        echo
        read -rp "请选择: " choice
        if [ "$choice" = "0" ]; then
            if [ "$current_dir" = "/etc/sing-box" ]; then
                return
            fi
            current_dir=$(dirname "$current_dir")
            continue
        fi
        if [[ "$choice" =~ ^[Cc]$ ]]; then
            clear
            green "================ JSON 配置检查 ================"
            echo
            errors=()
            while IFS= read -r file; do
                result=$(/etc/sing-box/sing-box check -c "$file" 2>&1)
                if [ $? -eq 0 ]; then
                    green "[正确] $(basename "$file")"
                else
                    green "[错误] $(basename "$file")"
                    errors+=("$file")
                    echo "$result"
                    echo
                fi
            done < <(find "/etc/sing-box/conf" -maxdepth 1 -type f -name "*.json" -print | sort)
            echo
            if [ "${#errors[@]}" -eq 0 ]; then
                green "全部 JSON 配置文件检查通过"
                echo
                read -rp "按回车返回..." _
                continue
            fi
            green "发现 ${#errors[@]} 个配置文件存在错误"
            echo
            for i in "${!errors[@]}"; do
                green "$((i + 1)). ${errors[$i]}"
            done
            echo
            green "0. 返回"
            echo
            read -rp "请选择要修改的错误配置文件: " choice
            if [ "$choice" = "0" ]; then
                continue
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#errors[@]}" ]; then
                clear
                green "================ 配置文件 ================"
                echo
                echo "文件：${errors[$((choice - 1))]}"
                echo
                content=$(cat "${errors[$((choice - 1))]}")
                printf '%s\n' "$content"
                echo
                green "e. 编辑  保存：Ctrl + O 回车（Enter）确认,   退出：Ctrl + X"
                green "0. 退出"
                echo
                read -rp "请选择: " choice
                case "$choice" in
                    e|E)
                        nano "${errors[$((choice - 1))]}"
                        ;;
                esac
            fi
            continue
        fi
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#items[@]}" ]; then
            green "无效选择"
            sleep 1
            continue
        fi
        selected="${items[$((choice-1))]}"
        local selected_type="${selected%%|*}"
        local selected_rest="${selected#*|}"
        local selected_path="${selected_rest#*|}"
        if [ "$selected_type" = "d" ]; then
            current_dir="$selected_path"
        else
            while true; do
                clear
                green "================ 文件内容 ================"
                echo
                echo "文件：$selected_path"
                echo
                if [ -f "$selected_path" ]; then
                    cat "$selected_path"
                else
                    green "文件不存在"
                fi
                echo
                green "e. 编辑  保存：Ctrl + O 回车（Enter）确认,   退出：Ctrl + X"
                green "0. 退出"
                echo
                read -rp "请选择: " choice
                case "$choice" in
                    e|E)
                        nano "$selected_path"
                        ;;
                    0)
                        break
                        ;;
                    *)
                        green "无效选择"
                        sleep 1
                        ;;
                esac
            done
        fi
    done
}
    
