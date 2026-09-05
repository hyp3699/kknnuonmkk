#!/bin/bash

# ========================
# 老王sing-box四合一安装脚本
# vless-version-reality|vmess-ws-tls(tunnel)|hysteria2|tuic5
# 最后更新时间: 2026.3.05
# =========================

export LANG=en_US.UTF-8
# --- 颜色和基础工具函数 ---
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

generate_vars() {
  local cc=$(curl -sm 3 "https://api.ip.sb/geoip" | awk -F\" '{for(x=1;x<=NF;x++) if($x=="country_code") print $(x+2)}' | head -n 1)
  [ -z "$cc" ] && cc=$(curl -sm 3 "https://ipapi.co/json" | awk -F\" '{for(x=1;x<=NF;x++) if($x=="country_code") print $(x+2)}' | head -n 1)
  if echo "$cc" | grep -q '^[A-Z][A-Z]$'; then
      isp=$(printf $(echo "$cc" | awk '{
          chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          i1 = index(chars, substr($0, 1, 1))
          i2 = index(chars, substr($0, 2, 1))
          printf("\\xF0\\x9F\\x87\\x%X\\xF0\\x9F\\x87\\x%X", 165+i1, 165+i2)
      }'))
  else
      isp="🌐" 
  fi     
}

# 用于存放已分配端口的数组
declare -A used_ports
get_available_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65535 -n 1)
        if [ -n "${used_ports[$port]}" ]; then
            continue
        fi
        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -qE ":$port\b"; then
                continue
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -qE ":$port\b"; then
                continue
            fi
        fi
        used_ports[$port]=1
        echo "$port"
        break
    done
}

# 自动检测并安装 nftables
check_and_install_nftables() {
    if ! command -v nft &> /dev/null; then
        echo -e "\033[0;33m[!] 检测到系统未安装 nftables，正在自动安装...\033[0m"
        if [ -f /etc/debian_version ]; then
            apt-get update -y && apt-get install -y nftables
        elif [ -f /etc/redhat-release ]; then
            yum install -y nftables 2>/dev/null || dnf install -y nftables
        else
            echo -e "\033[0;31m[-] 未知的 Linux 系统类型，请手动安装 nftables！\033[0m"
            return 1
        fi
        
        systemctl enable nftables >/dev/null 2>&1
        systemctl start nftables >/dev/null 2>&1
        echo -e "\033[0;32m[+] nftables 自动安装完成！\033[0m"
        sleep 1
    fi
}


# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
xray_dir="/etc/xray"
xray_conf_dir="${xray_dir}/conf"
serverxray_name="xray"
configxray_dir="${xray_conf_dir}/config.json"
config_dir="${conf_dir}/config.json"
client_dir="${work_dir}/url.txt"
export CFIP=${CFIP:-'cf.877774.xyz'} 
export CFPORT=${CFPORT:-'443'} 
uuid=$(cat /proc/sys/kernel/random/uuid)
nginx_port=$(get_available_port)
tuic_port=$(get_available_port)
socks_port=$(get_available_port)
http_port=$(get_available_port)
anytls_port=$(get_available_port)
xtls_reality=$(get_available_port)
vless_tcp_tls=$(get_available_port)
anytls_reality=$(get_available_port)
naive_port=$(get_available_port)
h2_reality=$(get_available_port)
hy2_port=$(get_available_port)
grpc_reality=$(get_available_port)
xray_xhttp_reality=$(get_available_port)
vless_wstls_cdn_port=$(get_available_port)
vless_ws_cdn_port=$(get_available_port)
vmess_ws_cdn_port=$(get_available_port)
trojan_ws_cdn_port=$(get_available_port)
username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

to_chinese() {
    local clean_status=$(echo "$1" | sed 's/\x1b\[[0-9;]*m//g')
    [ -z "$clean_status" ] && clean_status="unknown" 
    case "$clean_status" in
        "running")       echo -e "\033[1;32m运行中\033[0m" ;;
        "not running")   echo -e "\033[1;33m未运行\033[0m" ;;
        "not installed") echo -e "\033[1;31m未安装\033[0m" ;;
        *)               echo -e "\033[0;37m$clean_status\033[0m" ;;
    esac
}

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本" && exit 1

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_service() {
    local service_name=$1
    local service_file=$2

    [[ -n "${service_file}" && ! -f "${service_file}" ]] && { red "not installed"; return 2; }

    if command_exists rc-service; then
        rc-service "${service_name}" status 2>&1 | grep -qE "started|running" && { green "running"; return 0; } || { yellow "not running"; return 1; }
    elif command_exists systemctl; then
        systemctl is-active --quiet "${service_name}" && { green "running"; return 0; } || { yellow "not running"; return 1; }
    else
        yellow "service manager not found"
        return 2
    fi
}

# 检查sing-box状态
check_singbox() {
    check_service "sing-box" "${work_dir}/${server_name}"
}

# 检查nginx状态
check_nginx() {
    command_exists nginx || { red "not installed"; return 2; }
    check_service "nginx" "$(command -v nginx)"
}

# 检查 xray 是否已安装
check_xray() {
if [ -f "/etc/xray/xray" ]; then
    if [ -f /etc/alpine-release ]; then
        rc-service xray status | grep -q "started" && return 0 || return 1
    else
        [ "$(systemctl is-active xray)" = "active" ] && return 0 || return 1
    fi
else
    return 2
fi
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装更新系统
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -y
        elif command_exists dnf; then
            dnf update -y
        elif command_exists yum; then
            yum update -y
        elif command_exists apk; then
            apk update && apk upgrade
        else
            yellow "Unknown system!\n"
        fi
        green "finished updated system\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 获取ip
get_realip() {
    ip=$(curl -4 -sL -m 3 ip.sb)
    ipv6() { curl -6 -sL -m 3 ip.sb; }

    if [ -z "$ip" ]; then
        echo "[$(ipv6)]"
    elif curl -4 -sL -m 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        v6=$(ipv6)
        if [ -n "$v6" ]; then
            echo "[$v6]"
        else
            echo "$ip"
        fi
    else
        echo "$ip"
    fi
}
ip_address() {
    ipv4_address=$(curl -s -m 3 ipv4.ip.sb)
    ipv6_address=$(curl -s -m 3 ipv6.ip.sb)
}
nginx_get_domain() {
    local file="$1"
    awk '/server_name/ {
        for(i=2;i<=NF;i++){
            gsub(";","",$i)
            if($i != "_")
                print $i
        }
    }' "$file" | sort -u | tr '\n' ' '
}

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
    read -rp "是否同时删除 ${domain} 的 Cloudflare 回源规则？(y/N): " del_cf
    [[ ! "$del_cf" =~ ^[Yy]$ ]] && {
        yellow "已跳过删除 Cloudflare 回源规则"
        return 0
    }
    # 没有认证信息时请求
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
            delete_response=$(cf_call DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" 2>/dev/null)

            if [[ "$(echo "$delete_response" | jq -r '.success // false')" == "true" ]]; then
                green "Cloudflare Tunnel 删除成功！"

                if [[ -n "$hostnames" ]]; then
                    while read -r dns_name; do
                        [[ -z "$dns_name" ]] && continue

                        dns_zone_id=$(cf_call GET "/zones?name=${dns_name#*.}&per_page=1" 2>/dev/null | jq -r '.result[0].id // empty')
                        [[ -z "$dns_zone_id" ]] && continue

                        dns_record=$(cf_call GET "/zones/${dns_zone_id}/dns_records?name=${dns_name}&type=CNAME&per_page=100" 2>/dev/null)

                        echo "$dns_record" | jq -r '.result[]?.id // empty' |
                        while read -r dns_id; do
                            [[ -z "$dns_id" ]] && continue
                            cf_call DELETE "/zones/${dns_zone_id}/dns_records/${dns_id}" >/dev/null 2>&1
                            green "DNS 已删除: $dns_name"
                        done
                    done <<< "$hostnames"
                fi
            else
                red "Cloudflare Tunnel 删除失败！"
                echo "$delete_response" | jq -r '.errors[]? | if (.code // "") != "" then "错误码: \(.code)\n错误信息: \(.message)" else .message // empty end'
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
    # ── 没有 Tunnel 就自动创建 ──
    if [[ ! -s "/etc/sing-box/conf/cloudflared.json" ]]; then
        yellow "未检测到 Cloudflare Tunnel，正在创建..."

        cf_create_tunnel || return 1

        if [[ ! -s "/etc/sing-box/conf/cloudflared.json" ]]; then
            red "Cloudflare Tunnel 创建失败！"
            return 1
        fi
    fi
    # ── 获取 Tunnel Token ──
    token=$(jq -r \
        '.inbounds[]? |
         select(.type == "cloudflared") |
         .token // empty' \
        /etc/sing-box/conf/cloudflared.json | head -n1)

    if [[ -z "$token" ]]; then
        red "无法从 cloudflared.json 获取 Tunnel Token！"
        return 1
    fi
    # ── 获取 Tunnel ID ──
    tunnel_id=$(echo "$token" |
        base64 -d 2>/dev/null |
        jq -r '.t // empty' 2>/dev/null)

    if [[ -z "$tunnel_id" ]]; then
        red "无法获取 Tunnel ID！"
        return 1
    fi
    # ── 检查 Tunnel ──
    tunnel_data=$(cf_call GET \
        "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" \
        2>/dev/null)
    if [[ "$(echo "$tunnel_data" | jq -r '.success // false')" != "true" ]]; then
        red "Tunnel 不存在或无权访问！"
        return 1
    fi
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
                    protocol: "http2",
                    post_quantum: false
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

# 查看已申请证书
view_certs() {
    clear
    skyblue "=== 已申请的证书 ==="
    local found=0
    for base_dir in "/root/cert" "/etc/nginx/cert"; do
        [[ -d "$base_dir" ]] || continue
        for domain_dir in "$base_dir"/*; do
            [[ -d "$domain_dir" ]] || continue
            local domain=$(basename "$domain_dir")
            local cert_file="$domain_dir/fullchain.pem"
            local key_file="$domain_dir/privkey.pem"
            
            if [[ -f "$cert_file" && -f "$key_file" ]]; then
                local exp_raw exp_formatted
                exp_raw=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                if [[ -n "$exp_raw" ]]; then
                    exp_formatted=$(date -d "$exp_raw" "+%Y.%m.%d %H:%M:%S" 2>/dev/null)
                    [[ -z "$exp_formatted" ]] && exp_formatted="$exp_raw" # 兼容性回退
                else
                    exp_formatted="读取失败"
                fi
                
                green "域名: $domain"
                echo "  证书路径: $cert_file"
                echo "  私钥路径: $key_file"
                if [[ "$exp_formatted" != "读取失败" ]]; then
                    yellow "  到期时间: $exp_formatted"
                else
                    red "  到期时间: 读取失败"
                fi
                echo "----------------------------------------"
                found=1
            fi
        done
    done
    [[ $found -eq 0 ]] && yellow "未在 /root/cert 或 /etc/nginx/cert 中找到任何证书。"
    echo ""
    reading "按任意键返回上级菜单..." dummy_var
}


# 删除证书 
delete_cert() {
    clear
    skyblue "=== 已申请证书列表 ==="
    
    local domains=()
    for base_dir in "/root/cert" "/etc/nginx/cert"; do
        [[ -d "$base_dir" ]] || continue
        for domain_dir in "$base_dir"/*; do
            [[ -d "$domain_dir" ]] || continue
            local domain=$(basename "$domain_dir")
            local cert_file="$domain_dir/fullchain.pem"
            local key_file="$domain_dir/privkey.pem"
            
            if [[ -f "$cert_file" && -f "$key_file" ]]; then
                local already_added=0
                for d in "${domains[@]}"; do
                    [[ "$d" == "$domain" ]] && already_added=1 && break
                done
                [[ $already_added -eq 0 ]] && domains+=("$domain")
            fi
        done
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        yellow "未找到任何可删除的证书。"
        echo ""
        reading "按任意键返回证书管理菜单..." dummy_var
        return 0
    fi
    for idx in "${!domains[@]}"; do
        echo -e " \033[32m$((idx+1))\033[0m. ${domains[$idx]}"
    done
    echo -e " \033[33m0\033[0m. 取消并返回"
    skyblue "----------------------------------------"

    local choice
    reading "请输入要删除的证书编号 [0-${#domains[@]}]: " choice
    
    [[ "$choice" == "0" || -z "$choice" ]] && return 0
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#domains[@]} ]]; then
        red "无效编号！"
        sleep 1
        return 1
    fi

    local del_domain="${domains[$((choice-1))]}"
    echo ""
    skyblue "准备清理域名: ${del_domain}"
    if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
        "$HOME/.acme.sh/acme.sh" --remove -d "$del_domain" >/dev/null 2>&1
        green "[1/3] 已从 acme.sh 中取消该域名的续签任务。"
    fi
    local cert_removed=0
    for base_dir in "/root/cert" "/etc/nginx/cert"; do
        if [[ -d "$base_dir/$del_domain" ]]; then
            rm -rf "$base_dir/$del_domain"
            green "[2/3] 已删除本地证书: $base_dir/$del_domain"
            cert_removed=1
        fi
    done
    [[ $cert_removed -eq 0 ]] && yellow "[2/3] 提示：未在指定目录中找到该域名的文件夹。"
    local rm_dns
    reading "是否要从 Cloudflare 中删除该域名的 DNS 解析记录？(y/N，默认跳过): " rm_dns
    if [[ "$rm_dns" =~ ^[yY]$ ]]; then
        if [[ -z "${CF_TOKEN:-}" && ( -z "${CF_EMAIL:-}" || -z "${CF_KEY:-}" ) ]]; then
            skyblue "删除 Cloudflare 上的 DNS 记录需要验证凭证:"
            echo "1) Global API Key"
            echo "2) API Token"
            local cred_choice
            reading "请选择凭证类型 [1-2]: " cred_choice
            if [[ "$cred_choice" == "1" ]]; then
                reading "请输入 Cloudflare 登录邮箱: " CF_EMAIL
                reading "请输入 Cloudflare Global API Key: " CF_KEY
                export CF_EMAIL CF_KEY
            elif [[ "$cred_choice" == "2" ]]; then
                reading "请输入 Cloudflare API Token: " CF_TOKEN
                export CF_TOKEN
            else
                red "无效选择，跳过 DNS 删除。"
            fi
        fi
        
        skyblue "正在自动查找 Cloudflare Zone ID..."
        local zone_id
        zone_id=$(cf_find_zone "$del_domain" 2>/dev/null)
        if [[ -n "$zone_id" ]]; then
            local rid
            rid=$(cf_call GET "/zones/$zone_id/dns_records?name=$del_domain" | jq -r '.result[0].id // empty')
            if [[ -n "$rid" && "$rid" != "null" ]]; then
                cf_call DELETE "/zones/${zone_id}/dns_records/${rid}" >/dev/null
                green "[3/3] 成功！已从 Cloudflare 删除域名 $del_domain 的 DNS 解析记录。"
            else
                yellow "[3/3] 在 Cloudflare 中未找到域名 $del_domain 的 DNS 解析记录。"
            fi
        else
            red "[3/3] 匹配 Zone ID 失败，可能是凭证无效或域名不在当前账户下。"
        fi
    else
        yellow "[3/3] 选择跳过"
    fi
    
    echo ""
    green "=== 域名 $del_domain 清理完成 ==="
    echo ""
    reading "按任意键返回证书管理菜单..." dummy_var
}

# 证书管理菜单
cert_manager() {
    while true; do
        clear
        skyblue "================================================="
        skyblue "               证书管理"
        skyblue "================================================="
        echo -e " 1. 查看证书"
        echo -e " 2. 申请证书"
        echo -e " 3. 删除证书"
        echo -e " 0. 返回"
        skyblue "================================================="
        
        local choice
        reading "请输入选择 [0-3]: " choice
        
        case "$choice" in
            1) view_certs ;;
            2) 
                clear
                check_and_issue_ssl ""
                echo ""
                reading "按任意键返回..." dummy_var
                ;;
            3) delete_cert ;;
            0) break ;;
            *) 
                red "无效输入，请重新选择！"
                sleep 1 
                ;;
        esac
    done
}
# 80 端口申请模式
run_ssl_task() {
    local request_domain="$1"
    [[ -z "$request_domain" ]] && reading "请输入域名: " request_domain
    request_domain=$(echo "$request_domain" | tr -d '[:space:]')
    [[ -z "$request_domain" ]] && {
        red "域名不能为空"
        return 1
    }
    domain=""
    cert_file=""
    key_file=""
    manage_packages "install" "curl" "socat" "cron" "psmisc"
    mkdir -p "$HOME/.acme.sh"
    cat << 'EOF' > "$HOME/.acme.sh/release_80.sh"
#!/bin/bash

if command -v ss >/dev/null 2>&1; then
    pid=$(ss -tulpn 'sport = :80' 2>/dev/null |
        grep -o 'pid=[0-9]*' |
        cut -d'=' -f2 |
        head -n1)

    occupant=$(ss -tulpn 'sport = :80' 2>/dev/null |
        grep -o 'users:(("[^"]*"' |
        cut -d'"' -f2 |
        head -n1)

    if [[ -n "$pid" || -n "$occupant" ]]; then

        if [[ -n "$occupant" ]] &&
           systemctl is-active --quiet "$occupant" 2>/dev/null; then

            systemctl stop "$occupant" >/dev/null 2>&1
            echo "$occupant" > "$HOME/.acme.sh/last_80_occupant.txt"

            sleep 1
        fi

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" >/dev/null 2>&1
            sleep 1
        fi

        if command -v fuser >/dev/null 2>&1; then
            fuser -k -9 80/tcp >/dev/null 2>&1
            sleep 1
        fi
    fi
fi
EOF

    chmod +x "$HOME/.acme.sh/release_80.sh"
    cat << 'EOF' > "$HOME/.acme.sh/restore_80.sh"
#!/bin/bash
if [[ -f "$HOME/.acme.sh/last_80_occupant.txt" ]]; then
    occupant=$(cat "$HOME/.acme.sh/last_80_occupant.txt")
    if [[ -n "$occupant" ]]; then
        systemctl start "$occupant" >/dev/null 2>&1
    fi
    rm -f "$HOME/.acme.sh/last_80_occupant.txt"
fi
EOF
    chmod +x "$HOME/.acme.sh/restore_80.sh"
    local acme_cmd="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_cmd" ]]; then
        skyblue "正在安装 acme.sh..."
        curl -fsSL "https://get.acme.sh" |
            sh -s email="cert_${RANDOM}@gmail.com" >/dev/null 2>&1
        if [[ ! -f "$acme_cmd" ]]; then
            manage_packages "install" "git"
            rm -rf "$HOME/acme_git_tmp"
            git clone \
                "https://github.com/acmesh-official/acme.sh.git" \
                "$HOME/acme_git_tmp" >/dev/null 2>&1
            if [[ -d "$HOME/acme_git_tmp" ]]; then
                (
                    cd "$HOME/acme_git_tmp" &&
                    ./acme.sh \
                        --install \
                        -m "cert_${RANDOM}@gmail.com"
                ) >/dev/null 2>&1
                rm -rf "$HOME/acme_git_tmp"
            fi
        fi
    fi
    if [[ ! -f "$acme_cmd" ]]; then
        red "错误：acme.sh 安装失败！"
        return 1
    fi
    "$acme_cmd" \
        --set-default-ca \
        --server letsencrypt >/dev/null 2>&1
    local save_path="/root/cert/${request_domain}"
    mkdir -p "$save_path"
    skyblue "正在为 ${request_domain} 申请证书..."
    if ! "$acme_cmd" \
        --issue \
        -d "$request_domain" \
        --standalone \
        --httpport 80 \
        --force \
        --pre-hook "$HOME/.acme.sh/release_80.sh" \
        --post-hook "$HOME/.acme.sh/restore_80.sh"
    then
        # 即使失败，也尝试恢复服务
        "$HOME/.acme.sh/restore_80.sh" >/dev/null 2>&1
        red "申请失败，请检查 80 端口或域名解析状态！"
        return 1
    fi
    if ! "$acme_cmd" \
        --installcert \
        -d "$request_domain" \
        --key-file "${save_path}/privkey.pem" \
        --fullchain-file "${save_path}/fullchain.pem"
    then
        red "证书安装失败！"
        return 1
    fi
    if [[ ! -f "${save_path}/fullchain.pem" ||
          ! -f "${save_path}/privkey.pem" ]]; then
        red "证书文件生成失败！"
        return 1
    fi
    chmod 600 "${save_path}/privkey.pem"
    domain="$request_domain"
    cert_file="${save_path}/fullchain.pem"
    key_file="${save_path}/privkey.pem"
    green "申请成功！"
    green "域名: ${domain}"
    green "证书: ${cert_file}"
    green "私钥: ${key_file}"
    "$acme_cmd" \
        --upgrade \
        --auto-upgrade >/dev/null 2>&1
    return 0
}
#证书申请
issue_cf_dns_cert() {
    case "$CF_AUTH_TYPE" in
        token)
            if [[ -z "$CF_TOKEN" ]]; then
                red "Cloudflare API Token 不存在！"
                return 1
            fi
            ;;
        global)
            if [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]]; then
                red "Cloudflare Global API Key 信息不完整！"
                return 1
            fi
            ;;
        *)
            red "未检测到有效的 Cloudflare 认证方式！"
            return 1
            ;;
    esac
    cf_select_zone || return 1
    echo
    echo "=========================================="
    skyblue "请选择证书域名模式："
    echo "  1) 直接使用 $zone_domain"
    echo "  2) 在 $zone_domain 前添加前缀"
    echo "  3) 申请泛域名证书"
	echo "  4) 申请 Cloudflare Origin CA 15年证书"
    echo "=========================================="
    local mode
    reading "请输入数字 [1-3]: " mode
    local cert_domain
	local origin_ca=0
    case "$mode" in
        1)
            cert_domain="$zone_domain"
            ;;
        2)
            local prefix
            reading "请输入前缀，例如 node: " prefix
            prefix=$(echo "$prefix" | tr -d '[:space:]')
            [[ -z "$prefix" ]] && {
                red "前缀不能为空！"
                return 1
            }
            prefix="${prefix%.}"
            if [[ ! "$prefix" =~ ^[a-zA-Z0-9-]+$ ]]; then
                red "前缀只能是单段, 不能包含点号！"
                return 1
            fi
            cert_domain="${prefix}.${zone_domain}"
            ;;
        3)
            cert_domain="*.${zone_domain}"
            ;;
		4)
    origin_ca=1
    echo
    skyblue "请选择 Origin CA 证书域名："
    echo "  1) $zone_domain  （根域名证书，例如 example.com）"
    echo "  2) 子域名前缀   （例如 node → node.$zone_domain）"
    echo "  3) 泛域名证书   （例如 *.$zone_domain，可匹配所有子域名）"
    echo "=========================================="
    local ca_mode
    reading "请输入数字 [1-3]: " ca_mode
    case "$ca_mode" in
        1)
            cert_domain="$zone_domain"
            ;;
        2)
            local prefix
            reading "请输入前缀，例如 node: " prefix
            prefix=$(echo "$prefix" | tr -d '[:space:]')
            [[ -z "$prefix" ]] && {
                red "前缀不能为空！"
                return 1
            }
            cert_domain="${prefix}.${zone_domain}"
            ;;
        3)
            cert_domain="*.${zone_domain}"
            ;;
        *)
    red "无效选择！"
    return 1
    ;;
    esac
    ;;
        *)
            red "无效选择！"
            return 1
            ;;
    esac
    echo
    green "证书域名: $cert_domain"
    green "Cloudflare Zone: $zone_domain"
    green "Zone ID: $zone_id"
    manage_packages "install" "curl" "socat" "cron" "psmisc"
    local acme_cmd="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_cmd" ]]; then
        skyblue "正在安装 acme.sh..."
        rm -rf "$HOME/.acme.sh"
        curl -fsSL https://get.acme.sh \
            -o /tmp/acme_install.sh
        chmod +x /tmp/acme_install.sh
        bash /tmp/acme_install.sh
        if [[ ! -f "$acme_cmd" ]]; then
            red "acme.sh 安装失败！"
            return 1
        fi
    fi
    if [[ "$CF_AUTH_TYPE" == "token" ]]; then
        export CF_Token="$CF_TOKEN"
        skyblue "当前使用 Cloudflare API Token"
    elif [[ "$CF_AUTH_TYPE" == "global" ]]; then
        export CF_Email="$CF_EMAIL"
        export CF_Key="$CF_KEY"
        skyblue "当前使用 Cloudflare Global API Key"
    fi
    "$acme_cmd" \
        --set-default-ca \
        --server letsencrypt >/dev/null 2>&1
    local save_path="/root/cert/${cert_domain}"
    mkdir -p "$save_path"
    skyblue "正在申请证书..."
    skyblue "证书域名: $cert_domain"
	if [[ "$origin_ca" == "1" ]]; then
    issue_cf_origin_ca "$cert_domain" || return 1
    return 0
    fi
    if "$acme_cmd" \
        --issue \
        --dns dns_cf \
        -d "$cert_domain" \
        --keylength ec-256 \
        --force
    then
        if "$acme_cmd" \
            --installcert \
            -d "$cert_domain" \
            --ecc \
            --key-file "${save_path}/privkey.pem" \
            --fullchain-file "${save_path}/fullchain.pem"
        then
            if [[ ! -f "${save_path}/fullchain.pem" ||
                  ! -f "${save_path}/privkey.pem" ]]; then
                red "证书文件生成失败！"
                return 1
            fi
            chmod 600 "${save_path}/privkey.pem"
            domain="$cert_domain"
            cert_file="${save_path}/fullchain.pem"
            key_file="${save_path}/privkey.pem"
            raw_ip=$(get_realip)
            if [[ -n "$raw_ip" ]]; then
            cf_upsert_dns "$zone_id" "$cert_domain" "$raw_ip"
            fi
            green "=========================================="
            green "证书申请成功！"
            green "=========================================="
            green "域名: $cert_domain"
            green "证书: ${save_path}/fullchain.pem"
            green "私钥: ${save_path}/privkey.pem"
            green "=========================================="
            "$acme_cmd" \
                --upgrade \
                --auto-upgrade >/dev/null 2>&1
            return 0
        else
            red "证书安装失败！"
            return 1
        fi
    else
        red "证书申请失败！"
        red "请检查 Cloudflare 权限或 acme.sh 日志。"
        return 1
    fi
}
#Cloudflare 15年证书
issue_cf_origin_ca() {
    local ca_domain="$1"
    local save_path="/root/cert/${ca_domain}"
    mkdir -p "$save_path"
    skyblue "正在生成 Origin CA 私钥..."
    openssl ecparam \
        -genkey \
        -name prime256v1 \
        -out "${save_path}/privkey.pem"
    skyblue "正在生成 CSR..."
    openssl req \
        -new \
        -key "${save_path}/privkey.pem" \
        -subj "/CN=${ca_domain}" \
        -out "${save_path}/request.csr"
    local csr
    csr=$(cat "${save_path}/request.csr" | sed ':a;N;$!ba;s/\n/\\n/g')
    skyblue "正在申请 Cloudflare Origin CA 证书..."
    local result
    if [[ "$CF_AUTH_TYPE" == "token" ]]; then

    result=$(curl -sS \
    -X POST \
    "https://api.cloudflare.com/client/v4/certificates" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{
        \"hostnames\":[\"${ca_domain}\"],
        \"requested_validity\":5475,
        \"request_type\":\"origin-ecc\",
        \"csr\":\"${csr}\"
    }")
    elif [[ "$CF_AUTH_TYPE" == "global" ]]; then
    result=$(curl -sS \
    -X POST \
    "https://api.cloudflare.com/client/v4/certificates" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_KEY" \
    -H "Content-Type: application/json" \
    --data "{
        \"hostnames\":[\"${ca_domain}\"],
        \"requested_validity\":5475,
        \"request_type\":\"origin-ecc\",
        \"csr\":\"${csr}\"
    }")
else
    red "Cloudflare 认证方式错误"
    return 1
fi
    local cert
    cert=$(echo "$result" | jq -r '.result.certificate')
    if [[ "$cert" == "null" || -z "$cert" ]]; then
        red "Origin CA 申请失败"
        echo "$result"
        return 1
    fi
    echo "$cert" > "${save_path}/fullchain.pem"
    chmod 600 "${save_path}/privkey.pem"
    cert_file="${save_path}/fullchain.pem"
    key_file="${save_path}/privkey.pem"
	domain="$ca_domain"
    green "=========================================="
    green "Cloudflare Origin CA 证书申请成功"
    green "域名: $domain"
    green "证书: ${save_path}/fullchain.pem"
    green "私钥: ${save_path}/privkey.pem"
    green "=========================================="
	return 0
}

# 综合证书检查与申请 调用check_and_issue_ssl [域名] || return 1
check_and_issue_ssl() {
    local input_domain="$1"

    domain=""
    cert_file=""
    key_file=""

    if [[ -z "$input_domain" ]]; then
        local cert_domains=()
        local cert_paths=()
        local dir
        local d_name

        shopt -s nullglob

        for dir in /root/cert/* /etc/nginx/cert/*; do
            if [[ -d "$dir" &&
                  -f "$dir/fullchain.pem" &&
                  -f "$dir/privkey.pem" ]]; then
                d_name=$(basename "$dir")
                if [[ ! " ${cert_domains[*]} " =~ " ${d_name} " ]]; then
                    cert_domains+=("$d_name")
                    cert_paths+=("$dir")
                fi
            fi
        done
        shopt -u nullglob
        echo
        skyblue "============== 本地已有证书列表 =============="

        if [[ ${#cert_domains[@]} -eq 0 ]]; then
            echo "  (未检测到任何本地证书)"
        else
            local i=2
            local idx
            for idx in "${!cert_domains[@]}"; do
            local cert_mark=""
            local cert_file_tmp="${cert_paths[$idx]}/fullchain.pem"
            if openssl x509 -in "$cert_file_tmp" -noout -issuer 2>/dev/null | grep -qi "CloudFlare Origin SSL"; then
            cert_mark=" ${red}【15年证书】${re}"
            fi
            echo -e " ${i}) ${cert_domains[$idx]}${cert_mark}  (路径: ${cert_paths[$idx]})"
            ((i++))
        done
        fi
        skyblue "=============================================="
        echo " 1) 申请新证书"
        echo " 0) 退出"
        echo
        local menu_choice
        reading "请选择操作 [0-1 或已有证书序号]: " menu_choice
        if [[ "$menu_choice" == "0" ]]; then
            red "已取消操作。"
            return 1
        fi
        if [[ "$menu_choice" =~ ^[0-9]+$ ]] &&
           [[ "$menu_choice" -ge 2 ]] &&
           [[ "$menu_choice" -lt "$i" ]]; then
            local sel_idx=$((menu_choice - 2))
            domain="${cert_domains[$sel_idx]}"
            cert_file="${cert_paths[$sel_idx]}/fullchain.pem"
            key_file="${cert_paths[$sel_idx]}/privkey.pem"
            green "已选择并使用域名 ${domain} 的现有证书。"
local check_dns
reading "是否检查 DNS 解析记录？(y/回车跳过): " check_dns
if [[ "$check_dns" == "y" || "$check_dns" == "Y" ]]; then
    echo
    skyblue "请选择 Cloudflare 认证方式："
    echo " 1) API Token（推荐）"
    echo " 2) Global API Key"
    echo
    local cf_choice
    reading "请输入选择 [1-2] (默认 1): " cf_choice
	[[ -z "$cf_choice" ]] && cf_choice=1
    case "$cf_choice" in
        1)
            if ! cf_auth_token; then
                red "Cloudflare Token 认证失败"
                return 1
            fi
            ;;
        2)
            if ! cf_auth_global; then
                red "Cloudflare Global API Key 认证失败"
                return 1
            fi
            ;;
        *)
            red "无效选择"
            return 1
            ;;
    esac
	selected_zone_id=""
if ! cf_get_zone_id_by_domain "$domain"; then
    red "获取 Cloudflare Zone 失败"
    return 1
fi
    server_ip=$(get_realip)
    if [[ -z "$server_ip" ]]; then
        red "无法获取服务器公网 IP"
        return 1
    fi
    local dns_count
    dns_count=$(cf_call GET \
        "/zones/${selected_zone_id}/dns_records?name=${domain}" \
        | jq -r '.result | length')
    if [[ "$dns_count" == "0" ]]; then
        yellow "未检测到 ${domain} DNS 记录，正在添加..."
        if cf_upsert_dns \
            "$selected_zone_id" \
            "$domain" \
            "$server_ip"; then
            green "DNS 添加成功（已开启小黄云）"
        else
            red "DNS 添加失败"
        fi
    else
        green "检测到 ${domain} 已存在 DNS 记录"
    fi
fi
            return 0
        fi
        if [[ "$menu_choice" != "1" ]]; then
            red "无效的选择！"
            return 1
        fi
    fi
    if [[ -n "$input_domain" ]]; then
        domain="$input_domain"
        domain=$(echo "$domain" | tr -d '[:space:]')
        [[ -z "$domain" ]] && {
            red "域名不能为空！"
            return 1
        }
    fi
    if [[ -n "$domain" ]]; then
        local existing_path=""
        if [[ -f "/root/cert/${domain}/fullchain.pem" &&
              -f "/root/cert/${domain}/privkey.pem" ]]; then
            existing_path="/root/cert/${domain}"
        elif [[ -f "/etc/nginx/cert/${domain}/fullchain.pem" &&
                -f "/etc/nginx/cert/${domain}/privkey.pem" ]]; then
            existing_path="/etc/nginx/cert/${domain}"
        fi
        if [[ -n "$existing_path" ]]; then
            cert_file="${existing_path}/fullchain.pem"
            key_file="${existing_path}/privkey.pem"
            skyblue "检测到域名 ${domain} 的证书已存在，直接使用。"
            return 0
        fi
    fi
    if [[ -n "$domain" && "$domain" == *.*.* ]]; then
        local parent_domain
        parent_domain="${domain#*.}"
        local wildcard_cert=""
        local wildcard_key=""
        local wdir
        shopt -s nullglob
        for wdir in \
            "/root/cert/*.${parent_domain}" \
            "/etc/nginx/cert/*.${parent_domain}"; do
            if [[ -f "$wdir/fullchain.pem" &&
                  -f "$wdir/privkey.pem" ]]; then
                wildcard_cert="$wdir/fullchain.pem"
                wildcard_key="$wdir/privkey.pem"
                break
            fi
        done
        shopt -u nullglob
        if [[ -n "$wildcard_cert" ]]; then
            yellow "检测到可用泛域名证书 (*.${parent_domain})。"
            local use_wildcard
            reading \
                "是否直接使用该泛域名证书保护 ${domain}？(y/n): " \
                use_wildcard
            if [[ "$use_wildcard" == "y" ||
                  "$use_wildcard" == "Y" ]]; then
                cert_file="$wildcard_cert"
                key_file="$wildcard_key"
                green "已选择使用泛域名证书。"
                return 0
            fi
        fi
        local parent_cert=""
        local parent_key=""
        if [[ -f "/root/cert/${parent_domain}/fullchain.pem" &&
              -f "/root/cert/${parent_domain}/privkey.pem" ]]; then
            parent_cert="/root/cert/${parent_domain}/fullchain.pem"
            parent_key="/root/cert/${parent_domain}/privkey.pem"
        elif [[ -f "/etc/nginx/cert/${parent_domain}/fullchain.pem" &&
                -f "/etc/nginx/cert/${parent_domain}/privkey.pem" ]]; then
            parent_cert="/etc/nginx/cert/${parent_domain}/fullchain.pem"
            parent_key="/etc/nginx/cert/${parent_domain}/privkey.pem"
        fi
        if [[ -n "$parent_cert" ]]; then
            yellow "当前域名无证书，但检测到父域名 ${parent_domain} 已有普通证书。"
            local use_parent
            reading \
                "是否尝试使用父域名证书？(y/n): " \
                use_parent
            if [[ "$use_parent" == "y" ||
                  "$use_parent" == "Y" ]]; then
                cert_file="$parent_cert"
                key_file="$parent_key"
                green "已选择使用 ${parent_domain} 的证书。"
                return 0
            fi
        fi
    fi
    echo
    skyblue "=============================================="
    echo "请选择证书申请方式："
    echo
    echo " 1) 80 端口申请"
    echo " 2) Cloudflare Global API Key)"
    echo -e " ${red}3) Cloudflare API Token(推荐)${re}"
    skyblue "=============================================="
    local ssl_choice
    reading "请输入选择 [1-3]（默认 3）: " ssl_choice
	[[ -z "$ssl_choice" ]] && ssl_choice=3
    case "$ssl_choice" in
    1)
        if [[ -z "$domain" ]]; then
            reading "请输入要申请证书的域名: " domain
            domain=$(echo "$domain" | tr -d '[:space:]')
            [[ -z "$domain" ]] && {
                red "域名不能为空！"
                return 1
            }
        fi
        if ! run_ssl_task "$domain"; then
            red "80 端口方式申请证书失败。"
            return 1
        fi
        ;;
    2)
        if ! cf_auth_global; then
            red "Cloudflare Global API Key 认证失败！"
            return 1
        fi
        if ! issue_cf_dns_cert; then
            red "Cloudflare Global API Key 方式申请证书失败。"
            return 1
        fi
        ;;
    3)
        if ! cf_auth_token; then
            red "Cloudflare API Token 认证失败！"
            return 1
        fi
        if ! issue_cf_dns_cert; then
            red "Cloudflare API Token 方式申请证书失败。"
            return 1
        fi
        ;;
    *)
        red "无效选择！"
        return 1
        ;;
    esac
    if [[ -z "$domain" ]]; then
        red "证书申请成功，但未返回证书域名。"
        return 1
    fi
    if [[ -z "$cert_file" ]]; then
        red "证书申请成功，但未返回证书路径。"
        return 1
    fi
    if [[ -z "$key_file" ]]; then
        red "证书申请成功，但未返回私钥路径。"
        return 1
    fi
    if [[ ! -f "$cert_file" ]]; then
        red "证书文件不存在："
        red "$cert_file"
        return 1
    fi
    if [[ ! -f "$key_file" ]]; then
        red "私钥文件不存在："
        red "$key_file"
        return 1
    fi
    green "=============================================="
    green "证书已经准备完成！"
    green "域名: $domain"
    green "证书: $cert_file"
    green "私钥: $key_file"
    green "=============================================="
	local check_dns
    reading "是否添加 DNS 解析记录？(y/回车跳过): " check_dns
    if [[ "$check_dns" == "y" || "$check_dns" == "Y" ]]; then
    if [[ -z "${CF_TOKEN:-}" ]]; then
    if ! cf_auth_token; then
        red "Cloudflare Token 认证失败"
        return 1
    fi
    fi
    selected_zone_id=""
    if ! cf_get_zone_id_by_domain "$domain"; then
        red "获取 Cloudflare Zone 失败"
        return 1
    fi
    local server_ip
    server_ip=$(get_realip)
    if [[ -z "$server_ip" ]]; then
        red "无法获取服务器公网 IP"
        return 1
    fi
    local dns_count
    dns_count=$(cf_call GET \
        "/zones/${selected_zone_id}/dns_records?name=${domain}" \
        | jq -r '.result | length')
    if [[ "$dns_count" == "0" ]]; then
        yellow "未检测到 ${domain} DNS 记录，正在添加..."
        if cf_upsert_dns \
            "$selected_zone_id" \
            "$domain" \
            "$server_ip"; then
            green "DNS 添加成功（已开启小黄云）"
        else
            red "DNS 添加失败"
        fi
    else
        green "检测到 ${domain} 已存在 DNS 记录"
    fi
fi
    return 0
} 

# 处理防火墙
allow_port() {
    local has_ufw=0
    local has_firewalld=0
    local has_nft=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists nft && has_nft=1

    # 出站和基础规则
    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    
    # 初始化 nftables 原生基础表和链（如果不存在）
    if [ "$has_nft" -eq 1 ]; then
        if ! nft list table inet filter &>/dev/null; then
            nft add table inet filter
            nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
            nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
            nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
        fi
        # 放行本地回环和 ICMP (Ping)
        nft add rule inet filter input iif "lo" accept 2>/dev/null
        nft add rule inet filter input ip protocol icmp accept 2>/dev/null
        nft add rule inet filter input ip6 nexthdr icmpv6 accept 2>/dev/null
    fi

    # 入站规则处理
    for rule in "$@"; do
        local port=${rule%/*}
        local proto=${rule#*/}
        # 如果传入的参数没有包含协议(例如直接传入 80 而不是 80/tcp)，则默认使用 tcp
        [ "$port" == "$proto" ] && proto="tcp"

        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        
        # 原生 nftables 内存规则写入 (inet 自动双栈生效)
        if [ "$has_nft" -eq 1 ]; then
            # 避免重复添加规则
            if ! nft list chain inet filter input 2>/dev/null | grep -qw "$proto dport $port"; then
                nft add rule inet filter input $proto dport $port accept comment "ScriptManaged" 2>/dev/null
            fi
        fi
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    # 规则持久化：直接导出当前原生规则覆盖配置文件
    if [ "$has_nft" -eq 1 ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null
    fi
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

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."
    # 判断系统架构
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l') ARCH='armv7' ;;
        's390x') ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}" && mkdir -p "${conf_dir}"
    # 下载sing-box,cloudflared
    latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name | sub("^v"; "")')
    work_dir=${work_dir:-/etc/sing-box}
