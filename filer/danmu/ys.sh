#!/usr/bin/env bash
# 影视播放器管理（弹幕 2525 + 精简网页播放器 3003）  快捷命令：ys
RAW=https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu
APP_DIR=/opt/danmu
ENVF=/etc/danmu.env
PY="$APP_DIR/venv/bin/python"
re="\033[0m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
pause() { read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'; echo; }
[ "$(id -u)" = 0 ] || { red "请用 root 运行"; exit 1; }

env_of() { systemctl show -p Environment --value danmu 2>/dev/null | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }
port() { p=$(env_of PORT); echo "${p:-2525}"; }
web_port() { p=$(env_of WEB_PORT); echo "${p:-3003}"; }
web_on() { [ "$(env_of WEB)" = 1 ]; }
ip() { curl -s4 -m 3 ifconfig.me 2>/dev/null || echo 你的IP; }
installed() { [ -f "$APP_DIR/danmu_server.py" ] && [ -f /etc/systemd/system/danmu.service ]; }
getenv() { grep -oP "^$1=\K.*" "$ENVF" 2>/dev/null | tail -1; }
setenv() { touch "$ENVF"; sed -i "/^$1=/d" "$ENVF"; [ -n "$2" ] && echo "$1=$2" >> "$ENVF"; }
ensure_envfile() {  # 老版本的 danmu.service 没读 /etc/danmu.env
  grep -q '^EnvironmentFile=-/etc/danmu.env' /etc/systemd/system/danmu.service 2>/dev/null && return
  sed -i '/^ExecStart=/i EnvironmentFile=-/etc/danmu.env' /etc/systemd/system/danmu.service && systemctl daemon-reload
}

install_web() {
  curl -fsSL "$RAW/deploy.sh?t=$(date +%s)" -o /tmp/danmu_deploy.sh && MODE=web bash /tmp/danmu_deploy.sh
}

show_status() {
  if ! installed; then yellow "未安装（选 1 安装）"; return; fi
  local st ver
  st=$(systemctl is-active danmu 2>/dev/null)
  ver=$(curl -s -m 3 "http://127.0.0.1:$(port)/version")
  echo "弹幕服务：$st  版本：${ver:-?}  端口：$(port)  域名：$(getenv DANMU_DOMAIN || true)"
  if web_on; then
    echo "网页播放器：开启  端口：$(web_port)  账号：$(AUTH_FILE=$APP_DIR/web_auth.json $PY $APP_DIR/danmu_server.py --auth-user 2>/dev/null)  域名：$(getenv WEB_DOMAIN || true)"
  else
    echo "网页播放器：未开启（选 1 安装精简网页版）"
  fi
  echo "采集站数量：$(python3 -c "import json;print(len(json.load(open('$APP_DIR/www/jjoo.json'))['sites']))" 2>/dev/null || echo ?)"
  echo "采集站下次更新：$(systemctl list-timers danmu-sites.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')"
}

show_urls() {
  local I DD WD; I=$(ip); DD=$(getenv DANMU_DOMAIN); WD=$(getenv WEB_DOMAIN)
  green "OK影视 配置：${DD:-http://$I:$(port)}/sub/jjoo.json"
  green "弹幕接口：  ${DD:-http://$I:$(port)}/danmu?name={name}&episode={episode}"
  [ -n "$DD" ] && skyblue "（IP 方式仍可用：http://$I:$(port)/sub/jjoo.json，订阅里的弹幕地址会自动跟随你用的地址）"
  if web_on; then
    green "网页播放器：${WD:-http://$I:$(web_port)}"
    [ -n "$WD" ] && [ "$(getenv WEB_BIND)" != 127.0.0.1 ] && skyblue "（IP 方式仍可用：http://$I:$(web_port)）"
  fi
  yellow "云厂商安全组要放行用到的端口"
}

reset_auth() {
  installed || { red "未安装"; return; }
  [ -x "$PY" ] || { red "缺少 $PY，请先选 1 安装"; return; }
  local u p p2 cur
  cur=$(AUTH_FILE=$APP_DIR/web_auth.json $PY $APP_DIR/danmu_server.py --auth-user 2>/dev/null)
  reading "新账号（回车保持 ${cur:-admin}）: " u; u=${u:-${cur:-admin}}
  read -s -p "$(red "新密码（回车随机生成）: ")" p; echo
  if [ -z "$p" ]; then
    p=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
  else
    read -s -p "$(red "再输一次: ")" p2; echo
    [ "$p" = "$p2" ] || { red "两次不一致"; return; }
  fi
  AUTH_FILE=$APP_DIR/web_auth.json $PY $APP_DIR/danmu_server.py --set-auth "$u" "$p" >/dev/null || { red "设置失败"; return; }
  green "已重置：账号 $u  密码 $p"
  yellow "所有已登录的设备需要重新登录（立即生效，无需重启）"
}

# ---------------- 域名 + HTTPS（nginx 反代） ----------------
v6() { [ -s /proc/net/if_inet6 ] && echo "$1"; }
listener() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -1; }
nginx_stream_on() { local p=$1; grep -rsE "^\s*stream\s*\{" /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/modules-enabled >/dev/null 2>&1 && grep -rsE "listen\s+(\[::\]:)?$p\b" /etc/nginx/stream* /etc/nginx/nginx.conf 2>/dev/null | grep -q .; }

