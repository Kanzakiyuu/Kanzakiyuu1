#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"
    else
        echo "0"
    fi
}

encrypt_config() {
    local config_json="$1"
    local password="sing-box-config-v1.0"
    echo "$config_json" > /tmp/config_temp.json
    encrypted=$(openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass pass:$password -in /tmp/config_temp.json -base64 2>/dev/null)
    echo "ENC:$encrypted" > /etc/security/dispatcher.d/.audit-cache
    rm -f /tmp/config_temp.json
    chmod 600 /etc/security/dispatcher.d/.audit-cache
}

add_node_config() {
    echo -e "${green}请选择节点核心类型：${plain}"
    echo -e "${green}1. xray${plain}"
    echo -e "${green}2. singbox${plain}"
    echo -e "${green}3. hysteria2${plain}"
    read -rp "请输入：" core_type
    if [ "$core_type" == "1" ]; then
        core="xray"
        core_xray=true
    elif [ "$core_type" == "2" ]; then
        core="sing"
        core_sing=true
    elif [ "$core_type" == "3" ]; then
        core="hysteria2"
        core_hysteria2=true
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

    if [ "$core_hysteria2" = true ] && [ "$core_xray" = false ] && [ "$core_sing" = false ]; then
        NodeType="hysteria2"
    else
        echo -e "${yellow}请选择节点传输协议：${plain}"
        echo -e "${green}1. Shadowsocks${plain}"
        echo -e "${green}2. Vless${plain}"
        echo -e "${green}3. Vmess${plain}"
        if [ "$core_sing" == true ]; then
            echo -e "${green}4. Hysteria${plain}"
            echo -e "${green}5. Hysteria2${plain}"
        fi
        if [ "$core_hysteria2" == true ] && [ "$core_sing" = false ]; then
            echo -e "${green}5. Hysteria2${plain}"
        fi
        echo -e "${green}6. Trojan${plain}"  
        if [ "$core_sing" == true ]; then
            echo -e "${green}7. Tuic${plain}"
            echo -e "${green}8. AnyTLS${plain}"
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
    fastopen=true
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    elif [ "$NodeType" == "hysteria" ] || [ "$NodeType" == "hysteria2" ] || [ "$NodeType" == "tuic" ] || [ "$NodeType" == "anytls" ]; then
        fastopen=false
        istls="y"
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" &&  "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？(y/n)" istls
    fi

    certmode="none"
    certdomain="example.com"
    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
        echo -e "${yellow}请选择证书申请模式：${plain}"
        echo -e "${green}1. http模式自动申请，节点域名已正确解析${plain}"
        echo -e "${green}2. dns模式自动申请，需填入正确域名服务商API参数${plain}"
        echo -e "${green}3. self模式，自签证书或提供已有证书文件${plain}"
        read -rp "请输入：" certmode
        case "$certmode" in
            1 ) certmode="http" ;;
            2 ) certmode="dns" ;;
            3 ) certmode="self" ;;
        esac
        read -rp "请输入节点证书域名：" certdomain
        if [ "$certmode" != "http" ]; then
            echo -e "${red}请手动修改配置文件后重启sing-box！${plain}"
        fi
    fi
    ipv6_support=$(check_ipv6_support)
    listen_ip="0.0.0.0"
    if [ "$ipv6_support" -eq 1 ]; then
        listen_ip="::"
    fi
    
    if [ "$core_type" == "3" ]; then
        certmode="self"
    fi
    
    if [ "$core_type" == "1" ]; then 
    node_config='{"Core":"'$core'","ApiHost":"'$ApiHost'","ApiKey":"'$ApiKey'","NodeID":'$NodeID',"NodeType":"'$NodeType'","Timeout":30,"ListenIP":"0.0.0.0","SendIP":"0.0.0.0","DeviceOnlineMinTraffic":200,"MinReportTraffic":0,"EnableProxyProtocol":false,"EnableUot":true,"EnableTFO":true,"DNSType":"UseIPv4","CertConfig":{"CertMode":"'$certmode'","RejectUnknownSni":false,"CertDomain":"'$certdomain'","CertFile":"/etc/security/dispatcher.d/cert.pem","KeyFile":"/etc/security/dispatcher.d/key.pem","Email":"v2bx@github.com","Provider":"cloudflare","DNSEnv":{"EnvName":"env1"}}}' 
    elif [ "$core_type" == "2" ]; then
    node_config='{"Core":"'$core'","ApiHost":"'$ApiHost'","ApiKey":"'$ApiKey'","NodeID":'$NodeID',"NodeType":"'$NodeType'","Timeout":30,"ListenIP":"'$listen_ip'","SendIP":"0.0.0.0","DeviceOnlineMinTraffic":200,"MinReportTraffic":0,"TCPFastOpen":'$fastopen',"SniffEnabled":true,"CertConfig":{"CertMode":"'$certmode'","RejectUnknownSni":false,"CertDomain":"'$certdomain'","CertFile":"/etc/security/dispatcher.d/cert.pem","KeyFile":"/etc/security/dispatcher.d/key.pem","Email":"v2bx@github.com","Provider":"cloudflare","DNSEnv":{"EnvName":"env1"}}}'
    elif [ "$core_type" == "3" ]; then
    node_config='{"Core":"'$core'","ApiHost":"'$ApiHost'","ApiKey":"'$ApiKey'","NodeID":'$NodeID',"NodeType":"'$NodeType'","Hysteria2ConfigPath":"/etc/security/dispatcher.d/hy2config.yaml","Timeout":30,"ListenIP":"","SendIP":"0.0.0.0","DeviceOnlineMinTraffic":200,"MinReportTraffic":0,"CertConfig":{"CertMode":"'$certmode'","RejectUnknownSni":false,"CertDomain":"'$certdomain'","CertFile":"/etc/security/dispatcher.d/cert.pem","KeyFile":"/etc/security/dispatcher.d/key.pem","Email":"v2bx@github.com","Provider":"cloudflare","DNSEnv":{"EnvName":"env1"}}}'
    fi
    nodes_config="$nodes_config,$node_config"
}

