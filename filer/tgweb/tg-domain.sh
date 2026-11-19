#!/bin/bash
# tgweb 域名（tg domain 调用，也可直接用 tg-domain）：直接列出本机已有证书的域名，选一个就把域名和证书写进 Nginx 配置并重载；再运行就换域名。
# 证书目录：/root/cert/<域名>/ 或 /etc/nginx/cert/<域名>/，里面要有 fullchain.pem 和 privkey.pem。
# 生成的配置：/etc/nginx/conf.d/tgweb-domain.conf，只有一份，换域名就覆盖（反代本机 127.0.0.1:9393 的网页服务）。
# 只生成 443，不生成 80：禁止用 HTTP 访问应用，绑了域名/IP 后 HTTP 入口必须关掉，否则 HTTPS 会被绕过。
# TGWEB-DOMAIN-TOOL（安装器靠这行识别 /usr/local/bin/tg-domain 是不是本工具）
set -uo pipefail
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "用法：tg domain [域名]"
  echo "  不给域名：列出本机已有证书，选一个绑定；选 1 取消域名，选 0 退出。"
  echo "  给域名：直接用该域名的证书绑定（没有就试泛域名、父域名证书）。"
  echo "  证书要自己先准备好，放在 /root/cert/<域名>/ 或 /etc/nginx/cert/<域名>/ 里。"
  exit 0
fi
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
if ! command -v nginx >/dev/null 2>&1; then
  echo "Nginx 未安装，请先装 Nginx 再用 tg domain。"
  exit 1
fi

CONF=/etc/nginx/conf.d/tgweb-domain.conf
OLD_PREFIX=/etc/nginx/conf.d/tgweb-domain-   # 旧版每个域名一份，换成单份时清掉
APP_UPSTREAM=http://127.0.0.1:9393

