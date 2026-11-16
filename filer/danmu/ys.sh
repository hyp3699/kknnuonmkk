#!/usr/bin/env bash
# 影视播放器管理（弹幕 2525 + 精简网页播放器 3003）  快捷命令：ys
RAW=https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu
APP_DIR=/opt/danmu
re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
pause() { read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'; echo; }
[ "$(id -u)" = 0 ] || { red "请用 root 运行"; exit 1; }

env_of() { systemctl show -p Environment --value danmu 2>/dev/null | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }
port() { p=$(env_of PORT); echo "${p:-2525}"; }
web_port() { p=$(env_of WEB_PORT); echo "${p:-3003}"; }
web_on() { [ "$(env_of WEB)" = 1 ]; }
ip() { curl -s4 -m 3 ifconfig.me 2>/dev/null || echo 你的IP; }

install_web() {
  curl -fsSL "$RAW/deploy.sh?t=$(date +%s)" -o /tmp/danmu_deploy.sh && MODE=web bash /tmp/danmu_deploy.sh
}

show_status() {
  if ! systemctl list-unit-files danmu.service >/dev/null 2>&1 || [ ! -f "$APP_DIR/danmu_server.py" ]; then
    yellow "未安装"; return
  fi
  local st ver
  st=$(systemctl is-active danmu 2>/dev/null)
  ver=$(curl -s -m 3 "http://127.0.0.1:$(port)/version")
  echo "弹幕服务：$st  版本：${ver:-?}  端口：$(port)"
  if web_on; then
    echo "网页播放器：开启  端口：$(web_port)"
  else
    echo "网页播放器：未开启（选 1 安装精简网页版）"
  fi
  echo "采集站数量：$(python3 -c "import json;print(len(json.load(open('$APP_DIR/www/jjoo.json'))['sites']))" 2>/dev/null || echo ?)"
  echo "采集站下次更新：$(systemctl list-timers danmu-sites.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')"
}

show_urls() {
  local I; I=$(ip)
  green "OK影视 配置：http://$I:$(port)/sub/jjoo.json"
  green "弹幕接口：  http://$I:$(port)/danmu?name={name}&episode={episode}"
  web_on && green "网页播放器：http://$I:$(web_port)"
  yellow "云厂商安全组要放行 $(port)$(web_on && echo " 和 $(web_port)") 端口"
}

uninstall_all() {
  reading "确定卸载弹幕服务、网页播放器、采集站定时？(y/N): " yn
  [ "$yn" = y ] || [ "$yn" = Y ] || return
  systemctl disable --now danmu danmu-sites.timer danmu-sites >/dev/null 2>&1
  rm -f /etc/systemd/system/danmu.service /etc/systemd/system/danmu-sites.service /etc/systemd/system/danmu-sites.timer
  systemctl daemon-reload
  rm -rf "$APP_DIR" /etc/danmu.env
  command -v ufw >/dev/null && { ufw delete allow 2525/tcp >/dev/null 2>&1; ufw delete allow 3003/tcp >/dev/null 2>&1; }
  if [ -f /opt/moontv/docker-compose.yml ]; then
    reading "检测到 MoonTVPlus，一起卸载？(y/N): " yn
    if [ "$yn" = y ] || [ "$yn" = Y ]; then
      (cd /opt/moontv && docker compose down -v --rmi all) ; rm -rf /opt/moontv
    fi
  fi
  rm -f /usr/local/bin/ys
  green "已卸载"
  exit 0
}

while true; do
  clear
  purple "=== 影视播放器管理（弹幕 + 精简网页版）==="
  show_status
  echo "-----------------------------"
  green "1. 安装 / 更新"
  green "2. 查看地址"
  green "3. 重启服务"
  green "4. 立即更新采集站（后台约 2-5 分钟）"
  green "5. 查看弹幕/网页日志"
  green "6. 查看采集站更新日志"
  red   "7. 卸载"
  echo "-----------------------------"
  purple "0. 退出"
  reading "请输入选择: " c
  echo
  case "$c" in
    1) install_web; pause ;;
    2) show_urls; pause ;;
    3) systemctl restart danmu && green "已重启"; pause ;;
    4) systemctl start --no-block danmu-sites && green "已开始，选 6 看进度"; pause ;;
    5) journalctl -u danmu -n 40 --no-pager; pause ;;
    6) journalctl -u danmu-sites -n 40 --no-pager; pause ;;
    7) uninstall_all; pause ;;
    0) exit 0 ;;
    *) red "无效选项"; sleep 1 ;;
  esac
done
