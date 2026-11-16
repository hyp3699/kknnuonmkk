#!/usr/bin/env bash
# 免 key 弹幕服务一键部署（三种模式，见仓库 README）
#   MODE=danmu  （默认）只装弹幕：端口 2525 + 采集站每 2 天自动维护（http://IP:2525/sub/jjoo.json 给 OK影视）
#   MODE=web    弹幕 + 精简网页播放器：端口 3003（选采集站/分类/站内搜索/播放+弹幕+播放记录，账号密码登录，无需 Docker）
#   MODE=moontv 弹幕 + MoonTVPlus 网页播放器：端口 3003（Docker）
#   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy.sh)
#   或 deploy_web.sh / deploy_moontv.sh
# 可选：/etc/danmu.env 里写 GITHUB_TOKEN=xxx（无权限的 token 即可），采集站能搜到更多新站
set -e
[ "$(id -u)" = 0 ] || { echo "请用 root 运行（sudo -i 后再执行）"; exit 1; }

APP_DIR=/opt/danmu
UNITF=/etc/systemd/system/danmu.service
# 重复运行时保留已有设置（端口、是否开网页版），命令行传入的优先
old_env() { grep -oP "^Environment=$1=\K\S+" "$UNITF" 2>/dev/null | tail -1 || true; }
PORT=${PORT:-$(old_env PORT)}; PORT=${PORT:-2525}
RAW=https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer
SRC=$RAW/danmu/danmu_server.py
[ -z "$MODE" ] && [ "$(old_env WEB)" = 1 ] && MODE=web
MODE=${MODE:-danmu}
case "$MODE" in danmu|web|moontv) ;; *) echo "MODE 只能是 danmu / web / moontv"; exit 1;; esac
WEB_PORT=${WEB_PORT:-$(old_env WEB_PORT)}; WEB_PORT=${WEB_PORT:-3003}
pubip() { curl -s4 --connect-timeout 3 --max-time 5 ifconfig.me 2>/dev/null || true; }
[ "$MODE" = web ] && SVC_WEB=1 || SVC_WEB=0
echo "== 安装模式：$MODE"

echo "[1/6] 安装 Python"
if command -v apt >/dev/null; then
  apt update -y || true
  apt install -y python3 python3-venv curl || echo "    ⚠ apt 有报错（多半是别的软件包如 nginx 配置坏了），继续安装"
elif command -v dnf >/dev/null; then
  dnf install -y python3 curl
elif command -v yum >/dev/null; then
  yum install -y python3 curl
fi

command -v python3 >/dev/null && python3 -c "import venv,ensurepip" 2>/dev/null || { echo "❌ python3-venv 没装上，请先修好 apt（运行 apt -f install 看报错）"; exit 1; }

