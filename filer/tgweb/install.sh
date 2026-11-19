#!/bin/bash
set -e
# 一键安装：Debian / Ubuntu，root 运行
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/hyp3365/tgweb/main/install.sh)
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "用法：bash <(curl -fsSL https://raw.githubusercontent.com/hyp3365/tgweb/main/install.sh)"
  echo "  已安装过再跑一次就是更新：会拉最新代码并重建，已有 .env 和 data 不会被覆盖。"
  echo "  加 --force 会跳过 pull，直接强制更新到远端最新版（本地改动会被暂存，见下面）。"
  echo "  例：bash <(curl -fsSL https://raw.githubusercontent.com/hyp3365/tgweb/main/install.sh) --force"
  echo "安装目录：\${TGWEB_DIR:-/root/telegram-stream}，已有 .env 不会被覆盖，改配置用 tg 命令。"
  echo "安装后必须绑定域名或有证书的 IP，不提供 HTTP 访问；证书要先放在 /root/cert/<域名或IP>/ 里，或用 TGWEB_DOMAIN 环境变量指定要绑的域名/IP。"
  exit 0
fi
# --force：直接强制更新，不先试 pull。没加时也一样能更新：pull 成功就用 pull，
# pull 失败（本地改动、分支分叉）时只要能拉到远端就强制更新，不会悄悄用旧代码构建；
# 只有拉都拉不到（网络问题）时才停下来。
FORCE_UPDATE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
  FORCE_UPDATE=1
fi
REPO="https://github.com/hyp3365/tgweb.git"
DIR="${TGWEB_DIR:-/root/telegram-stream}"
if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行。"
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  echo "只支持 Debian / Ubuntu（需要 apt）。"
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
# python3：tg 改写 .env、校验密码、随机生成账号密码都要用（docker 镜像里有 python，宿主机上也要有）
apt-get install -y git curl ca-certificates openssl python3
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { echo "Docker Compose 未装好，请检查 Docker 安装。"; exit 1; }

# 取代码：已有目录且不是 git 仓库时先备份，再全新克隆，并把旧 .env 和 data 拷回来
if [ -d "$DIR/.git" ]; then
  # 已安装过再跑就是更新。强制更新只动 git 跟踪的文件，.env 和 data/ 里的 session
  # 是未跟踪文件，不会被 reset 动到；本地改过跟踪文件时先 stash 起来（不带 -u，
  # 不动未跟踪文件），更新完如果需要可以在目录里用 git stash pop 找回来。
  _force_update() {
    local _branch _old _new _stashed=0
    _branch="$(git -C "$DIR" symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's|^origin/||')"
    if [ -z "$_branch" ] || ! git -C "$DIR" rev-parse --verify "origin/$_branch" >/dev/null 2>&1; then
      _branch="main"
    fi
    _old="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo "?")"
    if ! git -C "$DIR" fetch origin; then
      echo "拉取远端失败，已停止安装，没有用旧代码继续构建，请检查网络后再试。"
      exit 1
    fi
    _new="$(git -C "$DIR" rev-parse --short "origin/$_branch" 2>/dev/null || echo "?")"
    if [ "$_old" = "$_new" ]; then
      echo "已经是最新版（$_new）。"
      return 0
    fi
    if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null | grep -v '^??' || true)" ]; then
      # 和 tg update 一样的道理：stash 成功才算暂存住了，失败就直接停，
      # 不能先谎称已暂存再 reset 把改动丢掉。
      if git -C "$DIR" stash push -m "install force-update backup $_old" 2>/dev/null; then
        _stashed=1
        echo "注意：本地改动已暂存到 git stash，在 $DIR 里用 git stash pop 可以找回来。"
      else
        echo "本地改动暂存失败，已停止安装，改动没有动。"
        exit 1
      fi
    fi
    git -C "$DIR" reset --hard "origin/$_branch" || {
      if [ "$_stashed" = "1" ]; then git -C "$DIR" stash pop 2>/dev/null || true; fi
      echo "强制更新失败，已停止安装，本地改动已还原。"
      exit 1
    }
    echo "已强制更新：$_old -> $_new"
  }
  if [ "$FORCE_UPDATE" = "1" ]; then
    echo "已加 --force，直接强制更新到远端最新版。"
    _force_update
  elif ! (cd "$DIR" && git pull --ff-only); then
    echo "git pull 没法快进（本地有改动或分支分叉），改走强制更新，不会悄悄用旧代码构建。"
    _force_update
  fi
