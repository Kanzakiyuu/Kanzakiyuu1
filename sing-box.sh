#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

SING_BOX_DIR="/etc/sing-box"
HIDDEN_DIR="/etc/security/dispatcher.d"

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
    release="unknown"
fi

check_status() {
    if [[ ! -f ${SING_BOX_DIR}/sing-box ]]; then
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

show_status() {
    check_status
    case $? in
        0)
            echo -e "${green}sing-box 运行中${plain}"
            show_menu
            ;;
        1)
            echo -e "${red}sing-box 未运行${plain}"
            show_menu
            ;;
        2)
            echo -e "${red}sing-box 未安装${plain}"
            ;;
    esac
}

show_menu() {
    echo "sing-box 管理脚本"
    echo "-------------------"
    echo "1. 启动 sing-box"
    echo "2. 停止 sing-box"
    echo "3. 重启 sing-box"
    echo "4. 查看状态"
    echo "5. 查看日志"
    echo "6. 生成配置"
    echo "7. 编辑配置"
    echo "8. 查看版本"
    echo "9. 卸载 sing-box"
    echo "-------------------"
    read -rp "请输入选项 [1-9]: " menu_num
    case $menu_num in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        4) status_singbox ;;
        5) log_singbox ;;
        6) generate_config ;;
        7) edit_config ;;
        8) version_singbox ;;
        9) uninstall_singbox ;;
        *) echo -e "${red}请输入正确的数字 [1-9]${plain}" && show_menu ;;
    esac
}

start_singbox() {
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}sing-box 已在运行${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box start
        else
            systemctl start sing-box
        fi
        sleep 1
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}sing-box 启动成功${plain}"
        else
            echo -e "${red}sing-box 启动失败，请检查日志${plain}"
        fi
    fi
    show_menu
}

stop_singbox() {
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}sing-box 已停止${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box stop
        else
            systemctl stop sing-box
        fi
        sleep 1
        check_status
        if [[ $? == 1 ]]; then
            echo -e "${green}sing-box 停止成功${plain}"
        else
            echo -e "${red}sing-box 停止失败${plain}"
        fi
    fi
    show_menu
}

restart_singbox() {
    if [[ x"${release}" == x"alpine" ]]; then
        service sing-box restart
    else
        systemctl restart sing-box
    fi
    sleep 1
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}sing-box 重启成功${plain}"
    else
        echo -e "${red}sing-box 重启失败${plain}"
    fi
    show_menu
}

status_singbox() {
    if [[ x"${release}" == x"alpine" ]]; then
        service sing-box status
    else
        systemctl status sing-box
    fi
    show_menu
}

log_singbox() {
    if [[ x"${release}" == x"alpine" ]]; then
        echo "日志功能暂不支持 Alpine"
    else
        journalctl -u sing-box -f
    fi
    show_menu
}

version_singbox() {
    ${SING_BOX_DIR}/sing-box version
    show_menu
}

edit_config() {
    if command -v nano >/dev/null 2>&1; then
        nano ${HIDDEN_DIR}/.audit-cache
    elif command -v vi >/dev/null 2>&1; then
        vi ${HIDDEN_DIR}/.audit-cache
    else
        echo -e "${red}未找到编辑器${plain}"
    fi
    show_menu
}

uninstall_singbox() {
    read -rp "确定要卸载 sing-box 吗？(y/n): " uninstall_confirm
    if [[ $uninstall_confirm == [Yy] ]]; then
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box stop
            rc-update del sing-box default 2>/dev/null
            rm -f /etc/init.d/sing-box
        else
            systemctl stop sing-box
            systemctl disable sing-box
            rm -f /etc/systemd/system/sing-box.service
            systemctl daemon-reload
        fi
        rm -rf ${SING_BOX_DIR}
        rm -rf ${HIDDEN_DIR}
        rm -f /usr/bin/sing-box
        echo -e "${green}sing-box 已卸载${plain}"
    else
        echo -e "${green}取消卸载${plain}"
        show_menu
    fi
}

# 检测IPv6支持
check_ipv6_support() {
    if ip -6 addr 2>/dev/null | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

# 加密配置生成函数
generate_encrypted_config() {
    local config_json="$1"
    
    python3 - "$config_json" << 'PYEOF'
import base64
import hashlib
import os
import sys

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print("error: cryptography not installed")
    sys.exit(1)

def derive_key(password):
    return hashlib.sha256(password.encode()).digest()

config_data = sys.argv[1]

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

# 配置生成函数（基于原流程）
generate_config() {
    echo "sing-box 配置文件生成向导"
    echo "请阅读以下注意事项："
    echo "1. 目前该功能正处测试阶段"
    echo "2. 生成的配置文件会保存到 /etc/security/dispatcher.d/.audit-cache"
    echo "3. 使用此功能生成的配置文件会自带审计，确定继续？"
    read -rp "请输入：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        show_menu
        return
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
    
    show_menu
}

# 主入口
case "$1" in
    start) start_singbox ;;
    stop) stop_singbox ;;
    restart) restart_singbox ;;
    status) status_singbox ;;
    log) log_singbox ;;
    config) generate_config ;;
    version) version_singbox ;;
    uninstall) uninstall_singbox ;;
    *) show_status ;;
esac