OLD_VER=$(grep -oP '^VERSION = "\K[^"]+' "$APP_DIR/danmu_server.py" 2>/dev/null || { [ -f "$APP_DIR/danmu_server.py" ] && echo "旧版(无版本号)" || echo "未安装"; })
FIRST=0; [ -s "$APP_DIR/www/jjoo.json" ] || FIRST=1
echo "[2/6] 下载弹幕服务 + 依赖"
mkdir -p "$APP_DIR" "$APP_DIR/tools" "$APP_DIR/www"
# 先全部下载到临时目录并检查，任何一个失败就保留旧版退出，不会留下半截文件
NEW=$(mktemp -d); BAK="$APP_DIR/.bak"; trap 'rm -rf "$NEW"' EXIT
dl() { curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$1?t=$(date +%s)" -o "$2" && [ -s "$2" ]; }
dl "$SRC" "$NEW/danmu_server.py" && python3 -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$NEW/danmu_server.py" \
  || { echo "❌ 下载 danmu_server.py 失败或文件不完整，已保留旧版（$OLD_VER）"; exit 1; }
dl "$RAW/tools/update_sites.py" "$NEW/update_sites.py" && python3 -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$NEW/update_sites.py" \
  || { echo "❌ 下载 update_sites.py 失败，已保留旧版"; exit 1; }
if [ "$MODE" = web ]; then
  dl "$RAW/danmu/web.html" "$NEW/web.html" && grep -q '</html>' "$NEW/web.html" || { echo "❌ 下载 web.html 失败，已保留旧版"; exit 1; }
  # hls.js 失败不致命：保留本地旧版
  if curl -fsSL --connect-timeout 10 --max-time 60 https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js -o "$NEW/hls.min.js" && [ "$(stat -c %s "$NEW/hls.min.js")" -gt 100000 ]; then :; else rm -f "$NEW/hls.min.js"; echo "    ⚠ hls.js 下载失败，继续用本地旧版"; fi
fi
NEW_VER=$(grep -oP '^VERSION = "\K[^"]+' "$NEW/danmu_server.py" || echo "未知")
echo "    版本：$OLD_VER -> $NEW_VER"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip flask requests zhconv || { echo "❌ 安装依赖失败（pip），已保留旧版"; exit 1; }
# 备份旧版再替换
rm -rf "$BAK"; mkdir -p "$BAK"
for f in danmu_server.py web.html hls.min.js; do [ -f "$APP_DIR/$f" ] && cp -p "$APP_DIR/$f" "$BAK/"; done
[ -f "$APP_DIR/tools/update_sites.py" ] && cp -p "$APP_DIR/tools/update_sites.py" "$BAK/"
[ -f "$UNITF" ] && cp -p "$UNITF" "$BAK/danmu.service"
for f in danmu_server.py web.html hls.min.js; do [ -f "$NEW/$f" ] && mv -f "$NEW/$f" "$APP_DIR/$f"; done
mv -f "$NEW/update_sites.py" "$APP_DIR/tools/update_sites.py"
rollback() {
  echo "    ↩ 回滚到旧版 $OLD_VER"
  for f in danmu_server.py web.html hls.min.js; do [ -f "$BAK/$f" ] && cp -p "$BAK/$f" "$APP_DIR/$f"; done
  [ -f "$BAK/update_sites.py" ] && cp -p "$BAK/update_sites.py" "$APP_DIR/tools/update_sites.py"
  [ -f "$BAK/danmu.service" ] && cp -p "$BAK/danmu.service" "$UNITF"
  systemctl daemon-reload; systemctl restart danmu || true
}
# 带超时的端口检查：$1 端口  $2 判定字符串（空=有响应即可）
wait_up() { local i; for i in $(seq 1 20); do
  if [ -n "$2" ]; then curl -s --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null | grep -q "$2" && return 0
  else curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null && return 0; fi
  sleep 1; done; return 1; }

echo "[3/6] 注册 systemd 开机自启"
cat > "$UNITF" <<UNIT
[Unit]
Description=Danmu server (no key)
After=network-online.target
[Service]
Environment=PORT=$PORT
Environment=WEB=$SVC_WEB
Environment=WEB_PORT=$WEB_PORT
Environment=WWW_DIR=$APP_DIR/www
Environment=IDS_FILE=$APP_DIR/anime_ids.json
EnvironmentFile=-/etc/danmu.env
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/danmu_server.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable danmu >/dev/null 2>&1
# 3003 只能给一个网页版用：装精简版时停掉 MoonTVPlus（数据保留）
if [ "$MODE" = web ] && [ -f /opt/moontv/docker-compose.yml ] && command -v docker >/dev/null; then
  (cd /opt/moontv && docker compose stop >/dev/null 2>&1) || true
fi
# 网页登录账号：第一次装时随机生成，之后保持不变（ys 菜单可重置）
NEW_AUTH=""
AUTHC() { AUTH_FILE="$APP_DIR/web_auth.json" "$APP_DIR/venv/bin/python" "$APP_DIR/danmu_server.py" "$@"; }
if [ "$MODE" = web ] && ! AUTHC --check-auth >/dev/null 2>&1; then
  [ -s "$APP_DIR/web_auth.json" ] && { echo "    ⚠ 原账号文件损坏，重新生成账号"; mv -f "$APP_DIR/web_auth.json" "$APP_DIR/web_auth.json.bad"; }
  WEB_USER=${WEB_USER:-admin}
  WEB_PASS=${WEB_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)}
  if AUTHC --set-auth "$WEB_USER" "$WEB_PASS" >/dev/null && AUTHC --check-auth >/dev/null 2>&1; then
    NEW_AUTH=1
  else
    echo "❌ 网页账号设置失败，安装中止（网页播放器不会在没有密码的情况下启动）"; rollback; exit 1
  fi
fi
if ! systemctl restart danmu || ! wait_up "$PORT" ok; then
  echo "❌ 新版启动失败，日志："; journalctl -u danmu -n 20 --no-pager || true
  rollback; exit 1
fi