mkdir -p "$work_dir"
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; armv7l) ARCH=armv7;; i386|i686) ARCH=386;; *) ARCH="$ARCH_RAW";; esac
if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then LIBC=musl; else LIBC=glibc; fi
latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[]|select(.prerelease==false)][0].tag_name|sub("^v";"")')
[ -z "$latest_version" ] && latest_version=1.8.10
TAR="sing-box-${latest_version}-linux-${ARCH}-${LIBC}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/${TAR}"
curl -fSL -o "${work_dir}/${TAR}" "$URL" && tar -xzf "${work_dir}/${TAR}" -C "$work_dir" && mv "${work_dir}/sing-box-${latest_version}-linux-${ARCH}-${LIBC}/sing-box" "${work_dir}/sing-box" && chmod +x "${work_dir}/sing-box" && rm -rf "${work_dir}/${TAR}" "${work_dir}/sing-box-${latest_version}-linux-${ARCH}-${LIBC}"
       
    chown root:root ${work_dir} && chmod +x ${work_dir}/${server_name}
    
    # 放行端口
    allow_port $nginx_port/tcp $tuic_port/udp > /dev/null 2>&1
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))
    
   # 生成配置文件
cat > "${config_dir}" << EOF
{
   "http_clients": [
  {
    "tag": "direct",
    "connect_timeout": "5s"
   }
  ],
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "type": "local"
      }
    ],
    "strategy": "$dns_strategy"
  },
   "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
   }
}
EOF
cat > "${conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
	{
      "type": "socks",
      "tag": "warp-40000",
      "server": "127.0.0.1",
      "server_port": 40000
    }
  ]
}
EOF
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
    cat > "${conf_dir}/route.json" << EOF
{
  "route": {
    "default_http_client": "direct",
    "rule_set": [
      {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs"},
      {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs"}
    ],
    "rules": [{"rule_set": []}],
    "final": "direct"
  }
}
EOF
}
# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf/
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload 
    systemctl enable sing-box
    systemctl start sing-box
}

# 创建快捷指令（自动下载脚本到本地保存）
create_shortcut() {
    local remote_url="http://sb.133134.xyz"
    local local_file="$work_dir/sb.sh"
    if [ ! -s "$local_file" ]; then
        mkdir -p "$work_dir"
        curl -Lss "$remote_url" -o "$local_file"
    fi
    if [ -s "$local_file" ]; then
        chmod +x "$local_file"
        ln -sf "$local_file" /usr/bin/sb
		ln -sf "$local_file" /usr/bin/b
        if [ -x /usr/bin/sb ]; then
            green "\n快捷指令 sb 已创建\n"
        fi
		if [ -x /usr/bin/b ]; then
            green "\n快捷指令 b 已创建\n"
        fi
    else
        red "\n本地化保存失败，请检查网络后重新运行\n"
        rm -f "$local_file" 
    fi
}

# 适配alpine 守护进程
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run

description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default > /dev/null 2>&1
}


# nginx订阅配置
add_nginx_conf() {
    if ! command_exists nginx; then
        red "nginx未安装,无法配置订阅服务"
        return 1
    else
        manage_service "nginx" "stop" > /dev/null 2>&1
        pkill nginx  > /dev/null 2>&1
    fi

    mkdir -p /etc/nginx/conf.d

    [[ -f "/etc/nginx/conf.d/sing-box.conf" ]] && cp /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/sing-box.conf.bak.sb

    cat > /etc/nginx/conf.d/sing-box.conf << EOF
# sing-box 订阅配置
server {
    listen $nginx_port;
    listen [::]:$nginx_port;
    server_name _;

    # 安全设置
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location / {
        return 404;
    }

    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    # 检查主配置文件是否存在
    if [ -f "/etc/nginx/nginx.conf" ]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.sb > /dev/null 2>&1
        sed -i -e '15{/include \/etc\/nginx\/modules\/\*\.conf/d;}' -e '18{/include \/etc\/nginx\/conf\.d\/\*\.conf/d;}' /etc/nginx/nginx.conf > /dev/null 2>&1
        # 检查是否已包含配置目录
        if ! grep -q "include.*conf.d" /etc/nginx/nginx.conf; then
            http_end_line=$(grep -n "^}" /etc/nginx/nginx.conf | tail -1 | cut -d: -f1)
            if [ -n "$http_end_line" ]; then
                sed -i "${http_end_line}i \    include /etc/nginx/conf.d/*.conf;" /etc/nginx/nginx.conf > /dev/null 2>&1
            fi
        fi
    else 
        cat > /etc/nginx/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;
    
    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    # 检查nginx配置语法
    if nginx -t > /dev/null 2>&1; then
    
        if nginx -s reload > /dev/null 2>&1; then
            green "nginx订阅配置已加载"
        else
            start_nginx  > /dev/null 2>&1
        fi
    else
        yellow "nginx配置失败,订阅不可应,但不影响节点使用, issues反馈: https://github.com/eooce/Sing-box/issues"
        restart_nginx  > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            green "nginx订阅配置已生效"
        else
            [[ -f "/etc/nginx/nginx.conf.bak.sb" ]] && cp "/etc/nginx/nginx.conf.bak.sb" /etc/nginx/nginx.conf > /dev/null 2>&1
            restart_nginx  > /dev/null 2>&1
        fi
    fi
}
       
# 通用服务管理函数
manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"
        return 1
    fi
    
    local status=$(check_service "$service_name" 2>/dev/null)

    case "$action" in
        "start")
            if [ "$status" == "running" ]; then 
                yellow "${service_name} 正在运行\n"
                return 0
            elif [ "$status" == "not installed" ]; then 
                yellow "${service_name} 尚未安装!\n"
                return 1
            else 
                yellow "正在启动 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" start
                elif command_exists systemctl; then
                    systemctl daemon-reload
                    systemctl start "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功启动\n"
                    return 0
                else
                    red "${service_name} 服务启动失败\n"
                    return 1
                fi
            fi
            ;;
            
        "stop")
            if [ "$status" == "not installed" ]; then 
                yellow "${service_name} 尚未安装！\n"
                return 2
            elif [ "$status" == "not running" ]; then
                yellow "${service_name} 未运行\n"
                return 1
            else
                yellow "正在停止 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" stop
                elif command_exists systemctl; then
                    systemctl stop "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功停止\n"
                    return 0
                else
                    red "${service_name} 服务停止失败\n"
                    return 1
                fi
            fi
            ;;
            
        "restart")
            if [ "$status" == "not installed" ]; then
                yellow "${service_name} 尚未安装！\n"
                return 1
            else
                yellow "正在重启 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" restart
                elif command_exists systemctl; then
                    systemctl daemon-reload
                    systemctl restart "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功重启\n"
                    return 0
                else
                    red "${service_name} 服务重启失败\n"
                    return 1
                fi
            fi
            ;;
            
        *)
            red "无效的操作: $action\n"
            red "可用操作: start, stop, restart\n"
            return 1
            ;;
    esac
}