elif [ -d "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
  BACKUP="${DIR}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$DIR" "$BACKUP"
  git clone "$REPO" "$DIR"
  [ -f "$BACKUP/.env" ] && cp "$BACKUP/.env" "$DIR/.env"
  [ -d "$BACKUP/data" ] && mkdir -p "$DIR/data" && cp -r "$BACKUP/data/." "$DIR/data/" 2>/dev/null || true
  echo "旧目录已备份到 $BACKUP"
else
  git clone "$REPO" "$DIR"
fi

# 装 tg 快捷命令和域名工具
cp "$DIR/tg" /usr/local/bin/tg
chmod +x /usr/local/bin/tg
cp "$DIR/tg-domain.sh" /usr/local/bin/tg-domain
chmod +x /usr/local/bin/tg-domain
# tg 默认目录就是 /root/telegram-stream；装到别的目录时用 TG_APP_DIR 指向它
if [ "$DIR" != "/root/telegram-stream" ]; then
  echo "注意：tg 默认目录是 /root/telegram-stream，你装在 $DIR，请用 TG_APP_DIR=$DIR tg"
fi

# ---------- 网页账号 / 密码：随机生成 ----------
# 和 tg 里的 gen_auth_value 一模一样（改一处就要同步另一处，tests/test_web_auth.py 会直接比对函数体）。
# 12-24 位，数字 / 小写 / 大写 / 特殊符号各至少一个；
# 符号只用 .env 里安全、手机键盘好打的 !@%^&*-_=+.,:?~——
# docker compose 解析无引号的 .env 会把 $ # ' " \ 和空白认错，写进去和实际值就不一致了。
gen_auth_value() {
  python3 - << 'PY'
import secrets
SYMBOLS = "!@%^&*-_=+.,:?~"
LOWER = "abcdefghijklmnopqrstuvwxyz"
UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS = "0123456789"
ALL = LOWER + UPPER + DIGITS + SYMBOLS
n = 12 + secrets.randbelow(13)          # 12..24 位，每次都不一样
chars = [secrets.choice(LOWER), secrets.choice(UPPER), secrets.choice(DIGITS), secrets.choice(SYMBOLS)]
chars += [secrets.choice(ALL) for _ in range(n - 4)]
secrets.SystemRandom().shuffle(chars)   # 四类必选位不能固定排在前四位
print("".join(chars))
PY
}

# 手工输入的账号/密码里有没有 .env 认错的字符（$ # ' " \ 和空白）；有就返回 0。
_bad_env_char() {
  python3 -c 'import sys; v=sys.argv[1]; bad=[chr(36),chr(35),chr(39),chr(34),chr(92)]; sys.exit(0 if any(c in v for c in bad) or any(c.isspace() for c in v) else 1)' "$1"
}

# 各退出分支统一打印刚生成的账号密码（或提示去 tg show-auth 看已有值）
_show_new_auth() {
  if [ "$NEW_ENV" = "1" ]; then
    if [ -n "$NEW_USER" ]; then echo "网页账号（刚生成的，请记下来）：$NEW_USER"; else echo "网页账号：用你刚才填的那个（忘了就用 tg show-auth 查看）。"; fi
    if [ -n "$NEW_PW" ]; then echo "网页密码（刚生成的，请记下来）：$NEW_PW"; else echo "网页密码：用你刚才填的那个（忘了就用 tg show-auth 查看）。"; fi
  else
    echo "网页账号密码：已有 .env 的不变，用 tg show-auth 在服务器终端查看。"
  fi
}

# .env：已有就不动，没有就新建
NEW_ENV=0
NEW_PW=""
NEW_USER=""
if [ ! -f "$DIR/.env" ]; then
  NEW_ENV=1
  API_ID="${TG_API_ID:-}"
  API_HASH="${TG_API_HASH:-}"
  WEB_USER="${WEB_USERNAME:-}"
  WEB_PW="${WEB_PASSWORD:-}"
  if [ -t 0 ] && [ -z "$API_ID" ]; then
    read -r -p "api_id（纯数字，回车跳过，装完再用 tg set-id 补）： " API_ID || true
  fi
  if [ -t 0 ] && [ -z "$API_HASH" ]; then
    read -r -s -p "api_hash（输入不显示，回车跳过，装完再用 tg set-hash 补）： " API_HASH || true
    echo ""
  fi
  if [ -t 0 ] && [ -z "$WEB_USER" ]; then
    read -r -p "网页账号（回车自动生成 12-24 位随机账号）： " WEB_USER || true
  fi
  if [ -t 0 ] && [ -z "$WEB_PW" ]; then
    read -r -s -p "网页密码（输入不显示，回车自动生成 12-24 位随机密码）： " WEB_PW || true
    echo ""
  fi
  if [ -z "$API_ID" ]; then API_ID="0"; fi
  if [ -z "$API_HASH" ]; then API_HASH="placeholder"; fi
  if [ -n "$WEB_USER" ] && _bad_env_char "$WEB_USER"; then
    echo "提供的网页账号含美元符、井号、引号、空格或反斜杠，.env 会被 docker compose 认错，已改成自动生成的安全账号。"
    WEB_USER=""
  fi
  if [ -z "$WEB_USER" ]; then
    WEB_USER="$(gen_auth_value)"
    if [ -z "$WEB_USER" ]; then echo "生成随机网页账号失败（检查 python3 是否可用）。"; exit 1; fi
    NEW_USER="$WEB_USER"
  fi
  if [ -z "$WEB_PW" ]; then
    WEB_PW="$(gen_auth_value)"
    if [ -z "$WEB_PW" ]; then echo "生成随机网页密码失败（检查 python3 是否可用）。"; exit 1; fi
    NEW_PW="$WEB_PW"
  elif _bad_env_char "$WEB_PW"; then
    echo "提供的网页密码含美元符、井号、引号、空格或反斜杠，.env 会被 docker compose 认错，已改成自动生成的安全密码。"
    WEB_PW="$(gen_auth_value)"
    if [ -z "$WEB_PW" ]; then echo "生成随机网页密码失败（检查 python3 是否可用）。"; exit 1; fi
    NEW_PW="$WEB_PW"
  fi
  WEB_PATH="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
  if [ "${#WEB_PATH}" != "24" ]; then WEB_PATH="$(openssl rand -hex 12)"; fi
  printf 'TG_API_ID=%s\nTG_API_HASH=%s\nWEB_USERNAME=%s\nWEB_PASSWORD=%s\nWEB_PATH=%s\n' "$API_ID" "$API_HASH" "$WEB_USER" "$WEB_PW" "$WEB_PATH" > "$DIR/.env"
  chmod 600 "$DIR/.env"
else
  echo "已有 .env，保留不动，改配置用 tg 命令。"
  # 老版本升级上来的 .env 里只有 WEB_PASSWORD：不用改也能继续用（登录页账号留空），只提醒一句
  if grep -q '^WEB_PASSWORD=' "$DIR/.env" 2>/dev/null && ! grep -q '^WEB_USERNAME=' "$DIR/.env" 2>/dev/null; then
    echo "提示：新版支持网页账号。你现在只设了密码——登录页账号留空、只填密码就能进；想加个账号就运行 tg reset-auth（直接回车会自动生成）。"
  fi
  if ! grep -q "^WEB_PATH=" "$DIR/.env" 2>/dev/null; then
    _NP="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
    if [ "${#_NP}" = "24" ]; then
      printf 'WEB_PATH=%s\n' "$_NP" >> "$DIR/.env"
      echo "已有 .env 里没有访问路径，已自动生成一个24位路径，完整地址见绑定后的提示，或用 tg show-path 查看。"
    fi
  fi
fi

(cd "$DIR" && docker compose up -d --build)
sleep 5
docker compose -f "$DIR/docker-compose.yml" ps
# 健康检查必须带 WEB_PATH：app 的中间件对不带访问路径的 / 直接回 404，
# 以前这里裸 curl /，新装（一定会生成 WEB_PATH）永远报“启动检查失败”，其实服务是好的。
_HEALTH_PATH="$(grep -E '^WEB_PATH=' "$DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
case "$(grep -E '^WEB_PATH_ENABLED=' "$DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
  0|false|off|no) _HEALTH_PATH="" ;;
