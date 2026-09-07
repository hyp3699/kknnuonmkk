#!/bin/bash

# --- 定义颜色代码 ---
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

ip_address() {
    ipv4_address=$(curl -s -m 2 ipv4.ip.sb)
    ipv6_address=$(curl -s -m 2 ipv6.ip.sb)
}

manage_packages() {
    local action=$1
    shift
    if command -v apt >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    else
        red "未检测到支持的包管理器，请手动安装依赖。"
        return 1
    fi
    for package in "$@"; do
        if [ "$action" = "install" ]; then
            if command -v "$package" >/dev/null 2>&1; then
                continue
            fi      
            yellow "正在安装依赖: ${package}..."
            case "$PKG_MGR" in
                apt)
                    apt update -y >/dev/null 2>&1
                    apt install -y "$package" >/dev/null 2>&1
                    ;;
                dnf|yum)
                    $PKG_MGR install -y "$package" >/dev/null 2>&1
                    ;;
                apk)
                    apk add "$package" >/dev/null 2>&1
                    ;;
            esac
        fi
    done
    return 0
}

# 80 端口申请模式
run_ssl_task() {
    local domain="$1"
    [[ -z "$domain" ]] && reading "请输入域名: " domain
    [[ -z "$domain" ]] && red "域名不能为空" && return 1
    manage_packages "install" "curl" "socat"
    if command -v ss >/dev/null 2>&1; then
        local occupant=$(ss -ntlp | grep ":80 " | awk -F'users:\\(\\("' '{print $2}' | awk -F'"' '{print $1}' | head -n1)
        [[ -n "$occupant" ]] && red "错误: 80 端口正被 [${occupant}] 占用" && return 1
    fi
    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && skyblue "正在安装 acme.sh..." && curl -s https://get.acme.sh | sh >/dev/null 2>&1
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1    
    local save_path="/root/cert/${domain}"
    mkdir -p "$save_path"    
    skyblue "正在为 ${domain} 申请证书..."
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone --httpport 80 --force        
    if [ $? -eq 0 ]; then
        "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
            --key-file "${save_path}/privkey.pem" \
            --fullchain-file "${save_path}/fullchain.pem"
        
        chmod 600 "${save_path}/privkey.pem"
        cert_file="${save_path}/fullchain.pem"
        key_file="${save_path}/privkey.pem"
        green "申请成功！"
        green "证书: ${cert_file}"
        green "私钥: ${key_file}"      
        "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1
    else
        red "申请失败，请检查域名解析和 80 端口"
        return 1
    fi
}

# Cloudflare DNS API 模式申请证书函数
issue_cf_dns_cert() {
    if [[ -z "$domain" ]]; then
        reading "请输入域名 (支持通配符如 *.example.com): " domain
    fi
    [[ -z "$domain" ]] && red "域名不能为空" && return 1    
    reading "请输入 Cloudflare 登录邮箱: " cf_email
    [[ -z "$cf_email" ]] && red "邮箱不能为空" && return 1    
    reading "请输入 Cloudflare Global API Key: " cf_key
    [[ -z "$cf_key" ]] && red "API Key 不能为空" && return 1      
    export CF_Email=$(echo "$cf_email" | tr -d '[:space:]')
    export CF_Key=$(echo "$cf_key" | tr -d '[:space:]')      
    manage_packages "install" "curl" "socat" "cron" "psmisc"     
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        skyblue "正在安装 acme.sh..."
        curl https://get.acme.sh | sh -s email="$CF_Email" >/dev/null 2>&1
    fi      
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1      
    local save_path="/root/cert/${domain}"
    mkdir -p "$save_path"  
    skyblue "正在通过 DNS API 为 ${domain} 申请证书..."
    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$domain" --keylength ec-256 --force   
    if [ $? -eq 0 ]; then
        "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" --ecc \
            --key-file "${save_path}/privkey.pem" \
            --fullchain-file "${save_path}/fullchain.pem"                
        chmod 600 "${save_path}/privkey.pem"
        cert_file="${save_path}/fullchain.pem"
        key_file="${save_path}/privkey.pem"        
        green "申请成功！"
        green "证书: ${cert_file}"
        green "私钥: ${key_file}"      
        "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1
    else
        red "申请失败，请检查 CF 邮箱/Key 是否正确，或 API 频率限制。"
        return 1
    fi
}