echo "[4/6] 采集站自动维护"
if [ ! -s "$APP_DIR/www/jjoo.json" ]; then dl "$RAW/jjoo.json" "$NEW/jjoo.json" && mv -f "$NEW/jjoo.json" "$APP_DIR/www/jjoo.json" || echo "    ⚠ jjoo.json 下载失败，稍后选 ys 4 更新"; fi
[ -s "$APP_DIR/tools/sites_state.json" ] || dl "$RAW/tools/sites_state.json" "$APP_DIR/tools/sites_state.json" || echo '{"fails":{}}' > "$APP_DIR/tools/sites_state.json"
touch /etc/danmu.env
SITES_ENV="JJOO_PATH=$APP_DIR/www/jjoo.json STATE_PATH=$APP_DIR/tools/sites_state.json MOONTV_OUT=$APP_DIR/www/moontv.txt"
[ -s "$APP_DIR/www/jjoo.json" ] && { env $SITES_ENV "$APP_DIR/venv/bin/python" "$APP_DIR/tools/update_sites.py" --export-only || true; }
cat > /etc/systemd/system/danmu-sites.service <<UNIT
[Unit]
Description=Update video sites (jjoo.json / moontv.txt)
After=network-online.target
[Service]
Type=oneshot
EnvironmentFile=-/etc/danmu.env
Environment=$SITES_ENV
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/tools/update_sites.py
TimeoutStartSec=3600
UNIT
# 更新间隔：/etc/danmu.env 的 SITES_EVERY，ys 菜单 4 可改，默认 2（天）
#   1 = 每天北京时间 04:00   7 = 每周日 04:00（固定时刻，关机错过会补跑）
#   其它天数 N / 小时 Nh = 固定间隔：距上次更新满 N 天/小时（开机 15 分钟后先跑一次）
#   off = 关闭
SE=$(grep -oP '^SITES_EVERY=\K.*' /etc/danmu.env 2>/dev/null | tail -1 || true); SE=${SE:-2}
echo "$SE" | grep -qE '^(off|[1-9][0-9]?|[1-9][0-9]?h)$' || { echo "    ⚠ SITES_EVERY=$SE 无效，按 2 天"; SE=2; }
if [ "$SE" = off ]; then
  systemctl disable --now danmu-sites.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/danmu-sites.timer
  systemctl daemon-reload
  echo "    采集站自动更新：已关闭"
else
  case "$SE" in
    *h) TL="OnBootSec=15min
OnUnitActiveSec=${SE%h}h" ;;
    1)  TL="OnCalendar=*-*-* 20:00:00 UTC
Persistent=true" ;;
    7)  TL="OnCalendar=Sun *-*-* 20:00:00 UTC
Persistent=true" ;;
    *)  TL="OnBootSec=15min
OnUnitActiveSec=${SE}d" ;;
  esac
  cat > /etc/systemd/system/danmu-sites.timer <<UNIT
[Unit]
Description=Update video sites (SITES_EVERY=$SE)
[Timer]
$TL
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable danmu-sites.timer >/dev/null 2>&1 || true
  systemctl restart danmu-sites.timer || true
fi
# 只有第一次安装（或 SITES_NOW=1）才立即全量更新采集站；平时更新程序不跑
if [ "$FIRST" = 1 ] || [ "${SITES_NOW:-0}" = 1 ]; then
  systemctl start --no-block danmu-sites.service || true   # 后台跑一次（约 2-5 分钟）
  echo "    已在后台更新采集站（约 2-5 分钟）"
fi

echo "[5/6] 放行端口 $PORT"
command -v ufw >/dev/null && ufw allow $PORT/tcp >/dev/null 2>&1 || true
command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --add-port=$PORT/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; } || true

for P in $WEB_PORT; do
  [ "$MODE" = danmu ] && break
  command -v ufw >/dev/null && ufw allow $P/tcp >/dev/null 2>&1 || true
  command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --add-port=$P/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; } || true
done

if [ "$MODE" = moontv ]; then
  echo "[6/6] 网页播放器 MoonTVPlus（端口 $WEB_PORT）"
  # 之前装过精简版时，弹幕服务已不占 3003（WEB=0）
  MEM=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [ "$MEM" -lt 1500 ] && ! swapon --show | grep -q .; then
    echo "    内存 ${MEM}MB，加 2G swap 防止卡死"
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || { apt install -y docker-compose-plugin 2>/dev/null || dnf install -y docker-compose-plugin 2>/dev/null || yum install -y docker-compose-plugin; }
  mkdir -p /opt/moontv
  if [ ! -f /opt/moontv/.env ]; then
    echo "MT_USER=admin" > /opt/moontv/.env
    echo "MT_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)" >> /opt/moontv/.env
    echo "MT_CRON=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)" >> /opt/moontv/.env
  fi
  . /opt/moontv/.env
  cat > /opt/moontv/docker-compose.yml <<YML