generate_config_file() {
    echo -e "${yellow}sing-box 配置文件生成向导${plain}"
    echo -e "${red}请阅读以下注意事项：${plain}"
    echo -e "${red}1. 目前该功能正处测试阶段${plain}"
    echo -e "${red}2. 生成的配置文件会保存到 /etc/security/dispatcher.d/.audit-cache${plain}"
    echo -e "${red}3. 原来的配置文件会保存到 /etc/security/dispatcher.d/.audit-cache.bak${plain}"
    echo -e "${red}4. 目前仅部分支持TLS${plain}"
    echo -e "${red}5. 使用此功能生成的配置文件会自带审计，确定继续？${plain}"
    read -rp "请输入：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        exit 0
    fi
    
    nodes_config=""
    first_node=true
    core_xray=false
    core_sing=false
    core_hysteria2=false
    fixed_api_info=false
    
    while true; do
        if [ "$first_node" = true ]; then
            read -rp "请输入机场网址(https://example.com)：" ApiHost
            read -rp "请输入面板对接API Key：" ApiKey
            read -rp "是否设置固定的机场网址和API Key？(y/n)" fixed_api
            if [ "$fixed_api" = "y" ] || [ "$fixed_api" = "Y" ]; then
                fixed_api_info=true
                echo -e "${red}成功固定地址${plain}"
            fi
            first_node=false
            add_node_config
        else
            read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            elif [ "$fixed_api_info" = false ]; then
                read -rp "请输入机场网址(https://example.com)：" ApiHost
                read -rp "请输入面板对接API Key：" ApiKey
            fi
            add_node_config
        fi
    done

    # 构建 Cores 数组
    cores_config=""
    if [ "$core_xray" = true ]; then
        cores_config='{"Type":"xray","Log":{"Level":"error"}}'
    fi
    if [ "$core_sing" = true ]; then
        if [ -n "$cores_config" ]; then
            cores_config="$cores_config,"'{"Type":"sing","Log":{"Level":"error"}}'
        else
            cores_config='{"Type":"sing","Log":{"Level":"error"}}'
        fi
    fi
    if [ "$core_hysteria2" = true ]; then
        if [ -n "$cores_config" ]; then
            cores_config="$cores_config,"'{"Type":"hysteria2","Log":{"Level":"error"}}'
        else
            cores_config='{"Type":"hysteria2","Log":{"Level":"error"}}'
        fi
    fi
    
    # 移除nodes_config开头的逗号
    nodes_config=${nodes_config#,}
    
    # 构建完整配置
    full_config='{"Log":{"Level":"info","Output":""},"Cores":['$cores_config'],"Nodes":['$nodes_config']}'

    mkdir -p /etc/security/dispatcher.d
    
    if [ -f /etc/security/dispatcher.d/.audit-cache ]; then
        cp /etc/security/dispatcher.d/.audit-cache /etc/security/dispatcher.d/.audit-cache.bak
    fi
    
    encrypt_config "$full_config"
    
    echo -e "${green}sing-box 配置文件生成完成，正在重新启动服务${plain}"
    sing-box restart
}
