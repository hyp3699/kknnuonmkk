#!/bin/bash

set +e
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

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请使用 root 用户运行${NC}"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$ID"
else
    OS="unknown"
fi

install_dependencies() {
    local need_install=0
    command -v curl >/dev/null 2>&1 || need_install=1
    command -v python3 >/dev/null 2>&1 || need_install=1
    command -v gawk >/dev/null 2>&1 || need_install=1

    if [ "$need_install" -eq 1 ]; then
        echo -e "${YELLOW}正在安装依赖...${NC}"
        case "$OS" in
            debian|ubuntu|linuxmint|kali)
                apt-get update -y
                apt-get install -y curl python3 gawk
                ;;
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf >/dev/null 2>&1; then
                    dnf install -y curl python3 gawk
                else
                    yum install -y curl python3 gawk
                fi
                ;;
            alpine)
                apk add --no-cache curl python3 gawk
                ;;
            arch|manjaro)
                pacman -Sy --noconfirm curl python gawk
                ;;
            *)
                echo -e "${RED}无法识别系统：$OS${NC}"
                exit 1
                ;;
        esac
    fi

    if ! command -v trans >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 translate-shell...${NC}"
        curl -L --fail --connect-timeout 15 --max-time 60 \
            https://git.io/trans -o /usr/local/bin/trans
        if [ $? -ne 0 ]; then
            echo -e "${RED}translate-shell 安装失败${NC}"
            exit 1
        fi
        chmod +x /usr/local/bin/trans
    fi

    for cmd in curl python3 gawk trans; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}缺少依赖：$cmd${NC}"
            exit 1
        fi
    done
}



translate_logs() {
    local logfile="$1"

    python3 - "$logfile" <<'PY'
import sys
import subprocess
import re

filename = sys.argv[1]

with open(filename, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

pattern = re.compile(
    r"ERROR|FATAL|PANIC|failed|failure|invalid|unable|cannot|"
    r"unexpected|timeout|timed out|connection refused|"
    r"permission denied|address already in use|exception|critical|crash",
    re.I
)

seen = set()
errors = []

for line in lines:
    if "sing-box[" not in line:
        continue
    if not pattern.search(line):
        continue

    normalized = re.sub(r"sing-box\[\d+\]", "sing-box[PID]", line)
    normalized = re.sub(
        r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d\d:\d\d:\d\d\b",
        "TIME",
        normalized
    )
    normalized = re.sub(
        r"\b\d{1,2}月\d{1,2}日\d\d:\d\d:\d\d\b",
        "TIME",
        normalized
    )

    if normalized in seen:
        continue

    seen.add(normalized)
    errors.append(line)

if not errors:
    print("未发现 sing-box 错误信息")
    sys.exit(0)

for line in errors:
    try:
        result = subprocess.run(
            ["trans", "-b", ":zh", line],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15
        )
        translated = result.stdout.strip()
        print(translated if translated else line)
    except Exception:
        print(line)
PY
}

show_latest_start_errors() {
    clear

    echo
    echo -e "${CYAN}========== 最近一次 sing-box 启动错误 ==========${NC}"
    echo

    START_TIME=$(systemctl show sing-box -p ExecMainStartTimestamp --value 2>/dev/null)

    if [ -z "$START_TIME" ] || [ "$START_TIME" = "n/a" ]; then
        echo -e "${YELLOW}无法获取最近一次 sing-box 启动时间${NC}"
        echo
        read -r -p "按回车返回菜单..." _
        return
    fi

    START_TIME=$(date -d "$START_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

    if [ -z "$START_TIME" ]; then
        echo -e "${YELLOW}无法解析 sing-box 启动时间${NC}"
        echo
        read -r -p "按回车返回菜单..." _
        return
    fi

    echo "启动时间：$START_TIME"
    echo

    TMP_LOG=$(mktemp)

    journalctl -u sing-box \
        --since "$START_TIME" \
        --no-pager \
        > "$TMP_LOG" 2>&1

    translate_logs "$TMP_LOG"

    rm -f "$TMP_LOG"

    echo
    echo -e "${CYAN}==============================================${NC}"
    echo
    read -r -p "按回车返回菜单..." _
}

check_configs() {
    clear
    green "================ JSON 配置检查 ================"
    echo

    local errors=()
    local file=""
    local result=""
    local choice=""
    local content=""
    local i=1

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
    done < <(
        find "/etc/sing-box/conf" -maxdepth 1 \
            -type f -name "*.json" -print | sort
    )

    echo

    if [ "${#errors[@]}" -eq 0 ]; then
        green "全部 JSON 配置文件检查通过"
        echo
        read -rp "按回车返回..." _
        return
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
        return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] &&
       [ "$choice" -ge 1 ] &&
       [ "$choice" -le "${#errors[@]}" ]; then

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
}

main_menu() {
    while true; do
        clear
        echo
        echo -e "${CYAN}======================================${NC}"
        echo -e "${CYAN}       sing-box 错误检查${NC}"
        echo -e "${CYAN}======================================${NC}"
        echo
        echo "  1. 本次启动错误日志"
        echo "  2. 最近 50 条错误日志"
        echo "  3. 检查 sing-box 配置"
        echo "  0. 返回"
        echo
        read -r -p "请选择 [0-3]: " choice

        case "$choice" in
            1)
                 show_latest_start_errors
                 ;;
            2)
                show_logs "最近 50 条错误日志" \
                    "journalctl -u sing-box -n 50 --no-pager"
                ;;
            3)
                check_configs
                ;;
            0)
                clear
                exit 0
                ;;
            *)
                echo
                echo -e "${RED}请输入 0-3${NC}"
                sleep 1
                ;;
        esac
    done
}

install_dependencies
main_menu