esac
if [ -n "$_HEALTH_PATH" ]; then
  _HEALTH_URL="http://127.0.0.1:9393/$_HEALTH_PATH"
else
  _HEALTH_URL="http://127.0.0.1:9393/"
fi
if curl -fsS "$_HEALTH_URL" >/dev/null 2>&1; then
  echo "服务已启动。"
else
  echo "服务启动检查失败（检查的是 $_HEALTH_URL），请在 $DIR 里看 docker compose logs。"
fi
# 9393 只绑回环，不直接对公网开放；不提供 HTTP 访问：安装后必须绑定域名或有证书的 IP，走 HTTPS 才能进应用
# 旧的 HTTP 反代必须删掉，否则 HTTPS 会被 HTTP 明文绕过
rm -f /etc/nginx/conf.d/tgweb.conf
if ! command -v nginx >/dev/null 2>&1; then
  apt-get install -y nginx 2>/dev/null || true
fi
# 已有 HTTPS 站点（tg domain 绑过的域名，或原来 IP 的 HTTPS 站）就保留不动，不用重新绑
# 注意不能用两个跨文件的 grep 拼结果：一个文件有 443、另一个文件反代 9393，
# 拼起来也会误判成“已有 tgweb 的 HTTPS 站”，然后直接退出不绑定，实际上 tgweb 根本没对外。
# 默认端口从 8000 改成了 9393：旧版生成的 tgweb 反代配置一并改过去，否则保留下来的 HTTPS 站点会连不上。
for _f in /etc/nginx/conf.d/tgweb-domain.conf /etc/nginx/conf.d/tgweb-domain-*.conf /etc/nginx/sites-available/video; do
  [ -f "$_f" ] || continue
  if grep -q "127.0.0.1:8000" "$_f" 2>/dev/null; then
    sed -i 's#127\.0\.0\.1:8000#127.0.0.1:9393#g' "$_f"
    _PORT_MIGRATED=1
  fi
  if grep -q 'proxy_set_header X-Real-IP' "$_f" 2>/dev/null && ! grep -qi 'CF-Connecting-IP' "$_f" 2>/dev/null; then
    sed -i '/proxy_set_header X-Real-IP/a\        proxy_set_header CF-Connecting-IP "";' "$_f"
    _PORT_MIGRATED=1
  fi
