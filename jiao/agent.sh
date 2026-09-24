#!/bin/bash
set -e
CENTRAL_IP="${1:-}"
TOKEN="${2:-}"
CENTRAL_URL="http://${CENTRAL_IP}:18089/api/register"
WG_INTERFACE=central-mgmt
WG_NETWORK=10.231.47
WG_ADDRESS_PREFIX=24
WG_SERVER_ADDRESS=10.231.47.1
WG_DIR=/etc/wireguard
WG_CONFIG=$WG_DIR/central-mgmt.conf
WG_PRIVATE_KEY=$WG_DIR/central-mgmt-privatekey
[ -n "$CENTRAL_IP" ] || { echo "缺少中央 VPS IP"; exit 1; }
[ -n "$TOKEN" ] || { echo "缺少注册码"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "未安装 curl"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "未安装 python3"; exit 1; }
install_wireguard() {
if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
return
fi
if command -v apt-get >/dev/null 2>&1; then
apt-get update -y >/dev/null 2>&1
apt-get install -y wireguard >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
dnf install -y wireguard-tools >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
yum install -y wireguard-tools >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
apk add wireguard-tools >/dev/null 2>&1
else
echo "无法安装 WireGuard"
exit 1
fi
}
get_ipv4() {
curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
}
get_ipv6() {
curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true
}
get_country() {
local ip="$1"
[ -n "$ip" ] || return
curl -fsS --max-time 5 "https://ipapi.co/$ip/country_name/" 2>/dev/null || true
}
install_wireguard
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"
if [ ! -f "$WG_PRIVATE_KEY" ]; then
wg genkey > "$WG_PRIVATE_KEY"
chmod 600 "$WG_PRIVATE_KEY"
fi
PRIVATE_KEY=$(cat "$WG_PRIVATE_KEY")
PUBLIC_KEY=$(printf '%s' "$PRIVATE_KEY" | wg pubkey)
IPV4=$(get_ipv4)
IPV6=$(get_ipv6)
COUNTRY=$(get_country "$IPV4")
HOSTNAME=$(hostname)
OS=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null || uname -s)
ARCH=$(uname -m)
PAYLOAD=$(python3 - "$TOKEN" "$PUBLIC_KEY" "$IPV4" "$IPV6" "$COUNTRY" "$HOSTNAME" "$OS" "$ARCH" <<'PY'
import json,sys
print(json.dumps({
"token":sys.argv[1],
"wg_public_key":sys.argv[2],
"ipv4":sys.argv[3],
"ipv6":sys.argv[4],
"country":sys.argv[5],
"hostname":sys.argv[6],
"os":sys.argv[7],
"arch":sys.argv[8]
},ensure_ascii=False))
PY
)
RESULT=$(curl -fsS --max-time 15 -X POST "$CENTRAL_URL" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "$RESULT"
WG_ADDRESS=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("wg_address",""))')
WG_SERVER_KEY=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("wg_server_public_key",""))')
WG_ENDPOINT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("wg_endpoint",""))')
if [ -z "$WG_ADDRESS" ] || [ -z "$WG_SERVER_KEY" ] || [ -z "$WG_ENDPOINT" ]; then
echo "WG 参数获取失败"
exit 1
fi
cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $WG_ADDRESS/$WG_ADDRESS_PREFIX
PrivateKey = $PRIVATE_KEY
[Peer]
PublicKey = $WG_SERVER_KEY
Endpoint = $WG_ENDPOINT
AllowedIPs = $WG_NETWORK.0/24
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONFIG"
systemctl enable "wg-quick@$WG_INTERFACE" >/dev/null 2>&1 || true
systemctl restart "wg-quick@$WG_INTERFACE"
sleep 2
if ping -c 2 -W 3 "$WG_SERVER_ADDRESS" >/dev/null 2>&1; then
echo
echo "========================================"
echo "WG 通信成功"
echo "本机 WG: $WG_ADDRESS"
echo "中央 WG: $WG_SERVER_ADDRESS"
echo "接口: $WG_INTERFACE"
echo "========================================"
else
echo
echo "========================================"
echo "WG 已启动，但无法 ping 中央 VPS"
echo "本机 WG: $WG_ADDRESS"
echo "中央 WG: $WG_SERVER_ADDRESS"
echo "接口: $WG_INTERFACE"
echo "========================================"
wg show "$WG_INTERFACE"
fi