#下载安装xray
install_xray() {
    clear
    purple "正在安装 Xray 中，请稍等..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') GOARCH='amd64' ;;
        'aarch64' | 'arm64') GOARCH='arm64' ;;
        *) GOARCH='amd64' ;;
    esac
    # 确保原脚本的目录存在
    [ ! -d "${xray_dir}" ] && mkdir -p "${xray_dir}"
    [ ! -d "${xray_conf_dir}" ] && mkdir -p "${xray_conf_dir}"

    if [[ -x "${xray_dir}/xray" ]]; then
      echo "      已有 $("${xray_dir}/xray" version 2>/dev/null | head -1)"
    else
      case "$GOARCH" in
        amd64) XRAY_ASSET=Xray-linux-64.zip ;;
        arm64) XRAY_ASSET=Xray-linux-arm64-v8a.zip ;;
      esac
      echo "      下载 Xray (${XRAY_ASSET})"
      XT=$(mktemp -d)
      XURL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"
	  if [ -x "$(command -v systemctl)" ]; then
         xray_main_systemd_services
         elif [ -x "$(command -v rc-update)" ]; then
         xray_alpine_openrc_services
         else
         red "Unsupported init system"
         break
         fi
      
      if curl -fsSL "$XURL" -o "$XT/x.zip"; then
        if command -v unzip >/dev/null; then
          unzip -qo "$XT/x.zip" -d "$XT"
        elif command -v python3 >/dev/null; then
          python3 -c "import zipfile; zipfile.ZipFile('$XT/x.zip').extractall('$XT')"
        else
          [[ -n "$MGR" ]] && install_pkgs "$MGR" unzip >/dev/null 2>&1 || true
          unzip -qo "$XT/x.zip" -d "$XT"
        fi
        
        if [[ -f "$XT/xray" ]]; then
          install -m 755 "$XT/xray" "${xray_dir}/xray"
          echo "      $("${xray_dir}/xray" version 2>/dev/null | head -1)"
        else
          echo "      解压失败：未找到 xray 二进制文件" >&2
        fi
      else
        echo "      下载失败：网络请求错误" >&2
      fi
      rm -rf "$XT"
    fi
    rm -rf \
        "${xray_dir}/geosite.dat" \
        "${xray_dir}/geoip.dat" \
        "${xray_dir}/README.md" \
        "${xray_dir}/LICENSE"

    iptables -F > /dev/null 2>&1 \
        && iptables -P INPUT ACCEPT > /dev/null 2>&1 \
        && iptables -P FORWARD ACCEPT > /dev/null 2>&1 \
        && iptables -P OUTPUT ACCEPT > /dev/null 2>&1

    command -v ip6tables &> /dev/null \
        && ip6tables -F > /dev/null 2>&1 \
        && ip6tables -P INPUT ACCEPT > /dev/null 2>&1 \
        && ip6tables -P FORWARD ACCEPT > /dev/null 2>&1 \
        && ip6tables -P OUTPUT ACCEPT > /dev/null 2>&1

    cat > "${configxray_dir}" << EOF
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "dns": {
    "servers": ["https+local://8.8.8.8/dns-query"]
  },
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
cat > "${xray_conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "socks",
      "tag": "warp-40000",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
    }
  ]
}
EOF
cat > "${xray_conf_dir}/route.json" << EOF
{
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
}

# debian/ubuntu/centos 守护进程
xray_main_systemd_services() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=$xray_dir/xray run -confdir $xray_conf_dir
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi

    bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'

    systemctl daemon-reload
    systemctl enable xray
    systemctl is-active --quiet xray || systemctl start xray
}

# 适配 alpine 守护进程
xray_alpine_openrc_services() {
    cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run

description="Xray service"
command="/etc/xray/xray"
command_args="run -confdir /etc/xray/conf"
command_background=true
pidfile="/var/run/xray.pid"
EOF

    chmod +x /etc/init.d/xray
    rc-update add xray default
}

# 启动 sing-box
start_singbox() {
    manage_service "sing-box" "start"
}

# 停止 sing-box
stop_singbox() {
    manage_service "sing-box" "stop"
}

# 重启 sing-box
restart_singbox() {
    manage_service "sing-box" "restart"
}

# 启动 nginx
start_nginx() {
    manage_service "nginx" "start"
}

# 停止 nginx
stop_nginx() {
    manage_service "nginx" "stop"
}

# 重启 nginx
restart_nginx() {
    manage_service "nginx" "restart"
}

# 启动 xray
start_xray() {
    check_xray
    xray_status=$?

    if [ "$xray_status" -eq 1 ]; then
        yellow "\n正在启动 ${serverxray_name} 服务\n"
        if [ -f /etc/alpine-release ]; then
            rc-service xray start
        else
            systemctl daemon-reload
            systemctl start "${serverxray_name}"
        fi
        if [ $? -eq 0 ]; then
            green "${serverxray_name} 服务已成功启动\n"
        else
            red "${serverxray_name} 服务启动失败\n"
        fi

    elif [ "$xray_status" -eq 0 ]; then
        yellow "xray 正在运行\n"
        sleep 1

    else
        yellow "xray 尚未安装！\n"
        sleep 1
    fi
}
# 停止 xray
stop_xray() {
    check_xray
    xray_status=$?

    if [ "$xray_status" -eq 0 ]; then
        yellow "\n正在停止 ${serverxray_name} 服务\n"
        if [ -f /etc/alpine-release ]; then
            rc-service xray stop
        else
            systemctl stop "${serverxray_name}"
        fi
        if [ $? -eq 0 ]; then
            green "${serverxray_name} 服务已成功停止\n"
        else
            red "${serverxray_name} 服务停止失败\n"
        fi

    elif [ "$xray_status" -eq 1 ]; then
        yellow "xray 未运行\n"
        sleep 1

    else
        yellow "xray 尚未安装！\n"
        sleep 1
    fi
}
# 重启 xray
restart_xray() {
    check_xray
    xray_status=$?

    if [ "$xray_status" -eq 0 ]; then
        yellow "\n正在重启 ${serverxray_name} 服务\n"
        if [ -f /etc/alpine-release ]; then
            rc-service ${serverxray_name} restart
        else
            systemctl daemon-reload
            systemctl restart "${serverxray_name}"
        fi
        if [ $? -eq 0 ]; then
            green "${serverxray_name} 服务已成功重启\n"
        else
            red "${serverxray_name} 服务重启失败\n"
        fi

    elif [ "$xray_status" -eq 1 ]; then
        yellow "\n${serverxray_name} 未运行，正在启动...\n"
        if [ -f /etc/alpine-release ]; then
            rc-service ${serverxray_name} start
        else
            systemctl daemon-reload
            systemctl start "${serverxray_name}"
        fi
        if [ $? -eq 0 ]; then
            green "${serverxray_name} 服务已成功启动\n"
        else
            red "${serverxray_name} 服务启动失败\n"
        fi

    else
        yellow "${serverxray_name} 尚未安装！\n"
        sleep 1
    fi
}

# 卸载 Xray
uninstall_xray() {
    reading "确定要卸载 Xray 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 Xray..."
            if [ -f /etc/alpine-release ]; then
                rc-service xray stop 2>/dev/null
                rc-update del xray default 2>/dev/null
                rm -f /etc/init.d/xray
            else
                systemctl stop "${serverxray_name}" 2>/dev/null
                systemctl disable "${serverxray_name}" 2>/dev/null
                systemctl daemon-reload 2>/dev/null || true
            fi
            for target_conf in \
                "${xray_conf_dir}/xhttp-reality.json" \
                "${xray_conf_dir}/xhttp-cdn.json" \
                "${xray_conf_dir}/xhttp-cdn-tls.json"
            do
                if [ -f "$target_conf" ]; then
                    node_port=$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' "$target_conf" |
                        head -1 |
                        grep -o '[0-9]*$')

                    if [ -n "$node_port" ]; then
                        for handle in $(nft -a list chain inet filter input 2>/dev/null |
                            awk -v p="$node_port" '$0 ~ "dport "p {print $NF}')
                        do
                            nft delete rule inet filter input handle "$handle" 2>/dev/null
                        done
                    fi
                fi
            done
            nft list ruleset > /etc/nftables.conf 2>/dev/null
            if [ -f "/etc/sing-box/url.txt" ]; then
                sed -i \
                    -e '/_xray_vless_xhttp_reality$/d' \
                    -e '/_xray_vless_xhttp_cdn$/d' \
                    -e '/_xray_vless_xhttp_cdn_tls$/d' \
					-e '/_xray_vless_xhttp_tls$/d' \
					-e '/_xray_vless_xhttp_h3$/d' \
					-e '/_xray_vless_xhttp_tcpudpcdn$/d' \
                    "/etc/sing-box/url.txt"
                sed -i '/^$/N;/\n$/D' "/etc/sing-box/url.txt"

                echo "" >> "/etc/sing-box/url.txt"
            fi
            if [ -s "/etc/sing-box/url.txt" ]; then
                base64 -w0 "/etc/sing-box/url.txt" \
                    > "/etc/sing-box/sub.txt" 2>/dev/null
            else
                truncate -s 0 "/etc/sing-box/sub.txt"
            fi
            rm -rf "${xray_dir}" 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service 2>/dev/null
            systemctl daemon-reload 2>/dev/null || true
            green "==============================================="
            green " Xray 已卸载，所有 Xray 节点已移除!"
            green "==============================================="
            ;;
        *)
            purple "已取消卸载操作"
            ;;
    esac
}

update_xray_status() {
    check_xray >/dev/null 2>&1
    xray_check_result=$?
    case "${xray_check_result}" in
        0) check_xray_status="running" ;;
        1) check_xray_status="not running" ;;
        2) check_xray_status="not installed" ;;
    esac
}
  
# xray 管理
manage_xray() { 
    while true; do
	update_xray_status
        clear
		green "=== xray 管理 ===\n"
        printf "${purple} Xray 状态: %s${re}\n\n" "$(to_chinese "$check_xray_status")"
        green "1. 安装xray服务"
        skyblue "-------------------"
        green "2. 卸载xray服务"
        skyblue "-------------------"
        green "3. 启动xray服务"
        skyblue "-------------------"
        green "4. 停止xray服务"
        skyblue "-------------------"
		green "5. 重启xray服务"
        skyblue "-------------------"
        purple "0. 返回主菜单"
        skyblue "------------"
        reading "\n请输入选择: " choice
        case "${choice}" in
            1)
                check_xray
                if [ $? -eq 0 ]; then
                yellow "Xray 已经安装！"
                else
                install_xray
                if [ $? -ne 0 ]; then
                red "Xray 安装失败！"
                break
                fi
                fi
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            2)
                uninstall_xray
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            3)
                start_xray
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            4)
                stop_xray
                read -n 1 -s -r -p "按任意键返回..."
                ;;
			5)
                restart_xray
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            0)
                return 0
                ;;
            *)
                red "无效的选项！"
                read -n 1 -s -r -p "按任意键返回..."
                ;;
        esac
    done
}

# 卸载 sing-box
uninstall_singbox() {
   reading "确定要卸载 sing-box 吗? (y/n): " choice
   case "${choice}" in
       y|Y)
           yellow "正在卸载 sing-box"
           if command_exists rc-service; then
                rc-service sing-box stop
                rm /etc/init.d/sing-box 
                rc-update del sing-box default
           else               
		        # 停止 sing-box
                systemctl stop "${server_name}"		
                systemctl disable "${server_name}"
                # 重新加载 systemd
                systemctl daemon-reload || true

            fi
           # 删除配置文件和日志
           rm -rf "${work_dir}" || true
           rm -rf "${log_dir}" || true
           rm -rf /etc/systemd/system/sing-box.service > /dev/null 2>&1
           rm  -rf /etc/nginx/conf.d/sing-box.conf > /dev/null 2>&1
           # 卸载Nginx
           reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice
            case "${choice}" in
                y|Y)
				    stop_nginx
                    manage_packages uninstall nginx
					rm -f /etc/nginx/conf.d/sing-box.conf
                    rm -f /etc/nginx/conf.d/sing-box.conf.bak*
                    ;;
                 *) 
                    yellow "取消卸载Nginx\n\n"
                    ;;
            esac

            green "\nsing-box 卸载成功\n\n" && exit 0
           ;;
       *)
           purple "已取消卸载操作\n\n"
           ;;
   esac
}

# 适配alpine运行argo报错用户组和dns的问题
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}
# 修改sing-box节点uuid
change_uuid() {
    local conf_dir="/etc/sing-box/conf"
    local url_file="/etc/sing-box/url.txt"
    local sub_file="/etc/sing-box/sub.txt"
    [ -f "$url_file" ] || {
        red "未找到：$url_file"
        return 1
    }
    [ -d "$conf_dir" ] || {
        red "未找到：$conf_dir"
        return 1
    }
    while IFS= read -r file; do
        jq -e 'has("inbounds") and (.inbounds | type == "array")' "$file" >/dev/null 2>&1 || continue
        inbound_count=$(jq '.inbounds | length' "$file")
        for ((i=0; i<inbound_count; i++)); do
            protocol=$(jq -r ".inbounds[$i].type // empty" "$file")
            case "$protocol" in
                socks|http) continue ;;
            esac
            old_value=$(jq -r "
                .inbounds[$i].users[0].uuid //
                .inbounds[$i].users[0].password //
                empty
            " "$file")
            [ -z "$old_value" ] && continue
            [ "$old_value" = "null" ] && continue
            new_uuid=$(cat /proc/sys/kernel/random/uuid)
            if [ "$protocol" = "tuic" ]; then
                jq --arg uuid "$new_uuid" --argjson index "$i" '
                    if (.inbounds[$index].users? | type) == "array" then
                        .inbounds[$index].users |= map(
                            if .uuid != null then .uuid = $uuid else . end
                        )
                    else
                        .
                    end
                ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
                sed -i "s#tuic://${old_value}:#tuic://${new_uuid}:#g" "$url_file"
            elif [ "$protocol" = "vmess" ]; then
                jq --arg uuid "$new_uuid" --argjson index "$i" '
                    if (.inbounds[$index].users? | type) == "array" then
                        .inbounds[$index].users |= map(
                            if .uuid != null then .uuid = $uuid else . end
                        )
                    else
                        .
                    end
                ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
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
            else
                jq --arg uuid "$new_uuid" --argjson index "$i" '
                    if (.inbounds[$index].users? | type) == "array" then
                        .inbounds[$index].users |= map(
                            if .uuid != null then .uuid = $uuid else . end |
                            if .password != null then .password = $uuid else . end
                        )
                    else
                        .
                    end
                ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
                for scheme in vless hysteria2 anytls trojan; do
                    if grep -Fq "${scheme}://${old_value}@" "$url_file"; then
                        sed -i "s#${scheme}://${old_value}@#${scheme}://${new_uuid}@#g" "$url_file"
                        break
                    fi
                done
            fi
            green "UUID：$new_uuid"
        done
    done < <(find "$conf_dir" -type f -name "*.json")
    restart_singbox
    base64 -w0 "$url_file" > "$sub_file"
    green "所有节点 UUID 修改完成！"
}

# 变更配置
change_config() {
    # 检查sing-box状态
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?
    
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"
        sleep 1
        menu
        return
    fi
    
    clear
    echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $singbox_status\n"
	green "1. 修改节点UUID"
    skyblue "------------"
    green "2. 修改Reality伪装域名"
    skyblue "------------"
    green "3. 添加hysteria2端口跳跃"
    skyblue "------------"
    green "4. 删除hysteria2端口跳跃"
    skyblue "------------"
	green "5. hysteria2开启混淆"
    skyblue "------------"
    green "6. hysteria2关闭混淆"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
	    1) change_uuid ;;
        2)  
		  clear
		  green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n\n6. addons.mozilla.org\n\n7. www.iij.ad.jp\n\n8. 自定义域名\n"
		  reading "\n请输入新的Reality伪装域名序号(回车使用默认1): " new_sni
  
          case "$new_sni" in
            "1"|"") new_sni="www.joom.com" ;;
            "2") new_sni="www.stengg.com" ;;
            "3") new_sni="www.wedgehr.com" ;;
            "4") new_sni="www.cerebrium.ai" ;;
            "5") new_sni="www.nazhumi.com" ;;
			"6") new_sni="addons.mozilla.org" ;;
			"7") new_sni="www.iij.ad.jp" ;;
            "8")
              reading "\n请输入自定义的伪装域名(例如 www.example.com): " new_sni
              [[ -z "$new_sni" ]] && new_sni="www.joom.com"
              ;;
            *) new_sni="$new_sni" ;;
           esac
           
          conf_base_dir=$(dirname "$config_dir")

          for file in "${conf_base_dir}"/*.json; do
          if jq -e '.inbounds[0].tls.enabled == true and .inbounds[0].tls.reality.enabled == true' "$file" >/dev/null 2>&1; then
          jq --arg sni "$new_sni" '
         .inbounds[0].tls.server_name = $sni |
         .inbounds[0].tls.reality.handshake.server = $sni
         ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
          fi
          done

          restart_singbox
           
          if [ -f "$client_dir" ]; then
            # 通用正则替换 sni 参数
            sed -i "s/sni=[^&]*/sni=$new_sni/g" "$client_dir"
            base64 "$client_dir" | tr -d '\n' > /etc/sing-box/sub.txt
          fi
          
          while IFS= read -r line; do yellow "$line"; done < "${work_dir}/url.txt"
          green "\nReality SNI 已修改为：${purple}${new_sni}${re}\n"
           ;;
        3) 
		    generate_vars
            purple "端口跳跃需确保跳跃区间的端口没有被占用，NAT机请注意可用端口范围。\n"
            local check_cmds=("nft" "curl" "shuf" "python3")
            local install_pkgs=("nftables" "curl" "coreutils" "python3")
            
            for i in "${!check_cmds[@]}"; do
                if ! command -v "${check_cmds[$i]}" &> /dev/null; then
                    yellow "检测到缺少依赖 ${install_pkgs[$i]}，正在安装..."
                    if [ -f /etc/debian_version ]; then
                        apt-get update && apt-get install -y "${install_pkgs[$i]}"
                    elif [ -f /etc/redhat-release ]; then
                        yum install -y "${install_pkgs[$i]}"
                    fi
                fi
            done
            
            reading "请输入跳跃起始端口: " min_port
            while [ -z "$min_port" ]; do
                red "不能为空，请重新输入: "
                read min_port
            done
            yellow "起始端口为：$min_port"
            reading "请输入跳跃结束端口 (需大于起始端口，回车默认+100): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100)) 
            yellow "结束端口为：$max_port\n"
            
            listen_port=$(grep '"listen_port"' /etc/sing-box/conf/hysteria2.json | head -n 1 | awk -F': ' '{print $2}' | tr -d ', "')
            if [ -z "$listen_port" ]; then
                red "无法自动获取 Hysteria2 监听端口，请检查配置文件！"
                exit 1
            fi
            
            purple "正在设置端口跳跃规则..."
            
            sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
            [ -f /proc/sys/net/ipv6/conf/all/forwarding ] && sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
            
            nft add table ip nat 2>/dev/null
            nft 'add chain ip nat prerouting { type nat hook prerouting priority -100; policy accept; }' 2>/dev/null
            nft add rule ip nat prerouting udp dport $min_port-$max_port dnat to :$listen_port comment "Hysteria2_Hop" 2>/dev/null

            if [ -f /proc/net/if_inet6 ]; then
                nft add table ip6 nat 2>/dev/null
                nft 'add chain ip6 nat prerouting { type nat hook prerouting priority -100; policy accept; }' 2>/dev/null
                nft add rule ip6 nat prerouting udp dport $min_port-$max_port dnat to :$listen_port comment "Hysteria2_Hop" 2>/dev/null
            fi
            
            nft list ruleset > /etc/nftables.conf
            
            if command -v systemctl &> /dev/null; then
                systemctl enable nftables >/dev/null 2>&1
                systemctl start nftables >/dev/null 2>&1
            elif command -v rc-service &> /dev/null; then
                rc-update add nftables default 2>/dev/null
            fi

            restart_singbox
            ip=$(get_realip)
		    uuid=$(grep -oP 'hysteria2://\K[^@]+' "$client_dir" | head -n 1)
            sed -i "/hysteria2:/d" "$client_dir"
            key_path=$(grep '"key_path"' /etc/sing-box/conf/hysteria2.json | head -n 1 | sed -E 's/.*"key_path"\s*:\s*"([^"]+)".*/\1/')
            if [[ "$key_path" =~ \/root\/cert\/([^\/]+)\/ ]]; then
                custom_sni="${BASH_REMATCH[1]}"
                url_param="sni=${custom_sni}"
            else
                custom_sni="www.bing.com"
                url_param="insecure=0&sni=www.bing.com&pinSHA256=${fingerprint}"
            fi
            node_remark="${isp}_hysteria2"
            sed -i "/hysteria2:/d" "$client_dir"
            obfs_param="obfs=none"
            if [ -f "/etc/sing-box/conf/hysteria2.json" ]; then
                obfs_info=$(python3 -c "
import json
try:
    with open('/etc/sing-box/conf/hysteria2.json', 'r', encoding='utf-8') as f:
        data = json.load(f)
    obfs = {}
    if isinstance(data, dict):
        if 'inbounds' in data:
            for ib in data['inbounds']:
                if ib.get('type') == 'hysteria2':
                    obfs = ib.get('obfs', {})
        else:
            obfs = data.get('obfs', {})
    
    if obfs.get('type') == 'salamander' and obfs.get('password'):
        print(f\"obfs=salamander&obfs-password={obfs.get('password')}\")
    else:
        print(\"obfs=none\")
except:
    print(\"obfs=none\")
" 2>/dev/null)
                [ -n "$obfs_info" ] && obfs_param="$obfs_info"
            fi
            echo "hysteria2://$uuid@$ip:$listen_port?${url_param}&alpn=h3&${obfs_param}&mport=$listen_port,$min_port-$max_port#$node_remark" >> "$client_dir"        
            # ------------------------------------------------

            base64 -w0 "$client_dir" > /etc/sing-box/sub.txt         
            green "\nHysteria2 端口跳跃已开启"
            purple "跳跃区间：$min_port-$max_port"
            ;;

        4)  
            purple "正在清理端口跳跃规则..."
            if nft list chain ip nat prerouting &>/dev/null; then
                for handle in $(nft -a list chain ip nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                    nft delete rule ip nat prerouting handle $handle 2>/dev/null
                done
            fi
            
            if [ -f /proc/net/if_inet6 ] && nft list chain ip6 nat prerouting &>/dev/null; then
                for handle in $(nft -a list chain ip6 nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                    nft delete rule ip6 nat prerouting handle $handle 2>/dev/null
                done
            fi
            
            nft list ruleset > /etc/nftables.conf 2>/dev/null

            if [ -f "/etc/sing-box/url.txt" ]; then
                sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
                base64 -w0 "/etc/sing-box/url.txt" > /etc/sing-box/sub.txt
            fi
            
            green "\n[✔] 端口跳跃已关闭"
            ;;
		5)  # 检测并自动补全 python3 依赖
if ! command -v python3 &> /dev/null; then
    yellow "检测到缺少依赖 python3，正在安装..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y python3
    elif [ -f /etc/redhat-release ]; then
        yum install -y python3
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache python3
    fi
fi

            if [ ! -f "/etc/sing-box/conf/hysteria2.json" ] || ! grep -q "hysteria2://" "/etc/sing-box/url.txt"; then
                red "未检测到 Hysteria2 节点配置或链接，请先安装 Hysteria2！"
                exit 1
            fi
            obfs_pwd=$(tr -dc 'a-zA-Z' < /dev/urandom | head -c 12)   
            python3 -c "
import json
path = '/etc/sing-box/conf/hysteria2.json'
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    obfs_data = {
        'type': 'salamander',
        'password': '$obfs_pwd'
    }

    if isinstance(data, dict):
        if 'inbounds' in data:
            for ib in data['inbounds']:
                if ib.get('type') == 'hysteria2':
                    ib['obfs'] = obfs_data
        else:
            data['obfs'] = obfs_data

    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'修改 JSON 失败: {e}')
"
            sed -i -E 's/&obfs=[^&#]+//g; s/&obfs-password=[^&#]+//g' /etc/sing-box/url.txt
	        sed -i -E "s/&alpn=h3/\\&obfs=salamander\\&obfs-password=${obfs_pwd}\\&alpn=h3/g" /etc/sing-box/url.txt
			base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
            if command -v restart_singbox &> /dev/null; then
                restart_singbox
            else
                systemctl restart sing-box >/dev/null 2>&1
            fi
            hy2_link=$(grep -oP 'hysteria2://.*' /etc/sing-box/url.txt | head -n 1)
            
            echo ""
            green "=================================================="
            green "Hysteria2 Salamander 混淆已开启！"
            green "=================================================="
            green "${hy2_link}"
            green "=================================================="
            echo "" 
            ;;
		6)
            if [ ! -f "/etc/sing-box/conf/hysteria2.json" ] || ! grep -q "hysteria2://" "/etc/sing-box/url.txt"; then
                red "未检测到 Hysteria2 节点配置或链接！"
                exit 1
            fi
            python3 -c "
import json
path = '/etc/sing-box/conf/hysteria2.json'
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    if isinstance(data, dict):
        if 'inbounds' in data:
            for ib in data['inbounds']:
                if ib.get('type') == 'hysteria2' and 'obfs' in ib:
                    del ib['obfs']
        elif 'obfs' in data:
            del data['obfs']

    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
except Exception as e:
    print(f'清理 JSON 混淆配置失败: {e}')
"
            sed -i -E 's/&obfs=[^&#]+//g; s/&obfs-password=[^&#]+//g' /etc/sing-box/url.txt
			base64 -w0 "/etc/sing-box/url.txt" > "/etc/sing-box/sub.txt" 2>/dev/null
            if command -v restart_singbox &> /dev/null; then
                restart_singbox
            else
                systemctl restart sing-box >/dev/null 2>&1
            fi
            hy2_link=$(grep -oP 'hysteria2://.*' /etc/sing-box/url.txt | head -n 1)
            
            echo ""
            green "=================================================="
            green "Hysteria2 混淆已关闭！"
            green "=================================================="
            green "${hy2_link}"
            green "=================================================="
            echo ""
            ;;

        0)  menu ;;
        *)  read "无效的选项！" ;; 
    esac
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