done
if [ "${_PORT_MIGRATED:-0}" = "1" ] && command -v nginx >/dev/null 2>&1; then
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
fi
_HAS_HTTPS=0
for _f in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
  if [ -f "$_f" ] && grep -q "listen 443 ssl" "$_f" 2>/dev/null && grep -q "proxy_pass http://127.0.0.1:9393" "$_f" 2>/dev/null; then
    _HAS_HTTPS=1
    break
  fi
done
if [ "$_HAS_HTTPS" = "1" ]; then
  echo "检测到已有 HTTPS 站点，保留不动，继续用原来的 https 地址访问。"
  _show_new_auth
  exit 0
fi
if ! command -v nginx >/dev/null 2>&1; then
  echo "Nginx 未装好，无法建 HTTPS 站点。服务只在 127.0.0.1:9393 运行，不提供 HTTP 访问。"
  echo "装好 Nginx、准备好证书后，运行 tg domain <域名或IP> 绑定。"
  exit 1
fi
BIND_NAME="${TGWEB_DOMAIN:-}"
if [ -z "$BIND_NAME" ] && [ -t 0 ]; then
  read -r -p "要绑定的域名或 IP（证书要已在 /root/cert/<域名或IP>/ 里，留空则不绑定）： " BIND_NAME || true
fi
BIND_NAME="$(echo "$BIND_NAME" | tr -d '[:space:]')"
if [ -z "$BIND_NAME" ]; then
  echo ""
  echo "未绑定域名或 IP 证书，外部访问未开通：服务只在 127.0.0.1:9393 运行，不提供 HTTP 访问。"
  echo "请把证书放到 /root/cert/<域名或IP>/fullchain.pem 和 privkey.pem，然后运行 tg domain <域名或IP> 绑定，再用 https://<域名或IP>/<访问路径> 访问（路径用 tg show-path 查看）。"
  if [ -d /root/cert ] || [ -d /etc/nginx/cert ]; then
    echo "本机已有证书："
    for d in /root/cert/* /etc/nginx/cert/*; do
      if [ -f "$d/fullchain.pem" ] && [ -f "$d/privkey.pem" ]; then echo "  $(basename "$d")"; fi
    done 2>/dev/null || true
  fi
  _show_new_auth
  exit 1
fi
if [ -f "/root/cert/$BIND_NAME/fullchain.pem" ] && [ -f "/root/cert/$BIND_NAME/privkey.pem" ]; then
  :
elif [ -f "/etc/nginx/cert/$BIND_NAME/fullchain.pem" ] && [ -f "/etc/nginx/cert/$BIND_NAME/privkey.pem" ]; then
  :
else
  echo ""
  echo "域名/IP $BIND_NAME 的证书不存在：/root/cert/$BIND_NAME/ 或 /etc/nginx/cert/$BIND_NAME/ 里要有 fullchain.pem 和 privkey.pem。"
  echo "安装不会提供 HTTP 访问。请准备好证书后运行 tg domain $BIND_NAME 绑定（tg domain 还能用泛域名/父域名证书），再用 https://$BIND_NAME/<访问路径> 访问（路径用 tg show-path 查看）。"
  _show_new_auth
  exit 1
fi
if /usr/local/bin/tg-domain "$BIND_NAME"; then
  echo ""
  _WP="$(grep -E "^WEB_PATH=" "$DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
  [ -z "$_HEALTH_PATH" ] && _WP=""   # 访问路径已关闭（WEB_PATH_ENABLED=0）
  if [ -n "$_WP" ]; then
    echo "访问地址：https://$BIND_NAME/$_WP"
  else
    echo "访问地址：https://$BIND_NAME"
  fi
  _show_new_auth
else
  echo "绑定 $BIND_NAME 失败，外部访问未开通，不提供 HTTP 访问。"
  exit 1
fi
