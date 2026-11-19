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
ip() { curl -s4 --connect-timeout 3 --max-time 5 ifconfig.me 2>/dev/null || echo 你的IP; }
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
  echo "采集站自动更新：$(every_text)  下次：$(next_run)"
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

show_auth() {
  installed && [ -x "$PY" ] || { red "未安装"; return; }
  local a; a=$(AUTH_FILE=$APP_DIR/web_auth.json $PY $APP_DIR/danmu_server.py --auth-show 2>/dev/null)
  [ -n "$a" ] || { yellow "还没有有效账号，选 8 设置"; return; }
  green "网页账号：$a"
  yellow "密码只保存哈希，不能查看；忘了选 8 重置"
}

# ---------------- 采集站 ----------------
every_text() { local e; e=$(getenv SITES_EVERY); e=${e:-2}
  case "$e" in off) echo 已关闭;; *h) echo "每 ${e%h} 小时";; 1) echo 每天;; 7) echo 每周;; *) echo "每 $e 天";; esac; }
next_run() { systemctl is-active -q danmu-sites.timer 2>/dev/null || { echo -; return; }
  systemctl list-timers danmu-sites.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}'; }
write_timer() {  # $1 = 天数 / Nh / off（与 deploy.sh 相同规则，更新不会被覆盖）
  local e=$1 tl
  setenv SITES_EVERY "$e"
  case "$e" in
    off) systemctl disable --now danmu-sites.timer >/dev/null 2>&1; rm -f /etc/systemd/system/danmu-sites.timer; systemctl daemon-reload; return ;;
    *h) tl="OnBootSec=15min
OnUnitActiveSec=${e%h}h" ;;   # 固定间隔
    1) tl="OnCalendar=*-*-* 20:00:00 UTC
Persistent=true" ;;           # 每天北京时间 04:00
    7) tl="OnCalendar=Sun *-*-* 20:00:00 UTC
Persistent=true" ;;           # 每周日 04:00
    *) tl="OnBootSec=15min
OnUnitActiveSec=${e}d" ;;     # 固定间隔 N 天
  esac
  cat > /etc/systemd/system/danmu-sites.timer <<UNIT
[Unit]
Description=Update video sites (SITES_EVERY=$e)
[Timer]
$tl
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload; systemctl enable danmu-sites.timer >/dev/null 2>&1; systemctl restart danmu-sites.timer
}
sites_menu() {
  installed || { red "未安装"; return; }
  local c x
  while true; do
    clear; purple "=== 采集站 ==="
    echo "采集站数量：$(python3 -c "import json;print(len(json.load(open('$APP_DIR/www/jjoo.json'))['sites']))" 2>/dev/null || echo ?)"
    echo "自动更新：$(every_text)  下次：$(next_run)"
    systemctl is-active -q danmu-sites && yellow "正在更新中…"
    echo "-----------------------------"
    green "1. 立即更新（后台约 2-5 分钟）"
    green "2. 设置自动更新间隔"
    green "3. 查看更新日志"
    purple "0. 返回"
    reading "请选择: " c
    case "$c" in
      1) systemctl start --no-block danmu-sites && green "已开始，选 3 看进度"; sleep 1 ;;
      2) echo "-----------------------------"
         green "1. 每 6 小时    2. 每 12 小时"
         green "3. 每天         4. 每 2 天（默认）"
         green "5. 每 3 天      6. 每周"
         green "7. 自定义       8. 关闭自动更新"
         reading "请选择: " x
         case "$x" in
           1) write_timer 6h;; 2) write_timer 12h;; 3) write_timer 1;; 4) write_timer 2;;
           5) write_timer 3;; 6) write_timer 7;; 8) write_timer off;;
           7) reading "输入天数（1-30），或小时数加 h（如 8h）: " x
              if echo "$x" | grep -qE '^([1-9]|[12][0-9]|30)$|^([1-9]|1[0-9]|2[0-3])h$'; then write_timer "$x"; else red "格式不对"; sleep 1; continue; fi ;;
           *) continue ;;
         esac
         green "已设为：$(every_text)  下次：$(next_run)"; pause ;;
      3) journalctl -u danmu-sites -n 40 --no-pager; pause ;;
      *) return ;;
    esac
  done
}