disable_open_sub() {
    while true; do
    local nginx_status=$(check_nginx 2>/dev/null)
    
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"
        sleep 1
        menu
        return
    fi

    clear
    echo ""
    green "=== 节点订阅管理 ===\n"
    printf "${purple}--Nginx 状态: %s${re}\n" "$(to_chinese "$nginx_status")"
    skyblue "------------"
    green "1. 启动nginx"
    skyblue "------------"
	green "2. 停止nginx"
    skyblue "------------"
	green "3. 重启nginx"
    skyblue "------------"
	green "4. nginx配置"
    skyblue "------------"
    green "5. 关闭节点订阅"
    skyblue "------------"
    green "6. 开启重置订阅"
    skyblue "------------"
	green "7. 启用域名订阅"
    skyblue "------------"
	green "8. 删除域名订阅"
    skyblue "------------"
	green "9. nginx更新"
    skyblue "------------"
	green "10. nginx 反向代理"
    skyblue "------------"
	green "11. 域名证书管理"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
	local choice
    reading "请输入选择: " choice
    case "${choice}" in
	    1)
            start_nginx
            green "Nginx 服务已启动"
			sleep 1
            ;;
        2)
            stop_nginx
            yellow "Nginx 服务已停止"
			sleep 1
            ;;
        3)
            restart_nginx
            green "Nginx 服务已重启"
			sleep 1
            ;;
		4)
            while true; do
                clear
                green "=== Nginx配置管理 ==="
                skyblue "------------"
                avail_dir="/etc/nginx/sites-available"
                enabled_dir="/etc/nginx/sites-enabled"                        
                
                # 防止目录不存在导致报错
                mkdir -p "$avail_dir" "$enabled_dir"

                mapfile -t all_conf < <(ls "$avail_dir" 2>/dev/null | grep '\.conf$')
				disabled_list=()
                enabled_list=()
                for conf in "${all_conf[@]}"; do
                    if [ -L "$enabled_dir/$conf" ]; then
                        enabled_list+=("$conf")
                    else
                        disabled_list+=("$conf")
                    fi
                done
                local idx=1
                local mapping=()

                # --- 上部分：显示未启用 (不在 sites-enabled 中) ---
                green "未启用配置:"
                if [ ${#disabled_list[@]} -eq 0 ]; then
                    echo " (暂无)"
                else
                    for conf in "${disabled_list[@]}"; do
                        domain=$(nginx_get_domain "$avail_dir/$conf")
echo -e " $idx. \033[33m$conf\033[0m \033[36m[$domain]\033[0m"
                        mapping[$idx]="$conf:enable"
                        ((idx++))
                    done
                fi
                skyblue "------------"
                # --- 下部分：显示已启用 (已链接到 sites-enabled) ---
                green "已启用配置:"
                if [ ${#enabled_list[@]} -eq 0 ]; then
                    echo " (暂无)"
                else
                    for conf in "${enabled_list[@]}"; do
                        domain=$(nginx_get_domain "$avail_dir/$conf")
[ -z "$domain" ] && domain="无域名"
echo -e " $idx. \033[33m$conf\033[0m \033[36m[$domain]\033[0m"
                        mapping[$idx]="$conf:disable"
                        ((idx++))
                    done
                fi

                skyblue "------------"
                purple "0. 返回上级菜单"
                skyblue "------------"
                echo -e "操作指南: 输入 \033[33m纯数字\033[0m 切换启用/停用状态"
                echo -e "          输入 \033[31md+数字\033[0m 彻底删除对应配置 (例如 d1)"
                echo -n "请选择操作: "
                read sub_choice

                [ "$sub_choice" == "0" ] && break

                if [[ "$sub_choice" =~ ^[dD]([0-9]+)$ ]]; then
                    del_idx="${BASH_REMATCH[1]}"
                    target_info=${mapping[$del_idx]}
                    if [ -z "$target_info" ]; then
                        yellow "选择无效，请重新输入"
                        sleep 1
                        continue
                    fi
                    filename=${target_info%:*}
                    
                    echo ""
                    read -p "⚠️ : 确定要彻底删除配置 [$filename] 吗？(y/n): " confirm_del
                    if [[ "$confirm_del" == [yY]* ]]; then
                        rm -f "$avail_dir/$filename"
                        rm -f "$enabled_dir/$filename"
                        green "已彻底删除配置文件: $filename"
                        
                        echo -e "\033[1;33m正在验证并重载 Nginx 配置...\033[0m"
                        if nginx -t > /dev/null 2>&1; then
                            if command_exists rc-service 2>/dev/null; then
                                rc-service nginx reload
                            else 
                                systemctl reload nginx
                            fi
                            green "Nginx 已自动重载！"
                        else
                            red "错误：Nginx 配置检查失败，请手动排查！"
                        fi
                        sleep 2
                    fi
                    continue
                fi

                target_info=${mapping[$sub_choice]}
                if [ -z "$target_info" ]; then
                    yellow "选择无效，请重新输入"
                    sleep 1
                    continue
                fi
                filename=${target_info%:*}
                action=${target_info#*:}
                if [ "$action" == "enable" ]; then
                    ln -sf "$avail_dir/$filename" "$enabled_dir/$filename"
                    green "已创建软链接: $filename"
                else
                    rm -f "$enabled_dir/$filename"
                    yellow "已断开软链接: $filename"
                fi

                echo -e "\033[1;33m正在验证 Nginx 配置...\033[0m"
                if nginx -t > /dev/null 2>&1; then
                    if command_exists rc-service 2>/dev/null; then
                        rc-service nginx reload
                    else 
                        systemctl reload nginx
                    fi
                    green "Nginx 配置正常，已自动重载！"
                else
                    red "错误：Nginx 配置语法检查失败，请手动排查！"
                    
                    if [ "$action" == "enable" ]; then
                        yellow "已撤销刚才启用的软链接，以保证Nginx正常运行。"
                        rm -f "$enabled_dir/$filename"
                    fi
                fi
                sleep 2
            done
			sleep 1
            ;;
        5)
           rm -f /etc/nginx/conf.d/sing-box.conf
		   restart_nginx
		   green "节点订阅已删除"
		   sleep 1
		   ;;
        6)
		   nginx_port=$(shuf -i 1000-65000 -n 1)
		   server_ip=$(get_realip)
           password=$(tr -dc A-Za-z < /dev/urandom | head -c 32) 
		   cat > /etc/nginx/conf.d/sing-box.conf << EOF
server {
    listen $nginx_port;
    listen [::]:$nginx_port;
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location / {
        return 404;
    }
	location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
		   allow_port $nginx_port/tcp > /dev/null 2>&1   
           restart_nginx
           green "新的订阅链接为：http://$server_ip:$sub_port/$password"
		   sleep 1
		    ;;
		7)
                clear
                skyblue "=== 配置域名 ==="
                local domain
                reading "请输入你的订阅域名: " domain
                [[ -z "$domain" ]] && { red "错误：域名不能为空！"; sleep 1; continue; }
                
                stop_nginx
                check_and_issue_ssl "$domain"
                local cert_file="" key_file=""
                for base_dir in "/root/cert" "/etc/nginx/cert"; do
                    if [[ -f "$base_dir/$domain/fullchain.pem" && -f "$base_dir/$domain/privkey.pem" ]]; then
                        cert_file="$base_dir/$domain/fullchain.pem"
                        key_file="$base_dir/$domain/privkey.pem"
                        break
                    fi
                done
                if [[ -z "$cert_file" ]]; then
                    red "错误：未能获取到域名 $domain 的有效 SSL 证书（申请可能已失败），配置终止！"
                    restart_nginx
                    sleep 1
                    continue
                fi
                
                stop_nginx
                nginx2_port=$(shuf -i 1000-65000 -n 1)
                password=$(tr -dc A-Za-z < /dev/urandom | head -c 32) 
                
                cat > /etc/nginx/conf.d/sing-box1.conf << EOF
server {
    listen $nginx2_port ssl;
    listen [::]:$nginx2_port ssl;
    server_name $domain;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location / {
        return 404;
    }
	location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
                allow_port $nginx2_port/tcp > /dev/null 2>&1   
                restart_nginx
                green "域名订阅链接为：https://$domain:$nginx2_port/$password"
                sleep 1
                ;;
		8)
		   rm -f /etc/nginx/conf.d/sing-box1.conf
		   restart_nginx
		   green "域名订阅已删除"
		   sleep 1
		   ;;
	    9)
            clear
            skyblue "=============================="
            green "       Nginx 版本检查与更新       "
            skyblue "=============================="
            
            echo -e "正在检测最新版本..."
            
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                OS=$ID
            else
                OS="debian"
            fi
            
            apt install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring >/dev/null 2>&1
            curl -s https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null 2>&1
            CODENAME=$(lsb_release -cs)
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/$OS $CODENAME nginx" > /etc/apt/sources.list.d/nginx.list
            
            cat <<EOF > /etc/apt/preferences.d/99nginx
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

            apt-get update >/dev/null 2>&1
            
            CURRENT_VERSION=$(nginx -v 2>&1 | awk -F'/' '{print $2}')
            LATEST_VERSION=$(apt-cache policy nginx | grep Candidate | awk '{print $2}')
            
            echo -e "当前安装版本: ${CURRENT_VERSION:-未知}"
            echo -e "官方最新版本: ${LATEST_VERSION:-未知}"
            echo ""
            
            read -p "是否确认更新/升级 Nginx 到最新版？[y/N]: " choice_update
            if [[ "${choice_update}" =~ ^[Yy]$ ]]; then
                echo ""
                green "[+] 开始 Nginx 升级..."
                apt install -y --only-upgrade nginx || apt install -y nginx
                if [ -f /etc/nginx/nginx.conf ] && ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
                    if grep -q "conf.d/\*.conf;" /etc/nginx/nginx.conf; then
                        sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
                    fi
                fi
                
                # 测试并重载
                if nginx -t; then
                    systemctl enable --now nginx
                    systemctl reload nginx
                    green "[✔] Nginx 升级成功并已重载服务！"
                else
                    yellow "[!] Nginx 配置文件测试未通过，请检查配置。"
                fi
            else
                yellow "已取消更新。"
            fi
            echo ""
            read -p "按回车键继续..."
			sleep 1
            ;;
       10)
    clear
    green "=== 添加 Nginx 反向代理 ==="
    skyblue "------------"
    
    echo -e "请输入目标反代地址"
    echo -e "(例如 \033[33mhttp://127.0.0.1:8899\033[0m 或 \033[33mhttp://127.0.0.1:8899/aGnZvKr7AL/\033[0m): "
    read -p "反代地址 : " proxy_target
    if [ -z "$proxy_target" ]; then
        red "错误：反代地址不能为空！"
        sleep 1.5; return 1
    fi

    echo -e "\n请输入要绑定的域名: "
    read -p "域名 : " proxy_domain
    if [ -z "$proxy_domain" ]; then
        red "错误：域名不能为空！"
        sleep 1.5; return 1
    fi

    echo -e "\n\033[1;33m正在检查并处理 SSL 证书...\033[0m"
    check_and_issue_ssl "$proxy_domain"
    if [ $? -ne 0 ]; then
        red "证书获取失败，无法继续配置反代！"
        sleep 2; return 1
    fi
    nginx_cert_dir="/etc/nginx/cert/${proxy_domain}"
    mkdir -p "$nginx_cert_dir"
    cp -f "$cert_file" "${nginx_cert_dir}/fullchain.pem"
    cp -f "$key_file" "${nginx_cert_dir}/privkey.pem"
  
    final_cert="${nginx_cert_dir}/fullchain.pem"
    final_key="${nginx_cert_dir}/privkey.pem"

    echo -e "\n请输入 Nginx 配置文件名称 (直接回车则自动生成随机名称): "
    read -p "配置名 : " custom_conf_name
    
    if [ -z "$custom_conf_name" ]; then
        rand_str=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 6 | head -n 1)
        conf_name="${proxy_domain}_${rand_str}"
    else
        conf_name="${custom_conf_name%.conf}"
    fi
    rm -f /etc/nginx/sites-enabled/default
    avail_file="/etc/nginx/sites-available/${conf_name}.conf"
    enabled_file="/etc/nginx/sites-enabled/${conf_name}.conf"

    cat > "$avail_file" <<EOF
server {
    listen 80;
    server_name ${proxy_domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${proxy_domain};

    ssl_certificate ${final_cert};
    ssl_certificate_key ${final_key};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass ${proxy_target};
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    ln -sf "$avail_file" "$enabled_file"
    echo -e "\n\033[1;33m正在验证并加载 Nginx 配置...\033[0m"
    if nginx -t >/dev/null 2>&1; then
        if command_exists rc-service 2>/dev/null; then
            rc-service nginx reload
        elif type restart_nginx >/dev/null 2>&1; then
            restart_nginx
        else 
            systemctl reload nginx
        fi
        
        green "配置生成成功！"
        skyblue "配置文件: $avail_file"
        skyblue "访问地址: https://${proxy_domain}"
    else
        red "Nginx 配置语法检查失败！已自动撤销此配置。"
        rm -f "$enabled_file"
    fi
    
    echo ""
    read -n 1 -s -r -p "按任意键返回上级菜单..."
    sleep 1
    ;;
       11) cert_manager
		   ;;
        0) 
        break
        ;; 
        *)  
        red "无效的选项！"
        sleep 1 
        ;;
    esac
  done
}
#删除节点函数
delete_node() {
local target="$1"
local target_conf="$2"
local service="$3"
if [ ! -f "$target_conf" ]; then
    red "错误: 未找到配置文件 ($target_conf)，删除取消。"
    return 1
fi
local port
port=$(grep -E '"listen_port"|"port"' "$target_conf" | head -1 | tr -cd '0-9')
if [ -n "$port" ] && [ "$port" != "443" ]; then
    for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$port" '$0~"dport "p {print $NF}'); do
        nft delete rule inet filter input handle "$handle" 2>/dev/null
    done
    nft list ruleset > /etc/nftables.conf 2>/dev/null
fi
rm -f "$target_conf"
if [ -f "/etc/sing-box/url.txt" ]; then
    sed -i "/${target}/d" /etc/sing-box/url.txt
    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
    echo "" >> /etc/sing-box/url.txt
fi
if [ -s "/etc/sing-box/url.txt" ]; then
    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
else
    truncate -s 0 /etc/sing-box/sub.txt
fi
if [ "$service" = "xray" ]; then
    restart_xray
else
    restart_singbox
fi
green "==============================================="
green " 节点已移除!"
green "==============================================="
}

manage_nodes_menu() {
    if [ -z "$private_key" ]; then
        output=$(${work_dir}/sing-box generate reality-keypair)
        private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
		short_id=$(openssl rand -hex 6)
    fi
    while true; do
       local CONF_DIR="/etc/sing-box/conf"
       local XRAY_CONF_DIR="/etc/xray/conf"
       local width=45
  fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
  local node_list=(
    "$CONF_DIR/xtls-reality.json|vless-Reality|1"
    "$CONF_DIR/hysteria2.json|hysteria2|2"
    "$CONF_DIR/tuic.json|tuic|3"
    "$CONF_DIR/h2-reality.json|http-Reality|4"
    "$CONF_DIR/grpc-reality.json|gRPC-Reality|5"
    "$CONF_DIR/anytls.json|anytls|6"
	"$CONF_DIR/anytls-reality.json|anytls-Reality|7"
    "$CONF_DIR/socks5.json|socks5|8"
    "$CONF_DIR/http.json|HTTP|9"
    "$CONF_DIR/vless-wstls-cdn.json|vless-ws-tls-cdn|10"
    "$CONF_DIR/vless-ws-cdn.json|Vless-Vmess-Trojan-cdn|11"
	"$CONF_DIR/tunnel-ws-argo.json|Vless-Vmess-Trojan-argo|12"
    "$XRAY_CONF_DIR/xhttp-reality.json|xhttp-reality|13"
    "$XRAY_CONF_DIR/xhttp-cdn.json|xhttp-cdn|14"
    "$XRAY_CONF_DIR/xhttp-cdn-tls.json|xhttp-cdn-tls|15"
	"$XRAY_CONF_DIR/xhttp-udp-tls.json|xhttp-udp-tls|16"
	"$XRAY_CONF_DIR/xhttp-tcpudp-tls.json|xhttp-tcpudp-cdn-tls|17"
	"$CONF_DIR/vless-tcp-tls.json|vless-tcp-tls|18"
	"$CONF_DIR/naive-tls.json|Naiveproxy|19"
	"$CONF_DIR/vmess-ws.json|vmess-ws|20"
	"$CONF_DIR/vless-ws.json|vless-ws|21"
)
		
        clear
        yellow "============================================="
        echo -e "             添加节点               "
        yellow "============================================="
        echo -e "\e[1;34m[ 未添加节点 ]\033[0m"
        local has_unadded=false
        for item in "${node_list[@]}"; do
            local file=$(echo $item | cut -d'|' -f1)
            local name=$(echo $item | cut -d'|' -f2)
            local id=$(echo $item | cut -d'|' -f3)
            
            if [ ! -f "$file" ]; then
                local left_text=" ${id}. ${name}节点"
                local right_text="(未添加) -> 输入 ${id} 开始配置"
                printf "%s%$(($width - ${#left_text}))s\n" "$left_text" "$(red "$right_text")"
                has_unadded=true
            fi
        done
        [ "$has_unadded" = false ] && echo -e " (所有节点已添加)"

        echo -e "\n============================================="
        echo -e "\e[1;32m[ 已添加节点 ]\033[0m"
        local has_added=false
        for item in "${node_list[@]}"; do
            local file=$(echo $item | cut -d'|' -f1)
            local name=$(echo $item | cut -d'|' -f2)
            local id=$(echo $item | cut -d'|' -f3)
            local del_id=$((id + 50))
            
            if [ -f "$file" ]; then
                local left_text=" ${del_id}. ${name}节点"
                local right_text="(已添加) -> 输入 ${del_id} 删除节点"
                printf "%s%$(($width - ${#left_text}))s\n" "$left_text" "$(green "$right_text")"
                has_added=true
            fi
        done
        [ "$has_added" = false ] && echo -e " (当前无运行中节点)"

        yellow "============================================="
		echo -e "\033[31m 0. 返回上一级菜单\033[0m"
        echo -ne "\n"
        reading "请选择操作: " choice
		case "${choice}" in
    1|2|3|4|5|6|7|8|9|13|18|20|21)
    if [[ "$choice" == "12" ]]; then
        check_xray
        xray_status=$?
        if [ $xray_status -eq 2 ]; then
            red "Xray 未安装！"
            read -rp "按回车安装 Xray，其他键取消: " install_choice
            if [ -z "$install_choice" ]; then
                install_xray
                check_xray
                xray_status=$?
                if [ $xray_status -eq 2 ]; then
                    red "Xray 安装失败！"
                    return 1
                fi
            else
                return 1
            fi
        fi
    fi
    generate_vars
    server_ip=$(get_realip)
    case "$choice" in
    1)
        default_port=$xtls_reality
        ;;
	2)
        default_port=$hy2_port
        ;;
    3)
        default_port=$tuic_port
        ;;
    4)
        default_port=$h2_reality
        ;;
    5)
        default_port=$grpc_reality
        ;;
    6)
        default_port=$anytls_port
        ;;
    7)
        default_port=$anytls_reality_port
        ;;
    8)
        default_port=$socks_port
        ;;
    9)
        default_port=$http_port
        ;;
    13)
        default_port=$xray_xhttp_reality
        ;;
	18)
        default_port=$vless_tcp_tls
        ;;
	20)
        default_port=60001
        ;;
    21)
        default_port=60002
        ;;
esac
    while true; do
    read -rp "请输入 ${node_name} 端口 (100-65535, 默认 ${default_port}): " custom_port
    if [ -z "$custom_port" ]; then
        custom_port=$default_port
        break
    fi
    if [[ "$custom_port" =~ ^[0-9]+$ ]] && [ "$custom_port" -ge 100 ] && [ "$custom_port" -le 65535 ]; then
        if ss -tuln | grep -qE ":$custom_port\b"; then
            red "该端口已被占用，请重新输入！"
            continue
        fi
        break
    else
        red "输入错误！请输入有效的端口号 (100-65535)。"
    fi
