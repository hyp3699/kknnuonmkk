server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
config_dir="${conf_dir}/config.json"
client_dir="${work_dir}/url.txt"
export CFIP=${CFIP:-'cf.877774.xyz'} 
export CFPORT=${CFPORT:-'443'} 
uuid=$(cat /proc/sys/kernel/random/uuid)
uuid99=$(cat /proc/sys/kernel/random/uuid)
nginx_port=$(get_available_port)
tuic_port=$(get_available_port)
socks_port=$(get_available_port)
http_port=$(get_available_port)
anytls_port=$(get_available_port)
xtls_reality=$(get_available_port)
vless_tcp_tls=$(get_available_port)
anytls_reality=$(get_available_port)
naive_port=$(get_available_port)
h2_reality=$(get_available_port)
hy2_port=$(get_available_port)
grpc_reality=$(get_available_port)
xhttp_port=$(get_available_port)
xray_xhttp_reality=$(get_available_port)
vless_ws_port=$(get_available_port)
vmess_ws_port=$(get_available_port)
trojan_ws_port=$(get_available_port)
username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

BASE_DIR="/etc/sing-box"
DATA_DIR="$BASE_DIR/user_manager"
LIMIT_DIR="$DATA_DIR/limits"
TRAFFIC_DIR="$DATA_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
PYTHON="$(command -v python3 2>/dev/null || true)"


# 创建快捷指令（自动下载脚本到本地保存）
create_shortcut() {
    local remote_url="https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/jiao/sing-box-cf08.sh"
    local local_file="$work_dir/sb.sh"
    if [ ! -s "$local_file" ]; then
        mkdir -p "$work_dir"
        curl -Lss "$remote_url" -o "$local_file"
    fi
    if [ -s "$local_file" ]; then
        chmod +x "$local_file"
        ln -sf "$local_file" /usr/bin/sb
		ln -sf "$local_file" /usr/bin/b
        if [ -x /usr/bin/sb ]; then
            green "\n快捷指令 sb 已创建\n"
        fi
		if [ -x /usr/bin/b ]; then
            green "\n快捷指令 b 已创建\n"
        fi
    else
        red "\n本地化保存失败，请检查网络后重新运行\n"
        rm -f "$local_file" 
    fi
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装更新系统
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -y
        elif command_exists dnf; then
            dnf update -y
        elif command_exists yum; then
            yum update -y
        elif command_exists apk; then
            apk update && apk upgrade
        else
            yellow "Unknown system!\n"
        fi
        green "finished updated system\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 处理防火墙
allow_port() {
    local has_ufw=0
    local has_firewalld=0
    local has_nft=0
    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists nft && has_nft=1
    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    if [ "$has_nft" -eq 1 ]; then
        if ! nft list table inet filter &>/dev/null; then
            nft add table inet filter
        fi
        if ! nft list chain inet filter input &>/dev/null; then
            nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
        fi
        if ! nft list chain inet filter forward &>/dev/null; then
            nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
        fi
        if ! nft list chain inet filter output &>/dev/null; then
            nft add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
        fi
        if ! nft list chain inet filter script_input &>/dev/null; then
            nft add chain inet filter script_input
        fi
        if ! nft list chain inet filter input 2>/dev/null | grep -q 'jump script_input'; then
            nft insert rule inet filter input jump script_input comment "Jump-to-Script" 2>/dev/null
        fi
        nft add rule inet filter input iif "lo" accept 2>/dev/null
        nft add rule inet filter input ip protocol icmp accept 2>/dev/null
        nft add rule inet filter input ip6 nexthdr icmpv6 accept 2>/dev/null
    fi
    for rule in "$@"; do
        local port=${rule%/*}
        local proto=${rule#*/}
        [ "$port" == "$proto" ] && proto="tcp"
        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        if [ "$has_nft" -eq 1 ]; then
            if ! nft list chain inet filter script_input 2>/dev/null | grep -qw "$proto dport $port"; then
                nft add rule inet filter script_input $proto dport $port accept comment "ScriptManaged" 2>/dev/null
            fi
        fi
    done
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1
    if [ "$has_nft" -eq 1 ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null
    fi
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."
    # 判断系统架构
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l') ARCH='armv7' ;;
        's390x') ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}" && mkdir -p "${conf_dir}"
    # 下载sing-box,cloudflared
    latest_tag=$(curl -fsSL \
    "https://api.github.com/repos/hyp3699/sssssssssssiiii/releases" |
    jq -r '[.[] |
        select(.prerelease==false) |
        select(.draft==false) |
        select(.tag_name | endswith("-xhttp"))
    ][0].tag_name')

[ -n "$latest_tag" ] || {
    red "获取 sing-box 最新版本失败"
    exit 1
}

TAR="sing-box-linux-${ARCH}.tar.gz"
URL="https://github.com/hyp3699/sssssssssssiiii/releases/download/${latest_tag}/${TAR}"
curl -fSL -o "${work_dir}/${TAR}" "$URL" && tar -xzf "${work_dir}/${TAR}" -C "${work_dir}" && chmod +x "${work_dir}/sing-box-linux-${ARCH}" && mv -f "${work_dir}/sing-box-linux-${ARCH}" "${work_dir}/sing-box" && rm -f "${work_dir}/${TAR}"

    chown root:root ${work_dir} && chmod +x ${work_dir}/${server_name}

    # 放行端口
    allow_port $nginx_port/tcp $tuic_port/udp > /dev/null 2>&1
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))
    
   # 生成配置文件
cat > "${config_dir}" << EOF
{
   "http_clients": [
  {
    "tag": "direct",
    "connect_timeout": "5s"
   }
  ],
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  },
  "dns": {
     "servers": [
       {
         "tag": "local",
         "type": "local"
       }
      ],
      "strategy": "prefer_ipv4",
      "final": "local",
      "cache_capacity": 8192,
      "optimistic": {
        "enabled": true,
        "timeout": "3d"
          }
   },
   "services": [
    {
      "type": "api",
      "listen": "127.0.0.1",
      "listen_port": 9093,
      "secret": "$password",
      "dashboard": {
        "enabled": true
      }
    }
  ],
   "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
   },
    "experimental": {
    "v2ray_api": {
      "listen": "127.0.0.1:9094",
      "stats": {
        "enabled": true,
        "users": [
          
        ]
      }
    }
  }
}
EOF
cat > "${conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
	{
      "type": "socks",
      "tag": "warp-40000",
      "server": "127.0.0.1",
      "server_port": 40000
    }
  ]
}
EOF
cat > "${conf_dir}/endpoints.json" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8dfe:d141:69bb:6b80:925/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [78, 135, 76]
        }
      ]
    }
  ]
}
EOF
    cat > "${conf_dir}/route.json" << EOF
{
  "route": {
    "default_http_client": "direct",
    "rule_set": [
      {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs"}
    ],
    "rules": [],
    "final": "direct"
  }
}
EOF
}
# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf/
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload 
    systemctl enable sing-box
    systemctl start sing-box
}
