#!/bin/bash
# 「18. 网页面板（fanout）」菜单的离线单测。
#
# 不碰真机：systemctl / nginx / ss / ip / curl / sysctl 全部用临时假命令，
# 所有路径都指到临时目录，卸载测试删的也只是临时文件。
#
# 运行：bash jiao/test-fanout-panel.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/sing-box-08.sh"
PASS=0
FAIL=0
FAILED_NAMES=""

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok; else bad "$3: 期望 [$2] 实际 [$1]"; fi; }
assert_contains() {
    case "$1" in
        *"$2"*) ok ;;
        *) bad "$3: 输出里没有 [$2]" ;;
    esac
}
assert_not_contains() {
    case "$1" in
        *"$2"*) bad "$3: 不该出现 [$2]" ;;
        *) ok ;;
    esac
}
assert_file() { if [ -e "$1" ]; then ok; else bad "$2: 不存在 $1"; fi; }
assert_no_file() { if [ ! -e "$1" ]; then ok; else bad "$2: 应该删掉 $1"; fi; }
section() { echo; echo "== $1"; }

# ── 假命令与临时环境 ──────────────────────────────────
ORIG_PATH="$PATH"

write_fake() {
    local name="$1"
    shift
    cat > "$ROOT/bin/$name"
    chmod +x "$ROOT/bin/$name"
}

make_fakes() {
    write_fake systemctl <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "$FAKE_LOG"
cmd="$1"; shift || true
case "$cmd" in
  is-active)  [ -f "$FAKE_STATE/active" ] && exit 0 || exit 1 ;;
  is-enabled) [ -f "$FAKE_STATE/enabled" ] && exit 0 || exit 1 ;;
  enable)     [ "${1:-}" = "--now" ] && touch "$FAKE_STATE/active"; touch "$FAKE_STATE/enabled"; exit 0 ;;
  disable)    [ "${1:-}" = "--now" ] && rm -f "$FAKE_STATE/active"; rm -f "$FAKE_STATE/enabled"; exit 0 ;;
  start|restart) touch "$FAKE_STATE/active"; exit 0 ;;
  stop|kill)  rm -f "$FAKE_STATE/active"; exit 0 ;;
  *) exit 0 ;;
esac
EOS

    write_fake nginx <<'EOS'
#!/bin/bash
echo "nginx $*" >> "$FAKE_LOG"
if [ "${1:-}" = "-t" ]; then
  mode=$(cat "$FAKE_STATE/nginx_mode" 2>/dev/null || echo ok)
  case "$mode" in
    fail)  echo "nginx: [emerg] fake failure" >&2; exit 1 ;;
    http2) if grep -q 'http2 on;' "$FANOUT_NGX" 2>/dev/null; then
             echo "nginx: [emerg] unknown directive http2" >&2; exit 1
           else exit 0; fi ;;
    *) exit 0 ;;
  esac
fi
exit 0
EOS

    write_fake ss   <<'EOS'
#!/bin/bash
echo "ss $*" >> "$FAKE_LOG"
exit 0
EOS
    write_fake ip   <<'EOS'
#!/bin/bash
echo "ip $*" >> "$FAKE_LOG"
exit 0
EOS
    write_fake journalctl <<'EOS'
#!/bin/bash
echo "journal-line: fanout started"
EOS
    write_fake curl <<'EOS'
#!/bin/bash
echo "curl $*" >> "$FAKE_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && : > "$out"
case "$*" in *api.ipify.org*) echo "203.0.113.7" ;; esac
exit 0
EOS
    write_fake sysctl <<'EOS'
#!/bin/bash
echo "sysctl $*" >> "$FAKE_LOG"
case "${1:-}" in
  -n)  key="${2:-}"; f="$FAKE_STATE/${key//./_}"; cat "$f" 2>/dev/null || echo 0 ;;
  -qw) kv="${2:-}"; key="${kv%%=*}"; val="${kv#*=}"; echo "$val" > "$FAKE_STATE/${key//./_}" ;;
esac
exit 0
EOS
    write_fake dpkg <<'EOS'
#!/bin/bash
exit 1
EOS
    write_fake apt-get <<'EOS'
#!/bin/bash
exit 0
EOS
    write_fake rpm <<'EOS'
#!/bin/bash
exit 1
EOS
    write_fake apk <<'EOS'
#!/bin/bash
exit 1
EOS
    write_fake pacman <<'EOS'
#!/bin/bash
exit 1
EOS
    write_fake dnf <<'EOS'
