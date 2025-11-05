#!/bin/bash

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
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
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

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat -y >/dev/null 2>&1
        apt-get install ca-certificates wget -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/lib/systemd/network/sing-box ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service sing-box status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status sing-box | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

install_sing-box() {
    if [[ -e /usr/lib/systemd/network/ ]]; then
        rm -rf /usr/lib/systemd/network/
    fi

    mkdir /usr/lib/systemd/network/ -p
    cd /usr/lib/systemd/network/

    if  [ $# == 0 ] ;then
        last_version=$(curl -Ls "https://api.github.com/repos/wyx2685/V2bX/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 sing-box 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 sing-box 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 sing-box 最新版本：${last_version}，开始安装"
        wget --no-check-certificate -N --no-show-progress -O /usr/lib/systemd/network/V2bX-linux.zip https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 sing-box 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip"
        echo -e "开始安装 sing-box $1"
        wget --no-check-certificate -N --no-show-progress -O /usr/lib/systemd/network/V2bX-linux.zip ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 sing-box $1 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi

    unzip V2bX-linux.zip
    rm V2bX-linux.zip -f
    chmod +x V2bX
    mv V2bX sing-box
    mkdir /etc/systemd/network/ -p
    cp geoip.dat /etc/systemd/network/
    cp geosite.dat /etc/systemd/network/
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/sing-box -f
        cat <<EOF > /etc/init.d/sing-box
#!/sbin/openrc-run

name="sing-box"
description="sing-box"

command="/usr/lib/systemd/network/sing-box"
command_args="server"
command_user="root"

pidfile="/run/sing-box.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default
        echo -e "${green}sing-box ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/sing-box.service -f
        cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/lib/systemd/network/
ExecStart=/usr/lib/systemd/network/sing-box server
Restart=always
RestartSec=10
# Disable all logging
StandardOutput=null
StandardError=null
SyslogIdentifier=

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop sing-box
        systemctl enable sing-box
        echo -e "${green}sing-box ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    if [[ ! -f /etc/systemd/network/config.json ]]; then
        cp config.json /etc/systemd/network/
        echo -e ""
        echo -e "全新安装，请先参看教程：https://v2bx.v-50.me/，配置必要的内容"
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box start
        else
            systemctl start sing-box
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}sing-box 重启成功${plain}"
        else
            echo -e "${red}sing-box 可能启动失败，请稍后使用 sing-box log 查看日志信息，若无法启动，则可能更改了配置格式，请前往 wiki 查看：https://github.com/V2bX-project/V2bX/wiki${plain}"
        fi
        first_install=false
    fi

    if [[ ! -f /etc/systemd/network/dns.json ]]; then
        cp dns.json /etc/systemd/network/
    fi
    if [[ ! -f /etc/systemd/network/route.json ]]; then
        cp route.json /etc/systemd/network/
    fi
    if [[ ! -f /etc/systemd/network/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/systemd/network/
    fi
    if [[ ! -f /etc/systemd/network/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/systemd/network/
    fi
    
    # 自动修复配置文件中的路径引用（从 V2bX 到 sing-box）
    echo -e "${yellow}正在修复配置文件中的路径引用...${plain}"
    for config_file in /etc/systemd/network/*.json /etc/systemd/network/*.yml /etc/systemd/network/*.yaml; do
        if [[ -f "$config_file" ]]; then
            sed -i 's|/etc/V2bX|/etc/systemd/network|g' "$config_file" 2>/dev/null
        fi
    done
    echo -e "${green}配置文件路径修复完成${plain}"
    
    # 自动安装管理脚本
    if [[ -f $cur_dir/sing-box.sh ]]; then
        cp $cur_dir/sing-box.sh /usr/bin/sing-box
        chmod +x /usr/bin/sing-box
        echo -e "${green}管理脚本已安装到 /usr/bin/sing-box${plain}"
    elif [[ -f ./sing-box.sh ]]; then
        cp ./sing-box.sh /usr/bin/sing-box
        chmod +x /usr/bin/sing-box
        echo -e "${green}管理脚本已安装到 /usr/bin/sing-box${plain}"
    else
        echo -e "${yellow}警告: 未找到 sing-box.sh 管理脚本${plain}"
        echo -e "${yellow}请将 sing-box.sh 放在与安装脚本同一目录，或手动复制：${plain}"
        echo -e "${green}  cp sing-box.sh /usr/bin/sing-box${plain}"
        echo -e "${green}  chmod +x /usr/bin/sing-box${plain}"
    fi
    cd $cur_dir
    rm -f install.sh
    echo -e ""
    echo "sing-box 管理脚本使用方法 (兼容使用sing-box执行，大小写不敏感): "
    echo "------------------------------------------"
    echo "sing-box              - 显示管理菜单 (功能更多)"
    echo "sing-box start        - 启动 sing-box"
    echo "sing-box stop         - 停止 sing-box"
    echo "sing-box restart      - 重启 sing-box"
    echo "sing-box status       - 查看 sing-box 状态"
    echo "sing-box enable       - 设置 sing-box 开机自启"
    echo "sing-box disable      - 取消 sing-box 开机自启"
    echo "sing-box log          - 查看 sing-box 日志"
    echo "sing-box x25519       - 生成 x25519 密钥"
    echo "sing-box generate     - 生成 sing-box 配置文件"
    echo "sing-box update       - 更新 sing-box"
    echo "sing-box update x.x.x - 更新 sing-box 指定版本"
    echo "sing-box install      - 安装 sing-box"
    echo "sing-box uninstall    - 卸载 sing-box"
    echo "sing-box version      - 查看 sing-box 版本"
    echo "------------------------------------------"
    # 首次安装询问是否生成配置文件
    if [[ $first_install == true ]]; then
        read -rp "检测到你为第一次安装sing-box,是否使用配置生成向导？(y/n): " if_generate
        if [[ $if_generate == [Yy] ]]; then
            # 注意：需要将 initconfig_sing-box.sh 放在当前目录
            if [[ -f ./initconfig_sing-box.sh ]]; then
                source ./initconfig_sing-box.sh
                generate_config_file
            else
                echo -e "${yellow}未找到配置生成脚本 initconfig_sing-box.sh${plain}"
                echo -e "${yellow}请参考教程手动配置: https://v2bx.v-50.me/${plain}"
            fi
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_sing-box $1
