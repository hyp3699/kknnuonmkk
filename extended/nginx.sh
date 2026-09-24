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
            systemctl restart nginx
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