# 综合证书检查与申请 调用check_and_issue_ssl || return 1
check_and_issue_ssl() {
    local input_domain="$1"
    [[ -z "$input_domain" ]] && reading "请输入域名: " input_domain
    [[ -z "$input_domain" ]] && red "域名不能为空!" && return 1  
    domain="$input_domain"
    cert_file="/root/cert/${domain}/fullchain.pem"
    key_file="/root/cert/${domain}/privkey.pem"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        skyblue "检测到域名 ${domain} 的证书已存在，直接使用。"
        return 0
    fi
    if [[ "$domain" == *.*.* ]]; then
        local parent_domain=$(echo "$domain" | cut -d'.' -f2-)
        local p_cert="/root/cert/${parent_domain}/fullchain.pem"
        local p_key="/root/cert/${parent_domain}/privkey.pem"

        if [[ -f "$p_cert" && -f "$p_key" ]]; then
            yellow "当前域名无证书，但检测到父域名 ${parent_domain} 已有证书。"
            reading "是否直接使用父域名证书？(y/n): " use_parent
            if [[ "$use_parent" == "y" ]]; then
                cert_file="$p_cert"
                key_file="$p_key"
                green "已选择使用 ${parent_domain} 的证书。"
                return 0
            fi
        fi
    fi
    echo -e "未检测到可用证书，请选择申请方式"
	echo -e "通过80端口申请 确保域名已解析到服务器并且已关闭代理模式"
    echo -e "1) 通过 80 端口申请 "
    echo -e "2) 通过 Cloudflare DNS API"
    reading "请输入选择 [1-2]: " ssl_choice

    case "$ssl_choice" in
        1) run_ssl_task "$domain" ;;
        2) issue_cf_dns_cert "$domain" ;;
        *) red "无效选择"; return 1 ;;
    esac
    if [[ $? -eq 0 && -f "$cert_file" ]]; then
        green "证书申请成功并已就绪！"
        return 0
    else
        red "证书申请失败，请检查日志。"
        return 1
    fi
}

add_swap() {
    clear
    purple "=== 虚拟内存 (Swap) ==="
    echo ""
    current_swap=$(free -m | awk '/Swap/ {print $2}')
    green "当前系统 Swap 容量: ${current_swap}MB"
    echo ""
    reading "请输入需要设置的 Swap 大小 (单位 MB): " swap_size
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        red "错误: 请输入有效的数字！"
        sleep 2
        return
    fi
    
    echo "正在处理中..."
    swapoff -a >/dev/null 2>&1
    rm -f /swapfile
    
    if ! fallocate -l ${swap_size}M /swapfile; then
        dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=progress
    fi
    
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    
    echo ""
    green "设置成功！当前系统内存状态："
    free -h
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}

