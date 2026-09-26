# ── 底层请求封装（支持 Global Key 或 Token 自动切换）──
cf_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local args=(
        -sS
        -X "$method"
        -H "Content-Type: application/json"
    )
    if [[ -n "${CF_TOKEN:-}" ]]; then
        args+=(-H "Authorization: Bearer $CF_TOKEN")
    else
        args+=(
            -H "X-Auth-Email: $CF_EMAIL"
            -H "X-Auth-Key: $CF_KEY"
        )
    fi
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" \
        "https://api.cloudflare.com/client/v4${endpoint}"
}
# ── 辅助函数：获取 Zone ID  ──────
cf_find_zone() {
    local domain="$1"
    local zones best_name="" best_id=""    
    zones=$(cf_call GET "/zones?per_page=500" 2>/dev/null | \
        jq -r '.result[]? | "\(.name) \(.id)"' 2>/dev/null)
    if [[ -z "$zones" ]]; then
        return 1
    fi
    while IFS=' ' read -r zone_name zone_id; do
        [[ -z "$zone_name" || -z "$zone_id" ]] && continue
        if [[ "$domain" == "$zone_name" ||
              "$domain" == *".$zone_name" ]]; then
            if [[ ${#zone_name} -gt ${#best_name} ]]; then
                best_name="$zone_name"
                best_id="$zone_id"
            fi
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || return 1
    echo "$best_id"
}

# ── 自动添加或【修改/覆盖】 DNS 记录 ──────────
cf_upsert_dns() {
    local zone_id="$1" domain="$2" raw_ip="$3"
    local existing rid payload type clean_ip
    clean_ip="${raw_ip//[/}"
    clean_ip="${clean_ip//]/}"
    if [[ "$clean_ip" =~ ":" ]]; then
        type="AAAA"
    else
        type="A"
    fi
    existing=$(cf_call GET "/zones/$zone_id/dns_records?type=$type&name=$domain" | jq '.result[0] // empty')
    payload=$(jq -n --arg n "$domain" --arg c "$clean_ip" --arg t "$type" '{type:$t,name:$n,content:$c,proxied:true,ttl:1}')
    
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        rid=$(echo "$existing" | jq -r '.id')
        cf_call PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" >/dev/null
    else
    cf_call POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
fi
}
cf_get_zone_id_by_domain() {
    local domain="$1"
    local response zone
    zone="$domain"
    while [[ "$zone" == *.* ]]; do
        response=$(cf_call GET "/zones?name=$zone")
        if echo "$response" | jq -e '.success == true and (.result | length > 0)' >/dev/null 2>&1; then
            selected_zone_id=$(echo "$response" | jq -r '.result[0].id')
            export selected_zone_id
            return 0
        fi
        zone="${zone#*.}"
    done
    return 1
}
# ── 删除 Cloudflare DNS 记录 ──
cf_delete_dns() {
    local zone_id="$1"
    local domain="$2"
    local records rid
    records=$(cf_call GET \
        "/zones/${zone_id}/dns_records?name=${domain}" \
        | jq -r '.result[]?.id')
    [[ -z "$records" ]] && return 0
    while read -r rid; do
        [[ -z "$rid" ]] && continue
        cf_call DELETE \
            "/zones/${zone_id}/dns_records/${rid}" \
            >/dev/null
    done <<< "$records"
}

# ── 设置 Cloudflare SSL 模式 (Flexible/Full/Strict) ─
cf_set_ssl() {
    local zone_id="$1"
    local ssl_mode="$2"
    local payload
    local response
    local ssl_name
    [[ -z "$zone_id" || -z "$ssl_mode" ]] && return 1
    case "$ssl_mode" in
        flexible)
            ssl_name="灵活(Flexible)"
            ;;
        full)
            ssl_name="完全(Full)"
            ;;
        strict)
            ssl_name="完全严格(Full Strict)"
            ;;
        *)
            ssl_name="$ssl_mode"
            ;;
    esac
    payload=$(jq -n \
        --arg v "$ssl_mode" \
        '{value:$v}')
    response=$(cf_call PATCH \
        "/zones/${zone_id}/settings/ssl" \
        "$payload")
    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        green "Cloudflare SSL 模式已设置为: $ssl_name"
        return 0
    fi
    yellow "Cloudflare SSL 模式设置失败"
    echo "$response" | jq -r '.errors[]?.message // empty' 2>/dev/null
    return 1
}
# ── Cloudflare Origin Rules 获取 ──
cf_get_origin_rules() {
    local zone_id="$1"
    local response

    [[ -z "$zone_id" ]] && {
        echo "[]"
        return 1
    }
    response=$(cf_call GET \
        "/zones/${zone_id}/rulesets/phases/http_request_origin/entrypoint")
    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        echo "$response" | jq -c '.result.rules // []'
    else
        echo "[]"
    fi
}

