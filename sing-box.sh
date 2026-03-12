#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

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

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/sing-box/sing-box ]]; then
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
            echo -e "sing-box状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "sing-box状态: ${yellow}未运行${plain}"
            ;;
        2)
            echo -e "sing-box状态: ${red}未安装${plain}"
    esac
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}sing-box已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box start
        else
            systemctl start sing-box
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}sing-box 启动成功，请使用 sing-box log 查看运行日志${plain}"
        else
            echo -e "${red}sing-box可能启动失败，请稍后使用 sing-box log 查看日志信息${plain}"
        fi
    fi
    before_show_menu
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service sing-box stop
    else
        systemctl stop sing-box
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}sing-box 停止成功${plain}"
    else
        echo -e "${red}sing-box停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi
    before_show_menu
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        service sing-box restart
    else
        systemctl restart sing-box
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}sing-box 重启成功，请使用 sing-box log 查看运行日志${plain}"
    else
        echo -e "${red}sing-box可能启动失败，请稍后使用 sing-box log 查看日志信息${plain}"
    fi
    before_show_menu
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service sing-box status
    else
        systemctl status sing-box --no-pager -l
    fi
    before_show_menu
}

log() {
    if [[ x"${release}" == x"alpine" ]]; then
        echo -e "${red}alpine系统暂不支持日志查看${plain}\n" && exit 1
    else
        journalctl -u sing-box.service -e --no-pager -f
    fi
    before_show_menu
}

version() {
    echo -n "sing-box 版本："
    /etc/sing-box/sing-box version
    echo ""
    before_show_menu
}

config() {
    echo "sing-box在修改配置后会自动尝试重启"
    vi /etc/sing-box/config.json
    sleep 2
    restart
    check_status
    case $? in
        0)
            echo -e "sing-box状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动sing-box或sing-box自动重启失败，是否查看日志？[Y/n]" && echo
            read -e -rp "(默认: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               log
            fi
            ;;
        2)
            echo -e "sing-box状态: ${red}未安装${plain}"
    esac
}

generate_config() {
    curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/initconfig_sing-box.sh
    source initconfig.sh
    rm initconfig.sh -f
    generate_config_file
    before_show_menu
}

uninstall() {
    read -rp "确定要卸载 sing-box 吗？: " uninstall_confirm
    if [[ $uninstall_confirm == [Yy] ]]; then
        if [[ x"${release}" == x"alpine" ]]; then
            service sing-box stop
            rc-update del sing-box
            rm /etc/init.d/sing-box -f
        else
            systemctl stop sing-box
            systemctl disable sing-box
            rm /etc/systemd/system/sing-box.service -f
            systemctl daemon-reload
            systemctl reset-failed
        fi
        rm /etc/sing-box/ -rf
        rm /etc/security/dispatcher.d/ -rf
        rm /usr/bin/sing-box -f
        echo -e "${green}sing-box 已卸载${plain}"
    else
        echo -e "${green}取消卸载${plain}"
        before_show_menu
    fi
}

show_menu() {
    echo -e "
  ${green}sing-box 管理脚本

  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 sing-box
  ${green}3.${plain} 卸载 sing-box
————————————————
  ${green}4.${plain} 启动 sing-box
  ${green}5.${plain} 停止 sing-box
  ${green}6.${plain} 重启 sing-box
  ${green}7.${plain} 查看 sing-box 状态
  ${green}8.${plain} 查看 sing-box 日志
————————————————
  ${green}12.${plain} 查看 sing-box 版本
  ${green}15.${plain} 生成 sing-box 配置文件
  ${green}16.${plain} 退出脚本
 "
    show_status
    echo && read -rp "请输入选择 [0-16]: " num

    case "${num}" in
        0) config ;;
        1) bash <(curl -Ls https://raw.githubusercontent.com/Kanzakiyuu/Kanzakiyuu1/master/install.sh) ;;
        3) uninstall ;;
        4) start ;;
        5) stop ;;
        6) restart ;;
        7) status ;;
        8) log ;;
        12) version ;;
        15) generate_config ;;
        16) exit ;;
        *) echo -e "${red}请输入正确的数字 [0-16]${plain}" ;;
    esac
}

# 命令行参数支持
if [[ $# > 0 ]]; then
    case $1 in
        "start") start ;;
        "stop") stop ;;
        "restart") restart ;;
        "status") status ;;
        "log") log ;;
        "config") config ;;
        "generate") generate_config ;;
        "uninstall") uninstall ;;
        "version") version ;;
        *) show_menu ;;
    esac
else
    show_menu
fi
