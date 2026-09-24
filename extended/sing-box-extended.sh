






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






# 批量关闭端口 (完全适配原生 nftables)
close_port() {
    local has_nft=0
    command_exists nft && has_nft=1
    
    for rule in "$@"; do
        local port=${rule%/*}
        
        if [ "$has_nft" -eq 1 ]; then
            # 在原生 nftables 中，删除规则最安全的方式是获取 handle 句柄并删除
            # 通过 awk 提取匹配该端口规则的 handle 值
            for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$port" '$0~"dport "p {print $NF}'); do
                nft delete rule inet filter input handle $handle 2>/dev/null
            done
        fi
    done
    
    # 删除完毕后，将新的规则状态持久化到文件
    if [ "$has_nft" -eq 1 ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null
    fi
}


    









       
# 通用服务管理函数


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
    }delete_inbound
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

# WARP 分流管理
warp_manage() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi
    clear  
    route_file="${conf_dir}/route.json"  
    outbound_file="${conf_dir}/outbounds.json"  
    echo ""  
    green "=== WARP / 节点分流管理 ===\n"  
    local current_final  
    current_final=$(jq -r '.route.final // empty' "$route_file" 2>/dev/null)  
    if [ -z "$current_final" ] || [ "$current_final" == "direct" ] || [ "$current_final" == "null" ]; then  
        echo -e "当前全局默认出站: ${skyblue}direct (服务器原IP直连)${re}\n"  
    else  
        echo -e "当前全局默认出站: ${purple}${current_final} ${yellow}[全局代理已开启]${re}\n"  
    fi  
    green "当前已启用的分流规则 (输入对应字母可快捷切换出站):"  
    local has_rules=0  
    local rule_letters=("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z")  
    local rule_indices=()  
    local rule_count=0  
    while IFS='|' read -r p1 p2 p3 r_idx; do  
        [ -z "$p1" ] && continue  
        local current_letter="${rule_letters[$rule_count]}"  
        echo -e "  - ${yellow}[${current_letter}]${re} ${skyblue}${p1}${re} - ${green}${p2}${re} - ${purple}出站: ${p3}${re}"  
        rule_indices[$rule_count]="$r_idx"  
        rule_count=$((rule_count + 1))  
        has_rules=1  
    done < <(jq -r '  
        {"vmess-ws": "vmess-argo", "vless-reality": "xtls-reality", "hysteria2": "hysteria2", "tuic": "tuic"} as $inMap  
        | (.route.rules // []) | to_entries[]  
        | .key as $idx  
        | .value as $r  
        | (
            if $r.rule_set then "[预设规则] \($r.rule_set | join(", "))" 
            elif $r.domain_suffix then "[域名后缀] \($r.domain_suffix | join(", "))" 
            elif $r.domain_keyword then "[域名关键字] \($r.domain_keyword | join(", "))" 
            elif $r.domain then "[全域名] \($r.domain | join(", "))" 
            elif $r.geosite then "[GeoSite] \($r.geosite | join(", "))" 
            elif $r.geoip then "[GeoIP] \($r.geoip | join(", "))" 
            elif $r.ip_cidr then "[IP/CIDR] \($r.ip_cidr | join(", "))" 
            else "[所有流量]" end
          ) as $p1  
        | (
            if $r.inbound and (.inbound | length > 0) then 
               ($inMap[.inbound[0]] // .inbound[0]) 
            else "全部节点" end
          ) as $p2  
        | $r.outbound as $p3  
        | "\($p1)|\($p2)|\($p3)|\($idx)"  
    ' "$route_file" 2>/dev/null)  
    [ $has_rules -eq 0 ] && echo "    无"  
    echo ""  
    green "已添加的 Socks/HTTP 代理出站:"
    jq -r '.outbounds[]? | select(.tag != "direct" and .tag != "wireguard-out") | "  - \(.tag) [\(.type)]"' "$outbound_file" 2>/dev/null || echo "    无"
    echo ""
    green "1. 设置分流服务"
    skyblue "----------------------"
    red "2. 删除分流规则"
    skyblue "--------------"
    green "3. 添加 Socks5/HTTP 出站"
    skyblue "----------------------"
    red "4. 管理 Socks5/HTTP 出站"
    skyblue "----------------------"
	green "5. 添加 warp 出站"
    skyblue "----------------------"
	green "6. 优化DNS地址"
	skyblue "----------------------"
	green "7. fanout"
    skyblue "----------------------"
	green "8. 网页版分流"
    skyblue "----------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    purple "00. 退出脚本"
    skyblue "------------"
    reading "请输入选择: " choice
	local target_rule_idx=-1
    for i in "${!rule_letters[@]}"; do
        if [ "$choice" == "${rule_letters[$i]}" ]; then
            if [ $i -lt ${#rule_indices[@]} ]; then
                target_rule_idx="${rule_indices[$i]}"
            fi
            break
        fi
    done
    if [ "$target_rule_idx" -ne -1 ]; then
        local selected_out=""
        if select_outbound_target; then
            jq --argjson r_idx "$target_rule_idx" --arg new_out "$selected_out" \
                '.route.rules[$r_idx].outbound = $new_out' \
                "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
            
            systemctl reload sing-box
            green "\n成功将该规则的出站修改为：${purple}${selected_out}${re}"
            sleep 1
        else
            red "操作已取消"; sleep 1
        fi
        warp_manage
        return
    fi
    case "${choice}" in
        1)  add_rule_menu ;;
        2)  delete_rule_menu ;;
        3)  add_socks5_proxy ;;
        4)  delete_socks5_proxy ;;
		5)  wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh ;;
		6)  
            clear
            echo "当前DNS地址"
            echo "------------------------"
            cat /etc/resolv.conf
            echo "------------------------"
            echo ""
            # 询问用户是否要优化DNS设置
            read -p $'\033[1;35m是否要设置为Cloudflare和Google的DNS地址？(y/n): \033[0m' choice

            if [ "$choice" == "y" ]; then
                cloudflare_ipv4="1.1.1.1"
                google_ipv4="8.8.8.8"
                cloudflare_ipv6="2606:4700:4700::1111"
                google_ipv6="2001:4860:4860::8888"
                ipv6_available=0
                if [[ $(ip -6 addr | grep -c "inet6") -gt 0 ]]; then
                    ipv6_available=1
                fi
                echo "设置DNS为Cloudflare和Google"
                echo "nameserver $cloudflare_ipv4" > /etc/resolv.conf
                echo "nameserver $google_ipv4" >> /etc/resolv.conf
                if [[ $ipv6_available -eq 1 ]]; then
                    echo "nameserver $cloudflare_ipv6" >> /etc/resolv.conf
                    echo "nameserver $google_ipv6" >> /etc/resolv.conf
                fi
                echo "DNS地址已更新"
                echo "------------------------"
                cat /etc/resolv.conf
                echo "------------------------"
            else
                echo "DNS设置未更改"
            fi
			sleep 1; warp_manage
              ;;
	    7)  extract_fanout_socks ;;
	    8)
        clear
        green "=== 网页版分流 ==="
        skyblue "------------------------"
        green "1. 开启"
        red "2. 卸载"
        skyblue "------------------------"
        purple "0. 返回上级菜单"
        skyblue "------------------------"
        read -p "请输入选择: " web_choice
        case "$web_choice" in
            1)
                echo "正在启动..."
                local WEB_SCRIPT_URL="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/singbox_web.py"
                
                mkdir -p /etc/sing-box
                curl -sSL -o /etc/sing-box/singbox_web.py "$WEB_SCRIPT_URL"
                
                if [ ! -f "/etc/sing-box/singbox_web.py" ]; then
                    red "下载失败，请检查远程链接是否正确！"
                    sleep 2
                    warp_manage
                    return
                fi
                
                # 停止旧进程
                pkill -f singbox_web.py
                # 后台运行
                nohup python3 /etc/sing-box/singbox_web.py > /dev/null 2>&1 &
                sleep 1
                
                if [ -f "/etc/sing-box/web_config.json" ]; then
                    local web_port=$(grep -o '"port": *[0-9]*' /etc/sing-box/web_config.json | grep -o '[0-9]*')
                    local web_pwd=$(grep -o '"password": *"[^"]*"' /etc/sing-box/web_config.json | cut -d'"' -f4)
                    local server_ip=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
                    
                    echo
                    echo -e "  ${G}成功启动${N}"
                    echo
                    echo -e "  ${B}管理地址  http://${server_ip}:${web_port}/${N}"
                    echo -e "  ${B}访问口令  ${web_pwd}${N}"
                    echo
                else
                    red "面板启动异常，请检查 Python 环境或依赖。"
                fi
                echo ""
                read -p "按回车键继续..."
                ;;
            2)
                echo "正在卸载..."
                pkill -f singbox_web.py
                rm -f /etc/sing-box/singbox_web.py
                rm -f /etc/sing-box/web_config.json
                green "已卸载"
                sleep 1
                ;;
			0)
                warp_manage
                return
                ;;
            *)
                red "无效选项"
                sleep 1
                ;;
        esac
        warp_manage
        ;;
        0)  menu ;;
        00) exit 0 ;;
        *)  red "无效选项"; sleep 1; warp_manage ;;
    esac
}

#把fanout socks出站添加到sing-box出站
extract_fanout_socks() {
    if [ ! -d "/var/lib/fanout" ] || ! command -v f &> /dev/null; then
        echo "检测到 fanout 尚未安装，正在为您执行安装..."
        bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/fanout/main/install.sh)
        echo ""
        echo "----------------------------------------"
        read -p "安装已完成，快捷命令f已创建, 按回车键返回主菜单..."
    fi

    local input_file="/var/lib/fanout/xray.json"
    local output_file="/etc/sing-box/conf/outbounds.json"

    if ! command -v jq &> /dev/null; then
        echo "错误: 未找到 jq 工具。请先安装 (例如执行: apt install jq)"
        return 1
    fi

    if [ ! -f "$input_file" ]; then
        echo "错误: 找不到 $input_file，请确保 fanout 已成功配置节点。"
        return 1
    fi
    mkdir -p "$(dirname "$output_file")"
    local new_fanout_nodes
    new_fanout_nodes=$(jq '[
      .outbounds[]? | 
      select(.protocol == "socks" and (.tag | tostring | test("fanout-"))) |
      . as $item |
      $item.settings.servers[0].port as $port |
      {
        type: "socks",
        tag: ("fanout-" + ($port | tostring)),
        server: $item.settings.servers[0].address,
        server_port: $port,
        username: $item.settings.servers[0].users[0].user,
        password: $item.settings.servers[0].users[0].pass
      }
    ]' "$input_file")

    if [ -f "$output_file" ]; then
        jq --argjson new_nodes "$new_fanout_nodes" '
          .outbounds as $old |
          if $old then
            .outbounds = [
              $old[]? | select(
                type != "object" or 
                (has("tag") | not) or 
                (.tag | tostring | test("^fanout-") | not)
              )
            ] + $new_nodes
          else
            .outbounds = $new_nodes
          end
        ' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
    else
        echo "{\"outbounds\": $new_nodes}" > "$output_file"
    fi

    if [ $? -eq 0 ]; then
        echo "更新成功！已同步至 $output_file"
        echo "当前文件中共有 $(jq '.outbounds | length' "$output_file") 个出站节点。"
    else
        echo "更新失败，请检查配置文件格式。"
        return 1
    fi
    sleep 1; warp_manage
}

# 选择目标出站时的通用函数 (自动测速 5 秒超时 + 实时显示延迟)
select_outbound_target() {
    echo ""
    green "正在检测已添加出站的连通性及延迟，请稍候 (最长5秒)..."
    local out_tags=("wireguard-out")
    local display_lines=()
    display_lines+=("  ${green}1.${re} ${skyblue}wireguard-out${re} (脚本 WARP 出站)")
    local custom_tags=($(jq -r '.outbounds[]? | select(.tag != "direct" and .tag != "wireguard-out") | .tag' "$outbound_file" 2>/dev/null))
    local tmp_dir=$(mktemp -d)
    local i=2
    for tag in "${custom_tags[@]}"; do
        (
            local proxy_json=$(jq -r --arg t "$tag" '.outbounds[] | select(.tag == $t)' "$outbound_file" 2>/dev/null)
            local type=$(echo "$proxy_json" | jq -r '.type // ""')
            local server=$(echo "$proxy_json" | jq -r '.server // ""')
            local port=$(echo "$proxy_json" | jq -r '.server_port // ""')
            local user=$(echo "$proxy_json" | jq -r '.username // ""')
            local pass=$(echo "$proxy_json" | jq -r '.password // ""')
            
            local status_str=""
            if [[ "$type" == "socks" || "$type" == "http" ]] && [[ -n "$server" && -n "$port" ]]; then
                local auth=""
                [ -n "$user" ] && [ -n "$pass" ] && auth="${user}:${pass}@"
                local scheme="socks5h"
                [ "$type" == "http" ] && scheme="http"
                local proxy_url="${scheme}://${auth}${server}:${port}"
                
                local curl_out=$(curl -m 5 -s -o /dev/null -w "%{http_code}|%{time_total}" -x "$proxy_url" "https://www.gstatic.com/generate_204" 2>/dev/null)
                local http_code=$(echo "$curl_out" | cut -d'|' -f1)
                local time_total=$(echo "$curl_out" | cut -d'|' -f2)
                
                if [ "$http_code" == "204" ] || [ "$http_code" == "200" ]; then
                    local ms_delay=$(awk -v t="$time_total" 'BEGIN{printf "%.0f", t * 1000}')
                    status_str="${green}[延迟: ${ms_delay} ms]${re}"
                else
                    status_str="${red}[连接超时/不通]${re}"
                fi
            else
                status_str="${yellow}[${type}]${re}"
            fi
            echo "$status_str" > "$tmp_dir/$i.res"
        ) &
        ((i++))
    done
    wait
    i=2
    for tag in "${custom_tags[@]}"; do
        local status_str=""
        if [ -f "$tmp_dir/$i.res" ]; then
            status_str=$(cat "$tmp_dir/$i.res")
        fi
        
        display_lines+=("  ${green}${i}.${re} ${skyblue}${tag}${re} ${status_str}")
        out_tags+=("$tag")
        ((i++))
    done
    rm -rf "$tmp_dir"
    display_lines+=("  ${green}${i}.${re} ${skyblue}direct${re} (服务器 IP 直连)")
    out_tags+=("direct")
    ((i++))
    display_lines+=("  ${green}${i}.${re} ${red}reject${re} (🚫UDP流量从VPS到网站强制使用TCP )")
    out_tags+=("reject")
    echo ""
    green "请选择分流流量要走的出站线路或动作:"
    for line in "${display_lines[@]}"; do
        echo -e "$line"
    done
    echo ""    
    reading "请输入编号: " out_choice    
    if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || [ "$out_choice" -lt 1 ] || [ "$out_choice" -gt "${#out_tags[@]}" ]; then
        red "无效选择"
        return 1
    fi    
    selected_out="${out_tags[$((out_choice-1))]}"
    return 0
}

# 选择规则生效的节点 (入站 Inbound)
select_inbound_target() {
    echo ""
    green "第一步：请选择该规则要生效的节点"
    local idx=1
    in_tags=()
    local available_tags=($(jq -r '.inbounds[]?.tag // empty' /etc/sing-box/conf/*.json 2>/dev/null | sort -u))
    if [ ${#available_tags[@]} -eq 0 ]; then
        red "未在 /etc/sing-box/conf/ 目录下的配置中找到任何节点！"
        return 1
    fi
    for tag in "${available_tags[@]}"; do
        # if [[ "$tag" == "dns-in" || "$tag" == "mixed-in" ]]; then continue; fi  
        echo -e "  ${green}${idx}.${re} ${tag}"
        in_tags+=("$tag")
        ((idx++))
    done
    echo ""
    while true; do
        reading "请输入节点编号: " in_choice   
        if [[ "$in_choice" =~ ^[0-9]+$ ]] && [ "$in_choice" -ge 1 ] && [ "$in_choice" -le "${#in_tags[@]}" ]; then
            selected_inbound="${in_tags[$((in_choice-1))]}"
            selected_inbound_name="${selected_inbound}"
            break
        else
            red "输入无效，请重新输入正确的节点编号！"
        fi
    done
    return 0
}

add_rule_menu() {
    clear
    green "选择要分流的服务或设置自定义域名:\n"
    green "1.  OpenAI"
    green "2.  Gemini"
    green "3.  Google"
    green "4.  YouTube"
    green "5.  Telegram"
    skyblue "-----------------------------"
    green "6. ➕ 自定义分流"
    skyblue "-----------------------------"
    green "7. 设置全局代理出站 (所有流量走指定代理)"
    green "8. 恢复服务器原IP出站 (所有流量走服务器IP)"
    skyblue "-----------------------------"
    purple "0.  返回上级菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " add_choice
    case "$add_choice" in
        1)  rule_tag="openai"   ;;
        2)  rule_tag="gemini"   ;;
        3)  rule_tag="google"   ;;     
        4)  rule_tag="youtube"  ;;      
        5)  rule_tag="telegram" ;;
        6) add_custom_domain_rule; return ;;
        7) set_global_outbound; return ;;
        8) restore_direct_outbound; return ;;
        0)  warp_manage; return ;;
        *)  red "无效选项"; sleep 1; add_rule_menu; return ;;
    esac
    
    select_inbound_target
    
    if jq -e --arg tag "$rule_tag" --arg inb "$selected_inbound" '
        .route.rules[]? | select(.rule_set != null) | 
        select( ( ($inb == "" and (has("inbound") | not)) or ($inb != "" and .inbound == [$inb]) ) ) | 
        .rule_set[]? | select(. == $tag)
    ' "$route_file" > /dev/null 2>&1; then
        yellow "规则集 '${rule_tag}' 已在 [${selected_inbound_name}] 运行中。"; sleep 1.5; warp_manage; return
    fi
    jq 'if .route.rules then .route.rules |= map(select( (.rule_set | length > 0) or (.domain_suffix | length > 0) )) else . end' \
        "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

    green "\n第二步："
    if ! select_outbound_target; then
        sleep 1; add_rule_menu; return
    fi
    if [ "$selected_out" == "reject" ]; then
        # 选中了 reject 动作，写入 action: reject 规则，并自动置顶
        jq --arg tag "$rule_tag" --arg inb "$selected_inbound" '
            .route.rules //= [] |
            (
                if $inb == "" then
                    {"rule_set": [$tag], "network": ["udp"], "action": "reject"}
                else
                    {"inbound": [$inb], "rule_set": [$tag], "network": ["udp"], "action": "reject"}
                end
            ) as $new_r |
            .route.rules = [$new_r] + (.route.rules | map(select(. != $new_r)))
        ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

        systemctl reload sing-box
        green "\n✅ 规则 '${rule_tag}' 已成功设置为：[ 🚫 拦截 UDP 强制 TCP ]！"
        sleep 2; warp_manage
        return
    fi
    # 选中常规出站线路 (wireguard-out / direct / socks5 等)
    jq --arg tag "$rule_tag" --arg out "$selected_out" --arg inb "$selected_inbound" '
        .route.rules //= [] |
        if $inb == "" then
            .route.rules += [{"rule_set": [$tag], "outbound": $out}]
        else
            .route.rules += [{"inbound": [$inb], "rule_set": [$tag], "outbound": $out}]
        end
    ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
    systemctl reload sing-box
    green "\n预设规则 '${rule_tag}' 已添加！\n生效节点: [ ${selected_inbound_name} ]\n出站线路: [ ${selected_out} ]"
    sleep 2; warp_manage
}
add_custom_domain_rule() {
    echo ""
    green "=== 添加自定义域名分流 ==="
    echo -e "提示: 输入要匹配的域名（后缀匹配，如输入 ${skyblue}baidu.com${re}）多个域名用英文逗号隔开"
    echo -e "      ${purple}直接回车 默认所有域名 ！${re}"
    reading "请输入域名: " custom_input
    select_inbound_target
    green "\n第二步："
    if ! select_outbound_target; then
        sleep 1; add_rule_menu; return
    fi
    if [ "$selected_out" == "reject" ]; then
        if [ -z "$custom_input" ]; then
            jq --arg inb "$selected_inbound" '
                .route.rules //= [] |
                (
                    if $inb == "" then
                        {"network": ["udp"], "action": "reject"}
                    else
                        {"inbound": [$inb], "network": ["udp"], "action": "reject"}
                    end
                ) as $new_r |
                .route.rules = [$new_r] + (.route.rules | map(select(. != $new_r)))
            ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
            custom_input="所有流量 (全局)"
        else
            local dom_json=$(echo "$custom_input" | tr ',' ' ' | jq -R 'split(" ") | map(select(length > 0))')
            jq --argjson doms "$dom_json" --arg inb "$selected_inbound" '
                .route.rules //= [] |
                (
                    if $inb == "" then
                        {"domain_suffix": $doms, "network": ["udp"], "action": "reject"}
                    else
                        {"inbound": [$inb], "domain_suffix": $doms, "network": ["udp"], "action": "reject"}
                    end
                ) as $new_r |
                .route.rules = [$new_r] + (.route.rules | map(select(. != $new_r)))
            ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
        fi
        systemctl reload sing-box
        green "\n✅ 规则 [ $custom_input ] 已成功设置为：[ 🚫 拦截 UDP 强制 TCP ]！"
        echo -e "   - 生效节点: [ ${skyblue}${selected_inbound_name}${re} ]"
        sleep 2
        warp_manage
        return
    fi
    if [ -z "$custom_input" ]; then
        jq --arg out "$selected_out" --arg inb "$selected_inbound" '
            .route.rules //= [] |
            if $inb == "" then
                .route.rules += [{"outbound": $out}]
            else
                .route.rules += [{"inbound": [$inb], "outbound": $out}]
            end
        ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"       
        custom_input="所有流量 (全局)"
    else
        local dom_json=$(echo "$custom_input" | tr ',' ' ' | jq -R 'split(" ") | map(select(length > 0))')       
        jq --argjson doms "$dom_json" --arg out "$selected_out" --arg inb "$selected_inbound" '
            .route.rules //= [] |
            if any(.route.rules[]; .outbound == $out and .domain_suffix != null and (($inb == "" and (has("inbound") | not)) or ($inb != "" and .inbound == [$inb]))) then
                .route.rules |= map(
                    if .outbound == $out and .domain_suffix != null and (($inb == "" and (has("inbound") | not)) or ($inb != "" and .inbound == [$inb])) then
                        .domain_suffix = (.domain_suffix + $doms | unique)
                    else . end
                )
            else
                if $inb == "" then
                    .route.rules += [{"domain_suffix": $doms, "outbound": $out}]
                else
                    .route.rules += [{"inbound": [$inb], "domain_suffix": $doms, "outbound": $out}]
                end
            end
        ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
    fi
    systemctl reload sing-box
    green "\n✅ 规则 [ $custom_input ] 已成功添加！"
    echo -e "   - 生效节点: [ ${skyblue}${selected_inbound_name}${re} ]"
    echo -e "   - 出站线路: [ ${purple}${selected_out}${re} ]"
    sleep 2
    warp_manage
}

# 设置全局代理出站
set_global_outbound() {
    local proxy_tags
    proxy_tags=($(jq -r '.outbounds[]? | select(.tag != "direct" and .tag != "wireguard-out") | .tag' \
        "$outbound_file" 2>/dev/null))

    if [ ${#proxy_tags[@]} -eq 0 ]; then
        yellow "\n当前没有可用的 socks5/http 代理出站。"
        yellow "请先返回 → 设置分流服务 → 添加代理出站，再设置全局代理。\n"
        sleep 3; add_rule_menu; return
    fi
    echo ""
    green "请选择全局代理出站:"
    for i in "${!proxy_tags[@]}"; do
        echo -e "  ${green}$((i+1)). ${skyblue}${proxy_tags[$i]}${re}"
    done
    echo ""
    reading "请输入编号: " out_choice
    if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
       [ "$out_choice" -lt 1 ] || \
       [ "$out_choice" -gt "${#proxy_tags[@]}" ]; then
        red "无效选择"; sleep 1; add_rule_menu; return
    fi
    local selected_out="${proxy_tags[$((out_choice-1))]}"
    cat > "${route_file}" <<EOF
{
  "route": {
    "final": "${selected_out}",
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ]
  }
}
EOF
    rm -rf ${conf_dir}/endpoints.json
    systemctl reload sing-box
    green "\n已安全设置全局代理出站：${purple}${selected_out}${re}"
    yellow "✅ 所有外网流量将通过 ${selected_out} 转发。"
    yellow "✅ 局域网及 SSH 连接已自动绕过代理 (直连)，防止断网。"
    yellow "如需恢复，请选择「恢复服务器原IP出站」\n"
    
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
    warp_manage
}

# 恢复服务器原IP出站（恢复默认 route.json）
restore_direct_outbound() {
    yellow "\n正在恢复默认路由配置...\n"

    # 恢复 outbounds.json 中的 direct 出站（不存在则插入到数组最前面）
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$outbound_file" > /dev/null 2>&1; then
        jq '.outbounds = [{"type": "direct", "tag": "direct"}] + .outbounds' \
            "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
    fi

    # 恢复默认 route.json
    cat > "${route_file}" << 'EOF'
{
  "route": {
    "rule_set": [
      {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs","download_detour":"direct"},
      {"tag":"claude","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/claude.srs","download_detour":"direct"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs","download_detour":"direct"},
      {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs","download_detour":"direct"},
      {"tag":"twitter","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs","download_detour":"direct"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs","download_detour":"direct"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs","download_detour":"direct"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs","download_detour":"direct"},
      {"tag":"netflix","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs","download_detour":"direct"}
    ],
    "rules": [],
    "final": "direct"
  }
}
EOF

    # 恢复默认 endpoints.json
    cat > "${conf_dir}/endpoints.json" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8dfe:d141:69bb:6b80:925/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [78, 135, 76]
        }
      ]
    }
  ]
}
EOF
    systemctl reload sing-box
    green "\n已恢复服务器原IP出站，所有流量走 direct。\n"
    sleep 2; warp_manage
}

add_socks5_proxy() {
    clear
    green "=== 添加 Socks5/HTTP 代理出站 ==="
    reading "请输入代理URL (支持 socks://, socks5://, http:// 以及包含 #别名 的链接): " proxy_url
    [ -z "$proxy_url" ] && {
        red "输入为空！"
        sleep 1
        warp_manage
        return
    }
    proto=$(echo "$proxy_url" | grep -oP '^[a-zA-Z0-9]+(?=://)')
    [[ ! "$proto" =~ ^(socks5|socks|http)$ ]] && {
        red "不支持的协议！仅支持 socks5/socks/http"
        sleep 2
        warp_manage
        return
    }
    case "$proto" in
        socks|socks5)
            outbound_type="socks"
            ;;
        http)
            outbound_type="http"
            ;;
    esac
    after_proto="${proxy_url#*://}"
    if [[ "$after_proto" == *"#"* ]]; then
        tag_from_url="${after_proto##*#}"
        tag_from_url=$(echo -e "$(echo "$tag_from_url" | sed 's/+/ /g;s/%/\\x/g')")
        after_proto="${after_proto%%#*}"
    else
        tag_from_url=""
    fi
    if [[ "$after_proto" == *"@"* ]]; then
        user_pass="${after_proto%%@*}"
        host_port="${after_proto##*@}"
    else
        user_pass=""
        host_port="$after_proto"
    fi
    user=""
    password=""

    if [ -n "$user_pass" ]; then
        decoded=$(echo "$user_pass" | base64 -d 2>/dev/null)

        if [ -n "$decoded" ] &&
           [[ "$decoded" != "$user_pass" ]] &&
           [[ "$decoded" == *":"* ]]; then

            user="${decoded%%:*}"
            password="${decoded#*:}"

        elif [[ "$user_pass" == *":"* ]]; then

            user="${user_pass%%:*}"
            password="${user_pass#*:}"

        else
            user="$user_pass"
        fi
    fi
    server="${host_port%%:*}"
    port="${host_port##*:}"

    [ -z "$server" ] || [ -z "$port" ] && {
        red "格式错误：缺少 IP 或端口！"
        sleep 2
        warp_manage
        return
    }
    # socks / socks5 统一为 socks5
    [[ "$proto" == "socks" || "$proto" == "socks5" ]] && \
        check_proto="socks5" || \
        check_proto="$proto"
    local proxy_auth=""
    if [ -n "$user" ] && [ -n "$password" ]; then
        proxy_auth="${user}:${password}@"
    elif [ -n "$user" ]; then
        proxy_auth="${user}@"
    fi
    local scheme="socks5h"
    [ "$outbound_type" == "http" ] && scheme="http"
    local proxy_url_test="${scheme}://${proxy_auth}${server}:${port}"
    yellow "正在测试代理 ${check_proto}://${server}:${port} ..."
    local curl_out
    local http_code
    local time_total
    curl_out=$(curl -m 5 -s -o /dev/null \
        -w "%{http_code}|%{time_total}" \
        -x "$proxy_url_test" \
        "https://www.gstatic.com/generate_204" 2>/dev/null)
    http_code=$(echo "$curl_out" | cut -d'|' -f1)
    time_total=$(echo "$curl_out" | cut -d'|' -f2)
    if [ "$http_code" == "204" ] || [ "$http_code" == "200" ]; then
        local ms_delay
        ms_delay=$(awk -v t="$time_total" 'BEGIN{printf "%.0f", t * 1000}')
        green "代理验证成功！"
        green "延迟: ${ms_delay} ms"

    else
        yellow "代理测试失败！"
        reading "是否仍然强制添加此代理？(y/n): " force_add
        [[ ! "$force_add" =~ ^[yY]$ ]] && {
            yellow "已取消添加。"
            sleep 1
            warp_manage
            return
        }
    fi
    tag="${check_proto}-${server}"
    local base_tag="$tag"
    local count=1
    while jq -e --arg t "$tag" \
        '.outbounds[] | select(.tag == $t)' \
        "$outbound_file" >/dev/null 2>&1; do
        tag="${base_tag}_${count}"
        ((count++))
    done
    if [ "$tag" != "$base_tag" ]; then
        yellow "注意：标签 '${base_tag}' 已存在，自动重命名为 '${tag}'"
    fi
    if [ -n "$user" ] && [ -n "$password" ]; then
        jq --arg type "$outbound_type" \
           --arg tag "$tag" \
           --arg server "$server" \
           --arg port "$port" \
           --arg user "$user" \
           --arg password "$password" \
           '.outbounds += [{
               "type": $type,
               "tag": $tag,
               "server": $server,
               "server_port": ($port | tonumber),
               "username": $user,
               "password": $password
           }]' \
           "$outbound_file" > "${outbound_file}.tmp" && \
           mv "${outbound_file}.tmp" "$outbound_file"
    else
        jq --arg type "$outbound_type" \
           --arg tag "$tag" \
           --arg server "$server" \
           --arg port "$port" \
           '.outbounds += [{
               "type": $type,
               "tag": $tag,
               "server": $server,
               "server_port": ($port | tonumber)
           }]' \
           "$outbound_file" > "${outbound_file}.tmp" && \
           mv "${outbound_file}.tmp" "$outbound_file"

    fi
    systemctl reload sing-box
    green "\n代理出站 '${tag}' 已成功添加！"
    sleep 1.5
    warp_manage
}

delete_socks5_proxy() {
    clear
    green "=== 出站代理管理 (删除) ==="
    
    local tags=($(jq -r '.outbounds[] | select(.tag != "direct" and .tag != "wireguard-out") | .tag' "$outbound_file" 2>/dev/null))
    
    if [ ${#tags[@]} -eq 0 ]; then
        yellow "当前没有可管理的自定义出站。"
        sleep 2
        warp_manage
        return
    fi
    
    green "正在检测所有出站的连通性及延迟，请稍候 (最长5秒)..."
    echo ""
    local tmp_dir=$(mktemp -d)
    local i=1
    for tag in "${tags[@]}"; do
        (
            local proxy_json=$(jq -r --arg t "$tag" '.outbounds[] | select(.tag == $t)' "$outbound_file")
            local type=$(echo "$proxy_json" | jq -r '.type // ""')
            local server=$(echo "$proxy_json" | jq -r '.server // ""')
            local port=$(echo "$proxy_json" | jq -r '.server_port // ""')
            local user=$(echo "$proxy_json" | jq -r '.username // ""')
            local pass=$(echo "$proxy_json" | jq -r '.password // ""')
            
            local status_str=""
            if [[ "$type" == "socks" || "$type" == "http" ]] && [[ -n "$server" && -n "$port" ]]; then
                local auth=""
                [ -n "$user" ] && [ -n "$pass" ] && auth="${user}:${pass}@"
                
                local scheme="socks5h"
                [ "$type" == "http" ] && scheme="http"
                
                local proxy_url="${scheme}://${auth}${server}:${port}"
                
                local curl_out=$(curl -m 5 -s -o /dev/null -w "%{http_code}|%{time_total}" -x "$proxy_url" "https://www.gstatic.com/generate_204")
                local http_code=$(echo "$curl_out" | cut -d'|' -f1)
                local time_total=$(echo "$curl_out" | cut -d'|' -f2)
                
                if [ "$http_code" == "204" ] || [ "$http_code" == "200" ]; then
                    local ms_delay=$(awk -v t="$time_total" 'BEGIN{printf "%.0f", t * 1000}')
                    status_str="${green}[延迟: ${ms_delay} ms]${re}"
                else
                    status_str="${red}[连接超时/不通]${re}"
                fi
            else
                status_str="${yellow}[${type}]${re}"
            fi
            
            echo "$status_str" > "$tmp_dir/$i.res"
        ) &  # 这个 & 符号代表放入后台并发执行
        ((i++))
    done
    
    wait
    
    local display_lines=()
    i=1
    for tag in "${tags[@]}"; do
        local status_str=""
        if [ -f "$tmp_dir/$i.res" ]; then
            status_str=$(cat "$tmp_dir/$i.res")
        fi
        display_lines+=("  [${green}${i}${re}] . ${skyblue}${tag}${re} ${status_str}")
        ((i++))
    done
    
    rm -rf "$tmp_dir"
    
    green "当前可用出站列表:"
    for line in "${display_lines[@]}"; do
        echo -e "$line"
    done
    
    echo ""
    purple "0. 返回上级菜单"
    echo -e "---------------------------------"
    echo -e "提示: 请直接输入 ${red}对应数字${re} 删除无效或不需要的出站"
    reading "请输入你要删除的编号: " input
    
    if [ "$input" == "0" ]; then
        warp_manage
        return
    fi
    
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        if [ "$input" -lt 1 ] || [ "$input" -gt "${#tags[@]}" ]; then
            red "输入的数字编号无效！"
            sleep 1; delete_socks5_proxy; return
        fi
        
        local tag="${tags[$((input-1))]}"
        
        if [[ "$tag" == "wireguard-out" || "$tag" == "direct" ]]; then
            red "脚本内置出站，不可删除！"
            sleep 2; delete_socks5_proxy; return
        fi

        jq --arg tag "$tag" 'del(.outbounds[] | select(.tag == $tag))' "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
        jq --arg tag "$tag" '
            if .route.rules then
                del(.route.rules[] | select(.outbound == $tag or .outbound_tag == $tag))
            else
                .
            end
        ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

        systemctl reload sing-box
        green "\n✅ 代理出站 '${tag}' 及其绑定的分流规则已彻底删除！"
        sleep 1.5
        delete_socks5_proxy
        return
    else
        red "输入格式有误，请输入列表内对应的数字！"
        sleep 1; delete_socks5_proxy; return
    fi
}        

delete_rule_menu() {
    clear
    green "=== 删除分流规则 ==="
    local rule_count=$(jq '.route.rules | length' "$route_file" 2>/dev/null || echo 0)

    if [ "$rule_count" -eq 0 ]; then
        yellow "当前没有任何启用的分流规则！"; sleep 2; warp_manage; return
    fi

    echo ""
    green "当前已启用的分流规则列表:"
    
    jq -r '
        {"vmess-ws": "vmess-argo", "vless-reality": "xtls-reality", "hysteria2": "hysteria2", "tuic": "tuic"} as $inMap
        | .route.rules | to_entries[] | 
        (if .value.rule_set then "[预设规则] \(.value.rule_set | join(", "))" 
         elif .value.domain_suffix then "[域名] \(.value.domain_suffix | join(", "))" 
         else "[所有流量]" end) as $p1
        | (if .value.inbound and (.value.inbound | length > 0) then ($inMap[.value.inbound[0]] // .value.inbound[0]) else "全部节点" end) as $p2
        | "\(.key + 1)|\($p1)|\($p2)|\(.value.outbound)"
    ' "$route_file" 2>/dev/null | while IFS='|' read -r idx p1 p2 p3; do
        [ -z "$idx" ] && continue
        # 完美对齐并上色，显示格式： 1. [预设规则] openai - tuic - 出站: 🌐_socks5
        echo -e "  ${green}${idx}.${re} ${skyblue}${p1}${re} - ${green}${p2}${re} - ${purple}出站: ${p3}${re}"
    done

    echo ""
    purple "0. 返回上级菜单"
    skyblue "---------------------------------"
    reading "请输入要删除的规则序号: " del_input
    
    if [ "$del_input" == "0" ]; then
        warp_manage; return
    fi
    
    if [[ ! "$del_input" =~ ^[0-9]+$ ]] || [ "$del_input" -lt 1 ] || [ "$del_input" -gt "$rule_count" ]; then
        red "序号无效，请输入列表中对应的数字！"; sleep 1; delete_rule_menu; return
    fi
    
    local index=$((del_input - 1))
    jq --argjson idx "$index" 'del(.route.rules[$idx])' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
    
    systemctl reload sing-box
    green "第 ${del_input} 条分流规则已成功删除！"
    sleep 1.5
    warp_manage
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
# 主菜单
menu() {
   singbox_status=$(check_singbox 2>/dev/null)
   nginx_status=$(check_nginx 2>/dev/null)
   
   clear
   echo ""
   green "Telegram群组: ${purple}https://t.me/eooceu${re}"
   green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
   green "${purple}快捷命令sb或者b${re}  清屏 clear"
   purple "=== 老王sing-box四合一安装脚本 1.7===\n"
   printf "${purple}--Nginx 状态: %s${re}\n" "$(to_chinese "$nginx_status")"
   singbox_start_time=$(systemctl show -p ExecMainStartTimestamp --value sing-box 2>/dev/null)
   if [ -n "$singbox_start_time" ]; then
    singbox_start_ts=$(date -d "$singbox_start_time" +%s 2>/dev/null)
    singbox_now_ts=$(date +%s)
    singbox_uptime=$((singbox_now_ts - singbox_start_ts))
    singbox_uptime_text="$(printf '%d天 %02d小时 %02d分钟 %02d秒' $((singbox_uptime/86400)) $(((singbox_uptime%86400)/3600)) $(((singbox_uptime%3600)/60)) $((singbox_uptime%60)))"
    else
    singbox_uptime_text="未运行"
   fi
   printf "${purple}singbox 状态: %s${re}\n" "$(to_chinese "$singbox_status")"
   printf "${purple}singbox 运行: %s${re}\n\n" "$singbox_uptime_text"
   printf "%b%-28s%b%s%b\n" "$green" "1. 安装sing-box" "$red" "10. 开启BBR" "$re"
   printf "%b%-28s%b%s%b\n" "$green" "2. 卸载sing-box" "$red" "11. 更新脚本" "$re"
   printf "%b%-28s%b%s%b\n" "$green" "3. sing-box管理" "$red" "12. iptables" "$re"
   printf "%b%-28s%b%s%b\n" "$green" "4. cf管理" "$red" "13. 快捷指令" "$re"
   printf "%b%-32s%b%s%b\n" "$green" "5. 查看节点信息" "$red" "14. 本机信息" "$re"
   printf "%b%-32s%b%s%b\n" "$green" "6. 配置文件查看" "$red" "15. WARP分流管理" "$re"
   printf "%b%-32s%b%s%b\n" "$green" "7. 管理节点订阅" "$red" "16. token"    "$re"
   printf "%b%-28s%b%s%b\n" "$green" "8. 更新sing-box"                   "$re"
   printf "%b%-32s%b%s%b\n" "$green" "9. 添加删除节点"                     "$re"
   echo
   printf "%b%-32s%b%s%b\n" "$green" "99. 查看错误信息" "$red" "0. 退出脚步" "$re"
   reading "请输入数字选择: " choice
   echo ""
}

# 捕获 Ctrl+C 退出信号
trap 'red "已取消操作"; exit' INT

# 主循环
while true; do
   menu
   case "${choice}" in
        1)  
            check_singbox &>/dev/null; check_singbox=$?
            if [ ${check_singbox} -eq 0 ]; then
                yellow "sing-box 已经安装！\n"
            else
			    optimize_dns
                manage_packages install nginx jq tar openssl lsof coreutils
                install_singbox
				TRAFFIC_SCRIPT_URL="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing-box-name.sh"
TRAFFIC_SCRIPT="/etc/sing-box/sing-box-name.sh"
curl -fsSL "$TRAFFIC_SCRIPT_URL" -o "${TRAFFIC_SCRIPT}.new" 2>/dev/null
if [ -s "${TRAFFIC_SCRIPT}.new" ]; then
    mv -f "${TRAFFIC_SCRIPT}.new" "$TRAFFIC_SCRIPT"
fi
chmod 700 "$TRAFFIC_SCRIPT"
"$TRAFFIC_SCRIPT" --init >/dev/null 2>&1 || true
                if command_exists systemctl; then
                    main_systemd_services
                elif command_exists rc-update; then
                    alpine_openrc_services
                    change_hosts
                    rc-service sing-box restart
                else
                    echo "Unsupported init system"
                    exit 1 
                fi

                sleep 5
                
                add_nginx_conf
				create_shortcut
				setup_vps_traffic_stats
            fi
           ;;
        2) uninstall_singbox ;;
        3) manage_singbox ;;
        4) manage_cf ;;
        5) check_nodes ;;
        6) edit_singbox_files ;;
        7) disable_open_sub ;;
		8) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing.sh)
		   ;;
		9) manage_nodes_menu ;;
	    10) bbr_menu ;;
		11) update_script ;;
		12) iptables_ssl ;;
		13) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/aa.sh)
		   ;;
		14) vps_s ;;
		15)  warp_manage ;;
		
		16)  token_manage ;;
	    
		99) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing-boxjc.sh)
		   ;;
		0) exit 0 ;;
        *) red "无效的选项" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
done
