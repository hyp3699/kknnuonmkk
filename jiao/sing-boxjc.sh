#!/bin/bash
set +e

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

    CONFIG_DIR="/etc/sing-box/conf"
    SINGBOX_BIN="/etc/sing-box/sing-box"

    echo
    echo -e "${CYAN}========== sing-box 配置检查 ==========${NC}"
    echo
    echo "检查目录：$CONFIG_DIR"
    echo "程序路径：$SINGBOX_BIN"
    echo

    if [ ! -x "$SINGBOX_BIN" ]; then
        echo -e "${RED}未找到 sing-box：$SINGBOX_BIN${NC}"
        echo
        read -r -p "按回车返回菜单..." _
        return
    fi

    if [ ! -d "$CONFIG_DIR" ]; then
        echo -e "${RED}配置目录不存在：$CONFIG_DIR${NC}"
        echo
        read -r -p "按回车返回菜单..." _
        return
    fi

    shopt -s nullglob
    files=("$CONFIG_DIR"/*.json)
    shopt -u nullglob

    if [ "${#files[@]}" -eq 0 ]; then
        echo -e "${YELLOW}没有找到 JSON 配置文件${NC}"
        echo
        read -r -p "按回车返回菜单..." _
        return
    fi

    total=0
    success=0
    failed=0
    error_files=()

    for config in "${files[@]}"; do
        total=$((total + 1))

        echo -e "${CYAN}--------------------------------------${NC}"
        echo -e "配置文件：${YELLOW}$config${NC}"

        output=$("$SINGBOX_BIN" check -c "$config" 2>&1)
        status=$?

        if [ "$status" -eq 0 ]; then
            echo -e "${GREEN}✓ 配置正常${NC}"
            success=$((success + 1))
        else
            echo -e "${RED}✗ 配置错误${NC}"
            echo

            translated=$(printf '%s\n' "$output" | trans -b :zh 2>/dev/null)

            if [ -n "$translated" ]; then
                echo "$translated"
            else
                echo "$output"
            fi

            failed=$((failed + 1))
            error_files+=("$config")
        fi

        echo
    done

    echo -e "${CYAN}======================================${NC}"
    echo "检查完成"
    echo "配置文件：$total"
    echo -e "正常：${GREEN}$success${NC}"
    echo -e "错误：${RED}$failed${NC}"
    echo -e "${CYAN}======================================${NC}"

    if [ "${#error_files[@]}" -gt 0 ]; then
        echo
        echo -e "${YELLOW}错误配置文件：${NC}"

        for i in "${!error_files[@]}"; do
            printf "%d. %s\n" "$((i + 1))" "${error_files[$i]}"
        done

        echo
        read -r -p "输入编号编辑配置，回车返回：" edit_choice

        if [[ "$edit_choice" =~ ^[0-9]+$ ]]; then
            index=$((edit_choice - 1))

            if [ "$index" -ge 0 ] && [ "$index" -lt "${#error_files[@]}" ]; then
                config="${error_files[$index]}"

                if command -v nano >/dev/null 2>&1; then
                    nano "$config"
                elif command -v vi >/dev/null 2>&1; then
                    vi "$config"
                else
                    echo -e "${RED}未找到 nano 或 vi 编辑器${NC}"
                    read -r -p "按回车继续..." _
                fi
            else
                echo -e "${RED}无效的编号${NC}"
                sleep 1
            fi
        fi
    fi

    echo
    read -r -p "按回车返回菜单..." _
}

main_menu() {
    while true; do
        clear
        echo
        echo -e "${CYAN}======================================${NC}"
        echo -e "${CYAN}       sing-box 错误查看 / 翻译${NC}"
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
