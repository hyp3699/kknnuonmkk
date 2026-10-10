#!/bin/bash
# --- 基础配置 ---
BASE_DIR="/etc/sing-box"
CONFIG_FILE="$BASE_DIR/conf/config.json"
SB_BIN=""
ARGO_BIN=""
ARCH="amd64"
# --- 颜色与格式定义 ---
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
PURPLE="\033[1;35m"
BLUE="\033[1;34m"
RESET="\033[0m"
# 搜索二进制文件逻辑
scan_bins() {
    SB_BIN=""
    ARGO_BIN=""
    if [ -d "$BASE_DIR" ]; then
        [ -x "$BASE_DIR/sing-box" ] && SB_BIN="$BASE_DIR/sing-box"
        [ -x "$BASE_DIR/cloudflared" ] && ARGO_BIN="$BASE_DIR/cloudflared"
        [ -x "$BASE_DIR/argo" ] && ARGO_BIN="$BASE_DIR/argo"
    fi
    if [ -z "$SB_BIN" ] || [ -z "$ARGO_BIN" ]; then
        for dir in "/usr/bin" "/usr/local/bin" "/root"; do
            [ -d "$dir" ] || continue
            [ -z "$SB_BIN" ] && SB_BIN=$(find "$dir" -maxdepth 1 -type f -executable -name "sing-box*" ! -name "*.bak" 2>/dev/null | head -n 1)
            [ -z "$ARGO_BIN" ] && ARGO_BIN=$(find "$dir" -maxdepth 1 -type f -executable \( -name "cloudflared*" -o -name "argo*" \) 2>/dev/null | head -n 1)
        done
    fi
    [ -z "$SB_BIN" ] && SB_BIN="/usr/local/bin/sing-box"
}
detect_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo -e "${RED}❌ 不支持的架构${RESET}"; exit 1 ;;
    esac
}
get_current_version() {
    if [ -x "$1" ]; then
        local first_line=$("$1" version 2>/dev/null | head -n 1)
        local ver=$(echo "$first_line" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?')
        [ -n "$ver" ] && echo "$ver" || echo "$first_line" | awk '{print $1,$2}'
    else
        echo "未安装"
    fi
}
# --- 版本获取 ---
get_latest_stable() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}
get_latest_prerelease() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | grep '"tag_name":' | head -n 10 | grep -E "alpha|beta|rc" | head -n 1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}
get_latest_v2rayapi() {
    curl -fsSL "https://api.github.com/repos/hyp3699/kknnuonmkk/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}
get_latest_xhttp_v2rayapi() {
    curl -fsSL \
        "https://api.github.com/repos/hyp3699/sssssssssssiiii/releases" |
    jq -r '[.[] |
        select(.prerelease==false) |
        select(.draft==false) |
        select(.tag_name | endswith("-xhttp"))
    ][0].tag_name'
}
get_latest_argo() {
    curl -s "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/'
}
# 检查配置文件
check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}❌ 配置文件不存在: $CONFIG_FILE${RESET}"
        return 1
    fi
    return 0
}
# 检查 Python3
check_python3() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}❌ 系统没有安装 python3，无法安全修改 JSON 配置。${RESET}"
        return 1
    fi
    return 0
}
# 配置 V2Ray API
# 参数:
# enable = 编译版，确保存在 v2ray_api
# disable = 原版，删除 v2ray_api
configure_v2ray_api() {
    local mode="$1"
    check_config_file || return 1
    check_python3 || return 1
    local backup="${CONFIG_FILE}.before-v2ray-api.$(date +%Y%m%d%H%M%S).bak"
    cp -a "$CONFIG_FILE" "$backup" || {
        echo -e "${RED}❌ 无法备份配置文件。${RESET}"
        return 1
    }
    echo -e "${BLUE}▶ 正在检查 V2Ray API 配置...${RESET}"
    if python3 - "$CONFIG_FILE" "$mode" <<'PY'
import json
import sys
config_file = sys.argv[1]
mode = sys.argv[2]
try:
    with open(config_file, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"❌ JSON 配置读取失败: {e}")
    sys.exit(1)
if not isinstance(data, dict):
    print("❌ 配置文件不是 JSON 对象")
    sys.exit(1)
experimental = data.get("experimental")
if experimental is None:
    experimental = {}
    data["experimental"] = experimental
if not isinstance(experimental, dict):
    print("❌ experimental 不是 JSON 对象")
    sys.exit(1)
if mode == "enable":
    if "v2ray_api" in experimental:
        print("ℹ️ 已存在 experimental.v2ray_api，不修改。")
    else:
        experimental["v2ray_api"] = {
            "listen": "127.0.0.1:9094",
            "stats": {
                "enabled": True,
                "users": []
            }
        }
        print("✅ 已添加 experimental.v2ray_api。")
elif mode == "disable":
    if "v2ray_api" in experimental:
        del experimental["v2ray_api"]
        print("✅ 已删除 experimental.v2ray_api。")
    else:
        print("ℹ️ 未发现 experimental.v2ray_api，无需删除。")
if "experimental" in data and isinstance(data["experimental"], dict) and not data["experimental"]:
    del data["experimental"]
with open(config_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    then
        echo -e "${GREEN}✅ 配置修改完成。${RESET}"
    else
        echo -e "${RED}❌ 配置修改失败，正在恢复备份...${RESET}"
        cp -af "$backup" "$CONFIG_FILE"
        rm -f "$backup"
        return 1
    fi
    echo -e "${BLUE}▶ 正在检查 sing-box 配置...${RESET}"
    if "$SB_BIN" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ sing-box 配置检查通过。${RESET}"
        rm -f "$backup"
        return 0
    else
        echo -e "${RED}❌ sing-box 配置检查失败，正在恢复修改前的配置...${RESET}"
        cp -af "$backup" "$CONFIG_FILE"
        rm -f "$backup"
        echo -e "${YELLOW}🔄 配置已经恢复。${RESET}"
        return 1
    fi
}
update_sb() {
    local tag="$1"
    [ -z "$tag" ] && return
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${tag#v}-linux-${ARCH}.tar.gz"
    local tmp
    tmp=$(mktemp -d)
    echo -e "${BLUE}▶ 正在从官方源下载 [ ${tag} ]...${RESET}"
    if curl -fL -o "$tmp/sb.tgz" "$url"; then
        if ! tar -xzf "$tmp/sb.tgz" -C "$tmp"; then
            echo -e "${RED}❌ 解压失败。${RESET}"
            rm -rf "$tmp"
            return 1
        fi
        if [ ! -f "$tmp"/sing-box*/sing-box ]; then
            echo -e "${RED}❌ 下载包中没有找到 sing-box。${RESET}"
            rm -rf "$tmp"
            return 1
        fi
        [ -f "$SB_BIN" ] && cp "$SB_BIN" "$SB_BIN.bak" 2>/dev/null
        if ! cp "$tmp"/sing-box*/sing-box "$SB_BIN"; then
            echo -e "${RED}❌ 替换 sing-box 失败。${RESET}"
            rm -rf "$tmp"
            return 1
        fi
        chmod +x "$SB_BIN"
        echo -e "${BLUE}▶ 官方版不包含 V2Ray API，检查并删除旧 V2Ray API 配置...${RESET}"
        if ! configure_v2ray_api "disable"; then
            echo -e "${RED}❌ V2Ray API 配置处理失败，正在恢复 sing-box 二进制...${RESET}"
            if [ -f "$SB_BIN.bak" ]; then
                mv -f "$SB_BIN.bak" "$SB_BIN"
                chmod +x "$SB_BIN"
            fi
            rm -rf "$tmp"
            return 1
        fi
        rm -f "$SB_BIN.bak" 2>/dev/null
        systemctl restart sing-box 2>/dev/null
        sleep 1
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}✅ 官方版本更新成功，sing-box 已正常运行!${RESET}"
        else
            echo -e "${RED}❌ sing-box 更新后没有正常运行，请检查日志。${RESET}"
            journalctl -u sing-box -n 20 --no-pager
        fi
    else
        echo -e "${RED}❌ 下载失败，请检查网络环境。${RESET}"
    fi
    rm -rf "$tmp"
}
update_v2rayapi() {
    local tag="$1"
    [ -z "$tag" ] && return
    local url="https://github.com/hyp3699/kknnuonmkk/releases/download/${tag}/sing-box"
    local tmp
    tmp=$(mktemp -d)
    echo -e "${BLUE}▶ 正在从编译版 Release 下载 [ ${tag} ]...${RESET}"
    if curl -fL -o "$tmp/sing-box" "$url"; then
        if [ ! -s "$tmp/sing-box" ]; then
            echo -e "${RED}❌ 下载文件为空。${RESET}"
            rm -rf "$tmp"
            return 1
        fi
        chmod +x "$tmp/sing-box"
        if ! "$tmp/sing-box" version >/dev/null 2>&1; then
            echo -e "${RED}❌ 新下载的编译版 sing-box 无法运行。${RESET}"
            rm -rf "$tmp"
            return 1
        fi
        [ -f "$SB_BIN" ] && cp "$SB_BIN" "$SB_BIN.bak" 2>/dev/null
        mv "$tmp/sing-box" "$SB_BIN"
        chmod +x "$SB_BIN"
        echo -e "${BLUE}▶ 编译版需要 V2Ray API，检查并添加配置...${RESET}"
        if ! configure_v2ray_api "enable"; then
            echo -e "${RED}❌ V2Ray API 配置失败，正在恢复旧版本...${RESET}"
            if [ -f "$SB_BIN.bak" ]; then
                mv -f "$SB_BIN.bak" "$SB_BIN"
                chmod +x "$SB_BIN"
            fi
            rm -rf "$tmp"
            return 1
        fi
        rm -f "$SB_BIN.bak" 2>/dev/null
        systemctl restart sing-box 2>/dev/null
        sleep 1
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}✅ V2Ray API 编译版更新成功，sing-box 已正常运行!${RESET}"
        else
            echo -e "${RED}❌ 编译版更新后 sing-box 没有正常运行，请检查日志。${RESET}"
            journalctl -u sing-box -n 30 --no-pager
        fi
    else
        echo -e "${RED}❌ 编译版下载失败，请检查网络环境。${RESET}"
    fi
    rm -rf "$tmp"
}
update_xhttp_v2rayapi() {
    local tag="$1"
    [ -z "$tag" ] && return
    local url="https://github.com/hyp3699/sssssssssssiiii/releases/download/${tag}/sing-box-linux-amd64.tar.gz"
    local tmp
    local new_sb
    tmp=$(mktemp -d)
    echo -e "${BLUE}▶ 正在从 xhttp-V2Ray API Release 下载 [ ${tag} ]...${RESET}"
    if ! curl -fL -o "$tmp/sb.tgz" "$url"; then
        echo -e "${RED}❌ xhttp-V2Ray API 下载失败，请检查网络环境。${RESET}"
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "$tmp/sb.tgz" -C "$tmp"; then
        echo -e "${RED}❌ xhttp-V2Ray API 解压失败。${RESET}"
        rm -rf "$tmp"
        return 1
    fi
    new_sb=$(find "$tmp" -type f -name "sing-box" | head -n 1)
    if [ -z "$new_sb" ] || [ ! -f "$new_sb" ]; then
        echo -e "${RED}❌ 下载包中没有找到 sing-box。${RESET}"
        rm -rf "$tmp"
        return 1
    fi
    chmod +x "$new_sb"
    if ! "$new_sb" version >/dev/null 2>&1; then
        echo -e "${RED}❌ 新下载的 xhttp-V2Ray API 编译版无法运行。${RESET}"
        rm -rf "$tmp"
        return 1
    fi
    echo -e "${GREEN}▶ 新版本文件检查通过。${RESET}"
    if [ -f "$SB_BIN" ]; then
        cp -af "$SB_BIN" "$SB_BIN.bak" 2>/dev/null || {
            echo -e "${RED}❌ 备份当前 sing-box 失败。${RESET}"
            rm -rf "$tmp"
            return 1
        }
    fi
    echo -e "${BLUE}▶ 正在停止 sing-box...${RESET}"
    systemctl stop sing-box 2>/dev/null
    echo -e "${BLUE}▶ 正在替换 sing-box...${RESET}"
    if ! mv -f "$new_sb" "$SB_BIN"; then
        echo -e "${RED}❌ 替换 sing-box 失败，正在恢复旧版本...${RESET}"

        if [ -f "$SB_BIN.bak" ]; then
            cp -af "$SB_BIN.bak" "$SB_BIN"
            chmod 755 "$SB_BIN"
        fi
        systemctl start sing-box 2>/dev/null
        rm -rf "$tmp"
        return 1
    fi
    chown root:root "$SB_BIN"
    chmod 755 "$SB_BIN"
    echo -e "${BLUE}▶ xhttp-V2Ray API 需要 V2Ray API，检查并添加配置...${RESET}"
    if ! configure_v2ray_api "enable"; then
        echo -e "${RED}❌ V2Ray API 配置失败，正在恢复旧版本...${RESET}"
        rm -f "$SB_BIN"
        if [ -f "$SB_BIN.bak" ]; then
            mv -f "$SB_BIN.bak" "$SB_BIN"
            chmod 755 "$SB_BIN"
        fi
        systemctl start sing-box 2>/dev/null
        rm -rf "$tmp"
        return 1
    fi
    rm -f "$SB_BIN.bak" 2>/dev/null
    echo -e "${BLUE}▶ 正在启动 xhttp-V2Ray API 版 sing-box...${RESET}"
    systemctl start sing-box 2>/dev/null
    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ xhttp-V2Ray API 更新成功，sing-box 已正常运行!${RESET}"
        echo
        echo -e "${GREEN}版本信息:${RESET}"
        "$SB_BIN" version 2>/dev/null | head -n 1
    else
        echo -e "${RED}❌ xhttp-V2Ray API 更新后 sing-box 没有正常运行。${RESET}"
        echo
        journalctl -u sing-box -n 30 --no-pager
    fi
    rm -rf "$tmp"
}
update_argo() {
    local tag
    tag=$(get_latest_argo)
    local url="https://github.com/cloudflare/cloudflared/releases/download/${tag}/cloudflared-linux-${ARCH}"
    echo -e "${BLUE}▶ 正在停止正在运行的 Argo 服务...${RESET}"
    systemctl stop argo 2>/dev/null
    pkill -f "$ARGO_BIN" 2>/dev/null
    echo -e "${BLUE}▶ 正在下载 Cloudflared Argo...${RESET}"
    [ -f "$ARGO_BIN" ] && cp "$ARGO_BIN" "$ARGO_BIN.bak" 2>/dev/null
    if curl -fL -o "$ARGO_BIN" "$url"; then
        chmod +x "$ARGO_BIN"
        echo -e "${BLUE}▶ 正在启动最新版 Argo...${RESET}"
        systemctl start argo 2>/dev/null
        echo -e "${GREEN}✅ Argo 更新成功并已启动!${RESET}"
        rm -f "$ARGO_BIN.bak" 2>/dev/null
    else
        echo -e "${RED}❌ 下载失败，正在恢复旧版本...${RESET}"
        if [ -f "$ARGO_BIN.bak" ]; then
            mv -f "$ARGO_BIN.bak" "$ARGO_BIN"
            chmod +x "$ARGO_BIN"
            systemctl start argo 2>/dev/null
            echo -e "${YELLOW}🔄 已成功恢复并启动旧版本程序。${RESET}"
        else
            echo -e "${RED}❌ 未找到旧版本备份，请手动检查。${RESET}"
        fi
    fi
}
# --- 主循环界面 ---
while true; do
    clear
    scan_bins
    detect_arch
    echo -e "${YELLOW}=================================================${RESET}"
    echo -e "           ${GREEN}SING-BOX 更新${RESET}"
    echo -e "${YELLOW}=================================================${RESET}"
    echo -e "${BLUE}程序路径:${RESET}"
    echo -e "  sing-box:  ${RED}${SB_BIN:-未找到}${RESET}"
    echo -e "  argo:      ${RED}${ARGO_BIN:-未找到}${RESET}"
    echo
    echo -e "${BLUE}当前版本信息:${RESET}"
    echo -e "  sing-box:  ${RED}$(get_current_version "$SB_BIN")${RESET}"
    echo -e "  argo:      ${RED}$(get_current_version "$ARGO_BIN")${RESET}"
    echo -e "  系统架构:  ${RED}$ARCH${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo -e "${GREEN}正在获取版本信息...${RESET}"
    v_stable=$(get_latest_stable)
    v_pre=$(get_latest_prerelease)
    v_v2rayapi=$(get_latest_v2rayapi)
    v_xhttp_v2rayapi=$(get_latest_xhttp_v2rayapi)
    v_argo=$(get_latest_argo)
    echo -e "1) ${GREEN}更新 sing-box${RESET}  [ ${YELLOW}官方稳定版: ${v_stable:-获取中}${RESET} ]"
    echo -e "2) ${GREEN}更新 sing-box${RESET}  [ ${YELLOW}官方测试版: ${v_pre:-获取中}${RESET} ]"
    echo -e "3) ${GREEN}更新 sing-box${RESET}  [ ${YELLOW}V2Ray API 编译版: ${v_v2rayapi:-获取中}${RESET} ]"
    echo -e "4) ${GREEN}更新 sing-box${RESET}  [ ${YELLOW}xhttp-v2rayapi: ${v_xhttp_v2rayapi:-获取中}${RESET} ]"
    echo -e "5) ${GREEN}更新 argo   ${RESET}  [ ${YELLOW}最新版本: ${v_argo:-获取中}${RESET} ]"
    echo -e "0) ${RED}退出程序${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo
    read -p "请输入序号并回车: " choice
    case "$choice" in
        1) update_sb "$v_stable" ;;
        2) update_sb "$v_pre" ;;
        3) update_v2rayapi "$v_v2rayapi" ;;
        4) update_xhttp_v2rayapi "$v_xhttp_v2rayapi" ;;
        5) update_argo ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请输入 0-4 之间的数字。${RESET}" ;;
    esac
    echo
    read -p "按回车键继续..."
done