#查看内存占用排行
check_memory_usage() {
    # 辅助函数：自动清理与程序相关的 systemd 服务文件
    clean_systemd_service() {
        local cmd_name="$1"
        # 匹配可能包含该程序名的 .service 文件
        local service_files=$(find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -maxdepth 2 -iname "*${cmd_name}*.service" 2>/dev/null)

        if [ -n "$service_files" ]; then
            echo -e "\033[33m[!] 检测到关联的 systemd 自启动服务文件：\033[0m"
            echo "$service_files"
            read -p "是否同步停止、删除这些服务文件并重载 systemd？[y/N]: " confirm_svc
            if [[ "$confirm_svc" =~ ^[Yy]$ ]]; then
                echo "$service_files" | while read -r file; do
                    [ -z "$file" ] && continue
                    local svc_name=$(basename "$file")
                    # 尝试停止并禁用服务
                    systemctl stop "$svc_name" 2>/dev/null
                    systemctl disable "$svc_name" 2>/dev/null
                    # 删除服务文件
                    rm -f "$file"
                    echo -e "\033[32m[+] 已清理服务文件: $file\033[0m"
                done
                # 刷新 systemd 配置
                systemctl daemon-reload
                echo -e "\033[32m[+] 已成功重载 systemd 配置 (daemon-reload)。\033[0m"
            fi
        else
            echo -e "\033[36m[*] 未检测到与 $cmd_name 相关的 systemd 服务文件。\033[0m"
        fi
    }

    while true; do
        clear
        echo -e "\033[35m=== 系统内存使用概况 ===\033[0m"
        local mem_total=$(free -m | awk '/Mem:/ {print $2}')
        local mem_used=$(free -m | awk '/Mem:/ {print $3}')
        local swap_total=$(free -m | awk '/Swap:/ {print $2}')
        local swap_used=$(free -m | awk '/Swap:/ {print $3}')
        local disk_info=$(df -h / | awk 'NR==2 {print $2, $3, $5}')
        local disk_total=$(echo $disk_info | awk '{print $1}')
        local disk_used=$(echo $disk_info | awk '{print $2}')
        local disk_perc=$(echo $disk_info | awk '{print $3}')
        
        echo -e "\033[31m物理内存: ${mem_used}MB / ${mem_total}MB\033[0m"
        echo -e "\033[31m虚拟内存: ${mem_used_swap:-$swap_used}MB / ${swap_total}MB\033[0m"
        echo -e "\033[31m硬盘占用: ${disk_used} / ${disk_total} (${disk_perc})\033[0m"
        
        echo "--------------------------------------------"
        echo -e "\033[35m=== 进程内存占用排行 (Top 30) ===\033[0m"
        echo -e "序号  程序名称           内存占用   PID"
        echo "--------------------------------------------"
        
        local -a pids
        local -a cmds
        local i=1
        
        while read -r pid rss raw_cmd; do
            local mem_mb=$(awk "BEGIN {printf \"%.1f\", $rss/1024}")
            local short_cmd=$raw_cmd
            if [[ ! "$short_cmd" =~ ^\[.*\]$ ]]; then
                short_cmd="${short_cmd##*/}"
            fi
            
            pids[$i]=$pid
            cmds[$i]=$short_cmd
            
            local mem_str="${mem_mb}MB"
            local display_cmd="${short_cmd:0:16}"
            
            printf "%-5s \033[32m%-18s\033[0m %-10s %-8s\n" "${i})" "$display_cmd" "$mem_str" "$pid"
            ((i++))
        done < <(ps aux --sort=-rss | awk 'NR>1 {print $2, $6, $11}' | head -n 30)

        echo "--------------------------------------------"
        echo ""
        
        read -p "请输入对应数字进行操作 (输入 0 退出当前页): " choice
        
        if [[ "$choice" == "0" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt "$i" ]]; then
            local target_pid="${pids[$choice]}"
            local target_cmd="${cmds[$choice]}"
            local exe_path=$(readlink -f /proc/$target_pid/exe 2>/dev/null)
            
            echo ""
            echo "您选中了进程: $target_cmd (PID: $target_pid)"
            if [ -n "$exe_path" ]; then
                echo -e "物理文件路径: \033[33m$exe_path\033[0m"
            else
                echo -e "物理文件路径: \033[31m无法获取 (可能是内核进程或权限不足)\033[0m"
            fi
            echo ""
            echo "请选择操作:"
            echo "  1) 仅强制结束进程 (释放内存，安全)"
            echo "  2) 结束进程，删除源文件 + 清理自启服务文件"
            if [ -x "$(command -v apt)" ]; then
                echo "  3) 尝试通过 apt 彻底卸载 + 清理残留自启文件"
            elif [ -x "$(command -v yum)" ]; then
                echo "  3) 尝试通过 yum 彻底卸载 + 清理残留自启文件"
            fi
            echo "  0) 取消并返回"
            read -p "请输入操作序号: " sub_choice
            
            case "$sub_choice" in
                1)
                    kill -9 "$target_pid" 2>/dev/null
                    echo -e "\033[32m[+] 进程已结束。\033[0m"
                    ;;
                2)
                    if [ -z "$exe_path" ]; then
                        echo -e "\033[31m[-] 找不到源文件，无法删除。\033[0m"
                    else
                        read -p "【危险】确定彻底删除 $exe_path 吗？[y/N]: " confirm_del
                        if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                            kill -9 "$target_pid" 2>/dev/null
                            rm -rf "$exe_path"
                            echo -e "\033[32m[+] 进程已结束，主程序文件已被彻底删除。\033[0m"
                            
                            # 执行 systemd 检查与清理
                            clean_systemd_service "$target_cmd"
                        else
                            echo "已取消删除。"
                        fi
                    fi
                    ;;
                3)
                    if [ -z "$exe_path" ]; then
                        echo -e "\033[31m[-] 找不到源文件路径，无法匹配包管理器。\033[0m"
                    else
                        read -p "确定要尝试卸载该程序吗？ [y/N]: " confirm_pkg
                        if [[ "$confirm_pkg" =~ ^[Yy]$ ]]; then
                            kill -9 "$target_pid" 2>/dev/null
                            if [ -x "$(command -v apt)" ]; then
                                pkg_name=$(dpkg -S "$exe_path" 2>/dev/null | awk -F: '{print $1}')
                                if [ -n "$pkg_name" ]; then
                                    echo -e "找到归属软件包: \033[33m$pkg_name\033[0m，开始卸载..."
                                    apt-get purge -y "$pkg_name"
                                    apt-get autoremove -y
                                    echo -e "\033[32m[+] 包管理器卸载完成。\033[0m"
                                else
                                    echo -e "\033[31m[-] 该文件未通过 apt 安装，无法通过 apt 卸载。\033[0m"
                                fi
                            elif [ -x "$(command -v yum)" ]; then
                                pkg_name=$(rpm -qf "$exe_path" 2>/dev/null)
                                if [[ ! "$pkg_name" =~ "is not owned" ]] && [ -n "$pkg_name" ]; then
                                    echo -e "找到归属软件包: \033[33m$pkg_name\033[0m，开始卸载..."
                                    yum remove -y "$pkg_name"
                                    echo -e "\033[32m[+] 包管理器卸载完成。\033[0m"
                                else
                                    echo -e "\033[31m[-] 该文件未通过 yum 安装，无法通过 yum 卸载。\033[0m"
                                fi
                            fi
                            
                            clean_systemd_service "$target_cmd"
                        else
                            echo "已取消卸载。"
                        fi
                    fi
                    ;;
                0|*)
                    echo "已取消操作。"
                    ;;
            esac
            
            echo "3秒后自动刷新页面..."
            sleep 3
        else
            echo -e "\033[31m无效的输入！\033[0m"
            sleep 1
        fi
    done
}