done
    case "$choice" in
        1)
            xtls_reality=$custom_port
            cat > /etc/sing-box/conf/xtls-reality.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ]
}
EOF
            node_remark="${isp}_vless_tcp_reality"
            url="vless://${uuid}@${server_ip}:${custom_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${node_remark}"
            restart_service="singbox"
            ;;
		2)
    echo -e "\n请选择 TLS 证书类型:"
    echo -e " 1) \e[32m使用自签名证书\e[0m"
    echo -e " 2) \e[32m使用真实域名证书\e[0m"
    read -rp "请输入数字 [1-2] (默认 1): " cert_type
    [ -z "$cert_type" ] && cert_type=1
    if [ "$cert_type" -eq 2 ]; then
        if check_and_issue_ssl; then
            cert_path="$cert_file"
            key_path="$key_file"
            url_param="sni=${domain}"
        else
            return 1
        fi
    else
        cert_path="$work_dir/cert.pem"
        key_path="$work_dir/private.key"
        url_param="insecure=1&sni=www.bing.com&pinSHA256=${fingerprint}"
    fi
    yellow "正在配置 hysteria2..."
    cat > /etc/sing-box/conf/hysteria2.json << EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ]
}
EOF
    allow_port "$custom_port/udp" >/dev/null 2>&1
    node_remark="${isp}_hysteria2"
    url="hysteria2://${uuid}@${server_ip}:${custom_port}/?${url_param}&alpn=h3#${node_remark}"
    ;;
	3)
    echo -e "\n请选择 TLS 证书类型:"
    echo -e " 1) \e[32m使用自签名证书\e[0m"
    echo -e " 2) \e[32m使用真实域名证书\e[0m"
    read -rp "请输入数字 [1-2] (默认 1): " cert_type
    [ -z "$cert_type" ] && cert_type=1
    if [ "$cert_type" -eq 2 ]; then
        if check_and_issue_ssl; then
            cert_path="$cert_file"
            key_path="$key_file"
            url_param="sni=${domain}"
        else
            return 1
        fi
    else
        cert_path="$work_dir/cert.pem"
        key_path="$work_dir/private.key"
        url_param="insecure=1&sni=www.bing.com"
    fi
    yellow "正在配置 tuic..."
    cat > /etc/sing-box/conf/tuic.json << EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "uuid": "$uuid",
          "password": "$password"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
      }
    }
  ]
}
EOF
    allow_port "$custom_port/udp" >/dev/null 2>&1
    node_remark="${isp}_tuic"
    url="tuic://${uuid}:${password}@${server_ip}:${custom_port}/?${url_param}&congestion_control=bbr&udp_relay_mode=native&alpn=h3#${node_remark}"
    ;;
        4)
            h2_reality=$custom_port
            cat > /etc/sing-box/conf/h2-reality.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "h2-reality",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      },
      "transport": {
        "type": "http"
      },
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 1000,
          "down_mbps": 1000
        }
      }
    }
  ]
}
EOF
            node_remark="${isp}_vless_http_reality"
            url="vless://${uuid}@${server_ip}:${custom_port}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=http#${node_remark}"
            restart_service="singbox"
            ;;
        5)
            grpc_reality=$custom_port
            cat > /etc/sing-box/conf/grpc-reality.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "grpc-reality",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      },
      "transport": {
        "type": "grpc",
        "service_name": "grpc"
      },
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 200,
          "down_mbps": 200
        }
      }
    }
  ]
}
EOF
            node_remark="${isp}_vless_grpc_reality"
            url="vless://${uuid}@${server_ip}:${custom_port}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=grpc&serviceName=grpc#${node_remark}"
            restart_service="singbox"
            ;;
	    6)
    echo -e "\n请选择 TLS 证书类型:"
    echo -e " 1) \e[32m使用自签名证书\e[0m"
    echo -e " 2) \e[32m使用真实域名证书\e[0m"
    read -rp "请输入数字 [1-2] (默认 1): " cert_type
    [ -z "$cert_type" ] && cert_type=1
    if [ "$cert_type" -eq 2 ]; then
        if check_and_issue_ssl; then
            cert_path="$cert_file"
            key_path="$key_file"
            url_param="sni=${domain}"
        else
            return 1
        fi
    else
        cert_path="$work_dir/cert.pem"
        key_path="$work_dir/private.key"
        url_param="insecure=1&sni=www.bing.com&pinSHA256=${fingerprint}"
    fi
    yellow "正在配置 anytls..."
    cat > /etc/sing-box/conf/anytls.json << EOF
{
    "inbounds":[
        {
            "type":"anytls",
            "tag":"anytls",
            "listen":"::",
            "listen_port":$custom_port,
            "users":[
                {
                    "password":"$password"
                }
            ],
            "padding_scheme":[
                "stop=6",
                "0=30-50",
                "1=80-400",
                "2=400-500,c,500-1000,c,500-1000",
                "3=9-9,500-1000",
                "4=500-1000",
                "5=500-1000"
            ],
            "tls":{
                "enabled":true,
                "certificate_path":"$cert_path",
                "key_path":"$key_path"
            }
        }
    ]
}
EOF
    node_remark="${isp}_anytls_nt123"
    url="anytls://${password}@${server_ip}:${custom_port}?${url_param}&alpn=h3#${node_remark}"
    ;;
	7)
    yellow "正在配置 anytls + Reality..."
    cat > /etc/sing-box/conf/anytls-reality.json << EOF
{
    "inbounds":[
        {
            "type":"anytls",
            "listen":"::",
            "tag":"anytls-reality",
            "listen_port":$custom_port,
            "users":[
                {
                    "password":"$password"
                }
            ],
            "padding_scheme":[
                "stop=8",
                "0=30-30",
                "1=100-400",
                "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
                "3=9-9,500-1000",
                "4=500-1000",
                "5=500-1000",
                "6=500-1000",
                "7=500-1000"
            ],
            "tls":{
                "enabled":true,
                "server_name":"www.iij.ad.jp",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"www.iij.ad.jp",
                        "server_port":443
                    },
                    "private_key":"$private_key",
                    "short_id":["$short_id"]
                }
            }
        }
    ]
}
EOF
    node_remark="${isp}_anytls_reality"
    url="anytls://${password}@${server_ip}:${custom_port}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${node_remark}"
    ;;
		8)
    socks_port=$custom_port
    yellow "正在配置 Socks5..."
    cat > /etc/sing-box/conf/socks5.json << EOF
{
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "username": "$username",
          "password": "$password"
        }
      ]
    }
  ]
}
EOF
    node_remark="${isp}_socks5"
    url="socks://${username}:${password}@${server_ip}:${custom_port}#${node_remark}"
    restart_service="singbox"
    ;;
	9)
    http_port=$custom_port
    yellow "正在配置 HTTP 代理..."
    cat > /etc/sing-box/conf/http.json << EOF
{
  "inbounds": [
    {
      "type": "http",
      "tag": "http-in",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "username": "$username",
          "password": "$password"
        }
      ]
    }
  ]
}
EOF
    node_remark="${isp}_http"
    url="http://${username}:${password}@${server_ip}:${custom_port}#${node_remark}"
    restart_service="singbox"
    ;;
        13)
            xray_xhttp_reality=$custom_port
            mkdir -p /etc/xray/conf
            cat > /etc/xray/conf/xhttp-reality.json << EOF
{
  "inbounds": [
    {
      "listen": "::",
      "tag": "vless-xhttp-reality",
      "port": $custom_port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.iij.ad.jp:443",
          "xver": 0,
          "serverNames": [
            "www.iij.ad.jp"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id"
          ]
        },
        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "auto"
        }
      }
    }
  ]
}
EOF
            node_remark="${isp}_xray_vless_xhttp_reality"
            url="vless://${uuid}@${server_ip}:${custom_port}?encryption=none&flow=&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&sid=${short_id}&type=xhttp&path=%2Fxhttp&mode=auto#${node_remark}"
            restart_service="xray"
            ;;
18)
    check_and_issue_ssl || return 1

    cat > /etc/sing-box/conf/vless-tcp-tls.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-tcp-tls",
      "listen": "::",
      "listen_port": $custom_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${domain:-$server_ip}",
        "certificate_path": "$cert_file",
        "key_path": "$key_file"
      }
    }
  ]
}
EOF
    node_remark="${isp}_vless_tcp_tls"
    url="vless://${uuid}@${domain:-$server_ip}:${custom_port}?encryption=none&security=tls&sni=${domain:-$server_ip}&type=tcp#${node_remark}"
    restart_service="singbox"
	;;
20) 
    cat > /etc/sing-box/conf/vmess-ws.json <<EOF
{
  "inbounds": [
    {
       "type": "vmess",
       "tag": "vmess-ws",
       "listen": "::",
       "listen_port": $custom_port,
       "users": [
           {
              "uuid": "$uuid"
           }
        ],
       "transport": {
           "type": "ws",
           "path": "/asasbsbs-vmess",
		   "max_early_data": 2048,
           "early_data_header_name": "Sec-WebSocket-Protocol"
       }
     }
  ]
}
EOF
    node_remark="${isp}_vmess_ws_notls"
    VMESS="{ \"v\": \"2\", \"ps\": \"${node_remark}\", \"add\": \"${server_ip}\", \"port\": \"${custom_port}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"encryption\": \"auto\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"\", \"path\": \"/asasbsbs-vmess?ed=2048\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": false }"
    url="vmess://$(echo -n "$VMESS" | base64 -w0)"
    restart_service="singbox"
    ;;
21) 
    cat > /etc/sing-box/conf/vless-ws.json <<EOF
{
  "inbounds": [
    {
       "type": "vless",
       "tag": "vless-ws",
       "listen": "::",
       "listen_port": $custom_port,
       "users": [
           {
              "uuid": "$uuid"
           }
        ],
       "transport": {
           "type": "ws",
           "path": "/asasbsbs-vless",
		   "max_early_data": 2048,
           "early_data_header_name": "Sec-WebSocket-Protocol"
       }
     }
  ]
}
EOF
    node_remark="${isp}_vless_ws_notls"
    url="vless://${uuid}@${server_ip}:${custom_port}?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=none&type=ws&path=/asasbsbs-vless?ed=2048#${node_remark}"  
    restart_service="singbox"
    ;;
    esac
allow_port "$custom_port/tcp" >/dev/null 2>&1
sed -i "/#${node_remark}$/d" /etc/sing-box/url.txt 2>/dev/null
echo "$url" >> /etc/sing-box/url.txt
echo "" >> /etc/sing-box/url.txt
base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
if [[ "$choice" == "12" ]]; then
    restart_xray
else
    restart_singbox
fi
green "${node_name} 节点已添加!"
green "节点链接: $url"
;;
		10)
    check_and_issue_ssl || return 1
    generate_vars
    server_ip=$(get_realip)
    echo ""
    vless_wstls_cdn_port=$(get_available_port)
    if [[ ! "$vless_wstls_cdn_port" =~ ^[0-9]+$ ]]; then
        red "获取 VLESS WS TLS 端口失败：${vless_wstls_cdn_port:-<空>}"
        return 1
    fi
    ws_path="/sspaasksavxssaszass"
    cat > /etc/sing-box/conf/vless-wstls-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-wstls-cdn",
      "listen": "::",
      "listen_port": $vless_wstls_cdn_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${domain:-$server_ip}",
        "certificate_path": "$cert_file",
        "key_path": "$key_file"
      },
      "transport": {
        "type": "ws",
        "path": "$ws_path",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF

    allow_port "$vless_wstls_cdn_port/tcp" >/dev/null 2>&1
    node_remark_direct="${isp}_vless_wstls_direct"
    VLESS_DIRECT_URL="vless://${uuid}@${server_ip}:${vless_wstls_cdn_port}?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=tls&sni=${domain:-$server_ip}&type=ws&host=${domain:-$server_ip}&path=${ws_path}?ed=2048%3Fed%3D2560#${node_remark_direct}"
    if [ -f "${work_dir}/url.txt" ]; then
        sed -i "/#${node_remark_direct}$/{N;d;}" "${work_dir}/url.txt"
    fi
    echo "$VLESS_DIRECT_URL" >> "${work_dir}/url.txt"
    echo "" >> "${work_dir}/url.txt"
    echo ""
    read -rp "是否需要为此节点配置 Cloudflare CDN 节点？(y/N): " add_cdn
    unset VLESS_CDN_URL
    if [[ "$add_cdn" =~ ^[Yy]$ ]]; then
    if [[ -z "$domain" ]]; then
        yellow "未检测到有效的域名变量，已跳过 CDN 加速配置。"
    else
        if [[ -z "${CF_TOKEN:-}" &&
      ( -z "${CF_EMAIL:-}" || -z "${CF_KEY:-}" ) ]]; then
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
        if [[ -n "${CF_TOKEN:-}" ||
              ( -n "${CF_EMAIL:-}" && -n "${CF_KEY:-}" ) ]]; then
            zone_id=$(cf_find_zone "$domain")
            if [[ -n "$zone_id" ]]; then
                green "Cloudflare Zone 检测成功：$zone_id"
                if cf_upsert_dns "$zone_id" "$domain" "$server_ip"; then
                    green "Cloudflare DNS 配置成功"
                else
                    yellow "警告：Cloudflare DNS 配置失败"
                fi
                if cf_set_ssl "$zone_id" "full"; then
                    green "Cloudflare SSL 模式已设置为 Full"
                else
                    yellow "警告：Cloudflare SSL 模式设置失败"
                fi
                if set_domain_origin_port \
                    "$zone_id" \
                    "$domain" \
                    "$vless_wstls_cdn_port"; then
                    green "Cloudflare CDN 回源规则配置成功"
                    green "回源端口：$vless_wstls_cdn_port"
                else
                    yellow "警告：Cloudflare CDN 回源规则配置失败"
                fi
                node_remark_cdn="${isp}_vless_wstls_cdn"
                VLESS_CDN_URL="vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}%3Fed%3D2560#${node_remark_cdn}"
                if [ -f "${work_dir}/url.txt" ]; then
                    sed -i "/#${node_remark_cdn}$/{N;d;}" "${work_dir}/url.txt"
                fi
                echo "$VLESS_CDN_URL" >> "${work_dir}/url.txt"
                echo "" >> "${work_dir}/url.txt"
            else
                yellow "未找到 ${domain} 对应的 Cloudflare Zone。"
                yellow "请确认该域名已经添加到当前 Cloudflare 账户。"
            fi
        else
            yellow "未获得有效的 Cloudflare API 凭据，已跳过 CDN 配置。"
        fi
    fi
fi
    base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt" 2>/dev/null
    restart_singbox
    green "--------------------------------------------------"
    green " 节点创建完成！"
    green "--------------------------------------------------"
    green " 1. 直连节点链接："
    echo "$VLESS_DIRECT_URL"
    if [[ -n "${VLESS_CDN_URL:-}" ]]; then
        echo ""
        green " 2. CDN 节点链接："
        echo "$VLESS_CDN_URL"
    fi
    green "--------------------------------------------------"
    ;;
    11)
    generate_vars
    server_ip=$(get_realip)
    echo ""
    vmess_ws_cdn_port=$(get_available_port)
    vless_ws_cdn_port=$(get_available_port)
    trojan_ws_cdn_port=$(get_available_port)
    vmess_path="/vmess-ws"
    vless_path="/vless-ws"
    trojan_path="/trojan-ws"
    allow_port $vmess_ws_cdn_port/tcp > /dev/null 2>&1
    allow_port $vless_ws_cdn_port/tcp > /dev/null 2>&1
    allow_port $trojan_ws_cdn_port/tcp > /dev/null 2>&1
    echo ""
    skyblue "请选择 Cloudflare 验证方式："
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
green "当前 CDN 域名: $domain"
    if [[ -n "${CF_TOKEN:-}" || ( -n "${CF_EMAIL:-}" && -n "${CF_KEY:-}" ) ]]; then
        if [[ -n "$selected_zone_id" ]]; then
          green "匹配成功 (Zone ID: $selected_zone_id)"
          if cf_upsert_dns "$selected_zone_id" "$domain" "$server_ip"; then
          green "✓ DNS 解析已更新并开启 CDN 代理"
       else
        yellow "⚠ DNS 解析更新失败，请检查 API 权限。"
    fi
    cf_set_ssl "$selected_zone_id" "flexible"
    existing=$(cf_get_origin_rules "$selected_zone_id")
            kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$pfx" '[
                .[] | select(
                    (.description | startswith($pfx) | not) or
                    (.expression | ascii_downcase | contains("http.host eq \"" + ($d|ascii_downcase) + "\"") | not)
                )
            ]')
            pfx="${MANAGED_PREFIX:-Auto_Script:}"
new_managed=$(jq -n \
    --arg d "$domain" \
    --arg pfx "$pfx" \
    --argjson p1 "$vmess_ws_cdn_port" \
    --arg path1 "$vmess_path" \
    --argjson p2 "$vless_ws_cdn_port" \
    --arg path2 "$vless_path" \
    --argjson p3 "$trojan_ws_cdn_port" \
    --arg path3 "$trojan_path" \
'[
    {
        description: ($pfx + "VMESS_" + $d),
        enabled: true,
        expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + $path1 + "\")"),
        action: "route",
        action_parameters: {
            origin: {
                port: $p1
            }
        }
    },
    {
        description: ($pfx + "VLESS_" + $d),
        enabled: true,
        expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + $path2 + "\")"),
        action: "route",
        action_parameters: {
            origin: {
                port: $p2
            }
        }
    },
    {
        description: ($pfx + "TROJAN_" + $d),
        enabled: true,
        expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + $path3 + "\")"),
        action: "route",
        action_parameters: {
            origin: {
                port: $p3
            }
        }
    }
]')
            merged=$(jq -n --argjson a "$kept" --argjson b "$new_managed" '$a + $b')

            if cf_put_origin_rules "$selected_zone_id" "$merged"; then
            green "✓ 回源规则创建成功！"
            else
            yellow "⚠ 回源规则自动下发失败，请检查 API 权限。"
            fi
            else
            yellow "⚠ 未获取到 Cloudflare Zone ID。"
            fi
		fi
    mkdir -p /etc/sing-box/conf
    # 1. 写入 VMess 配置文件
    cat > /etc/sing-box/conf/vmess-ws-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-cdn",
      "listen": "::",
      "listen_port": $vmess_ws_cdn_port,
      "users": [
        {
          "uuid": "$uuid",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$vmess_path",
		"max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF

    # 2. 写入 VLESS 配置文件
    cat > /etc/sing-box/conf/vless-ws-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws-cdn",
      "listen": "::",
      "listen_port": $vless_ws_cdn_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$vless_path",
		"max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF

    # 3. 写入 Trojan 配置文件 
    cat > /etc/sing-box/conf/trojan-ws-cdn.json << EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-ws-cdn",
      "listen": "::",
      "listen_port": $trojan_ws_cdn_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$trojan_path",
		"max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF
                          
	vmess_remark="${isp}_vmess_ws_cdn"
    vless_remark="${isp}_vless_ws_cdn"
    trojan_remark="${isp}_trojan_ws_cdn"
    VMESS="{ \"v\": \"2\", \"ps\": \"${vmess_remark}\", \"add\": \"${CFIP}\", \"port\": \"443\", \"id\": \"${uuid}\", \"aid\": \"0\", \"encryption\": \"auto\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"${domain}\", \"path\": \"${vmess_path}?ed=2048\", \"tls\": \"tls\", \"sni\": \"${domain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": false }"
    vmess_url="vmess://$(echo -n "$VMESS" | base64 -w0)"
    vless_remark_enc=$(echo -n "$vless_remark" | jq -sRr @uri)
    vless_url="vless://${uuid}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${vless_path}?ed=2048#${vless_remark_enc}"
    trojan_remark_enc=$(echo -n "$trojan_remark" | jq -sRr @uri)
    trojan_url="trojan://${uuid}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&security=tls&sni=${domain}&type=ws&host=${domain}&path=${trojan_path}?ed=2048#${trojan_remark_enc}"
	if [ -f "/etc/sing-box/url.txt" ]; then
        sed -i "/${vmess_remark}/d" /etc/sing-box/url.txt
        sed -i "/${vless_remark}/d" /etc/sing-box/url.txt
        sed -i "/${trojan_remark}/d" /etc/sing-box/url.txt
    fi                              
    
    echo "$vmess_url" >> /etc/sing-box/url.txt
	echo "" >> /etc/sing-box/url.txt
    echo "$vless_url" >> /etc/sing-box/url.txt
	echo "" >> /etc/sing-box/url.txt
    echo "$trojan_url" >> /etc/sing-box/url.txt
	echo "" >> /etc/sing-box/url.txt
    
    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
    restart_singbox
    
    green "--------------------------------------------------"
    green " CDN 节点生成成功 (VMess / VLESS / Trojan)"
    green "--------------------------------------------------"
    green " VMess 节点 : "
    echo "$vmess_url"
    echo ""
    green " VLESS 节点 : "
    echo "$vless_url"
    echo ""
    green " Trojan 节点: "
    echo "$trojan_url"
    green "--------------------------------------------------"
    ;;
	12)
    skyblue "正在创建 Cloudflare Tunnel  节点..."
    generate_vars
    vmess_ws_argo_port=$(get_available_port)
    vless_ws_argo_port=$(get_available_port)
    trojan_ws_argo_port=$(get_available_port)
    vmess_path="/vmess-ws"
    vless_path="/vless-ws"
    trojan_path="/trojan-ws"
    ws_argo_config="${conf_dir}/tunnel-ws-argo.json"
    cf_add_tunnel_route \
        "$vmess_ws_argo_port" "$vmess_path" \
        "$vless_ws_argo_port" "$vless_path" \
        "$trojan_ws_argo_port" "$trojan_path" || return 1
    domain="$ArgoDomain"
    [[ -z "$domain" ]] && {
        red "未获取到 Tunnel 域名！"
        return 1
    }
    cat > "$ws_argo_config" <<EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $vmess_ws_argo_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$vmess_path",
		"max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $vless_ws_argo_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$vless_path",
		"max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $trojan_ws_argo_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$trojan_path",
		"max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF

	vmess_remark="${isp}_Tunnelvmess_ws_argo"
    vless_remark="${isp}_Tunnelvless_ws_argo"
    trojan_remark="${isp}_Tunneltrojan_ws_argo"
    VMESS="{ \"v\": \"2\", \"ps\": \"${vmess_remark}\", \"add\": \"${CFIP}\", \"port\": \"443\", \"id\": \"${uuid}\", \"aid\": \"0\", \"encryption\": \"auto\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"${domain}\", \"path\": \"${vmess_path}?ed=2048\", \"tls\": \"tls\", \"sni\": \"${domain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": false }"
    vmess_url="vmess://$(echo -n "$VMESS" | base64 -w0)"
    vless_remark_enc=$(echo -n "$vless_remark" | jq -sRr @uri)
    vless_url="vless://${uuid}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${vless_path}?ed=2048#${vless_remark_enc}"
    trojan_remark_enc=$(echo -n "$trojan_remark" | jq -sRr @uri)
    trojan_url="trojan://${uuid}@${CFIP}:443?ed=2048&eh=Sec-WebSocket-Protocol&security=tls&sni=${domain}&type=ws&host=${domain}&path=${trojan_path}?ed=2048#${trojan_remark_enc}"
	if [ -f "/etc/sing-box/url.txt" ]; then
        sed -i "/${vmess_remark}/d" /etc/sing-box/url.txt
        sed -i "/${vless_remark}/d" /etc/sing-box/url.txt
        sed -i "/${trojan_remark}/d" /etc/sing-box/url.txt
    fi                              
    echo "$vmess_url" >> /etc/sing-box/url.txt
	echo "" >> /etc/sing-box/url.txt
    echo "$vless_url" >> /etc/sing-box/url.txt
	echo "" >> /etc/sing-box/url.txt
    echo "$trojan_url" >> /etc/sing-box/url.txt
	echo "" >> /etc/sing-box/url.txt  
    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
    restart_singbox
	green "--------------------------------------------------"
    green "$vmess_url"
    green "$vless_url"
    green "$trojan_url"
	green "--------------------------------------------------"
    ;;
	14)
	check_xray
    xray_status=$?
    if [ $xray_status -eq 2 ]; then
    red "Xray 未安装！"
    read -rp "按回车安装 Xray，其他键取消: " choice
    if [ -z "$choice" ]; then
        install_xray
        check_xray
        xray_status=$?
        if [ $xray_status -eq 2 ]; then
            red "Xray 安装失败！"
            return 1
        fi
    else
        return 1
    fi
    fi
    generate_vars
    server_ip=$(get_realip)
    echo ""
    vless_xhttp_cdn_port=$(get_available_port)
    allow_port $vless_xhttp_cdn_port/tcp > /dev/null 2>&1
    node_remark="${isp}_vless_xhttp_cdn_notls"
    echo ""
    skyblue "请选择 Cloudflare 验证方式："
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
    green "当前 CDN 域名: $domain"
    if [[ -n "${CF_TOKEN:-}" || ( -n "${CF_EMAIL:-}" && -n "${CF_KEY:-}" ) ]]; then
        if [[ -n "$selected_zone_id" ]]; then
            green "匹配成功 (Zone ID: $selected_zone_id)"
            if cf_upsert_dns "$selected_zone_id" "$domain" "$server_ip"; then
                green "✓ DNS 解析已更新并开启 CDN 代理"
            else
                yellow "⚠ DNS 解析更新失败，请检查 API 权限。"
            fi
            cf_set_ssl "$selected_zone_id" "flexible"
            existing=$(cf_get_origin_rules "$selected_zone_id")
            pfx="${MANAGED_PREFIX:-Auto_Script:}"
            kept=$(echo "$existing" | jq --arg pfx "$pfx" '
            [
                .[] | select(
                    (.description | startswith($pfx) | not)
                )
            ]')
            new_managed=$(jq -n \
    --arg d "$domain" \
    --arg pfx "$pfx" \
    --argjson port "$vless_xhttp_cdn_port" \
    '[
        {
            description: ($pfx + "VLESS_XHTTP_" + $d),
            enabled: true,
            expression: ("(http.host eq \"" + $d + "\")"),
            action: "route",
            action_parameters: {
                origin: {
                    port: $port
                }
            }
        }
    ]')
            merged=$(jq -n --argjson a "$kept" --argjson b "$new_managed" '$a + $b')
            if cf_put_origin_rules "$selected_zone_id" "$merged"; then
                green "✓ 回源规则创建成功！"
            else
                yellow "⚠ 回源规则自动下发失败，请检查 API 权限。"
            fi
        else
            yellow "⚠ 未获取到 Cloudflare Zone ID。"
        fi
    fi
    mkdir -p /etc/xray/conf
    cat > /etc/xray/conf/xhttp-cdn.json << EOF
{
  "inbounds": [
    {
	  "listen": "::",
      "port": $vless_xhttp_cdn_port,
      "protocol": "vless",
	  "tag": "vless-xhttp-cdn",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "none"
      },
	  "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/vless-xhttp",
          "mode": "auto"
        }
      }
    }
  ]
}
EOF
    vless_url="vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${domain}&type=xhttp&host=${domain}&path=/vless-xhttp&mode=auto#$(echo -n "$node_remark" | jq -sRr @uri)"
    if [ -f "/etc/sing-box/url.txt" ]; then
        sed -i "/${node_remark}/d" /etc/sing-box/url.txt
    fi
    echo "$vless_url" >> /etc/sing-box/url.txt
    echo "" >> /etc/sing-box/url.txt
    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
    restart_xray
    green "--------------------------------------------------"
    green " CDN VLESS XHTTP 节点生成成功"
    green "--------------------------------------------------"
    green " VLESS XHTTP 节点 : "
    echo "$vless_url"
    echo "--------------------------------------------------"
    ;;
	15)
	check_xray
    xray_status=$?
    if [ $xray_status -eq 2 ]; then
    red "Xray 未安装！"
    read -rp "按回车安装 Xray，其他键取消: " choice
    if [ -z "$choice" ]; then
        install_xray
        check_xray
        xray_status=$?
        if [ $xray_status -eq 2 ]; then
            red "Xray 安装失败！"
            return 1
        fi
    else
        return 1
    fi
    fi
    check_and_issue_ssl || return 1
    generate_vars
    server_ip=$(get_realip)
    vless_xhttp_cdn_tls_port=$(get_available_port)
    cat > /etc/xray/conf/xhttp-cdn-tls.json << EOF
{
  "inbounds": [
    {
      "tag": "vless-xhttp-cdn-tls",
      "listen": "::",
      "port": $vless_xhttp_cdn_tls_port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${domain:-$server_ip}",
          "certificates": [
            {
              "certificateFile": "$cert_file",
              "keyFile": "$key_file"
            }
          ]
        },
        "xhttpSettings": {
          "path": "/sspaasksavxssaszass",
          "mode": "auto"
        }
      }
    }
  ]
}
EOF

    allow_port "$vless_xhttp_cdn_tls_port/tcp" >/dev/null 2>&1
    node_remark_direct="${isp}_xray_vless_xhttp_tls"
    xhttp_direct="vless://${uuid}@${server_ip}:${vless_xhttp_cdn_tls_port}?encryption=none&host=${domain}&security=tls&sni=${domain:-$server_ip}&type=xhttp&mode=auto&path=/sspaasksavxssaszass#${node_remark_direct}"    
	if [ -f "${work_dir}/url.txt" ]; then
    sed -i "/#${node_remark_direct}$/{N;d;}" "${work_dir}/url.txt"
    fi
    echo "$xhttp_direct" >> "${work_dir}/url.txt"
    echo "" >> "${work_dir}/url.txt"
    echo ""
    read -rp "是否需要为此节点配置 Cloudflare CDN 节点？(y/N): " add_cdn
    unset VLESS_CDN_URL
    if [[ "$add_cdn" =~ ^[Yy]$ ]]; then
    if [[ -z "$domain" ]]; then
        yellow "未检测到有效的域名变量，已跳过 CDN 加速配置。"
    else
        if [[ -z "${CF_TOKEN:-}" &&
      ( -z "${CF_EMAIL:-}" || -z "${CF_KEY:-}" ) ]]; then
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
        if [[ -n "${CF_TOKEN:-}" ||
              ( -n "${CF_EMAIL:-}" && -n "${CF_KEY:-}" ) ]]; then
            zone_id=$(cf_find_zone "$domain")
            if [[ -n "$zone_id" ]]; then
                green "Cloudflare Zone 检测成功：$zone_id"
                if cf_upsert_dns "$zone_id" "$domain" "$server_ip"; then
                    green "Cloudflare DNS 配置成功"
                else
                    yellow "警告：Cloudflare DNS 配置失败"
                fi
                if cf_set_ssl "$zone_id" "full"; then
                    green "Cloudflare SSL 模式已设置为 Full"
                else
                    yellow "警告：Cloudflare SSL 模式设置失败"
                fi
                if set_domain_origin_port \
                    "$zone_id" \
                    "$domain" \
                    "$vless_xhttp_cdn_tls_port"; then
                    green "Cloudflare CDN 回源规则配置成功"
                    green "回源端口：$vless_xhttp_cdn_tls_port"
                else
                    yellow "警告：Cloudflare CDN 回源规则配置失败"
                fi
                node_remark_cdn="${isp}_xray_vless_xhttp_cdn_tls"
                XHTTP_CDN_URL="vless://${uuid}@${CFIP}:443?encryption=none&host=${domain}&security=tls&sni=${domain:-$server_ip}&type=xhttp&mode=auto&path=/sspaasksavxssaszass#${node_remark_cdn}"    
				if [ -f "${work_dir}/url.txt" ]; then
                    sed -i "/#${node_remark_cdn}$/{N;d;}" "${work_dir}/url.txt"
                fi
                echo "$XHTTP_CDN_URL" >> "${work_dir}/url.txt"
                echo "" >> "${work_dir}/url.txt"
            else
                yellow "未找到 ${domain} 对应的 Cloudflare Zone。"
                yellow "请确认该域名已经添加到当前 Cloudflare 账户。"
            fi
        else
            yellow "未获得有效的 Cloudflare API 凭据，已跳过 CDN 配置。"
        fi
    fi
