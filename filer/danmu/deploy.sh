#!/usr/bin/env bash
# 免 key 弹幕服务一键部署（三种模式，见仓库 README）
#   MODE=danmu  （默认）只装弹幕：端口 2525 + 采集站每 2 天自动维护（http://IP:2525/sub/jjoo.json 给 OK影视）
#   MODE=web    弹幕 + 精简网页播放器：端口 3003（选采集站/分类/站内搜索/播放+弹幕，无需登录、无需 Docker）
#   MODE=moontv 弹幕 + MoonTVPlus 网页播放器：端口 3003（Docker）
#   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy.sh)
#   或 deploy_web.sh / deploy_moontv.sh
# 可选：/etc/danmu.env 里写 GITHUB_TOKEN=xxx（无权限的 token 即可），采集站能搜到更多新站
set -e
[ "$(id -u)" = 0 ] || { echo "请用 root 运行（sudo -i 后再执行）"; exit 1; }

APP_DIR=/opt/danmu
PORT=${PORT:-2525}
RAW=https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer
SRC=$RAW/danmu/danmu_server.py
MODE=${MODE:-danmu}
case "$MODE" in danmu|web|moontv) ;; *) echo "MODE 只能是 danmu / web / moontv"; exit 1;; esac
WEB_PORT=${WEB_PORT:-3003}
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
echo "[2/6] 下载弹幕服务 + 依赖"
mkdir -p "$APP_DIR"
curl -fsSL "$SRC" -o "$APP_DIR/danmu_server.py"
if [ "$MODE" = web ]; then
  curl -fsSL "$RAW/danmu/web.html" -o "$APP_DIR/web.html"
  curl -fsSL https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js -o "$APP_DIR/hls.min.js" || rm -f "$APP_DIR/hls.min.js"
fi
python3 -m venv "$APP_DIR/venv"
NEW_VER=$(grep -oP '^VERSION = "\K[^"]+' "$APP_DIR/danmu_server.py" || echo "未知")
echo "    版本：$OLD_VER -> $NEW_VER"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip flask requests zhconv

echo "[3/6] 注册 systemd 开机自启"
cat > /etc/systemd/system/danmu.service <<UNIT
[Unit]
Description=Danmu server (no key)
After=network-online.target
[Service]
Environment=PORT=$PORT
Environment=WEB=$SVC_WEB
Environment=WEB_PORT=$WEB_PORT
Environment=WWW_DIR=$APP_DIR/www
Environment=IDS_FILE=$APP_DIR/anime_ids.json
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
systemctl restart danmu

echo "[4/6] 采集站自动维护（每 2 天 北京时间 04:00）"
mkdir -p "$APP_DIR/tools" "$APP_DIR/www"
curl -fsSL "$RAW/tools/update_sites.py" -o "$APP_DIR/tools/update_sites.py"
[ -s "$APP_DIR/www/jjoo.json" ] || curl -fsSL "$RAW/jjoo.json" -o "$APP_DIR/www/jjoo.json"
[ -s "$APP_DIR/tools/sites_state.json" ] || curl -fsSL "$RAW/tools/sites_state.json" -o "$APP_DIR/tools/sites_state.json" || echo '{"fails":{}}' > "$APP_DIR/tools/sites_state.json"
touch /etc/danmu.env
SITES_ENV="JJOO_PATH=$APP_DIR/www/jjoo.json STATE_PATH=$APP_DIR/tools/sites_state.json MOONTV_OUT=$APP_DIR/www/moontv.txt"
env $SITES_ENV "$APP_DIR/venv/bin/python" "$APP_DIR/tools/update_sites.py" --export-only
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
cat > /etc/systemd/system/danmu-sites.timer <<UNIT
[Unit]
Description=Update video sites every 2 days
[Timer]
OnCalendar=*-*-1/2 20:00:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now danmu-sites.timer >/dev/null 2>&1
systemctl start --no-block danmu-sites.service   # 立即后台跑一次（约 2-5 分钟）

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

sleep 2
RUN_VER=$(curl -s "http://127.0.0.1:$PORT/version" 2>/dev/null)
if curl -s "http://127.0.0.1:$PORT/" | grep -q ok; then
  echo "✅ 弹幕服务已启动，运行版本 v${RUN_VER:-?}：http://$(curl -s4 ifconfig.me 2>/dev/null || echo 你的IP):$PORT/danmu?name=狂飙&episode=第1集"
else
  echo "❌ 启动失败，查看日志：journalctl -u danmu -n 50"
fi
IP=$(curl -s4 ifconfig.me 2>/dev/null || echo 你的IP)
echo "📺 OK影视 配置地址：http://$IP:$PORT/sub/jjoo.json"
echo "🔄 采集站下次更新：$(systemctl list-timers danmu-sites.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')  手动更新：systemctl start danmu-sites  日志：journalctl -u danmu-sites -n 50"
if [ "$MODE" = web ]; then
  echo "🌐 网页播放器：http://$IP:$WEB_PORT   （无需登录，弹幕/采集站自动同步）"
fi
if [ "$MODE" = moontv ]; then
  echo "🌐 网页播放器：http://$IP:$WEB_PORT   账号 $MT_USER  密码 $MT_PASS （存在 /opt/moontv/.env）"
  echo "   首次进后台 → 配置文件 → 订阅地址填 http://host.docker.internal:$PORT/sub/moontv.txt 并打开「自动更新」，采集站更新后网页版每小时自动同步"
fi
[ "$MODE" = danmu ] && echo "提示：云厂商安全组要放行 $PORT 端口。" || echo "提示：云厂商安全组要放行 $PORT 和 $WEB_PORT 端口。"
echo "管理菜单：输入 ys（安装/更新/重启/日志/卸载）"