clean_system() {
    clear
    purple "=== 系统清理 ==="
    echo ""
    yellow "正在识别系统包管理器并清理，请稍候..."
    echo ""
    green "1. 正在清理系统日志 (Journal)..."
    journalctl --vacuum-time=1s >/dev/null 2>&1
    journalctl --vacuum-size=50M >/dev/null 2>&1
    if command -v apt &>/dev/null; then
        green "2. 正在清理 Debian/Ubuntu 冗余组件..."
        apt autoremove --purge -y >/dev/null 2>&1
        apt clean -y >/dev/null 2>&1
        apt autoclean -y >/dev/null 2>&1
        apt remove --purge $(dpkg -l | awk '/^rc/ {print $2}') -y >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        apt remove --purge $(dpkg -l | awk '/^ii linux-(image|headers)-[^ ]+/{print $2}' | grep -v $(uname -r | sed 's/-.*//') | xargs) -y >/dev/null 2>&1

    elif command -v yum &>/dev/null; then
        green "2. 正在清理 CentOS/RHEL 冗余组件..."
        yum autoremove -y >/dev/null 2>&1
        yum clean all >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        yum remove $(rpm -q kernel | grep -v $(uname -r)) -y >/dev/null 2>&1

    elif command -v dnf &>/dev/null; then
        green "2. 正在清理 Fedora/New CentOS 冗余组件..."
        dnf autoremove -y >/dev/null 2>&1
        dnf clean all >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        dnf remove $(rpm -q kernel | grep -v $(uname -r)) -y >/dev/null 2>&1

    elif command -v apk &>/dev/null; then
        green "2. 正在清理 Alpine 冗余组件..."
        apk autoremove -y >/dev/null 2>&1
        apk clean >/dev/null 2>&1
        green "3. 正在移除旧内核..."
        apk del $(apk info -vv | grep -E 'linux-[0-9]' | grep -v $(uname -r) | awk '{print $1}') -y >/dev/null 2>&1
    else
        red "未检测到支持的包管理器，清理跳过。"
    fi

    echo ""
    green "系统清理完成！"
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..."
}
#s-ui面板
sui_panel_menu() {
    while true; do
        clear
        purple "=== sui 面板==="
        echo "--------------"
        green  "1. 安装 sui 面板"
        red    "2. 卸载 sui 面板"
        echo "--------------"
        purple "0. 返回上一级菜单"
        reading "请输入选择 [0-2]: " sub_choice
		case $sub_choice in
                  1)
                    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
                    read -n 1 -s -r -p "按任意键继续..."
					;;
                  2)
                    systemctl disable sing-box --now
                    systemctl disable s-ui --now

                    rm -f /etc/systemd/system/s-ui.service
                    systemctl daemon-reload

                    rm -fr /usr/local/s-ui
                    clear
                    echo -e "${green}sui面板已卸载${re}"
                    break_end
                    ;;
            0) break ;;
        esac
    done
}