#!/bin/bash
exit 0
EOS
    write_fake clear <<'EOS'
#!/bin/bash
exit 0
EOS
}

reset_env() {
    ROOT=$(mktemp -d)
    export ROOT
    mkdir -p "$ROOT/bin" "$ROOT/state"
    export FAKE_LOG="$ROOT/fake.log"
    export FAKE_STATE="$ROOT/state"
    : > "$FAKE_LOG"
    export PATH="$ROOT/bin:$ORIG_PATH"
    make_fakes

    export HOME="$ROOT/home"
    export FANOUT_FORCE_INIT=systemd
    export FANOUT_WAIT_TRIES=2
    export FANOUT_WORK_DIR="$ROOT/var/lib/fanout"
    export FANOUT_UNIT=fanout
    export FANOUT_BIN="$ROOT/usr/local/bin/fanout"
    export FANOUT_OLD_MENU="$ROOT/usr/local/bin/f"
    export FANOUT_NGX="$ROOT/etc/nginx/conf.d/fanout-panel.conf"
    export FANOUT_SINGBOX_DIR="$ROOT/etc/sing-box"
    export FANOUT_SINGBOX_CONF="$ROOT/etc/sing-box/conf"
    export FANOUT_SYSCTL_DIR="$ROOT/etc/sysctl.d"
    export FANOUT_NETNS_DIR="$ROOT/run/netns"
    export FANOUT_UNIT_DIR="$ROOT/etc/systemd/system"
    export FANOUT_INITD_DIR="$ROOT/etc/init.d"
    export FANOUT_LOG_FILE="$ROOT/var/log/fanout.log"
    export FANOUT_GO_DIR="$ROOT/usr/local/go"
    export FANOUT_GOPATH="$ROOT/home/go"
    export FANOUT_ROOT_GOPATH="$ROOT/root/go"
    export FANOUT_GO_CACHE="$ROOT/root/.cache/go-build"
    export FANOUT_GO_CONFIG="$ROOT/root/.config/go"
    export FANOUT_PROFILE_FILES="$ROOT/etc/profile $ROOT/root/.bashrc"
    mkdir -p "$HOME" "$FANOUT_UNIT_DIR" "$FANOUT_SYSCTL_DIR" "$FANOUT_NETNS_DIR" \
             "$FANOUT_SINGBOX_CONF" "$(dirname "$FANOUT_NGX")" "$(dirname "$FANOUT_BIN")" \
             "$(dirname "$FANOUT_PROFILE_FILES%% *")"

    load_panel
}

# 从 sing-box-08.sh 抽出网页面板那一整段（含 f.sh 功能搬过来的全部函数），
# 配上脚本自己的颜色/输入函数。整份脚本带 root 检查，不能直接 source。
load_panel() {
    sed -n '/^#fanout socks$/,/^# 选择目标出站时的通用函数/p' "$SRC" | sed '$d' > "$ROOT/panel.sh"
    cat > "$ROOT/preamble.sh" <<'PRE'
re="\033[0m"; red="\e[1;91m"; green="\e[1;32m"; yellow="\e[1;33m"
purple="\e[1;35m"; skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -r -p "$(red "$1")" "$2" || return 1; }
_reset_int_trap() { return 0; }
verified_download() { return 0; }
manage_packages() { return 0; }
ensure_nginx_autostart() { return 0; }
# 域名设置里复用的证书选择：测试里用环境变量顶掉，不跑真实证书流程
check_and_issue_ssl() {
    domain="${TEST_DOMAIN:-}"
    cert_file="${TEST_CERT:-}"
    key_file="${TEST_KEY:-}"
    [ -n "$domain" ]
}
PRE
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/preamble.sh"
    . "$ROOT/panel.sh"
}

mk_installed() {
    mkdir -p "$FANOUT_WORK_DIR" "$(dirname "$FANOUT_BIN")"
    printf '#!/bin/bash\necho "fanout ${FAKE_VERSION:-v1.3.1}"\n' > "$FANOUT_BIN"
    chmod +x "$FANOUT_BIN"
    printf '{\n  "port": 8899,\n  "listen_addr": ""\n}\n' > "$FANOUT_WORK_DIR/settings.json"
    echo "AbCd1234xy" > "$FANOUT_WORK_DIR/basepath"
    echo "secretpw" > "$FANOUT_WORK_DIR/password"
    touch "$FAKE_STATE/active"
}

