#!/bin/bash
set -e
CENTRAL_IP="${1:-}"
TOKEN="${2:-}"
CENTRAL_URL="http://${CENTRAL_IP}:18089/api/register"
[ -n "$CENTRAL_IP" ] || { echo "缺少中央 VPS IP"; exit 1; }
[ -n "$TOKEN" ] || { echo "缺少注册码"; exit 1; }
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
IPV4=$(get_ipv4)
IPV6=$(get_ipv6)
COUNTRY=$(get_country "$IPV4")
HOSTNAME=$(hostname)
OS=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null || uname -s)
ARCH=$(uname -m)
PAYLOAD=$(python3 - "$TOKEN" "$IPV4" "$IPV6" "$COUNTRY" "$HOSTNAME" "$OS" "$ARCH" <<'PY'
import json,sys
print(json.dumps({
"token":sys.argv[1],
"ipv4":sys.argv[2],
"ipv6":sys.argv[3],
"country":sys.argv[4],
"hostname":sys.argv[5],
"os":sys.argv[6],
"arch":sys.argv[7]
},ensure_ascii=False))
PY
)
RESULT=$(curl -fsS --max-time 15 -X POST "$CENTRAL_URL" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "$RESULT"

