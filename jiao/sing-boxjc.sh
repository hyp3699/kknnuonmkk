#!/bin/bash

# ==========================================
# sing-box 错误查看 / 翻译工具
# ==========================================

set +e

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

# ==========================================
# Root
# ==========================================

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请使用 root 用户运行${NC}"
    exit 1
fi

# ==========================================
# 检测系统
# ==========================================

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$ID"
else
    OS="unknown"
fi

# ==========================================
# 安装依赖
# ==========================================

install_dependencies() {

    echo
    echo -e "${YELLOW}正在检测依赖...${NC}"

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

    # ======================================
    # translate-shell
    # ======================================

    if ! command -v trans >/dev/null 2>&1; then

        echo -e "${YELLOW}正在安装 translate-shell...${NC}"

        curl -L --fail \
            --connect-timeout 15 \
            --max-time 60 \
            https://git.io/trans \
            -o /usr/local/bin/trans

        if [ $? -ne 0 ]; then
            echo -e "${RED}translate-shell 安装失败${NC}"
            exit 1
        fi

        chmod +x /usr/local/bin/trans
    fi

    # ======================================
    # 最终检测
    # ======================================

    for cmd in curl python3 gawk trans; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}缺少依赖：$cmd${NC}"
            exit 1
        fi
    done

    echo -e "${GREEN}依赖检测完成${NC}"
}

# ==========================================
# 翻译错误日志
# ==========================================

translate_logs() {

    local logfile="$1"

    python3 - "$logfile" <<'PY'
import sys
import subprocess
import re

filename = sys.argv[1]

with open(filename, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

seen = set()
errors = []

pattern = re.compile(
    r"\b("
    r"ERROR|FATAL|PANIC|"
    r"error|fatal|panic|"
    r"failed|failure|"
    r"invalid|unable|cannot|"
    r"unexpected|timeout|"
    r"timed out|"
    r"connection refused|"
    r"permission denied|"
    r"address already in use|"
    r"exception|critical|crash"
    r")\b",
    re.IGNORECASE
)

for line in lines:

    if not pattern.search(line):
        continue

    # PID 去重
    normalized = re.sub(
        r"sing-box\[\d+\]",
        "sing-box[PID]",
        line
    )

    # 时间去重
    normalized = re.sub(
        r"\b[A-Z][a-z]{2}\s+\d{1,2}\s+\d\d:\d\d:\d\d\b",
        "TIME",
        normalized
    )

    if normalized in seen:
        continue

    seen.add(normalized)
    errors.append(line)

if not errors:
    print("未发现错误信息")
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

        if translated:
            print(translated)
        else:
            print(line)

    except Exception:
        print(line)

PY
}

# ==========================================
# 普通命令
# ==========================================

run_command() {

    local cmd="$1"

    clear

    echo
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}正在执行${NC}"
    echo -e "${CYAN}$cmd${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo

    TMP_LOG=$(mktemp)

    bash -c "$cmd" >"$TMP_LOG" 2>&1

    STATUS=$?

    echo
    echo -e "${CYAN}========== 错误信息 ==========${NC}"

    translate_logs "$TMP_LOG"

    echo -e "${CYAN}==============================${NC}"

    rm -f "$TMP_LOG"

    echo
    echo -e "${YELLOW}命令退出状态：$STATUS${NC}"
    echo

    read -r -p "按回车返回菜单..." _
}

# ==========================================
# 实时错误
# ==========================================

live_logs() {

    clear

    echo
    echo -e "${CYAN}========== sing-box 实时错误 ==========${NC}"
    echo
    echo "按 Ctrl+C 返回"
    echo

    journalctl -u sing-box -f --no-pager |
    while IFS= read -r line; do

        if echo "$line" | grep -Eiq \
            'ERROR|FATAL|PANIC|failed|failure|invalid|unable|cannot|unexpected|timeout|refused|permission denied|address already in use|exception|critical|crash'
        then

            result=$(timeout 15 trans -b :zh "$line" 2>/dev/null)

            if [ -n "$result" ]; then
                echo "$result"
            else
                echo "$line"
            fi

        fi

    done
}

# ==========================================
# 检查所有 sing-box JSON 配置
# ==========================================
check_configs() {

    clear

    echo
    echo -e "${CYAN}========== sing-box 配置检查 ==========${NC}"
    echo
    echo "检查目录：/etc/sing-box/conf/"
    echo "程序路径：/etc/sing-box/sing-box"
    echo

    CONFIG_DIR="/etc/sing-box/conf"
    SINGBOX_BIN="/etc/sing-box/sing-box"

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

    # 保存错误文件
    error_files=()

    for config in "${files[@]}"; do

        total=$((total + 1))

        echo
        echo -e "${CYAN}--------------------------------------${NC}"
        echo -e "配置文件：${YELLOW}$config${NC}"
        echo -e "${CYAN}--------------------------------------${NC}"

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

            # 保存错误文件
            error_files+=("$config")

        fi

    done

    echo
    echo -e "${CYAN}======================================${NC}"
    echo "检查完成"
    echo "配置文件：$total"
    echo -e "正常：${GREEN}$success${NC}"
    echo -e "错误：${RED}$failed${NC}"
    echo -e "${CYAN}======================================${NC}"

    # 有错误文件才显示编辑菜单
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

                echo
                echo -e "${CYAN}正在编辑：${YELLOW}$config${NC}"
                echo

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

# ==========================================
# 主菜单
# ==========================================

main_menu() {

    while true; do

        clear

        echo
        echo -e "${CYAN}======================================${NC}"
        echo -e "${CYAN}       sing-box 错误查看 / 翻译${NC}"
        echo -e "${CYAN}======================================${NC}"
        echo
        echo "  1. 查看最近 50 条日志"
        echo "  2. 只查看错误日志"
        echo "  3. 查看当前启动日志"
        echo "  4. 实时查看错误"
        echo "  5. 检查 sing-box 配置"
        echo "  6. 查看监听端口"
        echo "  0. 返回"
        echo
        read -r -p "请选择 [0-6]: " choice

        case "$choice" in

            1)
                run_command \
                "journalctl -u sing-box -n 50 --no-pager"
                ;;

            2)
                run_command \
                "journalctl -u sing-box -n 100 --no-pager | grep -Ei 'FATAL|ERROR|PANIC|failed|failure|invalid|unable|cannot|unexpected|timeout|refused|permission denied|address already in use|exception|critical|crash'"
                ;;

            3)
                run_command \
                "journalctl -u sing-box -b --no-pager"
                ;;

            4)
                live_logs
                ;;

            5)
                check_configs
                ;;

            6)
                run_command \
                "ss -lntup | grep sing-box"
                ;;

            0)
                clear
                exit 0
                ;;

            *)
                echo
                echo -e "${RED}请输入 0-6${NC}"
                sleep 1
                ;;

        esac

    done
}

# ==========================================
# 启动
# ==========================================

install_dependencies

main_menu
