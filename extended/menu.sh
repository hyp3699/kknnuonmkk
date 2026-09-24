#!/usr/bin/env bash

# ============================================================
# 主菜单
# ============================================================
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
    green "Telegram群组: ${purple}https://t.me/eooceu${re}"
    green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
    green "${purple}快捷命令 sb 或者 b${re}  清屏 clear"
    purple "=== 老王sing-box四合一安装脚本 1.7 ===\n"
    printf "${purple}--Nginx 状态: %s${re}\n" \
        "$(to_chinese "$nginx_status")"
    singbox_start_time=$(systemctl show \
        -p ExecMainStartTimestamp \
        --value sing-box 2>/dev/null)
    if [ -n "$singbox_start_time" ]; then
        singbox_start_ts=$(date -d "$singbox_start_time" +%s 2>/dev/null)
        singbox_now_ts=$(date +%s)
        singbox_uptime=$((singbox_now_ts - singbox_start_ts))
        singbox_uptime_text="$(
            printf '%d天 %02d小时 %02d分钟 %02d秒' \
                $((singbox_uptime / 86400)) \
                $(((singbox_uptime % 86400) / 3600)) \
                $(((singbox_uptime % 3600) / 60)) \
                $((singbox_uptime % 60))
        )"
    else
        singbox_uptime_text="未运行"
    fi
    printf "${purple}singbox 状态: %s${re}\n" \
        "$(to_chinese "$singbox_status")"
    printf "${purple}singbox 运行: %s${re}\n\n" \
        "$singbox_uptime_text"
    printf "%b%-28s%b%s%b\n" \
        "$green" "1. 安装sing-box" \
        "$red" "10. 开启BBR" "$re"
    printf "%b%-28s%b%s%b\n" \
        "$green" "2. 卸载sing-box" \
        "$red" "11. 更新脚本" "$re"
    printf "%b%-28s%b%s%b\n" \
        "$green" "3. sing-box管理" \
        "$red" "12. iptables" "$re"
    printf "%b%-28s%b%s%b\n" \
        "$green" "4. cf管理" \
        "$red" "13. 快捷指令" "$re"
    printf "%b%-32s%b%s%b\n" \
        "$green" "5. 查看节点信息" \
        "$red" "14. 本机信息" "$re"
    printf "%b%-32s%b%s%b\n" \
        "$green" "6. 配置文件查看" \
        "$red" "15. WARP分流管理" "$re"
    printf "%b%-32s%b%s%b\n" \
        "$green" "7. 管理节点订阅" \
        "$red" "16. token" "$re"
    printf "%b%-28s%b\n" \
        "$green" "8. 更新sing-box" "$re"
    printf "%b%-32s%b\n" \
        "$green" "9. 添加删除节点" "$re"
    echo
    printf "%b%-32s%b%s%b\n" \
        "$green" "99. 查看错误信息" \
        "$red" "0. 退出脚步" "$re"
    echo
    reading "请输入数字选择: " choice
}
main_menu() {
    while true; do
        menu
        case "${choice}" in
            1)
                install_menu
                ;;
            2)
                uninstall_singbox
                ;;
            3)
                manage_singbox
                ;;
            4)
                manage_cf
                ;;
            5)
                check_nodes
                ;;
            6)
                edit_singbox_files
                ;;
            7)
                disable_open_sub
                ;;
            8)
                update_singbox
                ;;
            9)
                manage_nodes_menu
                ;;
            10)
                bbr_menu
                ;;
            11)
                update_script
                ;;
            12)
                iptables_ssl
                ;;
            13)
                shortcut_menu
                ;;
            14)
                vps_s
                ;;
            15)
                warp_manage
                ;;
            16)
                token_manage
                ;;
            99)
                show_error
                ;;
            0)
                exit 0
                ;;
            *)
                red "无效的选项"
                ;;
        esac
        echo
        read -n 1 -s -r -p \
            $'\033[1;91m按任意键返回...\033[0m'
    done
}
