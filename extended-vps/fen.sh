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