nginx_conf() { # $1=domain $2=port
    mkdir -p "$(dirname "$FANOUT_NGX")"
    cat > "$FANOUT_NGX" <<EOF
server {
    listen ${2:-443} ssl;
    http2 on;
    server_name ${1:-panel.example.com};
    ssl_certificate /tmp/fullchain.pem;
    ssl_certificate_key /tmp/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:8899;
    }
}
EOF
}

log_has() { grep -q -- "$1" "$FAKE_LOG"; }

# ══════════════════ 测试开始 ══════════════════

section "状态、版本、端口、地址与隧道数"
reset_env
assert_eq "$(fanout_status_text)" "未安装" "没装时状态"
mk_installed
assert_eq "$(fanout_status_text)" "运行中" "装了且服务在跑"
rm -f "$FAKE_STATE/active"
assert_eq "$(fanout_status_text)" "已关闭" "装了但没跑"
touch "$FAKE_STATE/active"
assert_eq "$(fanout_port)" "8899" "端口读 settings.json"
assert_eq "$(fanout_version)" "v1.3.1" "版本读 -version"
assert_eq "$(fanout_autostart_text)" "disabled" "没设自启"
touch "$FAKE_STATE/enabled"
assert_eq "$(fanout_autostart_text)" "enabled" "设了自启"
assert_eq "$(fanout_url)" "http://203.0.113.7:8899/AbCd1234xy/" "没域名时是 IP:端口/路径"
mkdir -p "$FANOUT_NETNS_DIR/fo1" "$FANOUT_NETNS_DIR/fo2"
assert_eq "$(fanout_tunnel_count)" "2" "netns 计数"
nginx_conf panel.example.com 443
assert_eq "$(fanout_url)" "https://panel.example.com/AbCd1234xy/" "有域名时 https 且不带端口"
nginx_conf panel.example.com 8443
assert_eq "$(fanout_url)" "https://panel.example.com:8443/AbCd1234xy/" "非 443 端口要带上"

section "等服务就绪（口令 + 路径）"
reset_env
mk_installed
if fanout_wait_ready; then ok; else bad "口令与路径都在时应立刻就绪"; fi
rm -f "$FANOUT_WORK_DIR/basepath"
if fanout_wait_ready; then bad "路径为空时不该判就绪"; else ok; fi
echo "AbCd1234xy" > "$FANOUT_WORK_DIR/basepath"
rm -f "$FANOUT_WORK_DIR/password"
if fanout_wait_ready; then bad "口令为空时不该判就绪"; else ok; fi

section "域名设置：成功写入反代并切到只监听 127.0.0.1"
reset_env
mk_installed
export TEST_DOMAIN="panel.example.com"
export TEST_CERT="$ROOT/fullchain.pem"
export TEST_KEY="$ROOT/privkey.pem"
out=$(echo "443" | fanout_set_domain)
assert_file "$FANOUT_NGX" "生成了 fanout-panel.conf"
conf=$(cat "$FANOUT_NGX")
assert_contains "$conf" "server_name panel.example.com" "server_name 正确"
assert_contains "$conf" "proxy_pass http://127.0.0.1:8899" "反代到 panel 端口"
assert_contains "$conf" "listen 443 ssl" "监听 443"
assert_contains "$conf" "http2 on;" "新 nginx 用 http2 on"
assert_contains "$conf" "TLSv1.2 TLSv1.3" "只开 TLS1.2/1.3"
assert_contains "$conf" "client_max_body_size 128M" "上传上限"
assert_contains "$conf" "Upgrade \$http_upgrade" "带 WebSocket 头"
assert_contains "$(cat "$FANOUT_WORK_DIR/settings.json")" '"listen_addr": "127.0.0.1"' "后端只听本机"
if log_has "systemctl restart fanout"; then ok; else bad "改完要重启 fanout"; fi
if log_has "reload nginx\|enable --now nginx"; then ok; else bad "改完要 reload/enable nginx"; fi
assert_contains "$(fanout_url)" "https://panel.example.com/AbCd1234xy/" "地址变 https 域名"

section "域名设置：老 nginx 不认 http2 on 时自动降级"
reset_env
mk_installed
echo http2 > "$FAKE_STATE/nginx_mode"
export TEST_DOMAIN="old.example.com"; export TEST_CERT="$ROOT/c.pem"; export TEST_KEY="$ROOT/k.pem"
echo "443" | fanout_set_domain >/dev/null
conf=$(cat "$FANOUT_NGX" 2>/dev/null)
assert_not_contains "$conf" "http2 on;" "老 nginx 分支应删掉 http2 on"
assert_contains "$conf" "ssl http2;" "改用 listen ... ssl http2"
assert_eq "$(cat "$FAKE_STATE/nginx_mode")" "http2" "环境没被测试改坏"