# ── Cloudflare Origin Rules 管理 ─────────────────────────
cf_put_origin_rules() {
    local zone_id="$1"
    local rules_json="$2"
    [[ -z "$zone_id" ]] && return 1
    [[ -z "$rules_json" ]] && return 1
    if ! printf '%s' "$rules_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
        red "Origin Rules 数据不是合法 JSON"
        return 1
    fi
    local max_rules=10
    local count
    local remove_count
    count=$(printf '%s' "$rules_json" | jq length)
    if [[ "$count" -gt "$max_rules" ]]; then
        remove_count=$((count - max_rules))
        yellow "Origin Rules 超过限制，需要清理 ${remove_count} 条旧规则..."
        rules_json=$(printf '%s' "$rules_json" | jq \
            --argjson num "$remove_count" '
            [
                .[]
                | select(
                    (.description // "")
                    | startswith("Auto_Script:")
                )
            ] as $old

            |
            (
                [
                    .[]
                    | select(
                        (.description // "")
                        | startswith("Auto_Script:")
                        | not
                    )
                ]
                +
                ($old[$num:])
            )
        ')
    fi
    local payload
    payload=$(printf '%s' "$rules_json" | jq -c '{rules:.}')
    if [[ -z "$payload" ]]; then
        red "生成 Origin Rules 请求数据失败"
        return 1
    fi
    local response
    response=$(cf_call PUT \
        "/zones/${zone_id}/rulesets/phases/http_request_origin/entrypoint" \
        "$payload")

    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        return 0
    fi
    yellow "Cloudflare Origin Rules 下发失败："
    echo "$response" | jq -r '.errors[]?.message // empty'
    return 1
}

set_domain_origin_port() {
    local zone_id="$1"
    local domain="$2"
    local target_port="$3"

    local pfx="${MANAGED_PREFIX:-Auto_Script:}"
    local existing
    local kept
    local new_managed
    local merged

    [[ -z "$zone_id" ]] && return 1
    [[ -z "$domain" ]] && return 1

    if [[ ! "$target_port" =~ ^[0-9]+$ ]]; then
        red "无效的回源端口：$target_port"
        return 1
    fi
    existing=$(cf_get_origin_rules "$zone_id")
    if [[ -z "$existing" || "$existing" == "null" ]]; then
        existing='[]'
    fi
    if ! printf '%s' "$existing" | jq -e 'type == "array"' >/dev/null 2>&1; then
        existing='[]'
    fi
    kept=$(printf '%s' "$existing" | jq -c \
        --arg d "$domain" \
        --arg pfx "$pfx" '
        [
            .[]
            | select(
                (
                    (.description // "")
                    | startswith($pfx)
                ) == false
                or
                (
                    (.expression // "")
                    | ascii_downcase
                    | contains(
                        "http.host eq \"" +
                        ($d | ascii_downcase) +
                        "\""
                    )
                ) == false
            )
        ]
    ' 2>/dev/null)
    [[ -z "$kept" ]] && kept='[]'
    new_managed=$(jq -n -c \
        --arg d "$domain" \
        --arg pfx "$pfx" \
        --arg port "$target_port" '
        [
            {
                description: ($pfx + "VLESS_WSTLS_CDN_" + $d),
                enabled: true,
                expression: ("(http.host eq \"" + $d + "\")"),
                action: "route",
                action_parameters: {
                    origin: {
                        port: ($port | tonumber)
                    }
                }
            }
        ]
    ' 2>/dev/null)

    if [[ -z "$new_managed" ]]; then
        red "生成新的 Cloudflare Origin Rule 失败"
        return 1
    fi
    merged=$(printf '%s\n%s\n' "$kept" "$new_managed" | jq -s -c '.[0] + .[1]' 2>/dev/null)
    if [[ -z "$merged" ]]; then
        red "合并 Cloudflare Origin Rules 失败"
        return 1
    fi
    if cf_put_origin_rules "$zone_id" "$merged"; then
        return 0
    fi
    return 1
}
#手动添加回源规则
cf_add_origin_rule_menu() {
    local port prefix ssl_choice ssl_mode full_domain existing kept new_rule merged server_ip
    echo
    reading "请输入回源端口: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        red "端口号无效"
        return 1
    fi
    echo
    cf_select_zone || return 1
    reading "请输入域名前缀: " prefix
    if [[ -z "$prefix" ]]; then
        red "域名前缀不能为空"
        return 1
    fi
    full_domain="${prefix}.${zone_domain}"
        local current_ssl
    current_ssl=$(cf_call GET "/zones/${zone_id}/settings/ssl" | jq -r '.result.value // empty' 2>/dev/null)
    echo
    skyblue "当前 Cloudflare SSL 模式: ${current_ssl:-未知}"
    green "1) 完全 (Full)"
    green "2) 灵活 (Flexible)"
    reading "请输入选择 [1-2]（回车保持当前）: " ssl_choice
    if [[ -n "$ssl_choice" ]]; then
        case "$ssl_choice" in
            1)
                ssl_mode="full"
                ;;
            2)
                ssl_mode="flexible"
                ;;
            *)
                red "无效选择！"
                return 1
                ;;
        esac
        cf_set_ssl "$zone_id" "$ssl_mode" || return 1
    else
        ssl_mode="$current_ssl"
        green "保持当前 SSL 模式"
    fi
    server_ip=$(get_realip)
    if [[ -z "$server_ip" ]]; then
        red "获取服务器 IP 失败"
        return 1
    fi
    if ! cf_upsert_dns "$zone_id" "$full_domain" "$server_ip"; then
        red "DNS 解析添加失败"
        return 1
    fi
    green "DNS 解析添加成功（已开启小黄云）"
    existing=$(cf_get_origin_rules "$zone_id")
    [[ -z "$existing" || "$existing" == "null" ]] && existing='[]'
    if ! printf '%s' "$existing" | jq -e 'type == "array"' >/dev/null 2>&1; then
        existing='[]'
    fi
    kept=$(printf '%s' "$existing" | jq -c --arg d "$full_domain" '
        [
            .[]
            | select(
                (
                    (.expression // "")
                    | ascii_downcase
                    | contains("http.host eq \"" + ($d | ascii_downcase) + "\"")
                ) == false
            )
        ]
    ' 2>/dev/null)
    [[ -z "$kept" ]] && kept='[]'
    new_rule=$(jq -n -c --arg d "$full_domain" --arg port "$port" '
        [
            {
                description: $d,
                enabled: true,
                expression: ("(http.host eq \"" + $d + "\")"),
                action: "route",
                action_parameters: {
                    origin: {
                        port: ($port | tonumber)
                    }
                }
            }
        ]
    ' 2>/dev/null)
    if [[ -z "$new_rule" ]]; then
        red "生成 Cloudflare Origin Rule 失败"
        return 1
    fi
    merged=$(printf '%s\n%s\n' "$kept" "$new_rule" | jq -s -c '.[0] + .[1]' 2>/dev/null)
    if [[ -z "$merged" ]]; then
        red "合并 Cloudflare Origin Rules 失败"
        return 1
    fi
    if cf_put_origin_rules "$zone_id" "$merged"; then
        echo
        green "Cloudflare 回源规则创建成功"
        green "域名: $full_domain"
        green "回源端口: $port"
        green "SSL 模式: $ssl_mode"
        return 0
    fi
    red "Cloudflare 回源规则创建失败"
    return 1
}
#手动删除回源规则和dns解析
 cf_delete_origin_rule_menu() {
    local existing count choice selected_rule rule_domain kept desc port confirm i
    echo
    cf_select_zone || return 1
    existing=$(cf_get_origin_rules "$zone_id")
    if [[ -z "$existing" || "$existing" == "null" ]] || ! printf '%s' "$existing" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        yellow "该域名没有 Cloudflare 回源规则"
        return 0
    fi
    count=$(printf '%s' "$existing" | jq 'length')
    echo
    skyblue "请选择要删除的回源规则："
    echo "=========================================="
    for ((i=0; i<count; i++)); do
        desc=$(printf '%s' "$existing" | jq -r ".[$i].description // \"未命名规则\"")
        port=$(printf '%s' "$existing" | jq -r ".[$i].action_parameters.origin.port // \"-\"")
        echo "  $((i + 1))) $desc  → 端口: $port"
    done
    echo "=========================================="
    reading "请输入选择 [1-$count]: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
        red "无效选择！"
        return 1
    fi
    selected_rule=$(printf '%s' "$existing" | jq -c ".[$((choice - 1))]")
    rule_domain=$(printf '%s' "$selected_rule" | jq -r '
        .expression
        | capture("http\\.host eq \"(?<domain>[^\"]+)\"")
        | .domain
    ' 2>/dev/null)
    if [[ -z "$rule_domain" || "$rule_domain" == "null" ]]; then
        red "无法从回源规则中获取域名"
        return 1
    fi
    echo
    yellow "将删除回源规则: $rule_domain"
    yellow "同时删除 DNS 解析: $rule_domain"
    read -rp "确认删除？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && {
        yellow "已取消"
        return 0
    }
    kept=$(printf '%s' "$existing" | jq -c --argjson index "$((choice - 1))" '
        to_entries
        | map(select(.key != $index))
        | map(.value)
    ')
    if ! cf_put_origin_rules "$zone_id" "$kept"; then
        red "Cloudflare 回源规则删除失败"
        return 1
    fi
    green "Cloudflare 回源规则已删除"
    if cf_delete_dns "$zone_id" "$rule_domain"; then
        green "${rule_domain} DNS 解析已删除"
    else
        red "${rule_domain} DNS 解析删除失败"
        return 1
    fi
    return 0
}

# ── 删除 Cloudflare CDN 回源规则 ──
cf_remove_cdn_rules() {
    local domain="$1"
    [[ -z "$domain" ]] && {
        yellow "未获取到 CDN 域名，跳过删除回源规则"
        return 0
    }
    if [[ -z "${CF_TOKEN:-}" &&
          ( -z "${CF_EMAIL:-}" || -z "${CF_KEY:-}" ) ]]; then
        echo
        skyblue "请输入 Cloudflare 验证信息"
        green "1) Cloudflare API Token"
        green "2) Cloudflare Global API Key (邮箱 + Key)"
        local cf_type
        reading "请输入选择 [1-2]（默认 1）: " cf_type
        [[ -z "$cf_type" ]] && cf_type=1
        case "$cf_type" in
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
    local zone_id
    local rules
    local kept
    zone_id=$(cf_find_zone "$domain" 2>/dev/null)
    if [[ -z "$zone_id" ]]; then
        yellow "未找到 ${domain} 对应 Zone"
        return 1
    fi
    rules=$(cf_get_origin_rules "$zone_id")
    [[ -z "$rules" || "$rules" == "null" ]] && {
        green "没有 Cloudflare 回源规则"
        cf_delete_dns "$zone_id" "$domain"
        return 0
    }
    kept=$(echo "$rules" | jq -c \
    --arg d "$domain" '
    [
        .[]
        | select(
            (
                (.description // "")
                | startswith("Auto_Script:")
            )
            and
            (
                (.description // "")
                | test("(^|_)"+$d+"$")
            )
            | not
        )
    ]')
    if cf_put_origin_rules "$zone_id" "$kept"; then
        green "${domain} Cloudflare 回源规则已删除"
        cf_delete_dns "$zone_id" "$domain"
        green "${domain} DNS 解析已删除"
        return 0
    else
        yellow "Cloudflare 回源规则删除失败"
        return 1
    fi
}

# ── 查看 / 删除 Cloudflare Tunnel ──
cf_list_tunnels() {
    local tunnels count choice tunnel_id tunnel_name tunnel_status
    local connections config_data hostnames connection_count
    local origin_ip i total
    declare -a tunnel_ids
    ip_address
    tunnels=$(cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&per_page=100" 2>/dev/null)
    [[ -z "$tunnels" ]] && { red "获取 Cloudflare Tunnel 失败！"; return 1; }
    if [[ "$(echo "$tunnels" | jq -r '.success // false')" != "true" ]]; then
        red "获取 Cloudflare Tunnel 失败！"
        echo "$tunnels" | jq -r '.errors[]?.message // empty'
        return 1
    fi
    count=$(echo "$tunnels" | jq '.result | length')
    if [[ "$count" -eq 0 ]]; then
        yellow "暂无 Cloudflare Tunnel。"
        reading "按回车返回..." _
        return 0
    fi
    while true; do
        clear
        echo -e "${skyblue}==========================================${re}"
        echo -e "${skyblue}        Cloudflare Tunnel${re}"
        echo -e "${skyblue}==========================================${re}"
        i=1
        unset tunnel_ids
        declare -a tunnel_ids
        while IFS='|' read -r tunnel_id tunnel_name tunnel_status; do
            [[ -z "$tunnel_id" ]] && continue
            tunnel_ids[$i]="$tunnel_id"
            case "$tunnel_status" in
                healthy)   tunnel_status="🟢 正常" ;;
                degraded)  tunnel_status="🟡 异常" ;;
                down)      tunnel_status="🔴 离线" ;;
                inactive)  tunnel_status="⚪ 未运行" ;;
                *)         tunnel_status="⚪ 未知" ;;
            esac
            echo -e "${green}${i})${re} ${tunnel_name}"
            echo "   状态: $tunnel_status"
            config_data=$(cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" 2>/dev/null)
            hostnames=$(echo "$config_data" | jq -r '.result.config.ingress[]?.hostname // empty' | paste -sd ',' -)
            [[ -n "$hostnames" ]] && echo "   域名: $hostnames" || echo "   域名: -"
            connections=$(cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/connections" 2>/dev/null)
            if [[ "$(echo "$connections" | jq -r '.success // false')" == "true" ]]; then
                connection_count=$(echo "$connections" | jq '[.result[]?.conns[]?] | length')
                if [[ "$connection_count" -gt 0 ]]; then
                    echo "   服务器IP:"
                    while read -r origin_ip; do
                        [[ -z "$origin_ip" ]] && continue
                        if [[ "$origin_ip" == "$ipv4_address" || "$origin_ip" == "$ipv6_address" ]]; then
                            echo -e "      ${red}${origin_ip} (本机ip)${re}"
                        else
                            echo "      $origin_ip"
                        fi
                    done < <(echo "$connections" | jq -r '.result[]?.conns[]?.origin_ip // empty' | sort -u)
                else
                    echo "   服务器IP: -"
                fi
            else
                echo "   服务器IP: -"
            fi
            echo "------------------------------------------"
            ((i++))
        done < <(echo "$tunnels" | jq -r '.result[] | "\(.id)|\(.name)|\(.status // "unknown")"')
        total=$((i - 1))
        echo -e "${red}0)${re} 返回"
        echo -e "${skyblue}==========================================${re}"
        reading "请输入选择 [0-$total]: " choice
        [[ "$choice" == "0" ]] && return 0
        if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || "$choice" -lt 1 || "$choice" -gt "$total" ]]; then
            red "无效选择！"
            sleep 1
            continue
        fi
        tunnel_id="${tunnel_ids[$choice]}"
        [[ -z "$tunnel_id" ]] && { red "Tunnel ID 获取失败！"; sleep 1; continue; }
        cf_tunnel_detail "$tunnel_id"
        tunnels=$(cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&per_page=100" 2>/dev/null)
        [[ "$(echo "$tunnels" | jq -r '.success // false')" != "true" ]] && return 1
    done
}


# ── Tunnel 详细信息 / 删除 ──
cf_tunnel_detail() {
    local tunnel_id="$1"
    local tunnel_data tunnel_name tunnel_status
    local connections config_data hostnames choice
    local delete_response dns_name dns_zone_id dns_record dns_id
    local origin_ip

    tunnel_data=$(cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" 2>/dev/null)
    if [[ "$(echo "$tunnel_data" | jq -r '.success // false')" != "true" ]]; then
        red "获取 Tunnel 信息失败！"
        sleep 1
        return
    fi

    tunnel_name=$(echo "$tunnel_data" | jq -r '.result.name // "-"')
    tunnel_status=$(echo "$tunnel_data" | jq -r '.result.status // "unknown"')

    case "$tunnel_status" in
        healthy)   tunnel_status="🟢 正常" ;;
        degraded)  tunnel_status="🟡 异常" ;;
        down)      tunnel_status="🔴 离线" ;;
        inactive)  tunnel_status="⚪ 未运行" ;;
        *)         tunnel_status="⚪ 未知" ;;
    esac

    config_data=$(cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" 2>/dev/null)
    hostnames=$(echo "$config_data" | jq -r '.result.config.ingress[]?.hostname // empty' | paste -sd ',' -)

    connections=$(cf_call GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/connections" 2>/dev/null)
    clear
    echo -e "${skyblue}==========================================${re}"
    echo -e "${skyblue}        Tunnel 详细信息${re}"
    echo -e "${skyblue}==========================================${re}"
    echo "隧道名称: $tunnel_name"
    echo "域名: ${hostnames:-"-"}"
    echo "状态: $tunnel_status"

    if [[ "$(echo "$connections" | jq -r '.success // false')" == "true" ]]; then
        origin_ip=$(echo "$connections" | jq -r '.result[]?.conns[]?.origin_ip // empty' | sort -u | head -n1)
        echo "服务器IP: ${origin_ip:-"-"}"
    else
        echo "服务器IP: -"
    fi
    echo -e "${skyblue}==========================================${re}"
    echo -e "${yellow}1)${re} 删除此 Tunnel"
    echo -e "${red}0)${re} 返回"
    echo -e "${skyblue}==========================================${re}"
    reading "请输入选择 [0-1]: " choice

    case "$choice" in
 1)
    local connections_ips is_local_tunnel
    local dns_name dns_zone_id dns_record dns_id
    ip_address
    connections_ips=$(echo "$connections" |
        jq -r '.result[]?.conns[]?.origin_ip // empty' |
        sort -u)
    is_local_tunnel=0
    if [[ -n "$ipv4_address" ]] &&
       echo "$connections_ips" | grep -Fxq "$ipv4_address"; then
        is_local_tunnel=1
    fi
    if [[ -n "$ipv6_address" ]] &&
       echo "$connections_ips" | grep -Fxq "$ipv6_address"; then
        is_local_tunnel=1
    fi
    if [[ "$is_local_tunnel" == "1" ]]; then
        systemctl stop sing-box 2>/dev/null
        sleep 2
    fi
    delete_response=$(cf_call DELETE \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" \
        2>/dev/null)
    if [[ "$(echo "$delete_response" | jq -r '.success // false')" == "true" ]]; then
        if [[ "$is_local_tunnel" == "1" ]]; then
            rm -f /etc/sing-box/conf/cloudflared.json
        fi
        if [[ -n "$hostnames" ]]; then
            while read -r dns_name; do
                [[ -z "$dns_name" ]] && continue
                dns_zone_id=$(cf_call GET \
                    "/zones?name=${dns_name#*.}&per_page=1" \
                    2>/dev/null |
                    jq -r '.result[0].id // empty')
                [[ -z "$dns_zone_id" ]] && continue
                dns_record=$(cf_call GET \
                    "/zones/${dns_zone_id}/dns_records?name=${dns_name}&type=CNAME&per_page=100" \
                    2>/dev/null)
                while read -r dns_id; do
                    [[ -z "$dns_id" ]] && continue
                    cf_call DELETE \
                        "/zones/${dns_zone_id}/dns_records/${dns_id}" \
                        >/dev/null 2>&1
                done < <(echo "$dns_record" | jq -r '.result[]?.id // empty')
            done <<< "$(echo "$hostnames" | tr ',' '\n')"
        fi
        if [[ "$is_local_tunnel" == "1" ]]; then
            systemctl restart sing-box 2>/dev/null
        fi
        green "Tunnel 删除成功！"
    else
        if [[ "$is_local_tunnel" == "1" ]]; then
            systemctl start sing-box 2>/dev/null
        fi
        red "Tunnel 删除失败！"
        echo "$delete_response" |
            jq -r '.errors[]?.message // empty'
    fi
    reading "按回车返回..." _
    ;;
        0)
            return 0
            ;;
        *)
            red "无效选择！"
            sleep 1
            ;;
    esac
}


# ── 添加 Cloudflare Tunnel 路由 ──
cf_add_tunnel_route() {
    local account_response
    local tunnel_data tunnel_id tunnel_name token
    local zone_response domain zone_id prefix hostname
    local config_data ingress new_config response
    local choice i total
    local port path
    declare -a zone_names zone_ids
    declare -a route_ports route_paths
    # ── 检查 Cloudflare API ──
    if [[ -z "${CF_TOKEN:-}" &&
          ( -z "${CF_EMAIL:-}" || -z "${CF_KEY:-}" ) ]]; then
        echo
        skyblue "请输入 Cloudflare 验证信息"
        green "1) Cloudflare API Token"
        green "2) Cloudflare Global API Key (邮箱 + Key)"
        local cf_type
        reading "请输入选择 [1-2]（默认 1）: " cf_type
        [[ -z "$cf_type" ]] && cf_type=1
        case "$cf_type" in
            1) cf_auth_token || return 1 ;;
            2) cf_auth_global || return 1 ;;
            *) red "无效选择！"; return 1 ;;
        esac
    fi
    # ── 获取 Account ID ──
    if [[ -z "${CF_ACCOUNT_ID:-}" ]]; then
        skyblue "正在获取 Cloudflare Account ID..."
        if [[ -n "$CF_TOKEN" ]]; then
            account_response=$(curl -sS \
                "https://api.cloudflare.com/client/v4/accounts" \
                -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json")
        else
            account_response=$(curl -sS \
                "https://api.cloudflare.com/client/v4/accounts" \
                -H "X-Auth-Email: $CF_EMAIL" \
                -H "X-Auth-Key: $CF_KEY" \
                -H "Content-Type: application/json")
        fi
        CF_ACCOUNT_ID=$(echo "$account_response" | jq -r '.result[0].id // empty')
        if [[ -z "$CF_ACCOUNT_ID" ]]; then
            red "获取 Cloudflare Account ID 失败！"
            return 1
        fi
        export CF_ACCOUNT_ID
    fi
    if [[ $# -eq 0 ]]; then
        reading "请输入程序端口: " port
        if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
            red "端口无效！"
            return 1
        fi
        route_ports[0]="$port"
        route_paths[0]="/"
    else
        if (( $# % 2 != 0 )); then
            red "参数错误！"
            red "格式：端口 路径 端口 路径 ..."
            return 1
        fi
        local args=("$@")
        local count=$(( $# / 2 ))
        for ((i=0; i<count; i++)); do
            port="${args[$((i * 2))]}"
            path="${args[$((i * 2 + 1))]}"

            if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
                red "端口无效：$port"
                return 1
            fi

            [[ -z "$path" ]] && path="/"
            [[ "$path" != /* ]] && path="/$path"

            route_ports[$i]="$port"
            route_paths[$i]="$path"
        done
    fi
# ── 查找当前服务器 Tunnel / 创建 Tunnel ──
cloudflared_conf="/etc/sing-box/conf/cloudflared.json"
local tunnel_list tunnel_data tunnel_id tunnel_name tunnel_token
local connections connections_ips origin_ip
local is_local_tunnel=0
ip_address
tunnel_list=$(cf_call GET \
    "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?per_page=100" \
    2>/dev/null)
if [[ "$(echo "$tunnel_list" |
    jq -r '.success // false' 2>/dev/null)" == "true" ]]; then
    while read -r tunnel_id; do
        [[ -z "$tunnel_id" ]] && continue
        tunnel_data=$(cf_call GET \
            "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" \
            2>/dev/null)
        [[ "$(echo "$tunnel_data" |
            jq -r '.success // false' 2>/dev/null)" != "true" ]] && continue
        connections_ips=$(echo "$tunnel_data" |
            jq -r '.result.connections[]?.origin_ip // empty' |
            sort -u)
        is_local_tunnel=0
        if [[ -n "$ipv4_address" ]] &&
           echo "$connections_ips" | grep -Fxq "$ipv4_address"; then
            is_local_tunnel=1
        fi
        if [[ -n "$ipv6_address" ]] &&
           echo "$connections_ips" | grep -Fxq "$ipv6_address"; then
            is_local_tunnel=1
        fi
        if [[ "$is_local_tunnel" == "1" ]]; then
            tunnel_name=$(echo "$tunnel_data" |
                jq -r '.result.name // "-"')
            break
        fi
    done < <(
        echo "$tunnel_list" |
            jq -r '.result[]?.id // empty'
    )
fi
# ── 当前服务器已有 Tunnel：获取 Token ──
if [[ "$is_local_tunnel" == "1" ]]; then
    green "检测到当前服务器已有 Cloudflare Tunnel"
    green "Tunnel: $tunnel_name"
    tunnel_token_response=$(cf_call GET \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token" \
        2>/dev/null)
    tunnel_token=$(echo "$tunnel_token_response" |
        jq -r '.result // empty')
    if [[ -z "$tunnel_token" || "$tunnel_token" == "null" ]]; then
        red "获取 Tunnel Token 失败！"
        return 1
    fi
# ── 当前服务器没有 Tunnel：创建新的 ──
else
    yellow "未检测到当前服务器的 Cloudflare Tunnel，正在创建..."
    if ! cf_create_tunnel; then
        red "Cloudflare Tunnel 创建失败！"
        return 1
    fi
    tunnel_token="$argo_auth"
    if [[ -z "$tunnel_token" ]]; then
        red "新 Tunnel Token 获取失败！"
        return 1
    fi
    tunnel_id=$(echo "$tunnel_token" |
        base64 -d 2>/dev/null |
        jq -r '.t // empty' 2>/dev/null)

    if [[ -z "$tunnel_id" ]]; then
        red "新 Tunnel ID 获取失败！"
        return 1
    fi
    tunnel_data=$(cf_call GET \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" \
        2>/dev/null)

    if [[ "$(echo "$tunnel_data" |
        jq -r '.success // false' 2>/dev/null)" != "true" ]]; then
        red "新创建的 Tunnel 验证失败！"
        return 1
    fi
    tunnel_name=$(echo "$tunnel_data" |
        jq -r '.result.name // "-"')
fi
# ── 无论新建还是已有，都重新生成 cloudflared.json ──
mkdir -p /etc/sing-box/conf
jq -n \
    --arg token "$tunnel_token" \
    '{
        inbounds: [
            {
                type: "cloudflared",
                tag: "cloudflared-in",
                token: $token,
                ha_connections: 4,
                protocol: "quic",
                post_quantum: true,
				edge_ip_version: 0,
				datagram_version: "v3"
            }
        ]
    }' > "$cloudflared_conf"

if [[ ! -s "$cloudflared_conf" ]]; then
    red "cloudflared.json 生成失败！"
    return 1
fi
token="$tunnel_token"
# ── 获取 Tunnel 名称 ──
tunnel_name=$(echo "$tunnel_data" |
    jq -r '.result.name // "-"')
    tunnel_name=$(echo "$tunnel_data" | jq -r '.result.name // "-"')
    zone_response=$(cf_call GET "/zones?per_page=500" 2>/dev/null)
    if [[ "$(echo "$zone_response" | jq -r '.success // false')" != "true" ]]; then
        red "获取 Cloudflare 域名失败！"
        return 1
    fi
    i=1
    while IFS='|' read -r domain zone_id; do
        [[ -z "$domain" || -z "$zone_id" ]] && continue
        echo "$i) $domain"
        zone_names[$i]="$domain"
        zone_ids[$i]="$zone_id"
        ((i++))
    done < <(
        echo "$zone_response" |
            jq -r '.result[]? | "\(.name)|\(.id)"'
    )
    total=$((i - 1))
    if [[ "$total" -lt 1 ]]; then
        red "没有找到 Cloudflare 域名！"
        return 1
    fi
    reading "请选择域名 [1-$total]: " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ||
          "$choice" -lt 1 ||
          "$choice" -gt "$total" ]]; then
        red "无效选择！"
        return 1
    fi
    domain="${zone_names[$choice]}"
    zone_id="${zone_ids[$choice]}"
    # ── 输入前缀 ──
    reading "请输入前缀或完整域名: " prefix
    prefix=$(echo "$prefix" | tr -d '[:space:]')
    prefix="${prefix#.}"
    prefix="${prefix%.}"
    if [[ -z "$prefix" ]]; then
        hostname="$domain"
    elif [[ "$prefix" == "$domain" ||
            "$prefix" == *".${domain}" ]]; then
        hostname="$prefix"
    else
        hostname="${prefix}.${domain}"
    fi
    echo
    green "Tunnel: $tunnel_name"
    green "域名: $hostname"
    for ((i=0; i<${#route_ports[@]}; i++)); do
        echo "  ${hostname}${route_paths[$i]} → 127.0.0.1:${route_ports[$i]}"
    done
    # ── 获取现有配置 ──
    config_data=$(cf_call GET \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
        2>/dev/null)
    if [[ "$(echo "$config_data" | jq -r '.success // false')" != "true" ]]; then
        red "获取 Tunnel 配置失败！"
        return 1
    fi
    ingress=$(echo "$config_data" |
        jq -c '.result.config.ingress // []')
    # ── 检查重复路由 ──
    for ((i=0; i<${#route_ports[@]}; i++)); do
        if echo "$ingress" | jq -e \
            --arg h "$hostname" \
            --arg p "${route_paths[$i]}" \
            'any(.[]?;
                .hostname == $h and
                (.path // "/") == $p
            )' >/dev/null 2>&1; then

            red "路由已存在：${hostname}${route_paths[$i]}"
            return 1
        fi
    done
        # ── 构建新路由 ──
    new_config=$(jq -n \
        --argjson ingress "$ingress" \
        --arg hostname "$hostname" \
        --argjson ports \
        "$(printf '%s\n' "${route_ports[@]}" |
            jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')" \
        --argjson paths \
        "$(printf '%s\n' "${route_paths[@]}" |
            jq -Rsc 'split("\n") | map(select(length > 0))')" \
        '
        {
            config: {
                ingress: (
                    ($ingress | map(select(.service != "http_status:404")))
                    +
                    [
                        range(0; ($ports | length)) as $i |
                        {
                            hostname: $hostname,
                            path: $paths[$i],
                            service: ("http://127.0.0.1:" + ($ports[$i] | tostring))
                        }
                    ]
                    +
                    [{service: "http_status:404"}]
                )
            }
        }')
    # ── 写入 Tunnel ──
    response=$(cf_call PUT \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
        "$new_config" \
        2>/dev/null)
        if [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]; then
        local dns_response dns_record_id dns_type dns_payload dns_content
        dns_content="${tunnel_id}.cfargotunnel.com"
        dns_response=$(cf_call GET \
            "/zones/${zone_id}/dns_records?name=${hostname}" \
            2>/dev/null)
        if [[ "$(echo "$dns_response" | jq -r '.success // false')" != "true" ]]; then
            red "获取 DNS 记录失败！"
            return 1
        fi
        dns_type=$(echo "$dns_response" |
            jq -r '.result[0].type // empty')
        if [[ -n "$dns_type" ]]; then
            if [[ "$dns_type" != "CNAME" ]]; then
                red "DNS 记录已存在且类型为 ${dns_type}，无法创建 Tunnel CNAME！"
                return 1
            fi
            dns_record_id=$(echo "$dns_response" |
                jq -r '.result[0].id // empty')
            dns_payload=$(jq -n \
                --arg n "$hostname" \
                --arg c "$dns_content" \
                '{type:"CNAME",name:$n,content:$c,proxied:true,ttl:1}')
            dns_response=$(cf_call PUT \
                "/zones/${zone_id}/dns_records/${dns_record_id}" \
                "$dns_payload" \
                2>/dev/null)
            if [[ "$(echo "$dns_response" | jq -r '.success // false')" != "true" ]]; then
                red "DNS CNAME 修改失败！"
                echo "$dns_response" |
                    jq -r '.errors[]?.message // empty'
                return 1
            fi
            green "DNS CNAME 已修改：${hostname} → ${dns_content}"
        else
            dns_payload=$(jq -n \
                --arg n "$hostname" \
                --arg c "$dns_content" \
                '{type:"CNAME",name:$n,content:$c,proxied:true,ttl:1}')
            dns_response=$(cf_call POST \
                "/zones/${zone_id}/dns_records" \
                "$dns_payload" \
                2>/dev/null)
            if [[ "$(echo "$dns_response" | jq -r '.success // false')" != "true" ]]; then
                red "DNS CNAME 添加失败！"
                echo "$dns_response" |
                    jq -r '.errors[]?.message // empty'
                return 1
            fi
            green "DNS CNAME 添加成功：${hostname} → ${dns_content}"
        fi
        ArgoDomain="$hostname"
        export ArgoDomain
        green "Tunnel 路由添加成功！"
        for ((i=0; i<${#route_ports[@]}; i++)); do
            green "${hostname}${route_paths[$i]} → 127.0.0.1:${route_ports[$i]}"
        done
        return 0
    fi
    red "Tunnel 路由添加失败！"
    echo "$response" |
        jq -r '.errors[]?.message // empty'
    return 1
}
TOKEN_FILE="/etc/sing-box/token"
token_manage() {
    mkdir -p /etc/sing-box
    echo -e "${green}1.${re} 添加 Token"
    echo -e "${green}2.${re} 删除 Token"
    reading "请选择: " choice
    case "$choice" in
        1)
            reading "请输入 Token: " token
            if [ -z "$token" ]; then
                red "Token 不能为空"
                return 1
            fi
            echo "$token" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            green "Token 添加成功"
            ;;
        2)
            if [ -f "$TOKEN_FILE" ]; then
                rm -f "$TOKEN_FILE"
                green "Token 删除成功"
            else
                yellow "Token 不存在"
            fi
            ;;
        *)
            red "无效选择"
            ;;
    esac
}
# ── Cloudflare API Token 获取 ──
cf_auth_token() {
    echo ""
    local token_file="/etc/sing-box/token"
    local cf_token
    if [ -f "$token_file" ]; then
        cf_token=$(cat "$token_file" | tr -d '[:space:]')
        if [[ -n "$cf_token" ]]; then
            green "读取本机保存的 Cloudflare Token"
            export CF_TOKEN="$cf_token"
            unset CF_EMAIL CF_KEY
            export CF_AUTH_TYPE="token"
            return 0
        fi
    fi
    green "=== Cloudflare API Token 获取 ==="
    skyblue "请按以下步骤在 Cloudflare 后台操作获取 Token："
    echo -e " 1. 登录 Cloudflare 官网，进入 \033[33m管理账户 -> API 令牌\033[0m"
    echo -e " 2. 点击右侧 \033[33m创建令牌--构建自定义权限策略\033[0m"
    echo -e " 3. 配置权限策略:选择 \033[33m所有域名\033[0m"
    echo -e " -\033[33mDNS & Zones - Zone\033[0m，权限设为 \033[32mRead (读取)\033[0m"
    echo -e " -\033[33mDNS & Zones - DNS\033[0m，权限设为 \033[32mEdit (编辑)\033[0m"
    echo -e " -\033[33mDNS & Zones - Zone Settings\033[0m，权限设为 \033[32mEdit (编辑)\033[0m"
    echo -e " -\033[33mRules & Configuration - Origin\033[0m，权限设为 \033[32mEdit (编辑)\033[0m"
    echo -e " 4. 添加策略:选择 \033[33m整个账户\033[0m"
    echo -e " -\033[33mCloudflare One / Zero Trust - Argo Tunnel\033[0m，权限设为 \033[32m(全部选择)\033[0m"
    echo -e " 5. 点击【继续以进行预览】->【创建令牌】并复制生成的字符串"
    skyblue "------------------------------------------"
    reading "请输入 Cloudflare API Token: " cf_token
    cf_token=$(echo "$cf_token" | tr -d '[:space:]')
    [[ -z "$cf_token" ]] && {
        red "Token 不能为空！"
        return 1
    }
    export CF_TOKEN="$cf_token"
    unset CF_EMAIL CF_KEY
    export CF_AUTH_TYPE="token"
    green "Token 已设置"
    return 0
}
# ── Cloudflare Global API Key 验证 ──
cf_auth_global() {
    local cf_email
    local cf_key
    reading "请输入 Cloudflare 登录邮箱: " cf_email
    cf_email=$(echo "$cf_email" | tr -d '[:space:]')
    [[ -z "$cf_email" ]] && {
        red "邮箱不能为空！"
        return 1
    }
    reading "请输入 Cloudflare Global API Key: " cf_key
    cf_key=$(echo "$cf_key" | tr -d '[:space:]')
    [[ -z "$cf_key" ]] && {
        red "API Key 不能为空！"
        return 1
    }
    export CF_EMAIL="$cf_email"
    export CF_KEY="$cf_key"
    unset CF_TOKEN
    export CF_AUTH_TYPE="global"
    return 0
}
# ── 拉取并选择 Cloudflare 域名 ──
cf_select_zone() {
    unset selected_zone_id
    skyblue "正在从 Cloudflare 拉取已托管的域名列表..."
    local response
    if [[ -n "$CF_TOKEN" ]]; then
        response=$(curl -sS --connect-timeout 10 \
            -X GET "https://api.cloudflare.com/client/v4/zones?per_page=500" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json")
    elif [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]; then
        response=$(curl -sS --connect-timeout 10 \
            -X GET "https://api.cloudflare.com/client/v4/zones?per_page=500" \
            -H "X-Auth-Email: $CF_EMAIL" \
            -H "X-Auth-Key: $CF_KEY" \
            -H "Content-Type: application/json")
    else
        red "没有检测到 Cloudflare 认证信息！"
        return 1
    fi
    if [[ -z "$response" ]]; then
        red "Cloudflare API 没有返回任何数据！"
        return 1
    fi
    local success
    success=$(echo "$response" | jq -r '.success // false' 2>/dev/null)
    if [[ "$success" != "true" ]]; then
        red "获取 Cloudflare 域名列表失败！"
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[]?.message // empty' 2>/dev/null)
        [[ -n "$error_msg" ]] && \
            red "Cloudflare: $error_msg" || \
            red "请检查 Cloudflare 认证信息和权限。"
        return 1
    fi
    local domains_and_ids
    domains_and_ids=$(echo "$response" | jq -r '.result[]? | "\(.name)|\(.id)"')
    if [[ -z "$domains_and_ids" ]]; then
        red "没有找到 Cloudflare 托管域名。"
        return 1
    fi
    declare -a domain_array
    declare -a zone_id_array
    local i=1
	local zone_name
    local zone_temp_id
    echo
    echo "=========================================="
    skyblue "请选择域名："
    echo "=========================================="
    while IFS='|' read -r zone_name zone_temp_id; do
    [[ -z "$zone_name" || -z "$zone_temp_id" ]] && continue
    local dns_count
    if [[ -n "$CF_TOKEN" ]]; then
        dns_count=$(curl -sS --connect-timeout 10 \
            -X GET "https://api.cloudflare.com/client/v4/zones/${zone_temp_id}/dns_records?per_page=1" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            | jq -r '.result_info.total_count // 0' 2>/dev/null)
    elif [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]; then
        dns_count=$(curl -sS --connect-timeout 10 \
            -X GET "https://api.cloudflare.com/client/v4/zones/${zone_temp_id}/dns_records?per_page=1" \
            -H "X-Auth-Email: $CF_EMAIL" \
            -H "X-Auth-Key: $CF_KEY" \
            -H "Content-Type: application/json" \
            | jq -r '.result_info.total_count // 0' 2>/dev/null)
    fi
    [[ -z "$dns_count" ]] && dns_count=0
    if (( dns_count > 0 )); then
    red "  $i) $zone_name  (${dns_count} 条 DNS)"
    else
    echo "  $i) $zone_name  (${dns_count} 条 DNS)"
    fi
    domain_array[$i]="$zone_name"
    zone_id_array[$i]="$zone_temp_id"
    ((i++))
    done <<< "$domains_and_ids"
    echo "=========================================="
    local total=$((i - 1))
    [[ "$total" -lt 1 ]] && {
        red "没有可用域名"
        return 1
    }
    local choice
    reading "请输入数字选择 [1-$total]: " choice
    if [[ -z "$choice" ||
          ! "$choice" =~ ^[0-9]+$ ||
          "$choice" -lt 1 ||
          "$choice" -gt "$total" ]]; then

        red "无效选择！"
        return 1
    fi
    zone_domain="${domain_array[$choice]}"
    zone_id="${zone_id_array[$choice]}"
    selected_zone_id="$zone_id"
    export selected_zone_id
    if [[ -z "$zone_domain" || -z "$zone_id" ]]; then
        red "获取 Zone 信息失败！"
        return 1
    fi
    green "已选择域名: $zone_domain"
    green "Zone ID: $zone_id"
    return 0
}
cf_update_dns_proxy() {
    local zone_id="$1"
    local record_id="$2"
    local proxy="$3"
    local response payload
    payload=$(jq -n \
        --argjson p "$proxy" \
        '{proxied:$p}')
    response=$(cf_call PATCH \
        "/zones/${zone_id}/dns_records/${record_id}" \
        "$payload")
    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        green "小黄云状态修改成功"
    else
        red "修改失败"
        echo "$response" | jq -r '.errors[]?.message // empty'
    fi
}
cf_update_dns_name() {
    local zone_id="$1"
    local record_id="$2"
    local new_name="$3"
    local response payload
    payload=$(jq -n \
        --arg n "$new_name" \
        '{name:$n}')
    response=$(cf_call PATCH \
        "/zones/${zone_id}/dns_records/${record_id}" \
        "$payload")
    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        green "域名前缀修改成功"
    else
        red "修改失败"
        echo "$response" | jq -r '.errors[]?.message // empty'
    fi
}
cf_update_dns_content() {
    local zone_id="$1"
    local record_id="$2"
    local new_ip="$3"
    local response payload
    payload=$(jq -n \
        --arg c "$new_ip" \
        '{content:$c}')
    response=$(cf_call PATCH \
        "/zones/${zone_id}/dns_records/${record_id}" \
        "$payload")
    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        green "解析IP修改成功"
    else
        red "修改失败"
        echo "$response" | jq -r '.errors[]?.message // empty'
    fi
}
#── 拉取 DNS 解析 ──
cf_select_dns_record_menu() {
    local records id type name content proxied i choice color cloud
    while true; do
        clear
        skyblue "=========================================="
        skyblue "${zone_domain} DNS解析记录"
        skyblue "=========================================="
        records=$(cf_call GET "/zones/${zone_id}/dns_records?per_page=500")
        if ! echo "$records" | jq -e '.success == true' >/dev/null 2>&1; then
            red "获取DNS记录失败"
            return 1
        fi
        local count
        count=$(echo "$records" | jq '.result | length')
        unset dns_id_array dns_type_array dns_name_array dns_content_array dns_proxy_array
        declare -a dns_id_array dns_type_array dns_name_array dns_content_array dns_proxy_array
        if (( count == 0 )); then
            yellow "没有DNS解析记录"
            i=1
        else
            i=1
            while IFS=$'\t' read -r id type name content proxied; do
                echo "$i) [$type] $name → $content"
                if [[ "$proxied" == "true" ]]; then
                    green "   🟢 小黄云开启"
                else
                    echo "   ⚪ 小黄云关闭"
                fi
                echo
                dns_id_array[$i]="$id"
                dns_type_array[$i]="$type"
                dns_name_array[$i]="$name"
                dns_content_array[$i]="$content"
                dns_proxy_array[$i]="$proxied"
                ((i++))
            done < <(
                echo "$records" | jq -r '
                .result[] |
                [.id,.type,.name,.content,.proxied] |
                @tsv'
            )
        fi
        red "0) 返回域名列表"
        local total=$((i-1))
        reading "请选择 [0-$total]: " choice
        if [[ "$choice" == "0" ]]; then
            return 0
        fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
           (( choice < 1 || choice > total )); then
            red "无效选择"
            sleep 1
            continue
        fi
        selected_dns_id="${dns_id_array[$choice]}"
        selected_dns_type="${dns_type_array[$choice]}"
        selected_dns_name="${dns_name_array[$choice]}"
        selected_dns_content="${dns_content_array[$choice]}"
        selected_dns_proxy="${dns_proxy_array[$choice]}"
        while true; do
            clear
            skyblue "=========================================="
            skyblue "DNS解析管理"
            skyblue "=========================================="
            echo "类型: $selected_dns_type"
            echo "名称: $selected_dns_name"
            echo "地址: $selected_dns_content"
            echo "小黄云: $selected_dns_proxy"
            echo
            green "1) 开启小黄云"
            green "2) 关闭小黄云"
            green "3) 修改前缀"
            green "4) 修改解析IP"
            red "5) 删除DNS"
            echo
            red "0) 返回DNS列表"
            echo
            reading "请选择 [0-5]: " dns_action
            case "$dns_action" in
                1)
    cf_update_dns_proxy "$zone_id" "$selected_dns_id" true
    sleep 1
    break
    ;;
                2)
    cf_update_dns_proxy "$zone_id" "$selected_dns_id" false
    sleep 1
    break
    ;;
                3)
    reading "请输入新的域名: " new_name
    [[ -z "$new_name" ]] && continue
    cf_update_dns_name "$zone_id" "$selected_dns_id" "$new_name"
    sleep 1
    break
    ;;
                4)
    reading "请输入新的解析IP: " new_ip
    [[ -z "$new_ip" ]] && continue
    cf_update_dns_content "$zone_id" "$selected_dns_id" "$new_ip"
    sleep 1
    break
    ;;
                5)
                    yellow "准备删除："
                    echo "$selected_dns_name → $selected_dns_content"
                    reading "确认删除？[y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        response=$(cf_call DELETE "/zones/${zone_id}/dns_records/${selected_dns_id}")
                        if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
                            green "DNS删除成功"
                            break
                        else
                            red "DNS删除失败"
                        fi
                    fi
                    ;;
                0)
                    break
                    ;;
                *)
                    red "无效选择"
                    ;;
            esac
        done
    done
}
# ── 获取 Cloudflare Account ID ──
cf_get_account_id() {
    local zones
    local account_id account_name
    local -a account_ids
    local -a account_names
    local choice i total
    zones=$(cf_call GET "/zones?per_page=500" 2>/dev/null | \
        jq -r '.result[]? | "\(.account.id)|\(.account.name // "")"')
    if [[ -z "$zones" ]]; then
        red "没有找到可用的 Cloudflare Account！"
        return 1
    fi
    i=1
    while IFS='|' read -r account_id account_name; do
        [[ -z "$account_id" ]] && continue
        if [[ -z "${account_ids[*]}" ]] || ! printf '%s\n' "${account_ids[@]}" | grep -qx "$account_id"; then
            account_ids[$i]="$account_id"
            account_names[$i]="$account_name"
            ((i++))
        fi
    done <<< "$zones"
    total=$((i - 1))
    if [[ "$total" -lt 1 ]]; then
        red "没有找到可用的 Cloudflare Account！"
        return 1
    fi
    if [[ "$total" -eq 1 ]]; then
        CF_ACCOUNT_ID="${account_ids[1]}"
        export CF_ACCOUNT_ID
        return 0
    fi
    echo "=========================================="
    skyblue "请选择 Cloudflare Account："
    echo "=========================================="
    for ((i=1; i<=total; i++)); do
        if [[ -n "${account_names[$i]}" ]]; then
            echo "  $i) ${account_names[$i]}"
        else
            echo "  $i) ${account_ids[$i]}"
        fi
    done
    echo "=========================================="
    reading "请输入选择 [1-$total]: " choice
    if [[ -z "$choice" ||
          ! "$choice" =~ ^[0-9]+$ ||
          "$choice" -lt 1 ||
          "$choice" -gt "$total" ]]; then
        red "无效选择！"
        return 1
    fi
    CF_ACCOUNT_ID="${account_ids[$choice]}"
    if [[ -z "$CF_ACCOUNT_ID" ]]; then
        red "获取 Cloudflare Account ID 失败！"
        return 1
    fi
    export CF_ACCOUNT_ID
    return 0
}
# ── 创建 Cloudflare Tunnel ──
cf_create_tunnel() {
    local tunnel_name tunnel_data
    local create_response tunnel_id
    local tunnel_token_response tunnel_token
    local account_response
    local cloudflared_file="/etc/sing-box/conf/cloudflared.json"
    if [[ -z "$CF_TOKEN" &&
          ( -z "$CF_EMAIL" || -z "$CF_KEY" ) ]]; then
        red "未配置 Cloudflare API 信息！"
        return 1
    fi
    if [[ -z "$CF_ACCOUNT_ID" ]]; then
        skyblue "正在获取 Cloudflare Account ID..."
        if [[ -n "$CF_TOKEN" ]]; then
            account_response=$(curl -sS \
                "https://api.cloudflare.com/client/v4/accounts" \
                -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json")
        else
            account_response=$(curl -sS \
                "https://api.cloudflare.com/client/v4/accounts" \
                -H "X-Auth-Email: $CF_EMAIL" \
                -H "X-Auth-Key: $CF_KEY" \
                -H "Content-Type: application/json")
        fi
        CF_ACCOUNT_ID=$(echo "$account_response" | jq -r '.result[0].id // empty')
        if [[ -z "$CF_ACCOUNT_ID" ]]; then
            red "获取 Cloudflare Account ID 失败！"
            return 1
        fi
        export CF_ACCOUNT_ID
    fi
    tunnel_name="sing-box-$(date +%Y%m%d%H%M%S)"
    tunnel_data=$(jq -n \
        --arg name "$tunnel_name" \
        '{
            name: $name,
            config_src: "cloudflare"
        }')
    create_response=$(cf_call POST \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        "$tunnel_data")
    if [[ -z "$create_response" ]]; then
        red "Cloudflare Tunnel 创建失败！"
        return 1
    fi
    if [[ "$(echo "$create_response" | jq -r '.success // false')" != "true" ]]; then
        red "Cloudflare Tunnel 创建失败！"
        echo "$create_response" | jq -r '.errors[]?.message // empty'
        return 1
    fi
    tunnel_id=$(echo "$create_response" | jq -r '.result.id // empty')
    if [[ -z "$tunnel_id" ]]; then
        red "Tunnel ID 获取失败！"
        return 1
    fi
    tunnel_token_response=$(cf_call GET \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token")
    if [[ -z "$tunnel_token_response" ]]; then
        red "Tunnel Token 获取失败！"
        return 1
    fi
    tunnel_token=$(echo "$tunnel_token_response" | jq -r '.result // empty')
    if [[ -z "$tunnel_token" || "$tunnel_token" == "null" ]]; then
        red "Tunnel Token 获取失败！"
        echo "$tunnel_token_response" | jq -r '.errors[]?.message // empty'
        return 1
    fi
    mkdir -p /etc/sing-box/conf
    jq -n \
        --arg token "$tunnel_token" \
        '{
            inbounds: [
                {
                    type: "cloudflared",
                    tag: "cloudflared-in",
                    token: $token,
                    ha_connections: 4,
                    protocol: "quic",			
                    post_quantum: true,
                    edge_ip_version: 0,
                    datagram_version: "v3"
                }
            ]
        }' > "$cloudflared_file"

    if [[ ! -s "$cloudflared_file" ]]; then
        red "cloudflared.json 创建失败！"
        return 1
    fi
    argo_auth="$tunnel_token"
    export argo_auth
    export CF_ACCOUNT_ID
    green "Cloudflare Tunnel 创建成功！"
    green "Tunnel ID: $tunnel_id"
    green "cloudflared 入站文件: $cloudflared_file"
    return 0
}