# 3x-ui面板
xui_panel_menu() {
    while true; do
        clear
        purple "=== 3x-ui 面板 ==="
        echo "--------------"
        green  "1. 安装 3x-ui "
        red    "2. 卸载 3x-ui "
        echo "--------------"
        purple "0. 返回上一级菜单"
        echo "--------------"
        reading "请输入选择 [0-2]: " sub_choice
        case $sub_choice in
            1)
                yellow "正在获取 3x-ui 安装脚本..."
                bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
                echo ""
                read -n 1 -s -r -p "按任意键继续..."
                ;;
            2)
                yellow "正在卸载 3x-ui 并清理所有数据..."
                systemctl stop x-ui >/dev/null 2>&1
                systemctl disable x-ui >/dev/null 2>&1
                rm -f /etc/systemd/system/x-ui.service
                systemctl daemon-reload
                rm -rf /usr/local/x-ui
                rm -f /usr/bin/x-ui

                clear
                green "3x-ui 面板已卸载。"
                sleep 2
                break # 卸载完成返回上一级
                ;;
            0) 
                break 
                ;;
            *)
                red "无效输入，请输入 0-2"
                sleep 1
                ;;
        esac
    done
}

cloudreve_menu() {
    while true; do
        clear
        purple "=== Cloudreve 云盘 ==="
        echo "--------------"
        green  "1. 安装 Cloudreve "
		green  "2. 配置域名访问 "
        red    "3. 卸载 Cloudreve "
        echo "--------------"
        purple "0. 返回上一级菜单"
        reading "请输入选择 [0-2]: " cr_choice
        case $cr_choice in
            1)
                yellow "正在获取最新版本号..."
                new_version=$(curl -s https://api.github.com/repos/cloudreve/Cloudreve/releases/latest | grep tag_name | cut -d '"' -f 4)               
                if [ -z "$new_version" ]; then
                    red "获取版本号失败，请检查网络！"
                    sleep 2 ; break
                fi             
                arch=$(uname -m)
                [[ "$arch" == "x86_64" ]] && pkg="cloudreve_${new_version}_linux_amd64.tar.gz"
                [[ "$arch" == "aarch64" ]] && pkg="cloudreve_${new_version}_linux_arm64.tar.gz"
                mkdir -p /usr/local/cloudreve
                cd /usr/local/cloudreve             
                yellow "正在下载并解压 ${new_version}..."
                wget -q --show-progress "https://github.com/cloudreve/Cloudreve/releases/download/${new_version}/${pkg}"
                tar -zxf ${pkg} && chmod +x cloudreve
                rm -f ${pkg}
                cat > /etc/systemd/system/cloudreve.service <<EOF
[Unit]
Description=Cloudreve
After=network.target

[Service]
WorkingDirectory=/usr/local/cloudreve
ExecStart=/usr/local/cloudreve/cloudreve
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable cloudreve --now >/dev/null 2>&1            
                clear
                green "Cloudreve 安装并启动成功！"
                echo "------------------------------------------------"
                green "访问地址: http://$(curl -s ipv4.icanhazip.com):5212"
                echo "------------------------------------------------"
                read -n 1 -s -r -p "按任意键返回菜单..."
                ;;
			2)
                clear
                purple "=== 配置 Cloudreve 域名及 SSL === "
                yellow "注意：请确保域名已解析到此 IP！"
                echo ""
                check_and_issue_ssl
                if [ $? -ne 0 ]; then
                    red "证书申请环节出错，无法继续配置 HTTPS。"
                    sleep 2 ; continue
                fi               
                domain_name="$domain"
				local cl_conf="/usr/local/cloudreve/data/conf.ini"          
                if [ -f "$cl_conf" ]; then
                    if grep -q "Listen =" "$cl_conf"; then
                        sed -i 's/Listen =.*/Listen = 127.0.0.1:5212/' "$cl_conf"
                    else
                        echo -e "\n[System]\nListen = 127.0.0.1:5212" >> "$cl_conf"
                    fi
                    systemctl restart cloudreve
                else
                    red "未找到 Cloudreve 配置文件 $cl_conf，请先安装！"
                    sleep 2 && continue
                fi
                if ! command -v nginx &>/dev/null; then
                    yellow "正在安装 Nginx..."
                    manage_packages "install" "nginx"
                fi
                local conf_file="/etc/nginx/conf.d/cloudreve.conf"
                if [ -d "/etc/nginx/sites-available" ]; then
                    conf_file="/etc/nginx/sites-available/cloudreve.conf"
                    local symlink="/etc/nginx/sites-enabled/cloudreve.conf"
                fi
                cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name $domain_name;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain_name;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:5212;

        client_max_body_size 1024m;

		proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
                if [ -n "$symlink" ]; then
                    ln -sf "$conf_file" "$symlink"
                fi
                yellow "正在校验 Nginx 配置并重启..."
                if nginx -t >/dev/null 2>&1; then
                    systemctl restart nginx
                    green "HTTPS 域名访问配置成功！"
                    echo "------------------------------------------------"
                    green "访问地址: https://$domain_name"
                    echo "------------------------------------------------"
                else
                    red "Nginx 配置检测失败，请检查端口占用或配置文件。"
                fi
                read -n 1 -s -r -p "按任意键返回菜单..."
                ;;
            3)
                yellow "正在卸载并清理所有数据..."
                systemctl disable cloudreve --now >/dev/null 2>&1
                rm -f /etc/systemd/system/cloudreve.service
                systemctl daemon-reload
                rm -f /etc/nginx/sites-available/cloudreve.conf
                rm -f /etc/nginx/sites-enabled/cloudreve.conf
                rm -f /etc/nginx/conf.d/cloudreve.conf
                if nginx -t >/dev/null 2>&1; then
                    systemctl restart nginx >/dev/null 2>&1
                fi
                rm -rf /usr/local/cloudreve                     
                green "Cloudreve 已卸载"
                sleep 2
                break 
                ;;
            0) break ;;
        esac
    done
}