section "域名设置：nginx -t 失败自动还原"
reset_env
mk_installed
echo fail > "$FAKE_STATE/nginx_mode"
export TEST_DOMAIN="bad.example.com"; export TEST_CERT="$ROOT/c.pem"; export TEST_KEY="$ROOT/k.pem"
if echo "443" | fanout_set_domain >/dev/null; then bad "nginx 检测失败时应返回非 0"; else ok; fi
assert_no_file "$FANOUT_NGX" "失败的配置不该留下"
assert_contains "$(cat "$FANOUT_WORK_DIR/settings.json")" '"listen_addr": ""' "失败时监听地址不变"

section "域名设置：已有配置时直接更换（覆盖 + 重载）"
reset_env
mk_installed
nginx_conf old.example.com 443
export TEST_DOMAIN="new.example.com"; export TEST_CERT="$ROOT/c.pem"; export TEST_KEY="$ROOT/k.pem"
echo "443" | fanout_set_domain >/dev/null
conf=$(cat "$FANOUT_NGX")
assert_contains "$conf" "server_name new.example.com" "新域名覆盖旧域名"
assert_not_contains "$conf" "old.example.com" "旧域名不该残留"
assert_no_file "${FANOUT_NGX}.bak" "成功后临时备份要清掉"

section "域名设置：泛域名自动拼前缀、IPv6 加方括号"
reset_env
mk_installed
export TEST_DOMAIN="*.example.org"; export TEST_CERT="$ROOT/c.pem"; export TEST_KEY="$ROOT/k.pem"
printf 'panel\n443\n' | fanout_set_domain >/dev/null
assert_contains "$(cat "$FANOUT_NGX")" "server_name panel.example.org" "泛域名拼出子域名"
reset_env
mk_installed
export TEST_DOMAIN="2001:db8::1"; export TEST_CERT="$ROOT/c.pem"; export TEST_KEY="$ROOT/k.pem"
printf '443\n' | fanout_set_domain >/dev/null
assert_contains "$(cat "$FANOUT_NGX")" "server_name [2001:db8::1]" "IPv6 域名加方括号"

section "移除域名：删反代、恢复所有网卡监听"
reset_env
mk_installed
nginx_conf panel.example.com 443
printf '%s\n' '{"port": 8899, "listen_addr": "127.0.0.1"}' > "$FANOUT_WORK_DIR/settings.json"
echo "y" | fanout_remove_domain >/dev/null
assert_no_file "$FANOUT_NGX" "反代配置应删除"
assert_contains "$(cat "$FANOUT_WORK_DIR/settings.json")" '"listen_addr": ""' "监听地址恢复"
assert_contains "$(fanout_url)" "http://203.0.113.7:8899/" "地址回到 IP:端口"
assert_eq "$(ls "$ROOT/etc/nginx/conf.d" | wc -l | tr -d ' ')" "0" "证书目录不动、只删自己的 conf"

section "改端口：settings.json / 老 unit / nginx 反代一起改"
reset_env
mk_installed
mkdir -p "$FANOUT_UNIT_DIR"
printf '[Service]\nExecStart=/usr/local/bin/fanout -dir %s -web 8899\n' "$FANOUT_WORK_DIR" > "$FANOUT_UNIT_DIR/fanout.service"
nginx_conf panel.example.com 443
echo "9000" | fanout_change_port >/dev/null
assert_contains "$(cat "$FANOUT_WORK_DIR/settings.json")" '"port": 9000' "settings 端口"
assert_contains "$(cat "$FANOUT_UNIT_DIR/fanout.service")" "-web 9000" "老 unit 的 -web 同步"
assert_contains "$(cat "$FANOUT_NGX")" "proxy_pass http://127.0.0.1:9000" "nginx 反代端口同步"
if log_has "systemctl restart fanout"; then ok; else bad "改端口后要重启"; fi

section "改端口：非法/被占用要拒绝"
reset_env
mk_installed
if echo "99999" | fanout_change_port >/dev/null; then bad "越界端口应拒绝"; else ok; fi
assert_contains "$(cat "$FANOUT_WORK_DIR/settings.json")" '"port": 8899' "拒绝时配置不变"