find_cert() {  # 复用 sing-box 脚本申请的证书（/root/cert、/etc/nginx/cert，含泛域名）
  local d=$1 parent=${1#*.} b
  for b in /root/cert /etc/nginx/cert; do
    for c in "$b/$d" "$b/*.$parent" "$b/$parent"; do
      if [ -s "$c/fullchain.pem" ] && [ -s "$c/privkey.pem" ]; then
        if [ "$c" = "$b/$parent" ]; then openssl x509 -in "$c/fullchain.pem" -noout -text 2>/dev/null | grep -q "\*\.$parent" || continue; fi
        CERT="$c/fullchain.pem"; KEY="$c/privkey.pem"; return 0
      fi
    done
  done
  return 1
}

issue_cert() {
  local d=$1 acme="$HOME/.acme.sh/acme.sh" occ
  if [ ! -x "$acme" ]; then
    skyblue "安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="cert_${RANDOM}@gmail.com" >/dev/null 2>&1
    [ -x "$acme" ] || { red "acme.sh 安装失败"; return 1; }
  fi
  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1
  occ=$(listener 80)
  if [ -z "$occ" ] || [ "$occ" = nginx ]; then
    mkdir -p /var/www/ys-acme
    "$acme" --issue -d "$d" -w /var/www/ys-acme --keylength ec-256 || return 1
  elif [ -x "$HOME/.acme.sh/release_80.sh" ]; then
    "$acme" --issue -d "$d" --standalone --keylength ec-256 --pre-hook "$HOME/.acme.sh/release_80.sh" --post-hook "$HOME/.acme.sh/restore_80.sh" || return 1
  else
    red "80 端口被 $occ 占用，无法申请证书。可先用 sing-box 脚本申请该域名证书，再回来设置。"; return 1
  fi
  mkdir -p "/root/cert/$d"
  "$acme" --install-cert -d "$d" --ecc --fullchain-file "/root/cert/$d/fullchain.pem" --key-file "/root/cert/$d/privkey.pem" --reloadcmd "systemctl reload nginx" >/dev/null || return 1
  CERT="/root/cert/$d/fullchain.pem"; KEY="/root/cert/$d/privkey.pem"
}

write_80() {  # 只写 80 端口（证书验证 + 跳转/直接反代）
  local name=$1 d=$2 up=$3 mode=$4 hp=$5
  local loc
  if [ "$mode" = redirect ]; then
    loc="return 301 https://\$host$( [ "$hp" = 443 ] || echo ":$hp")\$request_uri;"
  else
    loc="proxy_pass http://127.0.0.1:$up; proxy_set_header Host \$http_host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; proxy_buffering off; proxy_read_timeout 300s;"
  fi
  cat > "/etc/nginx/conf.d/$name.conf" <<EOF
# 由 ys 生成，勿手改（ys 菜单可删除）
server {
    listen 80;
$(v6 "    listen [::]:80;")
    server_name $d;
    location /.well-known/acme-challenge/ { root /var/www/ys-acme; }
    location / { $loc }
}
EOF
}

setup_domain() {  # $1=web|danmu
  installed || { red "未安装，先选 1"; return; }
  local kind=$1 name up envk label cur d rip myip hp occ http80
  if [ "$kind" = web ]; then
    web_on || { red "网页播放器未开启，先选 1 安装"; return; }
    name=ys-web; up=$(web_port); envk=WEB_DOMAIN; label=网页播放器
  else
    name=ys-danmu; up=$(port); envk=DANMU_DOMAIN; label=弹幕
  fi
  cur=$(getenv $envk)
  [ -n "$cur" ] && yellow "当前$label域名：$cur"
  reading "输入$label域名（如 tv.example.com；输入 del 删除已设置的；回车取消）: " d
  [ -z "$d" ] && return
  if [ "$d" = del ]; then
    rm -f "/etc/nginx/conf.d/$name.conf"; setenv $envk ""
    [ "$kind" = web ] && setenv WEB_BIND ""
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    ensure_envfile; systemctl restart danmu
    green "已删除$label域名"; return
  fi
  d=$(echo "$d" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##' | tr 'A-Z' 'a-z')
  echo "$d" | grep -qE '^[a-z0-9.-]+\.[a-z]{2,}$' || { red "域名格式不对"; return; }
  myip=$(ip); rip=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
  if [ "$rip" != "$myip" ]; then
    yellow "域名解析到 ${rip:-（无解析）}，本机 IP 是 $myip"
    yellow "请把 $d 的 A 记录指向 $myip（Cloudflare 申请证书时先关小黄云）"
    reading "仍然继续？(y/N): " yn; [ "$yn" = y ] || [ "$yn" = Y ] || return
  fi
  if ! command -v nginx >/dev/null; then
    skyblue "安装 nginx..."
    (apt install -y nginx || dnf install -y nginx || yum install -y nginx) >/dev/null 2>&1
    command -v nginx >/dev/null || { red "nginx 安装失败"; return; }
    systemctl enable --now nginx >/dev/null 2>&1
  fi
  nginx -t >/dev/null 2>&1 || { red "当前 nginx 配置本身有错误，先修好："; nginx -t; return; }

  # HTTPS 端口：443 被 sing-box 等占用时换一个
  hp=443; occ=$(listener 443)
  if { [ -n "$occ" ] && [ "$occ" != nginx ]; } || nginx_stream_on 443; then
    yellow "443 端口已被 ${occ:-nginx stream 分流} 占用"
    hp=8443
  fi
  reading "HTTPS 端口（回车用 $hp）: " x; hp=${x:-$hp}
  echo "$hp" | grep -qE '^[0-9]+$' || { red "端口不对"; return; }
  occ=$(listener "$hp")
  if [ -n "$occ" ] && [ "$occ" != nginx ]; then red "端口 $hp 被 $occ 占用，换一个"; return; fi
  [ "$hp" = "$(port)" ] || [ "$hp" = "$(web_port)" ] && { red "不能用服务自己的端口"; return; }

  occ=$(listener 80); http80=1
  if [ -n "$occ" ] && [ "$occ" != nginx ]; then http80=0; yellow "80 端口被 $occ 占用，跳过 80 端口配置"; fi
  if [ $http80 = 1 ]; then
    mkdir -p /var/www/ys-acme
    write_80 "$name" "$d" "$up" proxy "$hp"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || { rm -f "/etc/nginx/conf.d/$name.conf"; http80=0; }
  fi

  CERT=""; KEY=""
  if find_cert "$d"; then
    green "使用已有证书：$CERT"
  else
    skyblue "申请证书（需要安全组放行 80 端口）..."
    issue_cert "$d" || { red "证书申请失败"; [ $http80 = 1 ] && yellow "已保留 http://$d 访问（无 HTTPS）"; return; }
  fi

  # 网页播放器 80 跳 https；弹幕 80 也直接反代（老电视盒子不支持 https 也能用）
  [ $http80 = 1 ] && { [ "$kind" = web ] && write_80 "$name" "$d" "$up" redirect "$hp" || write_80 "$name" "$d" "$up" proxy "$hp"; }
  [ $http80 = 1 ] || : > "/etc/nginx/conf.d/$name.conf"
  cat >> "/etc/nginx/conf.d/$name.conf" <<EOF
server {
    listen $hp ssl;
$(v6 "    listen [::]:$hp ssl;")
    server_name $d;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 10m;
    location / {
        proxy_pass http://127.0.0.1:$up;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 300s;
    }
}
EOF
  if ! nginx -t >/dev/null 2>&1; then
    red "nginx 配置检查失败，已撤销："; nginx -t; rm -f "/etc/nginx/conf.d/$name.conf"; systemctl reload nginx; return
  fi
  systemctl reload nginx
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && { ufw allow "$hp"/tcp >/dev/null; ufw allow 80/tcp >/dev/null; }
  local url="https://$d$( [ "$hp" = 443 ] || echo ":$hp")"
  setenv $envk "$url"
  if [ "$kind" = web ]; then
    reading "只允许用域名访问网页（关闭 IP:$(web_port) 直连）？(y/N): " yn
    if [ "$yn" = y ] || [ "$yn" = Y ]; then setenv WEB_BIND 127.0.0.1; else setenv WEB_BIND ""; fi
  fi
  ensure_envfile; systemctl restart danmu
  green "✅ $label 域名已设置：$url"
  [ "$kind" = danmu ] && green "OK影视 配置改成：$url/sub/jjoo.json（弹幕地址会自动用这个域名）" && [ $http80 = 1 ] && skyblue "电视盒子不支持 https 可用：http://$d/sub/jjoo.json"
  yellow "云厂商安全组要放行 $hp$( [ $http80 = 1 ] && echo " 和 80") 端口"
}

uninstall_all() {
  reading "确定卸载弹幕服务、网页播放器、采集站定时？(y/N): " yn
  [ "$yn" = y ] || [ "$yn" = Y ] || return
  systemctl disable --now danmu danmu-sites.timer danmu-sites >/dev/null 2>&1
  rm -f /etc/systemd/system/danmu.service /etc/systemd/system/danmu-sites.service /etc/systemd/system/danmu-sites.timer
  systemctl daemon-reload
  rm -rf "$APP_DIR" /etc/danmu.env
  if ls /etc/nginx/conf.d/ys-*.conf >/dev/null 2>&1; then
    rm -f /etc/nginx/conf.d/ys-*.conf; nginx -t >/dev/null 2>&1 && systemctl reload nginx
  fi
  command -v ufw >/dev/null && { ufw delete allow 2525/tcp >/dev/null 2>&1; ufw delete allow 3003/tcp >/dev/null 2>&1; }
  if [ -f /opt/moontv/docker-compose.yml ]; then
    reading "检测到 MoonTVPlus，一起卸载？(y/N): " yn
    if [ "$yn" = y ] || [ "$yn" = Y ]; then
      (cd /opt/moontv && docker compose down -v --rmi all) ; rm -rf /opt/moontv
    fi
  fi
  rm -f /usr/local/bin/ys
  green "已卸载（证书保留在 /root/cert）"
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
  green "7. 重置网页账号密码"
  green "8. 设置网页播放器域名（HTTPS）"
  green "9. 设置弹幕域名（HTTPS）"
  red   "10. 卸载"
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
    7) reset_auth; pause ;;
    8) setup_domain web; pause ;;
    9) setup_domain danmu; pause ;;
    10) uninstall_all; pause ;;
    0) exit 0 ;;
    *) red "无效选项"; sleep 1 ;;
  esac
done