# File Browser 网盘
filebrowser_menu() {
    while true; do
        clear
        purple "=== File Browser 网盘管理 ==="
        echo "--------------"
        green  "1. 安装 File Browser"
        green  "2. 配置域名访问"
        red    "3. 卸载 File Browser"
        echo "--------------"
        purple "0. 返回上一级菜单"
        echo "--------------"
        reading "请输入选择 [0-3]: " fb_choice

        case $fb_choice in
            1)
                clear
                purple "=== 安装 File Browser ==="
                systemctl stop filebrowser >/dev/null 2>&1
                rm -rf /usr/local/filebrowser
                mkdir -p /usr/local/filebrowser
                yellow "正在执行官方安装脚本..."
                curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
                yellow "正在创建管理员账号 ..."          
                filebrowser -d /usr/local/filebrowser/filebrowser.db config init >/dev/null 2>&1
                filebrowser -d /usr/local/filebrowser/filebrowser.db config set --address 0.0.0.0 --port 8080 >/dev/null 2>&1
                filebrowser -d /usr/local/filebrowser/filebrowser.db users add admin admin12345678 --perm.admin >/dev/null 2>&1
                cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser
After=network.target

[Service]
User=root
WorkingDirectory=/usr/local/filebrowser
ExecStart=/usr/local/bin/filebrowser -d /usr/local/filebrowser/filebrowser.db
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable filebrowser --now
                
                echo ""
                if systemctl is-active --quiet filebrowser; then
                    green "================================================"
                    green "      File Browser 安装成功！"
                    green "================================================"
                    green "访问地址: http://$(curl -s ipv4.icanhazip.com):8080"
                    yellow "管理员账号: admin"
                    yellow "初始密码: admin12345678"
                    green "================================================"
                else
                    red "服务启动失败，请检查端口 8080 是否被占用。"
                fi
                
                read -n 1 -s -r -p "按任意键返回菜单..."
                ;;
            2)
                clear
                purple "=== 配置 File Browser 域名 SSL ==="
                check_and_issue_ssl
                [[ $? -ne 0 ]] && sleep 2 && continue
                domain_name="$domain"
                cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser
After=network.target

[Service]
User=root
WorkingDirectory=/usr/local/filebrowser
ExecStart=/usr/local/bin/filebrowser -d /usr/local/filebrowser/filebrowser.db --address 127.0.0.1 --port 8080
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl restart filebrowser
                local conf_file="/etc/nginx/conf.d/filebrowser.conf"
                [[ -d "/etc/nginx/sites-available" ]] && conf_file="/etc/nginx/sites-available/filebrowser.conf"
                cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name $domain_name;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    http2 on;
    server_name $domain_name;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;

    client_max_body_size 1024m;

    location / {
        proxy_pass http://127.0.0.1:8080;
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
                [[ -d "/etc/nginx/sites-enabled" ]] && ln -sf "$conf_file" "/etc/nginx/sites-enabled/"
                
                if nginx -t; then
                    systemctl restart nginx
                    echo "------------------------------------------------"
                    green "访问地址: https://$domain_name"
                    echo "------------------------------------------------"
                else
                    red "Nginx 配置错误，请检查！"
                fi
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            3)
                yellow "正在彻底卸载 File Browser..."
                systemctl disable filebrowser --now >/dev/null 2>&1
                rm -f /etc/systemd/system/filebrowser.service
                rm -f /usr/local/bin/filebrowser
                rm -rf /usr/local/filebrowser
                # 清理 Nginx
                rm -f /etc/nginx/conf.d/filebrowser.conf
                rm -f /etc/nginx/sites-available/filebrowser.conf
                rm -f /etc/nginx/sites-enabled/filebrowser.conf
                systemctl restart nginx >/dev/null 2>&1
                green "卸载完成"
                sleep 2 ; break
                ;;
            0) break ;;
        esac
    done
}