fi
    base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt" 2>/dev/null
    restart_xray
    green "--------------------------------------------------"
    green " 节点创建完成！"
    green "--------------------------------------------------"
    green " 1. 直连节点链接："
    echo "$xhttp_direct"
    if [[ -n "${XHTTP_CDN_URL:-}" ]]; then
        echo ""
        green " 2. CDN 节点链接："
        echo "$XHTTP_CDN_URL"
    fi
    green "--------------------------------------------------"
    ;;
	16)
check_xray
    xray_status=$?
    if [ $xray_status -eq 2 ]; then
    red "Xray 未安装！"
    read -rp "按回车安装 Xray，其他键取消: " choice
    if [ -z "$choice" ]; then
        install_xray
        check_xray
        xray_status=$?
        if [ $xray_status -eq 2 ]; then
            red "Xray 安装失败！"
            return 1
        fi
    else
        return 1
    fi
    fi
check_and_issue_ssl || return 1
generate_vars
vless_xhttp_udp_tls_port=$(get_available_port)

cat > /etc/xray/conf/xhttp-udp-tls.json <<EOF
{
  "inbounds": [
 {
  "tag": "xhttp-udp-tsl",
  "listen": "::",
  "port": $vless_xhttp_udp_tls_port,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$uuid",
        "flow": ""
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "xhttpSettings": {
      "mode": "auto",
      "path": "/ssuddxu"
    },
    "tlsSettings": {
      "alpn": [
        "h3"
      ],
      "certificates": [
        {
          "certificateFile": "$cert_file",
          "keyFile": "$key_file"
        }
      ]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
     ],
    "metadataOnly": false
    }
  }
 ]
}
EOF

allow_port "$vless_xhttp_udp_tls_port/udp" >/dev/null 2>&1
node_remark="${isp}_xray_vless_xhttp_h3"
xhttp_h3="vless://${uuid}@${domain}:${vless_xhttp_udp_tls_port}?encryption=none&security=tls&sni=${domain}&type=xhttp&mode=auto&path=/ssuddxu&alpn=h3#${node_remark}"
if [ -f "${work_dir}/url.txt" ]; then
    sed -i "/#${node_remark}$/{N;d;}" "${work_dir}/url.txt"
fi
echo "$xhttp_h3" >> "${work_dir}/url.txt"
echo "" >> "${work_dir}/url.txt"
base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt" 2>/dev/null
restart_xray
green "--------------------------------------------------"
green " VLESS XHTTP-H3 节点创建完成！"
green "--------------------------------------------------"
echo "$xhttp_h3"
green "--------------------------------------------------"
;;
17)
check_xray
    xray_status=$?
    if [ $xray_status -eq 2 ]; then
    red "Xray 未安装！"
    read -rp "按回车安装 Xray，其他键取消: " choice
    if [ -z "$choice" ]; then
        install_xray
        check_xray
        xray_status=$?
        if [ $xray_status -eq 2 ]; then
            red "Xray 安装失败！"
            return 1
        fi
    else
        return 1
    fi
    fi
check_and_issue_ssl || return 1
generate_vars
vless_xhttp_tcpudp_tls_port=$(shuf -e 2053 2083 2087 2096 8443 -n 1)

cat > /etc/xray/conf/xhttp-tcpudp-tls.json <<EOF
{
  "inbounds": [
{
  "tag": "xhttp-tcpudp-cdn-tls",
  "listen": "::",
  "port": $vless_xhttp_tcpudp_tls_port,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$uuid",
        "flow": ""
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "xhttpSettings": {
    "mode": "auto",
    "path": "/xjakakkakccdd"
    },
    "tlsSettings": {
     "alpn": [
      "h2","http/1.1"
       ],
      "certificates": [
        {
          "certificateFile": "$cert_file",
          "keyFile": "$key_file"
        }
      ]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
   "metadataOnly": false
  }
 }
 ]
}
EOF

allow_port "$vless_xhttp_tcpudp_tls_port/tcp" >/dev/null 2>&1
allow_port "$vless_xhttp_tcpudp_tls_port/udp" >/dev/null 2>&1
node_remark="${isp}_xray_vless_xhttp_tcpudpcdn"
xhttp_tcp="vless://${uuid}@${CFIP}:${vless_xhttp_tcpudp_tls_port}?encryption=none&security=tls&sni=${domain}&type=xhttp&host=${domain}&mode=auto&path=/xjakakkakccdd&#${node_remark}"
xhttp_udp="vless://${uuid}@${CFIP}:${vless_xhttp_tcpudp_tls_port}?encryption=none&security=tls&sni=${domain}&type=xhttp&host=${domain}&mode=auto&path=/xjakakkakccdd&alpn=h3#${node_remark}"
zone_id=$(cf_find_zone "$domain")
if [[ -n "$zone_id" ]]; then
    green "Cloudflare Zone 检测成功：$zone_id"
    if cf_upsert_dns "$zone_id" "$domain" "$server_ip"; then
        green "Cloudflare DNS 配置成功"
    else
        yellow "警告：Cloudflare DNS 配置失败"
    fi
    if cf_set_ssl "$zone_id" "full"; then
        green "Cloudflare SSL 模式已设置为 Full"
    else
        yellow "警告：Cloudflare SSL 模式设置失败"
    fi
else
    yellow "未找到 ${domain} 对应的 Cloudflare Zone。"
fi
if [ -f "${work_dir}/url.txt" ]; then
    sed -i "/#${node_remark}$/{N;d;}" "${work_dir}/url.txt"
fi
echo "$xhttp_tcp" >> "${work_dir}/url.txt"
echo "" >> "${work_dir}/url.txt"
echo "$xhttp_udp" >> "${work_dir}/url.txt"
echo "" >> "${work_dir}/url.txt"
base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt" 2>/dev/null
restart_xray
green "--------------------------------------------------"
green " 节点创建完成！"
echo "$xhttp_udp"
green "--------------------------------------------------"
echo "$xhttp_tcp"
green "--------------------------------------------------"
;;
19)
    check_and_issue_ssl || return 1
    generate_vars
    server_ip=$(get_realip)
    echo ""
    naive_port=$(get_available_port)
    if [[ ! "$naive_port" =~ ^[0-9]+$ ]]; then
        red "获取 Naive 端口失败：${naive_port:-<空>}"
        return 1
    fi
    cat > /etc/sing-box/conf/naive-tls.json << EOF
{
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive",
      "listen": "::",
      "listen_port": $naive_port,
      "users": [
        {
          "username": "$uuid",
          "password": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$cert_file",
        "key_path": "$key_file"
      }
    }
  ]
}
EOF

    allow_port "$naive_port/tcp" >/dev/null 2>&1
    allow_port "$naive_port/udp" >/dev/null 2>&1
    node_remark_h2="${isp}_naive_h2"
    node_remark_h3="${isp}_naive_h3"
    naive_server="${domain:-$server_ip}"
    NAIVE_H2_URL="naive+https://${uuid}:${uuid}@${naive_server}:${naive_port}?security=tls&sni=${naive_server}&insecure=0#${node_remark_h2}"
    NAIVE_H3_URL="naive+quic://${uuid}:${uuid}@${naive_server}:${naive_port}?congestion_control=bbr&security=tls&sni=${naive_server}&insecure=0#${node_remark_h3}"
    if [ -f "${work_dir}/url.txt" ]; then
        sed -i "/#${node_remark}$/{N;d;}" "${work_dir}/url.txt"
    fi
    echo "$NAIVE_H2_URL" >> "${work_dir}/url.txt"
	echo "" >> "${work_dir}/url.txt"
    echo "$NAIVE_H3_URL" >> "${work_dir}/url.txt"
    echo "" >> "${work_dir}/url.txt"
    base64 -w0 "${work_dir}/url.txt" > "${work_dir}/sub.txt" 2>/dev/null
    restart_singbox
    green "--------------------------------------------------"
    green " Naive 节点创建完成！"
    green "--------------------------------------------------"
    echo ""
    green "节点链接："
	echo  "$NAIVE_H2_URL"
	echo  "$NAIVE_H3_URL"
    green "--------------------------------------------------"
    ;;
            # --- 完整的删除逻辑 ---
51)
    delete_node "_vless_tcp_reality" "/etc/sing-box/conf/xtls-reality.json" "singbox"
    ;;
52) 
            target="_hysteria2"
            target_conf="/etc/sing-box/conf/hysteria2.json"
            if [ -f "$target_conf" ]; then
				hy2_port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
				
                # 安全清理 Hysteria2 的 NAT 端口跳跃规则
                if nft list chain ip nat prerouting &>/dev/null; then
                    for handle in $(nft -a list chain ip nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                        nft delete rule ip nat prerouting handle $handle 2>/dev/null
                    done
                fi
                if [ -f /proc/net/if_inet6 ] && nft list chain ip6 nat prerouting &>/dev/null; then
                    for handle in $(nft -a list chain ip6 nat prerouting 2>/dev/null | awk '/Hysteria2_Hop/ {print $NF}'); do
                        nft delete rule ip6 nat prerouting handle $handle 2>/dev/null
                    done
                fi

                # 清理入站放行规则
                if [ -n "$hy2_port" ] && [ "$hy2_port" != "443" ]; then
                 for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$hy2_port" '$0~"dport "p {print $NF}'); do
                 nft delete rule inet filter input handle $handle 2>/dev/null
                done
                nft list ruleset > /etc/nftables.conf 2>/dev/null
                fi

                rm -f "$target_conf"
                if [ -f "/etc/sing-box/url.txt" ]; then
                    sed -i "/${target}/d" /etc/sing-box/url.txt
                    sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
					echo "" >> /etc/sing-box/url.txt
                fi
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                restart_singbox                
                green "==============================================="
                green " 节点已移除!"
                green "==============================================="
            else
                red "错误: 未找到配置文件 ($target_conf)，删除取消。"
            fi
            ;;

53)
    delete_node "_tuic" "/etc/sing-box/conf/tuic.json" "singbox"
    ;;
54)
    delete_node "_vless_http_reality" "/etc/sing-box/conf/h2-reality.json" "singbox"
    ;;
55)
    delete_node "_vless_grpc_reality" "/etc/sing-box/conf/grpc-reality.json" "singbox"
    ;;
56)
    delete_node "_anytls_nt123" "/etc/sing-box/conf/anytls.json" "singbox"
    ;;
57)
    delete_node "_anytls_reality" "/etc/sing-box/conf/anytls-reality.json" "singbox"
    ;;
58)
    delete_node "_socks5" "/etc/sing-box/conf/socks5.json" "singbox"
    ;;
59)
    delete_node "_http" "/etc/sing-box/conf/http.json" "singbox"
    ;;
63)
    delete_node "_xray_vless_xhttp_reality" "/etc/xray/conf/xhttp-reality.json" "xray"
    ;;
64)
    delete_node "_vless_xhttp_cdn_notls" "/etc/xray/conf/xhttp-cnd.json" "xray"
    ;;
66)
    delete_node "_xray_vless_xhttp_h3" "/etc/xray/conf/xhttp-udp-tls.json" "xray"
    ;;
68)
    delete_node "_vless_tcp_tls" "/etc/sing-box/conf/vless-tcp-tls.json" "singbox"
    ;;
