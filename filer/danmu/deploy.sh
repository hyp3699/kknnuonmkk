#!/usr/bin/env bash
# 免 key 弹幕服务一键部署（端口 2525）
# 数据直接取自 腾讯视频 / 爱奇艺 / 芒果TV / B站，不需要任何 AppId
# 一键安装：
#   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy.sh)
set -e
[ "$(id -u)" = 0 ] || { echo "请用 root 运行（sudo -i 后再执行）"; exit 1; }

APP_DIR=/opt/danmu
PORT=${PORT:-2525}
SRC=https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/danmu_server.py

echo "[1/4] 安装 Python"
if command -v apt >/dev/null; then
  apt update -y && apt install -y python3 python3-venv curl
elif command -v dnf >/dev/null; then
  dnf install -y python3 curl
elif command -v yum >/dev/null; then
  yum install -y python3 curl
fi

OLD_VER=$(grep -oP '^VERSION = "\K[^"]+' "$APP_DIR/danmu_server.py" 2>/dev/null || { [ -f "$APP_DIR/danmu_server.py" ] && echo "旧版(无版本号)" || echo "未安装"; })
echo "[2/4] 下载弹幕服务 + 依赖"
mkdir -p "$APP_DIR"
curl -fsSL "$SRC" -o "$APP_DIR/danmu_server.py"
python3 -m venv "$APP_DIR/venv"
NEW_VER=$(grep -oP '^VERSION = "\K[^"]+' "$APP_DIR/danmu_server.py" || echo "未知")
echo "    版本：$OLD_VER -> $NEW_VER"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip flask requests

echo "[3/4] 注册 systemd 开机自启"
cat > /etc/systemd/system/danmu.service <<UNIT
[Unit]
Description=Danmu server (no key)
After=network-online.target
[Service]
Environment=PORT=$PORT
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/danmu_server.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable danmu >/dev/null 2>&1
systemctl restart danmu

echo "[4/4] 放行端口 $PORT"
command -v ufw >/dev/null && ufw allow $PORT/tcp >/dev/null 2>&1 || true
command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --add-port=$PORT/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; } || true

sleep 2
RUN_VER=$(curl -s "http://127.0.0.1:$PORT/version" 2>/dev/null)
if curl -s "http://127.0.0.1:$PORT/" | grep -q ok; then
  echo "✅ 弹幕服务已启动，运行版本 v${RUN_VER:-?}：http://$(curl -s4 ifconfig.me 2>/dev/null || echo 你的IP):$PORT/danmu?name=狂飙&episode=第1集"
else
  echo "❌ 启动失败，查看日志：journalctl -u danmu -n 50"
fi
echo "提示：云厂商安全组也要放行 $PORT 端口。更新：重新执行本命令即可。"
