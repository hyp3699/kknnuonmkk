#!/usr/bin/env bash
# 在你自己的 VPS 上一键部署弹幕服务（端口 2525），完全不碰 9763.kstore.vip
# 一键安装：
#   curl -fsSL https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy.sh | sudo APPID=你的AppId APPSECRET=你的AppSecret bash
set -e

APP_DIR=/opt/danmu
PORT=2525

echo "[1/5] 安装依赖"
if command -v apt >/dev/null; then
  apt update -y && apt install -y python3 python3-pip python3-venv
elif command -v yum >/dev/null; then
  yum install -y python3 python3-pip
fi

echo "[2/5] 建虚拟环境 + Flask"
mkdir -p "$APP_DIR"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip flask requests zhconv

echo "[3/5] 写入弹幕服务"
cat > "$APP_DIR/danmu_server.py" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, time, hashlib, base64, re, html
import requests
from flask import Flask, request, Response

APPID     = os.environ.get("APPID", "")
APPSECRET = os.environ.get("APPSECRET", "")
BASE      = "https://api.dandanplay.net"
UA        = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) danmu/1.0"
app = Flask(__name__)

def dd_headers(path):
    ts = str(int(time.time()))
    sig = base64.b64encode(hashlib.sha256((APPID+ts+path+APPSECRET).encode()).digest()).decode()
    return {"X-AppId":APPID,"X-Timestamp":ts,"X-Signature":sig,"Accept":"application/json","User-Agent":UA}

def dd_get(path, params=None):
    r = requests.get(BASE+path, params=params or {}, headers=dd_headers(path), timeout=15)
    r.raise_for_status(); return r.json()

def ep_number(s):
    m = re.search(r"\d+", s or ""); return int(m.group()) if m else None

def find_episode(name, epid):
    animes = (dd_get("/api/v2/search/episodes", {"anime":name}).get("animes") or [])
    if not animes: return None
    want = ep_number(epid)
    animes.sort(key=lambda a: 0 if a.get("animeTitle")==name else 1)
    for a in animes:
        eps = a.get("episodes") or []
        if not eps: continue
        if want is not None:
            for e in eps:
                if ep_number(e.get("episodeTitle","")) == want: return e["episodeId"]
            if 1 <= want <= len(eps): return eps[want-1]["episodeId"]
        return eps[0]["episodeId"]
    return None

def fetch_comments(eid):
    return dd_get(f"/api/v2/comment/{eid}", {"withRelated":"true","chConvert":"0"}).get("comments") or []

def to_xml(comments):
    out = ['<?xml version="1.0" encoding="UTF-8"?>','<i>']
    for c in comments:
        p = (c.get("p") or "").split(",")
        if len(p) < 3: continue
        out.append(f'<d p="{p[0]},{p[1]},25,{p[2]},{int(time.time())},0,0,0">{html.escape(c.get("m",""),quote=False)}</d>')
    out.append('</i>'); return "\n".join(out)

EMPTY = '<?xml version="1.0" encoding="UTF-8"?><i></i>'

@app.route("/danmu")
def danmu():
    name = request.args.get("name","").strip()
    epid = request.args.get("episode") or request.args.get("epid") or ""
    if not name: return Response(EMPTY, mimetype="application/xml")
    try:
        eid = find_episode(name, epid)
        xml = to_xml(fetch_comments(eid)) if eid else EMPTY
    except Exception as e:
        print("err", e); xml = EMPTY
    return Response(xml, mimetype="application/xml")

@app.route("/")
def root(): return "danmu ok"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT","2525")))
PY

echo "[4/5] 配置 dandanplay AppId（免费申请：https://doc.dandanplay.com/open/）"
if [ -n "$APPID" ] && [ -n "$APPSECRET" ]; then
  printf 'APPID=%s\nAPPSECRET=%s\nPORT=%s\n' "$APPID" "$APPSECRET" "$PORT" > /etc/danmu.env
elif [ ! -f /etc/danmu.env ]; then
  printf 'APPID=在这里填你的AppId\nAPPSECRET=在这里填你的AppSecret\nPORT=%s\n' "$PORT" > /etc/danmu.env
  echo ">> 已生成 /etc/danmu.env，填好 AppId 后执行 systemctl restart danmu"
fi
chmod 600 /etc/danmu.env

echo "[5/5] 注册 systemd 开机自启"
cat > /etc/systemd/system/danmu.service <<UNIT
[Unit]
Description=Danmu server
After=network.target
[Service]
EnvironmentFile=/etc/danmu.env
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/danmu_server.py
Restart=always
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable danmu
systemctl restart danmu

# 放行端口（有防火墙就开）
command -v ufw >/dev/null && ufw allow $PORT/tcp || true
command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --add-port=$PORT/tcp; firewall-cmd --reload; } || true

echo "完成。测试： curl 'http://127.0.0.1:$PORT/danmu?name=狂飙&epid=第1集'"
echo "注意：云厂商安全组里也要放行 $PORT 端口。"