71)
    delete_node "_vless_ws_notls" "/etc/sing-box/conf/vless-ws.json" "singbox"
    ;;

		 60) 
            target_cdn_conf="/etc/sing-box/conf/vless-wstls-cdn.json"
            target_direct_conf="/etc/sing-box/conf/vless-wstls-direct.json"
            if [ -f "$target_cdn_conf" ] || [ -f "$target_direct_conf" ]; then
			cdn_domain=""
            if [ -f "/etc/sing-box/url.txt" ]; then
            while IFS= read -r line; do
            if [[ "$line" == vless://*"_vless_wstls_cdn"* ]]; then
            cdn_domain=$(echo "$line" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
            break
            fi
            done < /etc/sing-box/url.txt
            fi
                if [ -f "$target_cdn_conf" ]; then
                    vless_wstls_cdn_port=$(grep '"listen_port"' "$target_cdn_conf" | tr -cd '0-9')
                    if [ -n "$vless_wstls_cdn_port" ]; then
                        for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$vless_wstls_cdn_port" '$0~"dport "p {print $NF}'); do
                            nft delete rule inet filter input handle $handle 2>/dev/null
                        done
                    fi
                    rm -f "$target_cdn_conf"
                fi
                if [ -f "$target_direct_conf" ]; then
                    vless_wstls_direct_port=$(grep '"listen_port"' "$target_direct_conf" | tr -cd '0-9')
                    if [ -n "$vless_wstls_direct_port" ]; then
                        for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$vless_wstls_direct_port" '$0~"dport "p {print $NF}'); do
                            nft delete rule inet filter input handle $handle 2>/dev/null
                        done
                    fi
                    rm -f "$target_direct_conf"
                fi
                nft list ruleset > /etc/nftables.conf 2>/dev/null
                if [ -f "/etc/sing-box/url.txt" ]; then
                     sed -i "/_vless_wstls_cdn/d" /etc/sing-box/url.txt
                     sed -i "/_vless_wstls_direct/d" /etc/sing-box/url.txt
                     
                     sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
                     echo "" >> /etc/sing-box/url.txt
                fi
                
                if [ -s "/etc/sing-box/url.txt" ]; then
                    base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
                else
                    truncate -s 0 /etc/sing-box/sub.txt
                fi
                
                restart_singbox               
                green "============================================"
                green " 节点已移除!"
                green "============================================"
				if [[ -n "$cdn_domain" ]]; then
                cf_remove_cdn_rules "$cdn_domain"
                fi
            else
                red "错误: 未找到 VLESS WS-TLS 相关的配置文件，删除取消。"
            fi
            ;;
		    
	61)
    targets=("_vmess_ws_cdn" "_vless_ws_cdn" "_trojan_ws_cdn")
    configs=("/etc/sing-box/conf/vmess-ws-cdn.json" "/etc/sing-box/conf/vless-ws-cdn.json" "/etc/sing-box/conf/trojan-ws-cdn.json")
    exist_flag=0
    for conf in "${configs[@]}"; do
        [ -f "$conf" ] && exist_flag=1 && break
    done
    if [ "$exist_flag" -eq 1 ]; then
        cdn_domain=""
        if [ -f "/etc/sing-box/url.txt" ]; then
            while IFS= read -r line; do
                if [[ "$line" == trojan://*"_trojan_ws_cdn"* ]]; then
                    cdn_domain=$(echo "$line" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
                    break
                fi
            done < /etc/sing-box/url.txt
        fi
        for conf in "${configs[@]}"; do
            if [ -f "$conf" ]; then
                port=$(grep '"listen_port"' "$conf" | tr -cd '0-9')
                if [ -n "$port" ]; then
                    nft delete rule inet filter input handle $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$port" '$0~"dport "p {print $NF}') 2>/dev/null
                fi
                rm -f "$conf"
            fi
        done
        nft list ruleset > /etc/nftables.conf 2>/dev/null
        if [ -f "/etc/sing-box/url.txt" ]; then
            tmp_file=$(mktemp)
            while IFS= read -r line || [ -n "$line" ]; do
                skip=0
                if [[ "$line" == vmess://* ]]; then
                    b64_str="${line#vmess://}"
                    decoded=$(echo "$b64_str" | base64 -d 2>/dev/null)
                    for t in "${targets[@]}"; do
                        if [[ "$decoded" == *"$t"* ]]; then
                            skip=1
                            break
                        fi
                    done
                else
                    for t in "${targets[@]}"; do
                        if [[ "$line" == *"$t"* ]]; then
                            skip=1
                            break
                        fi
                    done
                fi
                [ "$skip" -eq 0 ] && echo "$line" >> "$tmp_file"
            done < "/etc/sing-box/url.txt"
            mv "$tmp_file" /etc/sing-box/url.txt
            sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
        fi
        if [ -s "/etc/sing-box/url.txt" ]; then
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
        else
            truncate -s 0 /etc/sing-box/sub.txt
        fi
        restart_singbox
        green "==============================================="
        green " CDN 节点 (VMess/VLESS/Trojan) 已移除！"
        green "==============================================="
        if [[ -n "$cdn_domain" ]]; then
            cf_remove_cdn_rules "$cdn_domain"
        fi
    else
        red "错误: 未找到相关的 CDN 节点配置文件，删除取消。"
    fi
    ;;
	62)
    targets=("_Tunnelvmess_ws_argo" "_Tunnelvless_ws_argo" "_Tunneltrojan_ws_argo")
    configs=("/etc/sing-box/conf/tunnel-ws-argo.json")
    exist_flag=0
    for conf in "${configs[@]}"; do
        [ -f "$conf" ] && exist_flag=1 && break
    done
    if [ "$exist_flag" -eq 1 ]; then
        cdn_domain=""
        if [ -f "/etc/sing-box/url.txt" ]; then
            while IFS= read -r line; do
                if [[ "$line" == trojan://*"_Tunneltrojan_ws_argo"* ]]; then
                    cdn_domain=$(echo "$line" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
                    break
                fi
            done < /etc/sing-box/url.txt
        fi
        for conf in "${configs[@]}"; do
            if [ -f "$conf" ]; then
                port=$(grep '"listen_port"' "$conf" | tr -cd '0-9')
                if [ -n "$port" ]; then
                    nft delete rule inet filter input handle $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$port" '$0~"dport "p {print $NF}') 2>/dev/null
                fi
                rm -f "$conf"
            fi
        done
        nft list ruleset > /etc/nftables.conf 2>/dev/null
        if [ -f "/etc/sing-box/url.txt" ]; then
            tmp_file=$(mktemp)
            while IFS= read -r line || [ -n "$line" ]; do
                skip=0
                if [[ "$line" == vmess://* ]]; then
                    b64_str="${line#vmess://}"
                    decoded=$(echo "$b64_str" | base64 -d 2>/dev/null)
                    for t in "${targets[@]}"; do
                        if [[ "$decoded" == *"$t"* ]]; then
                            skip=1
                            break
                        fi
                    done
                else
                    for t in "${targets[@]}"; do
                        if [[ "$line" == *"$t"* ]]; then
                            skip=1
                            break
                        fi
                    done
                fi
                [ "$skip" -eq 0 ] && echo "$line" >> "$tmp_file"
            done < "/etc/sing-box/url.txt"
            mv "$tmp_file" /etc/sing-box/url.txt
            sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
        fi
        if [ -s "/etc/sing-box/url.txt" ]; then
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
        else
            truncate -s 0 /etc/sing-box/sub.txt
        fi
        restart_singbox
        green "==============================================="
        green " 节点已移除！"
        green "==============================================="
        if [[ -n "$cdn_domain" ]]; then
    cf_remove_cdn_rules "$cdn_domain"

    if cf_get_zone_id_by_domain "$cdn_domain"; then
        cf_delete_dns "$selected_zone_id" "$cdn_domain"
        green "DNS 解析已删除：$cdn_domain"
    fi

    if [[ -s "/etc/sing-box/conf/cloudflared.json" ]]; then
        tunnel_token=$(jq -r \
            '.inbounds[]? |
             select(.type == "cloudflared") |
             .token // empty' \
            /etc/sing-box/conf/cloudflared.json | head -n1)

        tunnel_id=$(echo "$tunnel_token" |
            base64 -d 2>/dev/null |
            jq -r '.t // empty' 2>/dev/null)

        if [[ -n "$tunnel_id" && -n "${CF_ACCOUNT_ID:-}" ]]; then
            config_data=$(cf_call GET \
                "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
                2>/dev/null)

            if [[ "$(echo "$config_data" | jq -r '.success // false')" == "true" ]]; then
                ingress=$(echo "$config_data" |
                    jq -c '.result.config.ingress // []')

                new_config=$(echo "$ingress" |
                    jq -c --arg h "$cdn_domain" '
                        {
                            config: {
                                ingress: (
                                    map(select(.hostname != $h))
                                )
                            }
                        }')

                response=$(cf_call PUT \
                    "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
                    "$new_config" \
                    2>/dev/null)

                if [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]; then
                    green "Tunnel 路由已删除：$cdn_domain"
                else
                    red "Tunnel 路由删除失败！"
                    echo "$response" |
                        jq -r '.errors[]?.message // empty'
                fi
            fi
        fi
    fi
fi
    else
        red "错误: 未找到相关的 CDN 节点配置文件，删除取消。"
    fi
    ;;
	65)
    target="_xray_vless_xhttp_tls"
    target_conf="/etc/xray/conf/xhttp-cdn-tls.json"
    if [ -f "$target_conf" ]; then
	    cdn_domain=""
            if [ -f "/etc/sing-box/url.txt" ]; then
            while IFS= read -r line; do
            if [[ "$line" == vless://*"_xray_vless_xhttp_cdn_tls"* ]]; then
            cdn_domain=$(echo "$line" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
            break
            fi
    done < /etc/sing-box/url.txt
fi
        vless_xhttp_cdn_tls_port=$(grep '"port"' "$target_conf" | head -1 | tr -cd '0-9')
        if [ -n "$vless_xhttp_cdn_tls_port" ]; then
            for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$vless_xhttp_cdn_tls_port" '$0~"dport "p {print $NF}'); do
                nft delete rule inet filter input handle $handle 2>/dev/null
            done
            nft list ruleset > /etc/nftables.conf 2>/dev/null
        fi
        rm -f "$target_conf"
        if [ -f "/etc/sing-box/url.txt" ]; then
            sed -i "/${target}/d" /etc/sing-box/url.txt
            sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
        fi
        if [ -s "/etc/sing-box/url.txt" ]; then
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
        else
            truncate -s 0 /etc/sing-box/sub.txt
        fi
        restart_xray
        green "==============================================="
        green " 节点已移除!"
        green "==============================================="
		if [[ -n "$cdn_domain" ]]; then
            cf_remove_cdn_rules "$cdn_domain"
        fi
    else
        red "错误: 未找到配置文件 ($target_conf)，删除取消。"
    fi
    ;;
	67)
    target="_xray_vless_xhttp_tcpudpcdn"
    target_conf="/etc/xray/conf/xhttp-tcpudp-tls.json"
    if [ -f "$target_conf" ]; then
	    cdn_domain=""
            if [ -f "/etc/sing-box/url.txt" ]; then
            while IFS= read -r line; do
            if [[ "$line" == vless://*"_xray_vless_xhttp_tcpudpcdn"* ]]; then
            cdn_domain=$(echo "$line" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
            break
            fi
    done < /etc/sing-box/url.txt
fi
        vless_xhttp_tcpudp_tls_port=$(grep '"port"' "$target_conf" | head -1 | tr -cd '0-9')
        if [ -n "$vless_xhttp_tcpudp_tls_port" ]; then
            for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$vless_xhttp_tcpudp_tls_port" '$0~"dport "p {print $NF}'); do
                nft delete rule inet filter input handle $handle 2>/dev/null
            done
            nft list ruleset > /etc/nftables.conf 2>/dev/null
        fi
        rm -f "$target_conf"
        if [ -f "/etc/sing-box/url.txt" ]; then
            sed -i "/${target}/d" /etc/sing-box/url.txt
            sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
        fi
        if [ -s "/etc/sing-box/url.txt" ]; then
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
        else
            truncate -s 0 /etc/sing-box/sub.txt
        fi
        restart_xray
        green "==============================================="
        green " 节点已移除!"
        green "==============================================="
		if [[ -n "$cdn_domain" ]]; then
            cf_remove_cdn_rules "$cdn_domain"
        fi
    else
        red "错误: 未找到配置文件 ($target_conf)，删除取消。"
    fi
    ;;
	70)
    target="_vmess_ws_notls"
    target_conf="/etc/sing-box/conf/vmess-ws.json"
    if [ -f "$target_conf" ]; then
        port=$(grep '"listen_port"' "$target_conf" | tr -cd '0-9')
        if [ -n "$port" ]; then
            for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$port" '$0 ~ "dport "p {print $NF}'); do
                nft delete rule inet filter input handle "$handle" 2>/dev/null
            done
        fi
        rm -f "$target_conf"
        nft list ruleset > /etc/nftables.conf 2>/dev/null
        if [ -f "/etc/sing-box/url.txt" ]; then
            tmp_file=$(mktemp)
            while IFS= read -r line || [ -n "$line" ]; do
                skip=0
                if [[ "$line" == vmess://* ]]; then
                    b64_str="${line#vmess://}"
                    decoded=$(echo "$b64_str" | base64 -d 2>/dev/null)
                    if [[ "$decoded" == *"$target"* ]]; then
                        skip=1
                    fi
                fi
                [ "$skip" -eq 0 ] && echo "$line" >> "$tmp_file"
            done < "/etc/sing-box/url.txt"
            mv "$tmp_file" /etc/sing-box/url.txt
            sed -i '/^$/N;/\n$/D' /etc/sing-box/url.txt
            echo "" >> /etc/sing-box/url.txt
        fi
        if [ -s "/etc/sing-box/url.txt" ]; then
            base64 -w0 /etc/sing-box/url.txt > /etc/sing-box/sub.txt 2>/dev/null
        else
            truncate -s 0 /etc/sing-box/sub.txt
        fi
        restart_singbox
        green "==============================================="
        green " 节点已移除！"
        green "==============================================="
    else
        red "错误: 未找到 VMess WS 节点配置文件，删除取消。"
    fi
    ;;
            0) break ;;
            *) red "无效选项"; sleep 1; continue ;;
        esac       
        echo -e "\n\033[31m按任意键返回菜单...\033[0m"
        read -n 1
    done
}

#更新脚本
update_script() {
    local remote_url="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing-box108.sh"
    local local_file="$work_dir/sb.sh"

    if curl -Lss "$remote_url" -o "${local_file}.tmp"; then
        if [ -s "${local_file}.tmp" ]; then
            mv -f "${local_file}.tmp" "$local_file"
            chmod +x "$local_file"
            ln -sf "$local_file" /usr/bin/sb
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

fail2ban_manage() {
    while true; do
        clear
        echo "========== Fail2ban 管理 =========="
        if ! command -v fail2ban-client >/dev/null 2>&1; then
            red "Fail2ban 未安装"
            read -p "是否安装 Fail2ban? [Y/n]: " yn
            yn=${yn:-Y}
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                if command -v apt >/dev/null 2>&1; then
                    apt update && apt install -y fail2ban
                elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
                    # CentOS/RHEL 需要 EPEL 源
                    yum install -y epel-release 2>/dev/null
                    yum install -y fail2ban 2>/dev/null || dnf install -y fail2ban
                elif command -v apk >/dev/null 2>&1; then
                    apk add fail2ban
                else
                    red "不支持的系统"
                    return
                fi
                systemctl enable fail2ban 2>/dev/null || rc-update add fail2ban default 2>/dev/null
                green "Fail2ban 安装完成"
            else
                return
            fi
        fi
        echo ""
        if systemctl is-active fail2ban >/dev/null 2>&1; then
            green "Fail2ban 状态: 运行中"
        else
            red "Fail2ban 状态: 未运行"
        fi
        echo ""
        echo "1. 查看状态"
        echo "2. 查看封禁IP"
        echo "3. 启动/配置Fail2ban"
        echo "4. 停止Fail2ban"
        echo "0. 返回"
        reading "请选择: " fb_choice
        case "$fb_choice" in
        1)
            echo "----------------------------------------"
            jail_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $4}')
            jail_list=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2)
            echo "|- 监控项数量：${jail_count:-0}"
            echo "\`- 监控列表：${jail_list:-无}"
            echo "----------------------------------------"
            read -p "按回车继续..."
            ;;
        2)
            read -p "请输入要查看的监控项名称（默认 sshd）： " jail_name
            jail_name=${jail_name:-sshd}
            echo "----------------------------------------"
            fail2ban-client status "$jail_name" 2>/dev/null | sed \
                -e "s/Status for the jail/监控项状态/g" \
                -e "s/|- Filter/|- 过滤器/g" \
                -e "s/|- Actions/|- 动作/g" \
                -e "s/\`- Banned IP list/\`- 已封禁 IP 列表/g"
            echo "----------------------------------------"
            read -p "按回车继续..."
            ;;
           3)
            ssh_port=$(grep -E "^Port[[:space:]]+" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | tail -n1)
            [ -z "$ssh_port" ] && ssh_port=22
            if command -v apt >/dev/null 2>&1; then
                apt install -y python3-systemd >/dev/null 2>&1
            elif command -v yum >/dev/null 2>&1; then
                yum install -y python3-systemd >/dev/null 2>&1
            fi
            cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
findtime = 10m
maxretry = 3
bantime = 7d

[sshd]
enabled = true
port = $ssh_port
filter = sshd
backend = systemd
EOF

            systemctl enable fail2ban 2>/dev/null
            systemctl restart fail2ban 2>/dev/null
            sleep 2
            if systemctl is-active fail2ban >/dev/null 2>&1; then
                green "Fail2ban 已启动"
                green "SSH防护端口: $ssh_port"
                green "规则: 10分钟失败3次，封禁7天"
            else
                red "Fail2ban 启动失败"
                journalctl -u fail2ban -n 20 --no-pager
            fi
            read -p "按回车继续..."
            ;;
        4)
            systemctl stop fail2ban 2>/dev/null
            red "Fail2ban 已停止"
            read -p "按回车继续..."
            ;;
        0)
            break
            ;;
        *)
            red "输入错误"
            sleep 1
            ;;
        esac
    done
}

# Iptables简单管理
ipt_msg() { echo -e "${1}${2}\033[0m"; }

save_nft_rules() {
    echo "flush ruleset" > /etc/nftables.conf
    nft list ruleset 2>/dev/null | awk '/table inet port_manager/{p=1;next} /^table /{p=0} !p' >> /etc/nftables.conf
}
check_rule_files() {
    local conf="/etc/nftables.conf"
    if ! command -v nft &> /dev/null; then return; fi
    
    if ! nft list table inet filter &>/dev/null; then
        cat > "$conf" << EOF
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        iif "lo" accept
        ct state established,related accept
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
        nft -f "$conf" 2>/dev/null
    fi
}
iptables_ssl() {
    check_and_install_nftables
    clear
    check_rule_files
    local tag="ScriptManaged"
    
    local status_text=""
    local mode_text=""
    local svc_status=$(systemctl is-active nftables 2>/dev/null)
    local pm_status=$(systemctl is-active port_manager 2>/dev/null)
    
    local policy=$(nft list chain inet filter input 2>/dev/null | awk '/policy/ {print $NF}' | tr -d ';')
    local rule_count=$(nft list ruleset 2>/dev/null | grep -vE "^table|^chain|^}" | wc -l)

    if ! command -v nft &> /dev/null; then
        status_text="\033[0;31m未安装\033[0m"
        mode_text="\033[0;37m未知\033[0m"
    elif [ "$rule_count" -gt 0 ] || [ "$svc_status" == "active" ]; then
        status_text="\033[0;32m运行中\033[0m"
        if [ "$policy" == "drop" ]; then
            mode_text="\033[0;32m开启\033[0m"
        else
            mode_text="\033[0;31m关闭\033[0m"
        fi
    else
        status_text="\033[0;31m已停止\033[0m"
        mode_text="\033[0;37m未拦截\033[0m"
    fi
	
    local ssh_p=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [ -z "$ssh_p" ] && ssh_p=22

    local nat_rules=$(nft list ruleset 2>/dev/null | awk '/dnat to/ {
        port=""; to="";
        for(i=1;i<=NF;i++){
            if($i=="dport") port=$(i+1);
            if($i=="to") to=$(i+1);
        }
        if(port != "") { print " 端口:" port " -> 转发至:" to }
    }')
    [ -z "$nat_rules" ] && nat_rules="  暂无转发规则"
	
    echo ""
    green "=== 防火墙与流量管理面板 ==="
    echo -e "防火墙状态: $status_text"
    echo -e "拦截模式: $mode_text"
    
    # 联动显示选项 8 流量管控服务状态
    if [ "$pm_status" == "active" ]; then
        local pm_cnt=$(ls -1 /etc/port_manager/*.conf 2>/dev/null | wc -l)
        echo -e "流量管控: \033[0;32m运行中\033[0m (已设置 $pm_cnt 个端口)"
    else
        echo -e "流量管控: \033[0;37m未启用\033[0m"
    fi
    
    ipt_msg "\033[0;36m" "系统当前 SSH 端口: ${ssh_p}"
    echo -e "\033[0;33m$nat_rules\033[0m"
    skyblue "---------------------------"

    ipt_msg "\033[0;33m" "已在防火墙放行的端口:"
    printf "%-13s %-19s %-15s\n" "端口号" "所属服务" "说明"   

    local allowed_ports=""
    if command -v nft &> /dev/null; then
        allowed_ports=$(nft list chain inet filter input 2>/dev/null | awk '/dport.*accept/ {
            for(i=1;i<=NF;i++) if($i=="dport") { print $(i+1); break; }
        }' | tr -d '{};' | tr ',' '\n' | grep -E "^[0-9]+$" | sort -un)
        
        for port in $allowed_ports; do
            local is_script=$(nft list chain inet filter input 2>/dev/null | grep -E "dport.*$port.*$tag")
            local note="系统/手动"
            [ -n "$is_script" ] && note="脚本放行"
            
            if [ -f "/etc/port_manager/${port}.conf" ]; then
                note="${note}[限速中]"
            fi
            
            local name="未运行"
            local ss_line=$(ss -tunlp | grep ":$port " | head -n1)
            if [[ "$ss_line" =~ \"([^\"]+)\" ]]; then
                name="${BASH_REMATCH[1]}"
            fi
            printf "\033[0;32m%-10s %-15s %-10s\033[0m\n" "$port" "$name" "$note"
        done
    fi
    
    echo -e "\033[0;36m---------------------------\033[0m"
    ipt_msg "\033[0;35m" "检测到正在运行但【未放行】的端口"
    printf "%-13s %-19s %-15s\n" "端口号"    "所属服务"    "监听IP/状态"    
    ss -tunlp | awk 'NR>1 {
        addr = $5; n = split(addr, a, ":"); port = a[n];
        ip = ""; for(i=1; i<n; i++) ip = (ip == "" ? a[i] : ip ":" a[i]);
        if (ip ~ /:/ || ip ~ /\[/) next;
        if (ip == "" || ip == "*") ip = "0.0.0.0";
        name = "未知服务"; if ($NF ~ /"/) { split($NF, s, "\""); name = s[2] }
        if (port ~ /^[0-9]+$/ && port > 0) print port, name, ip}' | sort -un | sort -n -k1,1 | while read -r p_port p_name p_ip; do
        if ! echo "$allowed_ports" | grep -qw "$p_port"; then
            local warn_extra=""
            if [ -f "/etc/port_manager/${p_port}.conf" ]; then
                warn_extra=" (已限速但未放行!)"
            fi
            printf "\033[0;31m%-10s %-15s %-10s\033[0m\n" "$p_port" "$p_name" "${p_ip}${warn_extra}"
        fi
    done
    skyblue "---------------------------"
    green "1. 开启端口"
    green "2. 关闭端口"
    green "3. 开启拦截"
    green "4. 关闭拦截"
    green "5. 安装更新"
    green "6. 停止运行"
    green "7. 程序重启"
    red   "8. 端口流量网速设置"
    green "9. 清理未运行端口"
	green "10. 修改SSH连接端口"	
	green "11. fail2ban"	
    purple "0. 回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " ipt_choice
    case "${ipt_choice}" in
         1)
            read -p "请输入要开放的端口号: " o_port
            if [ -z "$o_port" ]; then
                yellow "未输入端口号，操作已取消。"
            elif [ "$o_port" -eq 0 ] 2>/dev/null; then
                red "错误：端口号不能为 0"
            else
                if nft list chain inet filter input 2>/dev/null | grep -qw "$o_port"; then
                    yellow "端口 $o_port 规则已存在，无需重复添加"
                else
                    read -p "请输入允许连接的IP(回车允许所有IP): " allow_ip
if [ -n "$allow_ip" ]; then
    nft add rule inet filter input ip saddr "$allow_ip" tcp dport $o_port accept comment "$tag" 2>/dev/null
    nft add rule inet filter input ip saddr "$allow_ip" udp dport $o_port accept comment "$tag" 2>/dev/null
    green "成功：端口 $o_port 已放行，仅允许 $allow_ip 连接"
else
    nft add rule inet filter input tcp dport $o_port accept comment "$tag" 2>/dev/null
    nft add rule inet filter input udp dport $o_port accept comment "$tag" 2>/dev/null
    green "成功：端口 $o_port 已放行，允许所有IP连接"
fi
save_nft_rules
                fi
            fi
            sleep 1 && iptables_ssl ;;
            
        2)
            read -p "请输入要关闭端口号: " c_port
            if [ -z "$c_port" ]; then
                yellow "未输入端口号，操作取消"
            elif [ "$c_port" -eq 0 ] 2>/dev/null; then
                red "错误：端口号不能为 0"
            else
                for handle in $(nft -a list chain inet filter input 2>/dev/null | awk -v p="$c_port" '$0~"dport "p {print $NF}'); do
                    nft delete rule inet filter input handle $handle 2>/dev/null
                done
                save_nft_rules
                green "清理完成：端口 $c_port 已关闭"
            fi
            sleep 1 && iptables_ssl ;;

        3)
            yellow "正在开启拦截..."
            ssh_ports=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
            [ -z "$ssh_ports" ] && ssh_ports=22
            
            # 基础放行规则
            nft add rule inet filter input iif "lo" accept 2>/dev/null
            nft add rule inet filter input ct state established,related accept 2>/dev/null
            nft add rule inet filter input ip6 nexthdr icmpv6 icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept 2>/dev/null
            
            # 放行 SSH 端口
            for port in $ssh_ports; do
                nft add rule inet filter input tcp dport $port accept comment "SSH_Port" 2>/dev/null
            done
            
            for conf in /etc/port_manager/*.conf; do
                [ -e "$conf" ] || continue
                local pm_p=$(basename "$conf" .conf)
                if [ -n "$pm_p" ] && [ "$pm_p" -gt 0 ] 2>/dev/null; then
                    nft add rule inet filter input tcp dport $pm_p accept comment "PortManager" 2>/dev/null
                    nft add rule inet filter input udp dport $pm_p accept comment "PortManager" 2>/dev/null
                fi
            done
            
            nft 'add chain inet filter input { type filter hook input priority 0; policy drop; }' 2>/dev/null
            save_nft_rules
            
            green "开启拦截成功 (已自动放行 SSH 及限速管控端口)" && sleep 1
            iptables_ssl ;;
            
         4)
            yellow "正在关闭拦截..."
            nft 'add chain inet filter input { type filter hook input priority 0; policy accept; }' 2>/dev/null
            save_nft_rules
            green "已关闭拦截 (默认放行所有)" && sleep 1
            iptables_ssl ;;
            
        5)
            yellow "正在配置环境..."
            [[ $EUID -ne 0 ]] && red "请使用 root 用户运行此脚本！" && exit 1      
            if [ -f /etc/debian_version ]; then
                apt-get update -y
                apt-get install -y nftables
            elif [ -f /etc/redhat-release ]; then
                yum install -y nftables
            fi
            systemctl enable nftables 2>/dev/null
            systemctl start nftables 2>/dev/null
            check_rule_files
            save_nft_rules
            green "环境配置完成。" 
            sleep 1 && iptables_ssl ;;
            
        6)
            yellow "正在停止防火墙并清空规则..."
            systemctl stop nftables 2>/dev/null
            systemctl stop port_manager 2>/dev/null
            nft flush ruleset
            green "防火墙及流量限制服务已停止，规则已清空。"
            sleep 1 && iptables_ssl ;;
            
        7)
            yellow "正在重载并激活防火墙与流量限制规则..."
            systemctl enable nftables >/dev/null 2>&1
            systemctl start nftables >/dev/null 2>&1
            if [ -f "/etc/nftables.conf" ]; then
                nft -f /etc/nftables.conf && green " (/etc/nftables.conf) 防火墙规则已重载。"
            fi
            if [ -f "/usr/local/bin/port_menu.sh" ]; then
                systemctl restart port_manager >/dev/null 2>&1 && green " (port_manager) 流量限制服务已同步重启。"
            fi
            green "重载操作执行完毕。"
            sleep 1 && iptables_ssl ;;
            
        8)  
            clear
            yellow "正在初始化"
            if ! command -v tc &> /dev/null; then
                yellow "检测到系统缺少 tc 工具，正在自动安装"
                if [ -f /etc/debian_version ]; then
                    apt-get update -y && apt-get install -y iproute2
                elif [ -f /etc/redhat-release ]; then
                    yum install -y iproute 2>/dev/null || dnf install -y iproute
                fi
            fi

            cat << 'EOF' > /usr/local/bin/port_menu.sh
#!/bin/bash
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONF_DIR="/etc/port_manager"
TARGET_PATH="/usr/local/bin/port_menu.sh"

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m[-] 错误: 请使用 root 权限运行此脚本\033[0m"
    exit 1
fi

mkdir -p "$CONF_DIR"

get_interface() {
    local dev
    dev=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    if [ -z "$dev" ]; then
        dev=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1)
    fi
    echo "$dev"
}
INTERFACE=$(get_interface)

get_bj_time() {
    TZ='Asia/Shanghai' date "+%Y %m %d %H %M"
}

init_nft_table() {
    nft add table inet port_manager 2>/dev/null || true
    nft 'add chain inet port_manager prerouting { type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager postrouting { type filter hook postrouting priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager output { type filter hook output priority 0; policy accept; }' 2>/dev/null || true
    nft 'add chain inet port_manager input { type filter hook input priority 0; policy accept; }' 2>/dev/null || true
}

check_and_block() {
    init_nft_table
    read -r BJ_YEAR BJ_MONTH BJ_DAY BJ_HOUR BJ_MINUTE <<< "$(get_bj_time)"
    local CURRENT_MONTH_STR="${BJ_YEAR}${BJ_MONTH}"
    
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        
        [ -z "$STORED_TOTAL" ] && STORED_TOTAL=0
        [ -z "$LAST_IPT_BYTES" ] && LAST_IPT_BYTES=0
        [ -z "$RATE" ] && RATE="UNLIMITED"
        [ -z "$LAST_RESET_MONTH" ] && LAST_RESET_MONTH=""
        
        if [ "$RESET_MODE" == "MONTHLY" ]; then
            local should_reset=0
            if [ "$CURRENT_MONTH_STR" != "$LAST_RESET_MONTH" ]; then
                if [ "$BJ_DAY" -gt 1 ]; then
                    should_reset=1
                elif [ "$BJ_DAY" -eq 1 ]; then
                    if [ "$BJ_HOUR" -gt 0 ] || { [ "$BJ_HOUR" -eq 0 ] && [ "$BJ_MINUTE" -ge 1 ]; }; then
                        should_reset=1
                    fi
                fi
            fi
            
            if [ "$should_reset" -eq 1 ]; then
                nft flush chain inet port_manager "$CHAIN_NAME" 2>/dev/null
                nft add rule inet port_manager "$CHAIN_NAME" counter accept 2>/dev/null
                STORED_TOTAL=0
                LAST_IPT_BYTES=0
                sed -i "s/LAST_RESET_MONTH=.*/LAST_RESET_MONTH=\"$CURRENT_MONTH_STR\"/" "$conf"
                sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"0\"/" "$conf"
                sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"0\"/" "$conf"
                continue
            fi
        fi
        
        local NFT_BYTES
        NFT_BYTES=$(nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | awk '/bytes/ {for(i=1;i<=NF;i++) if($i=="bytes") {print $(i+1); exit}}')
        [ -z "$NFT_BYTES" ] && NFT_BYTES=0
        
        local DIFF=0
        if [ "$NFT_BYTES" -ge "$LAST_IPT_BYTES" ]; then
            DIFF=$(( NFT_BYTES - LAST_IPT_BYTES ))
        else
            DIFF="$NFT_BYTES"
        fi
        
        STORED_TOTAL=$(( STORED_TOTAL + DIFF ))
        LAST_IPT_BYTES="$NFT_BYTES"
        
        sed -i "s/STORED_TOTAL=.*/STORED_TOTAL=\"$STORED_TOTAL\"/" "$conf"
        sed -i "s/LAST_IPT_BYTES=.*/LAST_IPT_BYTES=\"$LAST_IPT_BYTES\"/" "$conf"

        if [ "$QUOTA" == "UNLIMITED" ]; then
            continue
        fi
        
        local LIMIT_BYTES=$(( QUOTA * 1048576 ))
        if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
            if ! nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
    done
}

rebuild_tc_filters() {
    tc filter del dev "$INTERFACE" parent 1:0 prio 1 2>/dev/null
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        
        if [ "$RATE" != "UNLIMITED" ]; then
            local HEX=$(printf "%x" "$p")
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip dport "$p" 0xffff flowid 1:$HEX 2>/dev/null
            tc filter add dev "$INTERFACE" protocol ip parent 1:0 prio 1 u32 match ip sport "$p" 0xffff flowid 1:$HEX 2>/dev/null
        fi
    done
}

restore_rules_func() {
    modprobe nf_tables 2>/dev/null || true
    
    while [ -z "$INTERFACE" ]; do
        sleep 2
        INTERFACE=$(get_interface)
    done

    tc qdisc add dev "$INTERFACE" root handle 1: htb default 30 2>/dev/null
    tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate 1000mbit 2>/dev/null
    tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit 2>/dev/null

    init_nft_table

    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        local p=$(basename "$conf" .conf)
        source "$conf"
        local HEX=$(printf "%x" "$p")
        local CHAIN_NAME="LIMIT_P_${p}"

        if [ "$RATE" != "UNLIMITED" ]; then
            tc class add dev "$INTERFACE" parent 1:1 classid 1:$HEX htb rate "$RATE" ceil "$RATE" 2>/dev/null || true
        fi

        nft add chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
        nft flush chain inet port_manager "$CHAIN_NAME"
        nft add rule inet port_manager "$CHAIN_NAME" counter accept

        nft add rule inet port_manager input tcp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager input udp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager output tcp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
        nft add rule inet port_manager output udp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true

        if [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            if [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ]; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
    done
    rebuild_tc_filters
}

if [ "$1" == "daemon" ]; then
    restore_rules_func
    while true; do
        if ! nft list table inet port_manager &>/dev/null; then
            restore_rules_func
        fi
        check_and_block
        sleep 3
    done
    exit 0
fi

apply_limit() {
    local p=$1
    local r=$2
    local q=$3
    local rm=$4
    read -r lm_y lm_m _ _ _ <<< "$(get_bj_time)"
    local lm="${lm_y}${lm_m}"
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    echo -e "RATE=\"$r\"\nQUOTA=\"$q\"\nRESET_MODE=\"$rm\"\nLAST_RESET_MONTH=\"$lm\"\nSTORED_TOTAL=\"0\"\nLAST_IPT_BYTES=\"0\"" > "$CONF_DIR/${p}.conf"

    tc class del dev "$INTERFACE" classid 1:$HEX 2>/dev/null
    if [ "$r" != "UNLIMITED" ]; then
        if ! tc qdisc show dev "$INTERFACE" | grep -q "htb"; then
            tc qdisc add dev "$INTERFACE" root handle 1: htb default 30
            tc class add dev "$INTERFACE" parent 1: classid 1:1 htb rate 1000mbit
            tc class add dev "$INTERFACE" parent 1:1 classid 1:30 htb rate 1000mbit ceil 1000mbit
        fi
        tc class add dev "$INTERFACE" parent 1:1 classid 1:$HEX htb rate "$r" ceil "$r"
    fi
    rebuild_tc_filters

    init_nft_table
    nft add chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
    nft flush chain inet port_manager "$CHAIN_NAME"
    nft add rule inet port_manager "$CHAIN_NAME" counter accept

    nft add rule inet port_manager input tcp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager input udp dport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager output tcp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
    nft add rule inet port_manager output udp sport "$p" jump "$CHAIN_NAME" 2>/dev/null || true
}

remove_limit() {
    local p=$1
    local HEX=$(printf "%x" "$p")
    local CHAIN_NAME="LIMIT_P_${p}"

    tc class del dev "$INTERFACE" classid 1:$HEX 2>/dev/null
    rm -f "$CONF_DIR/${p}.conf"
    rebuild_tc_filters

    nft flush chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
    nft delete chain inet port_manager "$CHAIN_NAME" 2>/dev/null || true
}

show_ports() {
    check_and_block
    echo -e "\033[36m当前网卡: $INTERFACE \033[0m"
    echo "---------------------------------------------"
    printf " %-6s | %-8s | %-8s | %-8s | %-8s | %b\n" "端口" "流量上限" "网速上限" "已用流量" "周期" "状态"
    echo "---------------------------------------------"
    
    local count=0
    for conf in "$CONF_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        count=$((count+1))
        local PORT=$(basename "$conf" .conf)
        source "$conf"
        
        local CHAIN_NAME="LIMIT_P_${PORT}"
        local COLOR_STATUS="\033[32m正常\033[0m"
        
        [ -z "$STORED_TOTAL" ] && STORED_TOTAL=0
        
        if [ "$STORED_TOTAL" -eq 0 ]; then
            local LIVE_BYTES
            LIVE_BYTES=$(nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | awk '/bytes/ {for(i=1;i<=NF;i++) if($i=="bytes") {print $(i+1); exit}}')
            [ -n "$LIVE_BYTES" ] && [ "$LIVE_BYTES" -gt 0 ] && STORED_TOTAL="$LIVE_BYTES"
        fi
        
        local USED_MB=$(awk "BEGIN {printf \"%.2f\", $STORED_TOTAL / 1048576}")
        
        local is_dropped=0
        if nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
            is_dropped=1
        elif [ "$QUOTA" != "UNLIMITED" ]; then
            local LIMIT_BYTES=$(( QUOTA * 1048576 ))
            [ "$STORED_TOTAL" -ge "$LIMIT_BYTES" ] && is_dropped=1
        fi

        if [ "$is_dropped" -eq 1 ]; then
            COLOR_STATUS="\033[31m阻断\033[0m"
            if ! nft list chain inet port_manager "$CHAIN_NAME" 2>/dev/null | grep -q "drop"; then
                nft insert rule inet port_manager "$CHAIN_NAME" index 0 drop 2>/dev/null || true
            fi
        fi
        
        local Q_DISP="无限制"
        [ "$QUOTA" != "UNLIMITED" ] && Q_DISP="${QUOTA}MB"
        
        local R_DISP="无限制"
        [ "$RATE" != "UNLIMITED" ] && R_DISP="${RATE/mbit/Mbps}"

        local M_DISP="一次性"
        [ "$RESET_MODE" == "MONTHLY" ] && M_DISP="每月(1日00:01)"
        
		printf " \033[31m%-6s\033[0m | %-8s | %-8s | %-8s | %-8s | %b\n" "$PORT" "$Q_DISP" "$R_DISP" "${USED_MB}MB" "$M_DISP" "$COLOR_STATUS"
    done
    
    if [ "$count" -eq 0 ]; then
        echo -e "                   \033[33m当前暂未设置任何端口限制\033[0m"
    fi
    echo "---------------------------------------------"
}

while true; do
    clear
    echo "============================================="
    echo "     端口网速与流量限制"
    echo "============================================="
    green "  1. 新增 端口限制"
    green "  2. 修改 端口限制 (会清零当前已用流量)"
    green "  3. 删除 端口限制"
    green "  4. 刷新 流量状态"
    green "  0. 返回 上级菜单"
    echo "============================================="
    echo -e "已设置的端口:\n"
    show_ports
    
	reading "请输入选项 [0-4]: " choice
    case $choice in
        1|2)
            if [ "$choice" == "2" ]; then
                read -p "请输入要【修改】的端口号: " port
                if [ ! -f "$CONF_DIR/${port}.conf" ]; then
                    echo -e "\033[31m[-] 未找到该端口的配置！\033[0m"
                    read -p "按回车键继续..."
                    continue
                fi
                remove_limit "$port"
            else
                read -p "请输入要【限制】的端口号 (如 443): " port
            fi
            
            if [ -z "$port" ]; then
                echo -e "\033[31m[-] 端口号不能为空！\033[0m"
                read -p "按回车键继续..."
                continue
            fi

            echo -e "\n\033[36m>>> 直接按回车跳过流量限制 <<<\033[0m"
            read -p "请输入流量上限(MB): " quota
            if [ -z "$quota" ]; then
                quota="UNLIMITED"
                echo -e " -> \033[33m已设为: 不限制流量\033[0m"
            fi

            echo -e "\n\033[36m>>> 直接输入数字即可 (默认单位 Mbps)，直接按回车跳过网速限制 <<<\033[0m"
            read -p "请输入网速上限(如输入 5 代表 5Mbps): " rate_num
            if [ -z "$rate_num" ]; then
                rate="UNLIMITED"
                echo -e " -> \033[33m已设为: 不限制网速\033[0m"
            else
                rate="${rate_num}mbit"
                echo -e " -> \033[32m已设为: ${rate_num} Mbps\033[0m"
            fi

            echo -e "\n\033[36m>>> 直接按回车默认为一次性限制 <<<\033[0m"
            read -p "是否按月自动重置流量？(输入 y 开启，每月北京时间1日00:01重置): " is_monthly
            if [[ "$is_monthly" == "y" || "$is_monthly" == "Y" ]]; then
                reset_mode="MONTHLY"
                echo -e " -> \033[32m已设为: 每月重置 (北京时间1日00:01)\033[0m"
            else
                reset_mode="ONCE"
                echo -e " -> \033[33m已设为: 一次性限制 (用完即永久阻断)\033[0m"
            fi
            
            apply_limit "$port" "$rate" "$quota" "$reset_mode"
            echo -e "\n\033[32m[+] 端口 $port 限制配置成功！\033[0m"
            read -p "按回车键继续..."
            ;;
        3)
            read -p "请输入要删除限制的端口号: " port
            if [ -f "$CONF_DIR/${port}.conf" ]; then
                remove_limit "$port"
                echo -e "\033[32m[+] 端口 $port 限制已彻底移除！\033[0m"
            else
                echo -e "\033[31m[-] 未找到该端口的配置！\033[0m"
            fi
            read -p "按回车键继续..."
            ;;
		4)
            echo -e "\n\033[36m[+] 正在刷新端口流量统计与拦截状态...\033[0m"
            check_and_block
            restore_rules_func
            echo -e "\n\033[32m[+] 刷新完成！当前数据已更新。\033[0m"
            sleep 1
            ;;
        0)
            echo -e "\033[32m返回防火墙。\033[0m"
            break
            ;;
        *)
            red "无效选项，请重新输入。"
            sleep 1
            ;;
    esac
done
EOF

            chmod +x /usr/local/bin/port_menu.sh
            cat << 'SRVEOF' > /etc/systemd/system/port_manager.service
[Unit]
Description=Port Traffic Manager Background Service (nftables)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/port_menu.sh daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SRVEOF

            systemctl daemon-reload >/dev/null 2>&1
            systemctl enable port_manager.service >/dev/null 2>&1
            systemctl restart port_manager.service >/dev/null 2>&1
            systemctl stop restore_iptables.service >/dev/null 2>&1
            systemctl disable restore_iptables.service >/dev/null 2>&1
            rm -f /etc/systemd/system/restore_iptables.service
            bash /usr/local/bin/port_menu.sh menu
            sleep 1 && iptables_ssl
            ;;                  
        9)
            yellow "正在自动扫描并清理所有未运行的无用端口规则..."
            for port in $(nft list chain inet filter input 2>/dev/null | awk '/ScriptManaged/ {for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}' | tr -d '{};' | tr ',' '\n' | grep -E "^[0-9]+$" | sort -un); do
                if ! ss -tunlp | grep -q ":$port "; then
                    for handle in $(nft -a list chain inet filter input | awk -v p="$port" '$0~"dport "p {print $NF}'); do
                        nft delete rule inet filter input handle $handle 2>/dev/null
                    done
                    green "已清理: $port"
                fi
            done
            save_nft_rules
            green "清理完成！配置文件已更新保存。"
            sleep 1 && iptables_ssl ;;
        10)
            clear
            sed -i 's/^#\s*Port/Port/' /etc/ssh/sshd_config
            current_port=$(grep -E '^Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
            [ -z "$current_port" ] && current_port=22
            
            ipt_msg "\033[0;36m" "当前的 SSH 端口号是: $current_port"
            skyblue "---------------------------"
            
            read -p $'\033[1;35m请输入新的 SSH 端口号 (1-65535): \033[0m' new_port
            
            if [ -z "$new_port" ]; then
                yellow "未输入端口号，操作取消"
                sleep 1 && iptables_ssl
            elif ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -le 0 ] || [ "$new_port" -gt 65535 ]; then
                red "错误：请输入 1-65535 之间的有效端口号！"
                sleep 1 && iptables_ssl
            elif [ "$new_port" -eq "$current_port" ]; then
                yellow "新端口与当前端口相同，无需修改。"
                sleep 1 && iptables_ssl
            else
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
                if grep -qE '^Port\s+[0-9]+' /etc/ssh/sshd_config; then
                    sed -i "s/^Port\s\+[0-9]\+/Port $new_port/g" /etc/ssh/sshd_config
                else
                    echo "Port $new_port" >> /etc/ssh/sshd_config
                fi
                
                if command -v systemctl &>/dev/null; then
                    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
                else
                    service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
                fi
                
                green "成功：SSH 端口已修改为 $new_port"

                if command -v apt-get &>/dev/null; then
                    apt-get remove -y iptables-persistent ufw >/dev/null 2>&1
                elif command -v yum &>/dev/null; then
                    yum remove -y firewalld iptables-services >/dev/null 2>&1
                fi
                
                yellow "为了防止新端口未放行导致断网，正在自动关闭防火墙拦截模式..."
                nft 'add chain inet filter input { type filter hook input priority 0; policy accept; }' 2>/dev/null
                save_nft_rules
                green "拦截已关闭，防火墙当前为 [放行所有] 状态"
                
                sleep 2 && iptables_ssl
            fi
            ;;
		11) fail2ban_manage ;;
        0) menu ;;
        *) iptables_ssl ;;
    esac
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
    
	current_bytes=$(awk 'BEGIN { rx = 0; tx = 0 } NR > 2 { rx += $2; tx += $10 } END { printf "%.0f %.0f", rx, tx }' /proc/net/dev)
