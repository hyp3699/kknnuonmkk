#!/usr/bin/env bash

# ============================================================
# 主菜单
# ============================================================
MODULE_DIR="/etc/sing-box"
source "$MODULE_DIR/core.sh"
source "$MODULE_DIR/install.sh"
source "$MODULE_DIR/service.sh"
source "$MODULE_DIR/nodes.sh"
source "$MODULE_DIR/subscription.sh"
source "$MODULE_DIR/config.sh"
source "$MODULE_DIR/cf.sh"
source "$MODULE_DIR/bbr.sh"
source "$MODULE_DIR/firewall.sh"
source "$MODULE_DIR/warp.sh"
source "$MODULE_DIR/token.sh"
source "$MODULE_DIR/system.sh"

export LANG=en_US.UTF-8
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


menu() {
    local singbox_status
    local nginx_status
    local singbox_start_time
    local singbox_start_ts
    local singbox_now_ts
    local singbox_uptime
    local singbox_uptime_text
   singbox_status=$(check_singbox 2>/dev/null)
   nginx_status=$(check_nginx 2>/dev/null)
   
   clear
   echo ""
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
            
