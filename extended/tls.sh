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
# IP 证书申请模式
run_ip_ssl_task() {
    domain=""
    cert_file=""
    key_file=""
    manage_packages "install" "curl" "socat" "cron" "psmisc"
    mkdir -p "$HOME/.acme.sh"
    local acme_cmd="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_cmd" ]]; then
        skyblue "正在安装 acme.sh..."
        curl -fsSL "https://get.acme.sh" | sh -s email="cert_${RANDOM}@gmail.com" >/dev/null 2>&1
        if [[ ! -f "$acme_cmd" ]]; then
            manage_packages "install" "git"
            rm -rf "$HOME/acme_git_tmp"
            git clone "https://github.com/acmesh-official/acme.sh.git" "$HOME/acme_git_tmp" >/dev/null 2>&1
            if [[ -d "$HOME/acme_git_tmp" ]]; then
                (
                    cd "$HOME/acme_git_tmp" &&
                    ./acme.sh --install -m "cert_${RANDOM}@gmail.com"
                ) >/dev/null 2>&1
                rm -rf "$HOME/acme_git_tmp"
            fi
        fi
    fi
    if [[ ! -f "$acme_cmd" ]]; then
        red "错误：acme.sh 安装失败！"
        return 1
    fi
    "$acme_cmd" --set-default-ca --server letsencrypt >/dev/null 2>&1
    local release_80="/root/release_80.sh"
    local restore_80="/root/restore_80.sh"
    cat > "$release_80" <<'EOF'
#!/bin/bash
for i in $(lsof -t -i:80 2>/dev/null | sort -u); do
    kill -9 "$i" 2>/dev/null
done
EOF
    chmod +x "$release_80"
    cat > "$restore_80" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$restore_80"
    local -a ip_sources=()
    local local_ipv4
    local local_ipv6
    local_ipv4=$(curl -4 -fsSL --max-time 8 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    local_ipv6=$(curl -6 -fsSL --max-time 8 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$local_ipv4" ]]; then
        ip_sources+=("本机IP|$local_ipv4")
    fi
    if [[ -n "$local_ipv6" ]]; then
        ip_sources+=("本机IP|$local_ipv6")
    fi
    local list_file
    local tunnel_name
    local tunnel_ip
    for list_file in /etc/tunnel64/*.list; do
        [[ -f "$list_file" ]] || continue
        tunnel_name=$(basename "$list_file")
        tunnel_name="${tunnel_name%%-*}"
        while IFS= read -r tunnel_ip || [[ -n "$tunnel_ip" ]]; do
            tunnel_ip=$(echo "$tunnel_ip" | xargs)
            [[ -z "$tunnel_ip" ]] && continue
            [[ "$tunnel_ip" =~ ^# ]] && continue
            ip_sources+=("${tunnel_name} IP|${tunnel_ip}")
        done < "$list_file"
    done
    if [[ ${#ip_sources[@]} -eq 0 ]]; then
        red "没有检测到任何 IP！"
        return 1
    fi
    echo
    skyblue "检测到以下 IP："
    echo
    local i
    local item
    local source
    local ip
    for i in "${!ip_sources[@]}"; do
        item="${ip_sources[$i]}"
        source="${item%%|*}"
        ip="${item#*|}"
        echo " $((i + 1))) ${source}: ${ip}"
    done
    echo
    local ip_choice
    reading "请选择要申请证书的 IP [1-${#ip_sources[@]}]: " ip_choice
    if ! [[ "$ip_choice" =~ ^[0-9]+$ ]]; then
        red "无效选择！"
        return 1
    fi
    if (( ip_choice < 1 || ip_choice > ${#ip_sources[@]} )); then
        red "无效选择！"
        return 1
    fi
    item="${ip_sources[$((ip_choice - 1))]}"
    source="${item%%|*}"
    ip="${item#*|}"
    echo
    skyblue "已选择：${source}: ${ip}"
    local save_path="/root/cert/${ip}"
    mkdir -p "$save_path"
    skyblue "正在为 ${source} ${ip} 申请 IP 证书..."
    if ! "$acme_cmd" \
        --issue \
        -d "$ip" \
        --standalone \
        --httpport 80 \
        -k ec-256 \
        --server letsencrypt \
        --cert-profile shortlived \
        --days 3 \
        --force \
        --pre-hook "$release_80" \
        --post-hook "$restore_80"
    then
        red "${source}: ${ip} 证书申请失败！"
        return 1
    fi
    if ! "$acme_cmd" \
        --installcert \
        -d "$ip" \
        --key-file "${save_path}/privkey.pem" \
        --fullchain-file "${save_path}/fullchain.pem" \
        --ecc
    then
        red "${source}: ${ip} 证书安装失败！"
        return 1
    fi
    if [[ ! -f "${save_path}/fullchain.pem" || ! -f "${save_path}/privkey.pem" ]]; then
        red "${source}: ${ip} 证书文件生成失败！"
        return 1
    fi
    chmod 600 "${save_path}/privkey.pem"
    domain="$ip"
    cert_file="${save_path}/fullchain.pem"
    key_file="${save_path}/privkey.pem"
    echo
    green "申请成功！"
    green "${source}: ${domain}"
    green "证书: ${cert_file}"
    green "私钥: ${key_file}"
    "$acme_cmd" --upgrade --auto-upgrade >/dev/null 2>&1
    return 0
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
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$domain" == *:* ]]; then
       check_dns="n"
    else
       reading "是否检查 DNS 解析记录？(y/回车跳过): " check_dns
    fi
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
	echo " 4) 申请ip证书"
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
	4)
        if ! run_ip_ssl_task; then
            red "IP 证书申请失败。"
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