read -r curr_rx curr_tx <<< "$current_bytes"
traffic_file="$HOME/.vps_traffic_stats"
cur_month=$(date -u "+%Y-%m")
last_month=""
month_start_rx=0
month_start_tx=0
if [ -f "$traffic_file" ]; then
    source "$traffic_file" 2>/dev/null
fi
if [ "$last_month" != "$cur_month" ]; then
    last_month="$cur_month"
    month_start_rx="$curr_rx"
    month_start_tx="$curr_tx"
fi
monthly_rx=$((curr_rx - month_start_rx))
monthly_tx=$((curr_tx - month_start_tx))
if [ "$monthly_rx" -lt 0 ]; then
    month_start_rx="$curr_rx"
    monthly_rx=0
fi
if [ "$monthly_tx" -lt 0 ]; then
    month_start_tx="$curr_tx"
    monthly_tx=0
fi
cat << EOF > "$traffic_file"
last_month="$last_month"
month_start_rx="$month_start_rx"
month_start_tx="$month_start_tx"
EOF

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
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox ;;  
        2) stop_singbox ;;
        3) restart_singbox ;;
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
    if [ -f "${work_dir}/url.txt" ]; then
        while IFS= read -r line; do 
            purple "$line"
        done < "${work_dir}/url.txt"
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
        green "订阅链接: ${purple}${base64_url}${re}\n"
        found_any=true
    fi
    if [ "$found_any" = false ]; then
        red "订阅服务未配置或订阅已关闭\n"
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
            
            restart_singbox
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
    local i=3
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
    i=3
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
    echo ""
    green "请选择分流流量要走的出站线路:"
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
    green "2.  Claude"
    green "3.  Gemini"
    green "4.  Google"
    green "5.  Tiktok"
    green "6.  Twitter"
    green "7.  YouTube"
    green "8.  Netflix"
    green "9.  Telegram"
    skyblue "-----------------------------"
    green "10. ➕ 自定义分流"
    skyblue "-----------------------------"
    green "11. 设置全局代理出站 (所有流量走指定代理)"
    green "12. 恢复服务器原IP出站 (所有流量走服务器IP)"
    skyblue "-----------------------------"
    purple "0.  返回上级菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " add_choice
    case "$add_choice" in
        1)  rule_tag="openai"   ;;
        2)  rule_tag="claude"   ;;
        3)  rule_tag="gemini"   ;;
        4)  rule_tag="google"   ;;
        5)  rule_tag="tiktok"   ;;
        6)  rule_tag="twitter"  ;;
        7)  rule_tag="youtube"  ;;
        8)  rule_tag="netflix"  ;;
        9)  rule_tag="telegram" ;;
        10) add_custom_domain_rule; return ;;
        11) set_global_outbound; return ;;
        12) restore_direct_outbound; return ;;
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

    jq --arg tag "$rule_tag" --arg out "$selected_out" --arg inb "$selected_inbound" '
        .route.rules //= [] |
        if any(.route.rules[]; .outbound == $out and .rule_set != null and (($inb == "" and (has("inbound") | not)) or ($inb != "" and .inbound == [$inb]))) then
            .route.rules |= map(
                if .outbound == $out and .rule_set != null and (($inb == "" and (has("inbound") | not)) or ($inb != "" and .inbound == [$inb])) then 
                    .rule_set = (.rule_set + [$tag] | unique) 
                else . end
            )
        else
            if $inb == "" then
                .route.rules += [{"rule_set": [$tag], "outbound": $out}]
            else
                .route.rules += [{"inbound": [$inb], "rule_set": [$tag], "outbound": $out}]
            end
        end
    ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

    restart_singbox
    green "预设规则 '${rule_tag}' 已添加！\n生效节点: [ ${selected_inbound_name} ]\n出站线路: [ ${selected_out} ]"
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

    restart_singbox
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
    restart_singbox
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
    restart_singbox
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
    restart_singbox
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

        restart_singbox
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
    
    restart_singbox
    green "第 ${del_input} 条分流规则已成功删除！"
    sleep 1.5
    warp_manage
}

# 主菜单
menu() {
   singbox_status=$(check_singbox 2>/dev/null)
   nginx_status=$(check_nginx 2>/dev/null)
   update_xray_status
   
   clear
   echo ""
   green "Telegram群组: ${purple}https://t.me/eooceu${re}"
   green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
   green "${purple}快捷命令sb或者b${re}"
   purple "=== 老王sing-box四合一安装脚本 1.0===\n"
   printf "${purple} --Xray 状态: %s${re}\n" "$(to_chinese "$check_xray_status")"
   printf "${purple}--Nginx 状态: %s${re}\n" "$(to_chinese "$nginx_status")"
   printf "${purple}singbox 状态: %s${re}\n\n" "$(to_chinese "$singbox_status")" 
   printf "%b%-28s%b%s%b\n" "$green" "1. 安装sing-box" "$red" "10. 开启BBR" "$re"
   printf "%b%-28s%b%s%b\n" "$green" "2. 卸载sing-box" "$red" "11. 更新脚本" "$re"
   printf "%b%-28s%b%s%b\n" "$green" "3. sing-box管理" "$red" "12. iptables" "$re"
   printf "%b%-28s%b%s%b\n" "$green" "4. cf管理" "$red" "13. 快捷指令" "$re"
   printf "%b%-32s%b%s%b\n" "$green" "5. 查看节点信息" "$red" "14. 本机信息" "$re"
   printf "%b%-32s%b%s%b\n" "$green" "6. 修改节点配置" "$red" "15. WARP分流管理" "$re"
   printf "%b%-32s%b%s%b\n" "$green" "7. 管理节点订阅" "$red" "16. xray管理" "$re"
   printf "%b%-28s%b%s%b\n" "$green" "8. 更新sing-box" "$red" "17. token" "$re"
   printf "%b%-32s%b%s%b\n" "$green" "9. 添加删除节点" "$red" "0. 退出脚本" "$re"
   reading "请输入选择(0-98): " choice
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
            fi
           ;;
        2) uninstall_singbox ;;
        3) manage_singbox ;;
        4) manage_cf ;;
        5) check_nodes ;;
        6) change_config ;;
        7) disable_open_sub ;;
		8) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/sing.sh)
		   ;;
		9) manage_nodes_menu ;;
	    10) clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/bbr.sh)
		   ;;
		11) update_script ;;
		12) iptables_ssl ;;
		13) 
           clear
		   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/jiao/aa.sh)
		   ;;
		14) vps_s ;;
		15)  warp_manage ;;
		16)  manage_xray ;;
		17)  token_manage ;;
		0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 16" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
done