services:
  moontv-core:
    image: ghcr.io/mtvpls/moontvplus:latest
    container_name: moontv-core
    restart: unless-stopped
    ports:
      - '$WEB_PORT:3000'
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    environment:
      - USERNAME=\${MT_USER}
      - PASSWORD=\${MT_PASS}
      - CRON_PASSWORD=\${MT_CRON}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://moontv-kvrocks:6666
      - CONFIG_SUBSCRIPTION_URL=http://host.docker.internal:$PORT/sub/moontv.txt
      - DANMAKU_API_BASE=http://host.docker.internal:$PORT
      - NEXT_PUBLIC_SITE_NAME=哈哈影视
    depends_on:
      - moontv-kvrocks
  moontv-kvrocks:
    image: apache/kvrocks
    container_name: moontv-kvrocks
    restart: unless-stopped
    volumes:
      - kvrocks-data:/var/lib/kvrocks
volumes:
  kvrocks-data:
YML
  cd /opt/moontv && docker compose pull -q; docker compose up -d --remove-orphans || { echo "    Docker 防火墙链丢失，重启 docker 后重试"; systemctl restart docker; sleep 5; docker compose up -d --remove-orphans; }
  cd - >/dev/null
fi

curl -fsSL "$RAW/danmu/ys.sh" -o /usr/local/bin/ys && chmod +x /usr/local/bin/ys || true

IP=$(pubip); IP=${IP:-你的IP}
RUN_VER=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/version" 2>/dev/null || true)
OKALL=1
if wait_up "$PORT" ok; then
  echo "✅ 弹幕服务已启动，运行版本 v${RUN_VER:-?}：http://$IP:$PORT/danmu?name=狂飙&episode=第1集"
else
  OKALL=0; echo "❌ 弹幕服务没响应，查看日志：journalctl -u danmu -n 50"
fi
if [ "$MODE" = web ]; then
  WB=$(grep -oP '^WEB_BIND=\K.*' /etc/danmu.env 2>/dev/null | tail -1 || true)
  OCC=$(ss -ltnpH "sport = :$WEB_PORT" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
  if [ -n "$OCC" ] && ! echo "$OCC" | grep -qi python; then
    OKALL=0; echo "❌ 网页播放器端口 $WEB_PORT 被 $OCC 占用，换端口：WEB_PORT=其它端口 bash deploy_web.sh"
  elif wait_up "$WEB_PORT" ""; then echo "✅ 网页播放器已启动（端口 $WEB_PORT）"
  else
    OKALL=0
    echo "❌ 网页播放器端口 $WEB_PORT 没响应${OCC:+（端口被 $OCC 占用）}，查看日志：journalctl -u danmu -n 50"
  fi
fi
if [ "$MODE" = moontv ]; then
  wait_up "$WEB_PORT" "" && echo "✅ MoonTVPlus 已启动（端口 $WEB_PORT）" || { OKALL=0; echo "⚠ MoonTVPlus 还没响应（首次拉镜像可能要几分钟）：cd /opt/moontv && docker compose logs --tail 50"; }
fi
DD=$(grep -oP '^DANMU_DOMAIN=\K.*' /etc/danmu.env 2>/dev/null | tail -1 || true)
echo "📺 OK影视 配置地址：${DD:-http://$IP:$PORT}/sub/jjoo.json"
echo "🔄 采集站自动更新：$( [ "$SE" = off ] && echo 已关闭 || systemctl list-timers danmu-sites.timer --no-pager 2>/dev/null | awk 'NR==2{print "下次 "$1,$2,$3}' || true)  手动更新：ys 选 4"
if [ "$MODE" = web ]; then
  WD=$(grep -oP '^WEB_DOMAIN=\K.*' /etc/danmu.env 2>/dev/null | tail -1 || true)
  echo "🌐 网页播放器：${WD:-http://$IP:$WEB_PORT}"
  if [ -n "$NEW_AUTH" ]; then
    echo "   账号 $WEB_USER   密码 $WEB_PASS   （请记下来；忘了可输入 ys 重置）"
  else
    echo "   账号 $(AUTHC --auth-user 2>/dev/null || true)（密码不变，ys 选 7 查看）"
  fi
fi
if [ "$MODE" = moontv ]; then
  echo "🌐 网页播放器：http://$IP:$WEB_PORT   账号 $MT_USER  密码 $MT_PASS （存在 /opt/moontv/.env）"
  echo "   首次进后台 → 配置文件 → 订阅地址填 http://host.docker.internal:$PORT/sub/moontv.txt 并打开「自动更新」，采集站更新后网页版每小时自动同步"
fi
[ "$MODE" = danmu ] && echo "提示：云厂商安全组要放行 $PORT 端口。" || echo "提示：云厂商安全组要放行 $PORT 和 $WEB_PORT 端口。"
echo "管理菜单：输入 ys（安装/更新/重启/日志/卸载）"
[ "$OKALL" = 1 ] || exit 1