re='\033[0m'; red='\033[1;91m'
red()     { echo -e "\033[1;91m$1\033[0m"; }
green()   { echo -e "\033[1;32m$1\033[0m"; }
yellow()  { echo -e "\033[1;93m$1\033[0m"; }
skyblue() { echo -e "\033[1;96m$1\033[0m"; }
reading() { read -r -p "$(echo -e "\033[1;91m$1\033[0m")" "$2" </dev/tty; }

# 检查并选择已有证书
# 调用：check_and_issue_ssl [域名] || return 1   结果在 domain / cert_file / key_file
check_and_issue_ssl() {
    local input_domain="$1"
    domain=""; cert_file=""; key_file=""

    # 无指定域名：显示本地已有证书列表
    if [[ -z "$input_domain" ]]; then
        local cert_domains=() cert_paths=() dir d_name
        shopt -s nullglob
        for dir in /root/cert/* /etc/nginx/cert/*; do
            if [[ -d "$dir" && -f "$dir/fullchain.pem" && -f "$dir/privkey.pem" ]]; then
                d_name=$(basename "$dir")
                if [[ ! " ${cert_domains[*]} " =~ " ${d_name} " ]]; then
                    cert_domains+=("$d_name"); cert_paths+=("$dir")
                fi
            fi
        done
        shopt -u nullglob

        echo
        local cur_domain=""; [[ -f "$CONF" ]] && cur_domain=$(awk '$1=="server_name"{sub(/;$/,"",$2); print $2; exit}' "$CONF")
        skyblue "============== 选择使用的域名 =============="
        [[ -n "$cur_domain" ]] && echo -e " 当前域名：\033[1;32m${cur_domain}\033[0m"
        local i=2 idx
        if [[ ${#cert_domains[@]} -eq 0 ]]; then
            echo "  (未检测到任何本地证书)"
        else
            for idx in "${!cert_domains[@]}"; do
                local cert_mark="" cert_file_tmp="${cert_paths[$idx]}/fullchain.pem"
                if openssl x509 -in "$cert_file_tmp" -noout -issuer 2>/dev/null | grep -qi "CloudFlare Origin SSL"; then
                    cert_mark=" ${red}【15年证书】${re}"
                fi
                [[ "${cert_domains[$idx]}" == "$cur_domain" ]] && cert_mark+=" \033[1;32m【当前】\033[0m"
                echo -e " ${i}) ${cert_domains[$idx]}${cert_mark}  (路径: ${cert_paths[$idx]})"
                ((i++))
            done
        fi
        skyblue "=============================================="
        [[ -n "$cur_domain" ]] && echo " 1) 取消域名（删除域名配置）"
        echo " 0) 退出"
        echo

        local menu_choice
        reading "请选择已有证书序号 [2-$((i-1))] 或 0 退出: " menu_choice
        if [[ "$menu_choice" == "0" ]]; then red "已取消操作。"; return 1; fi
        if [[ "$menu_choice" == "1" && -n "$cur_domain" ]]; then domain=""; return 2; fi
        if [[ "$menu_choice" =~ ^[0-9]+$ ]] && [[ "$menu_choice" -ge 2 ]] && [[ "$menu_choice" -lt "$i" ]]; then
            local sel_idx=$((menu_choice - 2))
            domain="${cert_domains[$sel_idx]}"
            cert_file="${cert_paths[$sel_idx]}/fullchain.pem"
            key_file="${cert_paths[$sel_idx]}/privkey.pem"
            green "已选择并使用域名 ${domain} 的现有证书。"
            return 0
        fi
        red "无效的选择！"; return 1
    fi

    # 指定域名
    domain=$(echo "$input_domain" | tr -d '[:space:]')
    if [[ -z "$domain" ]]; then red "域名不能为空！"; return 1; fi
    # IP 也能绑：install.sh 本来就承诺“域名或 IP”，证书放在 /root/cert/<IP>/ 或
    # /etc/nginx/cert/<IP>/ 里。以前这里直接拒绝 IP，install 走到这一步必定失败，
    # 而仓库里也没有别的 IP 配置生成器，IP 用户就卡住了。IP 没有泛域名/父域名那一套，
    # 只认它自己的证书目录，找不到就明说失败。
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ -f "/root/cert/${domain}/fullchain.pem" && -f "/root/cert/${domain}/privkey.pem" ]]; then
            cert_file="/root/cert/${domain}/fullchain.pem"; key_file="/root/cert/${domain}/privkey.pem"
        elif [[ -f "/etc/nginx/cert/${domain}/fullchain.pem" && -f "/etc/nginx/cert/${domain}/privkey.pem" ]]; then
            cert_file="/etc/nginx/cert/${domain}/fullchain.pem"; key_file="/etc/nginx/cert/${domain}/privkey.pem"
        else
            red "未找到 IP ${domain} 的证书，请先把证书放到 /root/cert/${domain}/ 或 /etc/nginx/cert/${domain}/ 里。"
            return 1
        fi
        skyblue "检测到 IP ${domain} 的证书已存在，直接使用。"
        return 0
    fi
    local domain_re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
    if ! [[ "$domain" =~ $domain_re ]]; then red "域名格式不对，例如 example.com"; return 1; fi

    # 1. 该域名自己的证书
    local existing_path=""
    if [[ -f "/root/cert/${domain}/fullchain.pem" && -f "/root/cert/${domain}/privkey.pem" ]]; then
        existing_path="/root/cert/${domain}"
    elif [[ -f "/etc/nginx/cert/${domain}/fullchain.pem" && -f "/etc/nginx/cert/${domain}/privkey.pem" ]]; then
        existing_path="/etc/nginx/cert/${domain}"
    fi
    if [[ -n "$existing_path" ]]; then
        cert_file="${existing_path}/fullchain.pem"; key_file="${existing_path}/privkey.pem"
        skyblue "检测到域名 ${domain} 的证书已存在，直接使用。"
        return 0
    fi

    # 2. 泛域名证书（api.example.com → *.example.com）
    if [[ "$domain" == *.*.* ]]; then
        local parent_domain="${domain#*.}" wildcard_cert="" wildcard_key="" wdir
        for wdir in "/root/cert/*.${parent_domain}" "/etc/nginx/cert/*.${parent_domain}"; do
            if [[ -f "$wdir/fullchain.pem" && -f "$wdir/privkey.pem" ]]; then
                wildcard_cert="$wdir/fullchain.pem"; wildcard_key="$wdir/privkey.pem"; break
            fi
        done
        if [[ -n "$wildcard_cert" ]]; then
            yellow "检测到可用泛域名证书 (*.${parent_domain})。"
            local use_wildcard
            reading "是否直接使用该泛域名证书保护 ${domain}？(y/n): " use_wildcard
            if [[ "$use_wildcard" == "y" || "$use_wildcard" == "Y" ]]; then
                cert_file="$wildcard_cert"; key_file="$wildcard_key"
                green "已选择使用泛域名证书。"; return 0
            fi
        fi

        # 3. 父域名普通证书
        local parent_cert="" parent_key=""
        if [[ -f "/root/cert/${parent_domain}/fullchain.pem" && -f "/root/cert/${parent_domain}/privkey.pem" ]]; then
            parent_cert="/root/cert/${parent_domain}/fullchain.pem"; parent_key="/root/cert/${parent_domain}/privkey.pem"
        elif [[ -f "/etc/nginx/cert/${parent_domain}/fullchain.pem" && -f "/etc/nginx/cert/${parent_domain}/privkey.pem" ]]; then
            parent_cert="/etc/nginx/cert/${parent_domain}/fullchain.pem"; parent_key="/etc/nginx/cert/${parent_domain}/privkey.pem"
        fi
        if [[ -n "$parent_cert" ]]; then
            yellow "当前域名无证书，但检测到父域名 ${parent_domain} 已有普通证书。"
            local use_parent
            reading "是否尝试使用父域名证书？(y/n): " use_parent
            if [[ "$use_parent" == "y" || "$use_parent" == "Y" ]]; then
                cert_file="$parent_cert"; key_file="$parent_key"
                green "已选择使用 ${parent_domain} 的证书。"; return 0
            fi
        fi
    fi

    red "未找到域名 ${domain} 的可用证书。"
    red "证书申请功能已移除，请手动准备证书后重试。"
    return 1
}

reload_or_rollback() {   # $1 = 备份文件（空 = 原来没有配置）
    # 以前这里只看 nginx -t，systemctl reload 失败也照样 return 0 还删备份：
    # 用户看到“已设置”，实际 nginx 还在跑旧配置。改成重载失败也算失败。
    local out
    if ! out=$(nginx -t 2>&1); then
        if [[ -n "$1" ]]; then mv "$1" "$CONF"; else rm -f "$CONF"; fi
        red "Nginx 配置检查没通过，已恢复原来的配置："
        echo "$out" | sed 's/^/  /'
        return 1
    fi
    # 重载按顺序试：systemd 方式不行就试 nginx -s reload（非 systemd 运行的 nginx），
    # nginx 根本没跑就试启动。哪一步成了才删备份、算成功。
    if systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || systemctl start nginx 2>/dev/null || nginx 2>/dev/null; then
        [[ -n "$1" ]] && rm -f "$1"
        return 0
    fi
    if [[ -n "$1" ]]; then mv "$1" "$CONF"; else rm -f "$CONF"; fi
    systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    red "Nginx 配置已写入且检查通过，但重载/启动失败，已恢复原来的配置。"
    red "请手动跑 systemctl reload nginx 或 nginx -s reload，成功后再重新绑定。"
    return 1
}

check_and_issue_ssl "${1:-}"; rc=$?
[[ $rc == 1 ]] && exit 1

backup=""
[[ -f "$CONF" ]] && { backup=$(mktemp); cp "$CONF" "$backup"; }

if [[ $rc == 2 ]]; then
    rm -f "$CONF"
    rm -f /etc/nginx/conf.d/tgweb.conf
    reload_or_rollback "$backup" && green "已取消域名，外部访问已关闭（不再提供 HTTP 访问，证书文件没动）。请重新用 tg domain 绑定域名或 IP 证书才能访问。"
    exit
fi

# 别的 Nginx 配置已经用了这个域名：提醒（同一域名两个 server 块，Nginx 只认第一个）
pat="${domain//./\\.}"; pat="${pat//\*/\\*}"
other=$(grep -rlsE "server_name[^;]*[[:space:]]${pat}([[:space:];]|$)" /etc/nginx/ 2>/dev/null | grep -v "^${CONF}$" | grep -v "^${OLD_PREFIX}" || true)
if [[ -n "$other" ]]; then
    yellow "注意：下面的 Nginx 配置也在用 ${domain}，可能冲突（只有一个生效）："
    echo "$other" | sed 's/^/  /'
fi

# http2 写法按 nginx 版本分：http2 on 是 1.25.1 才有的指令，apt 默认的
# Debian 12（1.22）/ Ubuntu 24.04（1.24）上写它，nginx -t 直接失败，绑定就回滚；
# listen ... http2 在老版本上能用，在新版本上只是提示 deprecated，还能跑。
# 所以老版本用 listen 参数，新版本用 http2 on，两边都不报错。
_NGINX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -n "$_NGINX_VER" ] && [ "$(printf '%s\n%s\n' "1.25.1" "$_NGINX_VER" | sort -V | head -1)" = "1.25.1" ]; then
    _LISTEN443="listen 443 ssl;"
    _LISTEN443V6="listen [::]:443 ssl;"
    _HTTP2_LINE="    http2 on;"
else
    _LISTEN443="listen 443 ssl http2;"
    _LISTEN443V6="listen [::]:443 ssl http2;"
    _HTTP2_LINE=""
fi

# 旧的 HTTP 反代必须删掉，否则绑了 HTTPS 也能用 HTTP 明文进应用
rm -f /etc/nginx/conf.d/tgweb.conf
cat > "$CONF" <<EOF
# tgweb 域名（由 tg domain 生成；再运行 tg domain 可换域名）
server {
    ${_LISTEN443}
    ${_LISTEN443V6}
    server_name ${domain};
    server_tokens off;
${_HTTP2_LINE}
    gzip on;
    gzip_proxied any;
    gzip_types application/json text/css application/javascript;
    ssl_certificate     ${cert_file};
    ssl_certificate_key ${key_file};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    location / {
        proxy_pass ${APP_UPSTREAM};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 0;
    }
}
EOF
olds=( ${OLD_PREFIX}*.conf ); old_bak=$(mktemp -d)
for f in "${olds[@]}"; do [[ -f "$f" ]] && mv "$f" "$old_bak/"; done
if reload_or_rollback "$backup"; then
    rm -rf "$old_bak"
    green "域名已设置：https://${domain}"
    echo "  证书：${cert_file}"
    echo "  私钥：${key_file}"
else
    mv "$old_bak"/* /etc/nginx/conf.d/ 2>/dev/null; rm -rf "$old_bak"
    exit 1
fi