toggle_run() {
  installed || { red "未安装"; return; }
  if systemctl is-active -q danmu; then
    reading "停止弹幕和网页播放器（开机也不再自动启动）？(y/N): " yn
    [ "$yn" = y ] || [ "$yn" = Y ] || return
    systemctl disable --now danmu danmu-sites.timer danmu-sites >/dev/null 2>&1
    green "已停止弹幕和网页播放器（采集站自动更新也暂停）。再选这一项可重新启动"
  else
    systemctl enable --now danmu >/dev/null 2>&1
    [ "$(getenv SITES_EVERY)" = off ] || systemctl enable --now danmu-sites.timer >/dev/null 2>&1
    sleep 1; systemctl is-active -q danmu && green "已启动" || { red "启动失败，看日志："; journalctl -u danmu -n 20 --no-pager; }
  fi
}

# ---------------- IP 访问限制 ----------------
ACL=$APP_DIR/acl.json
acl_py() { python3 - "$ACL" "$@" <<'PYEOF'
import json, sys, ipaddress
f, act = sys.argv[1], sys.argv[2]
try: d = json.load(open(f))
except Exception: d = {}
if act == "show":
    for sc, nm in (("web", "网页播放器"), ("danmu", "弹幕/OK影视订阅")):
        c = d.get(sc) or {}
        m = {"allow": "只允许名单内 IP", "deny": "禁止名单内 IP"}.get(c.get("mode"), "不限制")
        print(f"{nm}：{m}" + (("  名单：" + ", ".join(c.get("ips") or [])) if c.get("ips") else ""))
    sys.exit()
sc = sys.argv[3]; c = d.setdefault(sc, {"mode": "off", "ips": []}); c.setdefault("ips", [])
if act == "mode": c["mode"] = sys.argv[4]
elif act == "add":
    for x in sys.argv[4].replace("，", ",").replace(" ", ",").split(","):
        x = x.strip()
        if not x: continue
        try: ipaddress.ip_network(x, strict=False)
        except Exception: print("跳过无效：" + x); continue
        if x not in c["ips"]: c["ips"].append(x)
elif act == "del":
    for x in sys.argv[4].replace("，", ",").replace(" ", ",").split(","):
        if x.strip() in c["ips"]: c["ips"].remove(x.strip())
elif act == "clear": c["ips"] = []
json.dump(d, open(f, "w"), ensure_ascii=False, indent=1)
PYEOF
}

acl_menu() {
  installed || { red "未安装"; return; }
  local sc c x me
  me=$(echo "$SSH_CLIENT" | awk '{print $1}')
  while true; do
    clear; purple "=== IP 访问限制 ==="; acl_py show
    [ -n "$me" ] && skyblue "你当前 SSH 的 IP：$me"
    yellow "名单支持单个 IP 或网段（如 1.2.3.4、1.2.3.0/24），本机访问始终放行，立即生效"
    echo "-----------------------------"
    green "1. 设置网页播放器"
    green "2. 设置弹幕/OK影视订阅"
    purple "0. 返回"
    reading "请选择: " c
    case "$c" in 1) sc=web;; 2) sc=danmu;; *) return;; esac
    echo "-----------------------------"
    green "1. 只允许名单内 IP 访问（白名单）"
    green "2. 禁止名单内 IP 访问（黑名单）"
    green "3. 不限制"
    green "4. 添加 IP 到名单"
    green "5. 从名单删除 IP"
    green "6. 清空名单"
    reading "请选择: " c
    case "$c" in
      1) acl_py mode $sc allow; green "已设为白名单"
         if [ -n "$me" ] && ! grep -q "\"$me\"" "$ACL"; then acl_py add $sc "$me"; yellow "已自动把你当前 IP $me 加入名单，防止把自己关在外面"; fi; [ "$sc" = danmu ] && yellow "注意：手机流量 IP 经常变，白名单可能导致 OK影视 用不了";;
      2) acl_py mode $sc deny; green "已设为黑名单";;
      3) acl_py mode $sc off; green "已取消限制";;
      4) reading "输入 IP（多个用逗号或空格分开）: " x; [ -n "$x" ] && acl_py add $sc "$x" && green "已添加";;
      5) reading "输入要删除的 IP: " x; [ -n "$x" ] && acl_py del $sc "$x" && green "已删除";;
      6) acl_py clear $sc; green "已清空";;
    esac
    sleep 1
  done
}