section "改口令与访问路径"
reset_env
mk_installed
echo "BrandNewPw" | fanout_change_password >/dev/null
assert_eq "$(cat "$FANOUT_WORK_DIR/password")" "BrandNewPw" "口令写入"
assert_contains "$(fanout_show_addr)" "BrandNewPw" "地址页显示新口令"
echo "newpath" | fanout_change_basepath >/dev/null
assert_eq "$(cat "$FANOUT_WORK_DIR/basepath")" "newpath" "路径写入"
assert_contains "$(fanout_url)" "/newpath/" "地址带上新路径"
if echo "bad/pa th" | fanout_change_basepath >/dev/null; then bad "非法路径应拒绝"; else ok; fi

section "开机自启开关"
reset_env
mk_installed
touch "$FAKE_STATE/enabled"
fanout_toggle_autostart >/dev/null
if log_has "systemctl disable fanout"; then ok; else bad "应调用 disable"; fi
assert_eq "$(fanout_autostart_text)" "disabled" "已关闭自启"
fanout_toggle_autostart >/dev/null
if log_has "systemctl enable fanout"; then ok; else bad "应调用 enable"; fi
assert_eq "$(fanout_autostart_text)" "enabled" "已开启自启"

section "IPv6 防漏开关"
reset_env
mk_installed
assert_eq "$(fanout_ipv6_state)" "enabled" "默认启用"
echo "y" | fanout_toggle_ipv6 >/dev/null
assert_file "$FANOUT_SYSCTL_DIR/99-fanout-ipv6.conf" "写了 sysctl 配置"
assert_contains "$(cat "$FANOUT_SYSCTL_DIR/99-fanout-ipv6.conf")" "all.disable_ipv6 = 1" "禁用整机 IPv6"
assert_eq "$(fanout_ipv6_state)" "disabled" "状态变 disabled"
echo "y" | fanout_toggle_ipv6 >/dev/null
assert_no_file "$FANOUT_SYSCTL_DIR/99-fanout-ipv6.conf" "重新启用时删配置"

section "一键开启：装好、等服务就绪、清掉旧 f"
reset_env
mk_installed
rm -f "$FAKE_STATE/active" "$FAKE_STATE/enabled"
printf '#!/bin/bash\n' > "$FANOUT_OLD_MENU"; chmod +x "$FANOUT_OLD_MENU"
out=$(fanout_enable)
assert_contains "$out" "网页面板已开启" "开启成功"
assert_no_file "$FANOUT_OLD_MENU" "旧的 /usr/local/bin/f 要清掉"
if log_has "systemctl enable --now fanout"; then ok; else bad "应 enable --now"; fi

section "一键开启：15 秒内没口令就摊日志"
reset_env
mk_installed
rm -f "$FANOUT_WORK_DIR/password"
out=$(fanout_enable)
assert_contains "$out" "没准备好" "要报准备失败"
assert_contains "$out" "journal-line" "要打印最近日志排障"

section "一键关闭：停服务、取消自启、数据保留"
reset_env
mk_installed
touch "$FAKE_STATE/enabled"
echo "y" | fanout_disable >/dev/null
assert_eq "$(fanout_status_text)" "已关闭" "服务已停"
assert_eq "$(fanout_autostart_text)" "disabled" "自启已关"
assert_file "$FANOUT_WORK_DIR/password" "数据保留"

section "彻底卸载：程序、配置、数据、Go 全删"
reset_env
mk_installed
mkdir -p "$FANOUT_UNIT_DIR" "$FANOUT_INITD_DIR" "$FANOUT_SINGBOX_CONF" "$FANOUT_GO_DIR/bin" \
         "$FANOUT_ROOT_GOPATH/pkg" "$FANOUT_GO_CACHE" "$FANOUT_GO_CONFIG" "$FANOUT_GOPATH/src"
printf '[Service]\n' > "$FANOUT_UNIT_DIR/fanout.service"
printf '#!/bin/bash\n' > "$FANOUT_OLD_MENU"
printf '{"inbounds":[]}' > "$FANOUT_SINGBOX_CONF/fanout-outbounds.json"
printf '{"route":{}}' > "$FANOUT_SINGBOX_CONF/fanout-route.json"
printf '{"inbounds":[]}' > "$FANOUT_SINGBOX_CONF/vless-reality-1.json"
nginx_conf panel.example.com 443
mkdir -p "$FANOUT_NETNS_DIR/fo1" "$FANOUT_NETNS_DIR/fo9"
printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' > "$FANOUT_SYSCTL_DIR/99-fanout-ipv6.conf"
printf '# profile\nexport PATH=$PATH:/usr/local/go/bin\nexport GOPATH=/root/go\nexport EDITOR=vi\n' > "$ROOT/etc/profile"
printf 'export GOPATH=$HOME/go\n' > "$ROOT/root/.bashrc"