# --- 主菜单与逻辑循环 ---
while true; do
   clear
   echo ""
   green "1. 虚拟内存"
   green "2. 内存占用"
   green "3. 系统清理"
   green "4. S-UI面板"
   green "5. 3X-UI面板"
   green "6. Cloudreve云盘"
   green "7. FileBrowser网盘"
   green "8. 切换优先ipv4/ipv6"
   green "9. fanout"
   green "10. 三网回程测试"
   green "11. HE隧道"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择: " choice
   echo ""

   case $choice in
        1)
            add_swap
            ;;
		2)
            check_memory_usage
            ;;
        3)
            clean_system
            ;;
        4)
            sui_panel_menu
            ;;
		5)
            xui_panel_menu
            ;;
        6)
            cloudreve_menu
            ;;
		7)
            filebrowser_menu
            ;;
		8)
            clear
            GAI_CONF="/etc/gai.conf"

            echo ""
            if grep -qE '^\s*precedence\s+::ffff:0:0/96\s+100' "$GAI_CONF" 2>/dev/null; then
                echo "当前网络优先级设置: IPv4 优先"
            else
                echo "当前网络优先级设置: IPv6 优先"
            fi
            echo "------------------------"

            echo ""
            echo "切换的网络优先级"
            echo "------------------------"
            echo "1. IPv4 优先          2. IPv6 优先      3. 禁用 IPv6"
            echo "------------------------"
            read -p "选择优先的网络: " choice

            case $choice in
                1)
                    [ ! -f "${GAI_CONF}.bak" ] && cp "$GAI_CONF" "${GAI_CONF}.bak" 2>/dev/null
                    [ ! -f "$GAI_CONF" ] && touch "$GAI_CONF"
                    sed -i '/^\s*precedence\s\+::ffff:0:0\/96/d' "$GAI_CONF"
                    echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
                                       
                    v6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
                    if [ "$v6_disabled" -eq 1 ]; then
                        echo -e "\n${yellow}IPv6 已禁用，是否需要开启？[Y/N]${re}"
                        read -p "是否需要开启？[Y/N]" choice
                        if [[ "$choice" =~ [Yy] ]]; then
                            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
                            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
                            sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1
                
                            sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
                            sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
                            sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf

                            {
                                echo "net.ipv6.conf.all.disable_ipv6 = 0"
                                echo "net.ipv6.conf.default.disable_ipv6 = 0"
                                echo "net.ipv6.conf.lo.disable_ipv6 = 0"
                            } >> /etc/sysctl.conf

                            sysctl -p >/dev/null 2>&1
                        fi
                    fi
                    echo -e "\n${green}已切换为 IPv4 优先(IPv6 仍然可用，只是优先级降低)${re}\n"
                    ;;
                2)
                    [ ! -f "${GAI_CONF}.bak" ] && cp "$GAI_CONF" "${GAI_CONF}.bak" 2>/dev/null
                    [ ! -f "$GAI_CONF" ] && touch "$GAI_CONF"
                    # 移除 IPv4 优先规则即可恢复默认 IPv6 优先
                    sed -i '/^\s*precedence\s\+::ffff:0:0\/96/d' "$GAI_CONF"
                    sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1
                    echo -e "\n${green}已切换为 IPv6 优先(IPv4 仍然可用，只是优先级降低)${re}\n"
                    ;;
                3)
                    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
                    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
                    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1

                    sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
                    sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
                    sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf

                    {
                        echo "net.ipv6.conf.all.disable_ipv6 = 1"
                        echo "net.ipv6.conf.default.disable_ipv6 = 1"
                        echo "net.ipv6.conf.lo.disable_ipv6 = 1"
                    } >> /etc/sysctl.conf

                    sysctl -p >/dev/null 2>&1
                    sed -i '/^\s*precedence\s\+::ffff:0:0\/96/d' "$GAI_CONF" 2>/dev/null
                    echo -e "\n${yellow}✓ IPv6 已在系统层禁用${re}\n"
                    ;;
                *)
                    echo "无效的选择"
                    ;;
            esac
            ;;
		9) 
		    bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/fanout/main/install.sh)
		    echo ""
		    echo "----------------------------------------"
		    read -p "安装已完成，快捷命令f已创建, 按回车键返回主菜单..."
		    ;;
		10) 
		    bash <(curl -fsSL https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh)
		    ;;
		11) 
		    bash <(curl -fsSL https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/he-manager.sh)
		    ;;
        0)
            echo "退出脚本"
            exit 0
            ;;
        *)
            red "请输入正确的数字"
            sleep 1
            ;;
   esac
done