# 16-24 位，大小写字母+数字+特殊符号各至少一个
rand_cred() { $PY -c 'import secrets,string as s;S="!@#%^*_-+=";A=[s.ascii_lowercase,s.ascii_uppercase,s.digits,S];n=16+secrets.randbelow(9);c=[secrets.choice(a) for a in A]+[secrets.choice("".join(A)) for _ in range(n-4)];secrets.SystemRandom().shuffle(c);print("".join(c))'; }

reset_auth() {
  installed || { red "未安装"; return; }
  [ -x "$PY" ] || { red "缺少 $PY，请先选 1 安装"; return; }
  local u p p2 cur
  cur=$(AUTH_FILE=$APP_DIR/web_auth.json $PY $APP_DIR/danmu_server.py --auth-user 2>/dev/null)
  yellow "当前账号：${cur:-无}"
  reading "新账号（回车随机生成 16-24 位）: " u; [ -n "$u" ] || u=$(rand_cred)
  read -s -p "$(red "新密码（回车随机生成 16-24 位）: ")" p; echo
  if [ -z "$p" ]; then
    p=$(rand_cred)
  else
    read -s -p "$(red "再输一次: ")" p2; echo
    [ "$p" = "$p2" ] || { red "两次不一致"; return; }
  fi
  AUTH_FILE=$APP_DIR/web_auth.json $PY $APP_DIR/danmu_server.py --set-auth "$u" "$p" >/dev/null || { red "设置失败"; return; }
  green "已重置（请记下来）："; echo "  账号：$u"; echo "  密码：$p"
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
    loc="proxy_pass http://127.0.0.1:$up; proxy_set_header Host \$http_host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; proxy_buffering off; proxy_read_timeout 300s; client_max_body_size 10m;"
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
  # 像 sing-box 脚本一样列出本机已有证书（/root/cert、/etc/nginx/cert）直接选
  local names=() n i=2 sel dir
  shopt -s nullglob
  for dir in /root/cert/* /etc/nginx/cert/*; do
    [ -d "$dir" ] && [ -s "$dir/fullchain.pem" ] && [ -s "$dir/privkey.pem" ] || continue
    n=$(basename "$dir"); [[ " ${names[*]} " == *" $n "* ]] || names+=("$n")
  done
  shopt -u nullglob
  skyblue "============== 本机已有证书 =============="
  [ ${#names[@]} -eq 0 ] && echo "  （没有找到证书）"
  for n in "${names[@]}"; do
    local mk=""
    [[ "$n" == \** ]] && mk=" \e[1;33m【泛域名，选后输入前缀】\033[0m"
    echo "$cur" | grep -q "//$n\b" && mk="$mk \e[1;32m【当前使用】\033[0m"
    echo -e " $i) $n$mk"; i=$((i+1))
  done
  skyblue "=========================================="
  echo " 1) 输入新域名（自动申请证书）"
  [ -n "$cur" ] && echo " d) 删除已设置的$label域名"
  echo " 0) 取消"
  reading "请选择: " sel
  case "$sel" in
    ""|0) return ;;
    d|D|del) d=del ;;
    1) reading "输入$label域名（如 tv.example.com）: " d; [ -z "$d" ] && return ;;
    *) if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 2 ] && [ "$sel" -lt "$i" ]; then
         d=${names[$((sel-2))]}
         if [[ "$d" == \** ]]; then
           reading "输入前缀（如 tv → tv${d#\*}）: " x; [ -z "$x" ] && return; d="$x${d#\*}"
         fi
       else red "无效选项"; return; fi ;;
  esac
  if [ "$d" = del ]; then
    rm -f "/etc/nginx/conf.d/$name.conf"; setenv $envk ""
    [ "$kind" = web ] && setenv WEB_BIND ""
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    ensure_envfile; systemctl restart danmu
    green "已删除$label域名"; return
  fi
  d=$(echo "$d" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##' | tr 'A-Z' 'a-z')
  local isip=0
  echo "$d" | grep -qE '^[0-9]+(\.[0-9]+){3}$' && isip=1
  [ $isip = 1 ] || echo "$d" | grep -qE '^[a-z0-9.-]+\.[a-z]{2,}$' || { red "域名格式不对"; return; }
  myip=$(ip); rip=$d; [ $isip = 1 ] || rip=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
  if [ $isip = 1 ] && [ "$d" != "$myip" ]; then
    yellow "这个 IP 证书是 $d，本机 IP 是 $myip"; reading "仍然继续？(y/N): " yn; [ "$yn" = y ] || [ "$yn" = Y ] || return
  elif [ $isip = 0 ] && [ "$rip" != "$myip" ]; then
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

  # HTTPS 端口：nginx 按域名(SNI)区分，和 sing-box 脚本的 nginx 共用 443
  hp=443; occ=$(listener 443)
  if [ -n "$occ" ] && [ "$occ" != nginx ]; then
    yellow "443 端口被 $occ 直接占用（不是 nginx），nginx 无法共用，请换一个端口"
    hp=""
  elif nginx_stream_on 443; then
    yellow "443 被 nginx stream 分流占用，http 不能直接共用，请换一个端口"
    hp=""
  else
    green "443 由 nginx 管理${occ:+（与已有站点按域名共用）}"
  fi
  reading "HTTPS 端口（回车用 ${hp:-？}）: " x; hp=${x:-$hp}
  [ -n "$hp" ] || { red "没有可用端口"; return; }
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
  elif [ $isip = 1 ]; then
    red "没有 $d 的证书，IP 证书请先用 sing-box 脚本申请"; return
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
  if tg_installed; then
    reading "检测到 tgweb，一起卸载（含 TG 登录 session）？(y/N): " yn
    { [ "$yn" = y ] || [ "$yn" = Y ]; } && tg uninstall yes
  fi
  rm -f /usr/local/bin/ys
  green "已卸载（证书保留在 /root/cert）"
  exit 0
}

# ---------------- tgweb（Telegram 频道视频，Docker，只绑 127.0.0.1:9393）----------------
# 网页通过哈哈的 /tg/ 访问，登录用哈哈的账号；tgweb 自己的网页账号密码随机生成，只给哈哈后台代登录用
TGD=${TGWEB_DIR:-/root/telegram-stream}; export TG_APP_DIR="$TGD"
TG_RAW=https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/tgweb  # 哈哈自己保存的一份 tgweb，不从别的仓库拉
TG_FILES=".env.example .gitignore Dockerfile README.md app.py docker-compose.yml index.html install.sh requirements.txt sw.js tg tg-domain.sh"
tg_fetch() {  # 下载/更新 tgweb 代码：只覆盖代码文件，.env 和 data/（session）不动
  local tmp f; tmp=$(mktemp -d)
  for f in $TG_FILES; do
    curl -fsSL --connect-timeout 10 --max-time 120 "$TG_RAW/$f?t=$(date +%s)" -o "$tmp/$f" || { rm -rf "$tmp"; red "下载 tgweb 失败：$f"; return 1; }
  done
  mkdir -p "$TGD/data"
  for f in $TG_FILES; do cp -f "$tmp/$f" "$TGD/$f"; done
  chmod +x "$TGD/tg" "$TGD/tg-domain.sh" "$TGD/install.sh" 2>/dev/null
  rm -rf "$tmp" "$TGD/.git"  # 以前从别的仓库 clone 的：去掉 .git，以后只从哈哈仓库更新
  cp "$TGD/tg" /tmp/tg.new && chmod +x /tmp/tg.new && mv /tmp/tg.new /usr/local/bin/tg
  cp "$TGD/tg-domain.sh" /tmp/tg-domain.new && chmod +x /tmp/tg-domain.new && mv /tmp/tg-domain.new /usr/local/bin/tg-domain
}
tg_installed() { [ -f "$TGD/docker-compose.yml" ]; }
tg_running() { tg_installed && command -v docker >/dev/null && [ -n "$(cd "$TGD" && docker compose ps -q --status running 2>/dev/null)" ]; }
tg_envv() { grep -E "^$1=" "$TGD/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r'; }
tg_rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }
tg_setv() { touch "$TGD/.env"; sed -i "/^$1=/d" "$TGD/.env"; echo "$1=$2" >> "$TGD/.env"; }
tg_state() {
  if ! tg_installed; then echo "未安装"; return; fi
  local a="api 未配置（选 4/5 设置）"; [ -n "$(tg_envv TG_API_ID)" ] && [ "$(tg_envv TG_API_ID)" != 0 ] && [ -n "$(tg_envv TG_API_HASH)" ] && a="api 已配置"
  if tg_running; then echo "运行中  $a"; else echo "已停止  $a"; fi
}
tg_install() {  # 安装/补全 tgweb：跳过 api_id/api_hash；不碰 nginx（网页走哈哈的 /tg/）
  command -v apt-get >/dev/null || { red "tgweb 只支持 Debian/Ubuntu"; return 1; }
  command -v git >/dev/null || apt-get install -y git >/dev/null 2>&1 || { red "git 安装失败"; return 1; }
  if ! command -v docker >/dev/null; then
    skyblue "安装 Docker（tgweb 用）..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { red "Docker 安装失败，tgweb 跳过（弹幕和网页播放器不受影响）"; return 1; }
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin >/dev/null 2>&1 || { red "docker compose 不可用"; return 1; }
  tg_installed || tg_fetch || return 1
  [ -f "$TGD/.env" ] || printf 'TG_API_ID=\nTG_API_HASH=\nTG_PARALLEL=2\n' > "$TGD/.env"
  chmod 600 "$TGD/.env"
  [ -n "$(tg_envv WEB_USERNAME)" ] || tg_setv WEB_USERNAME "u$(tg_rand 15)"
  [ -n "$(tg_envv WEB_PASSWORD)" ] || tg_setv WEB_PASSWORD "$(tg_rand 32)"
  [ -n "$(tg_envv WEB_PATH)" ] || tg_setv WEB_PATH "$(tg_rand 24)"
  [ "$(tg_envv TG_STREAM_ENC)" = auto ] || tg_setv TG_STREAM_ENC auto  # 明文/加密都能放，由哈哈设置页的加密开关决定
  skyblue "构建并启动 tgweb（第一次要几分钟）..."
  (cd "$TGD" && docker compose up -d --build) >/tmp/tgweb_build.log 2>&1 || { red "tgweb 启动失败，日志：/tmp/tgweb_build.log"; return 1; }
  green "tgweb 已启动：网页左上角配置框选 tgweb；api_id/api_hash 在 ys 选 14 里设置"
}
tg_set_api() {  # api_id 明文输入，api_hash 不回显；改完重启 tgweb
  local v
  if [ "$1" = TG_API_ID ]; then
    reading "输入 api_id（my.telegram.org 获取，纯数字）: " v
    [[ "$v" =~ ^[0-9]+$ ]] || { red "api_id 必须是纯数字"; return 0; }
  else
    read -r -s -p "$(red "输入 api_hash（不回显）: ")" v; echo
    [ -n "$v" ] || { red "不能为空"; return 0; }
  fi
  tg_setv "$1" "$v"; green "已保存"
  (cd "$TGD" && docker compose up -d >/dev/null 2>&1) && green "tgweb 已重启生效"
}
tg_toggle() {
  tg_installed || { red "tgweb 未安装，先选 1"; return; }
  if tg_running; then
    (cd "$TGD" && docker compose stop) && green "tgweb 已停止（网页里不再显示 tgweb，开机也不自动启动）"
  else
    (cd "$TGD" && docker compose up -d) && green "tgweb 已启动"
  fi
}
tg_uninstall() {
  tg_installed || { red "未安装"; return; }
  reading "卸载 tgweb（删除容器、$TGD 含 TG 登录 session）？输入 yes 确认: " yn
  [ "$yn" = yes ] || { yellow "已取消"; return; }
  tg uninstall yes; green "tgweb 已卸载"
}
tg_menu() {
  while true; do
    clear
    purple "=== tgweb（TG 频道视频）==="
    echo "状态：$(tg_state)"
    echo "网页：哈哈左上角配置框选 tgweb（用哈哈的账号登录，只在运行时显示）"
    echo "-----------------------------"
    green "1. 安装 / 修复"
    green "2. 更新到最新版"
    if tg_running; then yellow "3. 停止程序"; else green "3. 启动程序"; fi
    green "4. 设置 api_id"
    green "5. 设置 api_hash"
    green "6. 删除 api 配置"
    green "7. 查看配置状态"
    green "8. 设置并行下载数（1-4，默认 2）"
    green "9. 同步 session 到备份仓库"
    green "10. 从备份仓库恢复 session"
    green "11. 重启"
    green "12. 查看日志"
    red   "13. 卸载 tgweb"
    echo "-----------------------------"
    purple "0. 返回"
    reading "请输入选择: " c
    echo
    case "$c" in
      1) tg_install; pause ;;
      2) if tg_installed; then tg_fetch && skyblue "重新构建 tgweb..." && (cd "$TGD" && docker compose up -d --build) >/tmp/tgweb_build.log 2>&1 && green "tgweb 已更新" || red "更新失败，日志：/tmp/tgweb_build.log"; else red "未安装"; fi; pause ;;
      3) tg_toggle; pause ;;
      4) tg_installed && tg_set_api TG_API_ID || red "未安装"; pause ;;
      5) tg_installed && tg_set_api TG_API_HASH || red "未安装"; pause ;;
      6) tg_installed && tg del || red "未安装"; pause ;;
      7) tg_installed && tg status || red "未安装"; pause ;;
      8) tg_installed && tg set-parallel || red "未安装"; pause ;;
      9) tg_installed && tg sync-session || red "未安装"; pause ;;
      10) tg_installed && tg restore-session || red "未安装"; pause ;;
      11) tg_installed && (cd "$TGD" && docker compose restart) && green "已重启" || red "未安装或重启失败"; pause ;;
      12) tg_installed && (cd "$TGD" && docker compose logs --tail 50) || red "未安装"; pause ;;
      13) tg_uninstall; pause ;;
      0|"") return ;;
      *) red "无效选项"; sleep 1 ;;
    esac
  done
}

while true; do
  clear
  purple "=== 影视播放器管理（弹幕 + 精简网页版）==="
  show_status
  echo "-----------------------------"
  green "1. 安装 / 更新（只更新程序，不重跑采集站）"
  green "2. 查看地址"
  green "3. 重启服务"
  green "4. 采集站（立即更新 / 更新间隔）"
  green "5. 查看弹幕/网页日志"
  green "6. 查看采集站更新日志"
  green "7. 查看网页账号"
  green "8. 重置网页账号密码"
  green "9. IP 访问限制（白名单/黑名单）"
  green "10. 设置网页播放器域名（HTTPS）"
  green "11. 设置弹幕域名（HTTPS）"
  if installed && ! systemctl is-active -q danmu; then green "12. 启动程序"; else yellow "12. 停止程序（弹幕 + 网页播放器）"; fi
  red   "13. 卸载"
  green "14. tgweb（TG 频道视频）：$(tg_state)"
  echo "-----------------------------"
  purple "0. 退出"
  reading "请输入选择: " c
  echo
  case "$c" in
    1) install_web; pause ;;
    2) show_urls; pause ;;
    3) systemctl restart danmu && green "已重启"; pause ;;
    4) sites_menu ;;
    5) journalctl -u danmu -n 40 --no-pager; pause ;;
    6) journalctl -u danmu-sites -n 40 --no-pager; pause ;;
    7) show_auth; pause ;;
    8) reset_auth; pause ;;
    9) acl_menu ;;
    10) setup_domain web; pause ;;
    11) setup_domain danmu; pause ;;
    12) toggle_run; pause ;;
    13) uninstall_all; pause ;;
    14) tg_menu ;;
    0) exit 0 ;;
    *) red "无效选项"; sleep 1 ;;
  esac
done
