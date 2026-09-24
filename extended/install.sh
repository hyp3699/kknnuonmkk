#!/usr/bin/env bash

server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
config_dir="${conf_dir}/config.json"
client_dir="${work_dir}/url.txt"

export CFIP=${CFIP:-'cf.877774.xyz'}
export CFPORT=${CFPORT:-'443'}

BASE_DIR="/etc/sing-box"
DATA_DIR="$BASE_DIR/user_manager"
LIMIT_DIR="$DATA_DIR/limits"
TRAFFIC_DIR="$DATA_DIR/traffic"
TRAFFIC_STATE="$TRAFFIC_DIR/state.json"
PYTHON="$(command -v python3 2>/dev/null || true)"
log_dir="${work_dir}/logs"

get_available_port() {
    local port
    while true; do
        port=$(shuf -i 10000-59999 -n 1)
        if command_exists ss; then
            if ! ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"; then
                echo "$port"
                return 0
            fi
        elif command_exists netstat; then
            if ! netstat -lntup 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
                echo "$port"
                return 0
            fi
        else
            if ! (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
                echo "$port"
                return 0
            fi
        fi
    done
}

create_shortcut() {
    local local_file="$work_dir/menu.sh"
    if [ -s "$local_file" ]; then
        chmod 700 "$local_file"
        ln -sf "$local_file" /usr/bin/sb
        ln -sf "$local_file" /usr/bin/b
    fi
    if [ -x /usr/bin/sb ] && [ -x /usr/bin/b ]; then
        green "\n快捷命令 sb 和 b 已创建\n"
    else
        red "\n快捷命令创建失败\n"
        return 1
    fi
}

manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    local action=$1
    shift
    local package

    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"

        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y &&
            DEBIAN_FRONTEND=noninteractive apt upgrade -y
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

    local rule
    for rule in "$@"; do
        local port=${rule%/*}
        local proto=${rule#/*}

        [ "$port" == "$rule" ] && proto="tcp"

        [ "$has_ufw" -eq 1 ] && ufw allow in "${port}/${proto}" >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1

        if [ "$has_nft" -eq 1 ]; then
            if ! nft list chain inet filter script_input 2>/dev/null | grep -qw "$proto dport $port"; then
                nft add rule inet filter script_input "$proto" dport "$port" accept comment "ScriptManaged" 2>/dev/null
            fi
        fi
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    if [ "$has_nft" -eq 1 ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null
    fi
}

install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."

    local ARCH_RAW
    local ARCH
    local latest_tag
    local TAR
    local URL
    local nginx_port
    local tuic_port
    local uuid
    local uuid99
    local username
    local password
    local fingerprint
    local dns_strategy

    ARCH_RAW=$(uname -m)

    case "${ARCH_RAW}" in
        x86_64)
            ARCH='amd64'
            ;;
        x86|i686|i386)
            ARCH='386'
            ;;
        aarch64|arm64)
            ARCH='arm64'
            ;;
        armv7l)
            ARCH='armv7'
            ;;
        s390x)
            ARCH='s390x'
            ;;
        *)
            red "不支持的架构: ${ARCH_RAW}"
            return 1
            ;;
    esac
    mkdir -p "${work_dir}"
    chmod 755 "${work_dir}"
    mkdir -p "${conf_dir}"
    chmod 755 "${conf_dir}"
    mkdir -p "${log_dir}"

    nginx_port=$(get_available_port)
    tuic_port=$(get_available_port)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    uuid99=$(cat /proc/sys/kernel/random/uuid)
    username=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 15)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)

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

    allow_port $nginx_port/tcp > /dev/null 2>&1
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))
    
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
      "strategy": "$dns_strategy",
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
        "users": []
        }
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

    return 0
}

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

alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run

description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1
}

add_nginx_conf() {
    if ! command_exists nginx; then
        red "nginx未安装,无法配置订阅服务"
        return 1
    else
        manage_service "nginx" "stop" >/dev/null 2>&1
        pkill nginx >/dev/null 2>&1
    fi

    mkdir -p /etc/nginx/conf.d

    [ -f "/etc/nginx/conf.d/sing-box.conf" ] &&
        cp /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/sing-box.conf.bak.sb

    cat > /etc/nginx/conf.d/sing-box.conf << EOF
server {
    listen $nginx_port;
    listen [::]:$nginx_port;
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    location / {
        return 404;
    }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    if [ -f "/etc/nginx/nginx.conf" ]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.sb >/dev/null 2>&1

        sed -i \
            -e '15{/include \/etc\/nginx\/modules\/\*\.conf/d;}' \
            -e '18{/include \/etc\/nginx\/conf\.d\/\*\.conf/d;}' \
            /etc/nginx/nginx.conf >/dev/null 2>&1

        if ! grep -q "include.*conf.d" /etc/nginx/nginx.conf; then
            local http_end_line
            http_end_line=$(grep -n "^}" /etc/nginx/nginx.conf | tail -1 | cut -d: -f1)

            if [ -n "$http_end_line" ]; then
                sed -i "${http_end_line}i \    include /etc/nginx/conf.d/*.conf;" \
                    /etc/nginx/nginx.conf >/dev/null 2>&1
            fi
        fi
    else
        cat > /etc/nginx/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;

    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    if nginx -t >/dev/null 2>&1; then
        if nginx -s reload >/dev/null 2>&1; then
            green "nginx订阅配置已加载"
        else
            start_nginx >/dev/null 2>&1
        fi
    else
        yellow "nginx配置失败,订阅不可用,但不影响节点使用, issues反馈: https://github.com/eooce/Sing-box/issues"
        restart_nginx >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            green "nginx订阅配置已生效"
        else
            [ -f "/etc/nginx/nginx.conf.bak.sb" ] &&
                cp "/etc/nginx/nginx.conf.bak.sb" /etc/nginx/nginx.conf >/dev/null 2>&1

            restart_nginx >/dev/null 2>&1
        fi
    fi
}

start_singbox() {
    manage_service "sing-box" "start"
}

stop_singbox() {
    manage_service "sing-box" "stop"
}

restart_singbox() {
    manage_service "sing-box" "restart"
}

start_nginx() {
    manage_service "nginx" "start"
}

stop_nginx() {
    manage_service "nginx" "stop"
}

restart_nginx() {
    manage_service "nginx" "restart"
}

uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice

    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"

            if command_exists rc-service; then
                rc-service sing-box stop
                rc-update del sing-box default
                rm -f /etc/init.d/sing-box
            else
                systemctl stop "${server_name}" 2>/dev/null || true
                systemctl disable "${server_name}" 2>/dev/null || true

                systemctl stop singbox-traffic.service 2>/dev/null || true
                systemctl disable singbox-traffic.service 2>/dev/null || true

                rm -f /etc/systemd/system/singbox-traffic.service

                systemctl daemon-reload || true
            fi

            rm -rf "${work_dir}" || true
            rm -rf "${log_dir}" || true
            rm -f /etc/systemd/system/sing-box.service
            rm -f /etc/systemd/system/singbox-traffic.service
            rm -f /etc/nginx/conf.d/sing-box.conf
            rm -f /etc/sing-box/sing-box-name.sh
            rm -rf /etc/sing-box/user_manager

            reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice

            case "${choice}" in
                y|Y)
                    stop_nginx
                    manage_packages uninstall nginx
                    rm -f /etc/nginx/conf.d/sing-box.conf
                    rm -f /etc/nginx/conf.d/sing-box.conf.bak*
                    ;;
                *)
                    yellow "取消卸载Nginx\n\n"
                    ;;
            esac

            green "\nsing-box 卸载成功\n\n"
            exit 0
            ;;
        *)
            purple "已取消卸载操作\n\n"
            ;;
    esac
}

change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}