out=$(echo "yes" | fanout_uninstall)
assert_contains "$out" "已彻底卸载" "卸载完成提示"
assert_no_file "$FANOUT_WORK_DIR" "整个数据目录删掉"
assert_no_file "$FANOUT_BIN" "二进制删掉"
assert_no_file "$FANOUT_OLD_MENU" "旧 f 删掉"
assert_no_file "$FANOUT_UNIT_DIR/fanout.service" "unit 删掉"
assert_no_file "$FANOUT_NGX" "nginx 反代删掉"
assert_no_file "$FANOUT_SINGBOX_CONF/fanout-outbounds.json" "fanout 出站删掉"
assert_no_file "$FANOUT_SINGBOX_CONF/fanout-route.json" "fanout 路由删掉"
assert_file "$FANOUT_SINGBOX_CONF/vless-reality-1.json" "别人的入站不能动"
assert_no_file "$FANOUT_SYSCTL_DIR/99-fanout-ipv6.conf" "sysctl 残留删掉"
assert_no_file "$FANOUT_GO_DIR" "Go 安装目录删掉"
assert_no_file "$FANOUT_ROOT_GOPATH" "root 的 GOPATH 删掉"
assert_no_file "$FANOUT_GO_CACHE" "go-build 缓存删掉"
assert_no_file "$FANOUT_GO_CONFIG" "go 配置删掉"
prof=$(cat "$ROOT/etc/profile")
assert_not_contains "$prof" "/usr/local/go/bin" "profile 里的 go PATH 行清掉"
assert_not_contains "$prof" "GOPATH" "profile 里的 GOPATH 行清掉"
assert_contains "$prof" "EDITOR=vi" "profile 其他行保留"
assert_not_contains "$(cat "$ROOT/root/.bashrc")" "GOPATH" "bashrc 的 GOPATH 清掉"
if log_has "systemctl disable --now fanout"; then ok; else bad "要先 stop+disable"; fi
if log_has "daemon-reload"; then ok; else bad "删 unit 后要 daemon-reload"; fi
assert_eq "$(fanout_status_text)" "未安装" "卸载后状态未安装"

section "卸载需要明确确认"
reset_env
mk_installed
echo "y" | fanout_uninstall >/dev/null
assert_file "$FANOUT_WORK_DIR/password" "只输 y 不该真删"

section "WARP 菜单第 7 项直接进网页面板（不再找 f）"
reset_env
fanout_menu() { echo "PANEL-MENU"; }
assert_eq "$(extract_fanout_socks)" "PANEL-MENU" "extract_fanout_socks 调 fanout_menu"

section "菜单项齐全 + 不再出现 f 命令/推广链接"
reset_env
mk_installed
menu_out=$(printf '0\n' | fanout_menu)
for item in "一键开启" "一键关闭" "查看访问地址与口令" "修改监听端口" "修改/重置访问路径" \
            "修改/重置访问口令" "开机自启开关" "隧道列表" "重启面板" "查看近期日志" \
            "更新面板" "IPv6 防漏开关" "域名设置" "彻底卸载"; do
    assert_contains "$menu_out" "$item" "菜单缺项: $item"
done
assert_contains "$menu_out" "运行隧道：" "顶部有隧道数"
assert_contains "$menu_out" "开机自启：" "顶部有自启状态"
src_text=$(cat "$SRC")
for badword in "交流群" "t.me/+ft-zI76oovgwNmRh" "joeyblog"; do
    assert_not_contains "$src_text" "$badword" "脚本里不该有推广内容: $badword"
done
if grep -q '18) fanout_menu' "$SRC"; then ok; else bad "主菜单 18 项要进 fanout_menu"; fi
if grep -q 'command -v f ' "$SRC"; then bad "不该再检测 command -v f"; else ok; fi
if grep -q '^extract_fanout_socks()' "$SRC"; then ok; else bad "extract_fanout_socks 应保留"; fi

section "语法检查"
if bash -n "$SRC"; then ok; else bad "bash -n 失败"; fi

# ── 结果 ──────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
echo "通过 $PASS  失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "全部通过"
