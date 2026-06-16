#!/bin/bash
# ============================================================
# 哪吒面板入侵 检测+清理脚本 v3.1
# 结合 nezha_ioc_check.sh 检测 + cleanup.sh 清理
# 适用于通过哪吒面板任务下发执行
# 注意: 不使用 set -e，避免管道执行时意外退出
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ALERT=0
log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "\n${GREEN}========== $1 ==========${NC}"; }

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   哪吒入侵 检测+清理 v3.0${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} 主机: $(hostname)  时间: $(date '+%F %T')${NC}"
echo ""

# ============================================================
# Part A: 恶意文件/进程检测
# ============================================================
log_step "Part A: 检测恶意文件/进程"

# 检测已知恶意文件
MALICIOUS_FILES=0
log_step "A1: 已知恶意文件"
for f in /tmp/b /tmp/.a /tmp/probe-agent; do
    if [ -f "$f" ]; then
        FILE_SIZE=$(stat -c%s "$f" 2>/dev/null || echo '?')
        log_warn "发现: $f ($FILE_SIZE bytes)"
        MALICIOUS_FILES=$((MALICIOUS_FILES + 1))
        ALERT=1
    fi
done
[ $MALICIOUS_FILES -eq 0 ] && log_info "未发现已知恶意文件"

# 检测恶意进程
MALICIOUS_PROCS=0
log_step "A2: 已知恶意进程"
for pattern in '/tmp/b' '/tmp/.a' '103.106.228.23' '86.54.82.179' 'ice.sh' 'attack_method'; do
    PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        log_warn "恶意进程 ($pattern): $PIDS"
        MALICIOUS_PROCS=$((MALICIOUS_PROCS + 1))
        ALERT=1
    fi
done
PIDS=$(pgrep -f '/tmp/probe-agent' 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    log_warn "假 probe-agent 进程: $PIDS"
    MALICIOUS_PROCS=$((MALICIOUS_PROCS + 1))
    ALERT=1
fi
[ $MALICIOUS_PROCS -eq 0 ] && log_info "未发现已知恶意进程"

# ============================================================
# Part B: IOC 深度检测（来自 check.sh）
# ============================================================
log_step "Part B: IOC 深度检测"

# B1: memfd 内存马
log_step "B1: memfd 内存马"
MEMFD_FOUND=0
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    if ls -l /proc/$pid/exe 2>/dev/null | grep -qi "memfd"; then
        CMD=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
        log_error "memfd 内存马: PID $pid cmd=$CMD"
        MEMFD_FOUND=1
        ALERT=1
    fi
done
[ $MEMFD_FOUND -eq 0 ] && log_info "未发现 memfd 内存马"

# B2: kworker 伪装进程
log_step "B2: kworker 伪装进程"
EXCLUDE_COMM="kdump|komari|kubelet"
KWORKER_FOUND=0
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    exe=$(readlink /proc/$pid/exe 2>/dev/null)
    ppid=$(awk '{print $4}' /proc/$pid/stat 2>/dev/null)
    case "$comm" in
        k*)
            if [ -n "$exe" ] && [ "$ppid" != "2" ]; then
                if ! echo "$comm" | grep -qE "^($EXCLUDE_COMM)" && [ "${exe#*/usr/lib/systemd/}" = "$exe" ]; then
                    log_error "kworker 伪装: PID $pid 进程名=$comm 父=$ppid exe=$exe"
                    KWORKER_FOUND=1
                    ALERT=1
                fi
            fi
            ;;
    esac
done
[ $KWORKER_FOUND -eq 0 ] && log_info "未发现 kworker 伪装进程"

# B3: 已删除文件执行 ((deleted))
log_step "B3: 已删除文件执行"
DELETED_FOUND=0
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    exe=$(readlink /proc/$pid/exe 2>/dev/null)
    case "$exe" in
        *"(deleted)"*)
            case "$exe" in
                */usr/*|*/bin/*|*/sbin/*|*/app/*|*/snap/*) ;;
                *)
                    CMD=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
                    log_error "已删除文件执行: PID $pid exe=$exe cmd=$CMD"
                    DELETED_FOUND=1
                    ALERT=1
                    ;;
            esac
            ;;
    esac
done
[ $DELETED_FOUND -eq 0 ] && log_info "未发现已删除文件执行"

# B4: 恶意哪吒 Agent 残留（随机后缀 config/service）
log_step "B4: 恶意哪吒 Agent 残留"
NEZHA_SUSPICIOUS=0
if ps aux 2>/dev/null | grep -i 'nezha-agent' | grep -v grep | grep -qE 'config-[a-z0-9]+\.yml'; then
    log_error "发现随机后缀 config 的 agent 进程"
    NEZHA_SUSPICIOUS=1
    ALERT=1
fi
if ls /etc/systemd/system/ 2>/dev/null | grep -qE 'nezha-agent-[a-z0-9]+\.service'; then
    log_error "发现随机后缀 nezha service"
    NEZHA_SUSPICIOUS=1
    ALERT=1
fi
if ls /opt/nezha/agent/config-*.yml 2>/dev/null | grep -q .; then
    log_error "发现随机 config 文件"
    NEZHA_SUSPICIOUS=1
    ALERT=1
fi
[ $NEZHA_SUSPICIOUS -eq 0 ] && log_info "未发现恶意哪吒 Agent 残留"

# B5: 挖矿程序
log_step "B5: 挖矿程序"
MINER_FOUND=0
[ -e /root/c3pool ] && { log_error "/root/c3pool 目录存在"; MINER_FOUND=1; ALERT=1; }
pgrep -x xmrig >/dev/null 2>&1 && { log_error "xmrig 进程在运行"; MINER_FOUND=1; ALERT=1; }
[ -e /etc/systemd/system/c3pool_miner.service ] && { log_error "c3pool_miner.service 存在"; MINER_FOUND=1; ALERT=1; }
[ $MINER_FOUND -eq 0 ] && log_info "未发现挖矿程序"

# B6: 守护复活服务
log_step "B6: 守护复活服务 (SystemLoger / systemlog)"
PERSISTENCE_FOUND=0
pgrep -x SystemLoger >/dev/null 2>&1 && { log_error "SystemLoger 进程在运行"; PERSISTENCE_FOUND=1; ALERT=1; }
[ -e /opt/systemlog ] && { log_error "/opt/systemlog 目录存在"; PERSISTENCE_FOUND=1; ALERT=1; }
[ -e /etc/systemd/system/systemlog.service ] && { log_error "systemlog.service 存在"; PERSISTENCE_FOUND=1; ALERT=1; }
[ $PERSISTENCE_FOUND -eq 0 ] && log_info "未发现守护复活服务"

# B7: SSH 后门公钥
log_step "B7: SSH 后门公钥"
SSH_BACKDOOR=0
if grep -qi "gary" ~/.ssh/authorized_keys 2>/dev/null; then
    log_error "authorized_keys 含可疑公钥(gary)"
    SSH_BACKDOOR=1
    ALERT=1
fi
KEY_COUNT=$(grep -c '^ssh-' ~/.ssh/authorized_keys 2>/dev/null || echo '0')
log_info "authorized_keys 公钥数: $KEY_COUNT"
[ $SSH_BACKDOOR -eq 0 ] && log_info "未发现 SSH 后门公钥"

# B8: 自启动持久化 (cron)
log_step "B8: 自启动持久化 (cron)"
CRON_SUSPICIOUS=0
# 检查各用户 crontab
for u in $(cut -f1 -d: /etc/passwd); do
    c=$(crontab -l -u "$u" 2>/dev/null | grep -vE '^\s*#|^\s*$')
    if [ -n "$c" ]; then
        log_info "用户 $u 有 cron:"
        echo "$c" | sed 's/^/      /'
    fi
done
# 检查 cron 文件中的可疑内容
CRON_FILES=$(grep -rEl 'curl|wget|/tmp/|base64 -d' /etc/cron* /var/spool/cron 2>/dev/null || true)
if [ -n "$CRON_FILES" ]; then
    log_error "以下 cron 文件含可疑下载/执行:"
    echo "$CRON_FILES" | sed 's/^/      /'
    CRON_SUSPICIOUS=1
    ALERT=1
fi
# 检查已知恶意特征
CRON_MALICIOUS=$(crontab -l 2>/dev/null | grep -iE 'probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack_method' || true)
if [ -n "$CRON_MALICIOUS" ]; then
    log_error "发现已知恶意 cron 条目:"
    echo "$CRON_MALICIOUS" | sed 's/^/      /'
    CRON_SUSPICIOUS=1
    ALERT=1
fi
[ $CRON_SUSPICIOUS -eq 0 ] && log_info "未发现可疑 cron 持久化"

# B9: ld.so.preload 劫持
log_step "B9: ld.so.preload 劫持"
LD_PRELOAD_FOUND=0
if [ -f /etc/ld.so.preload ]; then
    log_error "/etc/ld.so.preload 存在:"
    cat /etc/ld.so.preload | sed 's/^/      /'
    LD_PRELOAD_FOUND=1
    ALERT=1
fi
[ $LD_PRELOAD_FOUND -eq 0 ] && log_info "未发现 ld.so.preload 劫持"

# ============================================================
# Part C: nezha-agent 二进制完整性检测
# ============================================================
log_step "Part C: nezha-agent 二进制完整性"

NEZHA_TAMPERED=0
NEZHA_AGENT_PATH=""
NEZHA_PIDS=$(pgrep -f 'nezha-agent' 2>/dev/null || true)

# 查找二进制
for dir in /opt/nezha/agent /usr/local/bin /usr/bin /usr/local/sbin; do
    if [ -f "$dir/nezha-agent" ]; then
        NEZHA_AGENT_PATH="$dir/nezha-agent"
        break
    fi
done

if [ -z "$NEZHA_AGENT_PATH" ]; then
    log_info "未找到 nezha-agent 二进制"
else
    log_info "找到: $NEZHA_AGENT_PATH"

    # C1: 进程 exe 被删除
    for pid in $NEZHA_PIDS; do
        EXE_PATH=$(readlink /proc/$pid/exe 2>/dev/null || echo '')
        if echo "$EXE_PATH" | grep -q '(deleted)'; then
            log_error "二进制已被删除但进程仍在运行: $EXE_PATH"
            NEZHA_TAMPERED=1
            ALERT=1
        fi
    done

    # C2: strings 特征检测
    STRINGS_CHECK=$(strings "$NEZHA_AGENT_PATH" 2>/dev/null | grep -ciE 'nezha|nezhahq|dashboard' || echo '0')
    if [ "$STRINGS_CHECK" -lt 3 ]; then
        log_error "二进制中未发现 nezha 特征字符串，可能被替换"
        NEZHA_TAMPERED=1
        ALERT=1
    else
        log_info "nezha 特征字符串: $STRINGS_CHECK 处"
    fi

    # C3: 文件大小
    FILE_SIZE=$(stat -c%s "$NEZHA_AGENT_PATH" 2>/dev/null || echo '0')
    log_info "文件大小: $FILE_SIZE bytes"
    if [ "$FILE_SIZE" -lt 500000 ] 2>/dev/null; then
        log_error "二进制异常小（< 500KB）"
        NEZHA_TAMPERED=1
        ALERT=1
    fi

    # C4: ELF 格式
    FILE_TYPE=$(file "$NEZHA_AGENT_PATH" 2>/dev/null || echo '')
    if echo "$FILE_TYPE" | grep -qi 'ELF'; then
        log_info "格式正常: ELF"
    else
        log_error "格式异常: $FILE_TYPE"
        NEZHA_TAMPERED=1
        ALERT=1
    fi

    # C5: 已知恶意 MD5
    MD5=$(md5sum "$NEZHA_AGENT_PATH" 2>/dev/null | awk '{print $1}')
    log_info "MD5: $MD5"
    for BAD_HASH in "5bf237efebf9d6980031cef42f220e74" "17e98a0d5a0a44d265740837716b02d0"; do
        if [ "$MD5" = "$BAD_HASH" ]; then
            log_error "MD5 匹配已知恶意哈希"
            NEZHA_TAMPERED=1
            ALERT=1
        fi
    done

    # C6: 进程 cmdline 正常性
    for pid in $NEZHA_PIDS; do
        CMDLINE=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || echo '')
        if ! echo "$CMDLINE" | grep -q '\-c.*config'; then
            log_warn "PID $pid 启动参数异常: $CMDLINE"
        fi
    done
fi

# ============================================================
# Part D: 综合判断
# ============================================================
log_step "Part D: 综合判断"

NEED_UNINSTALL=0

# 恶意文件/进程 → 需要清理
HAS_MALICIOUS=0
if [ $MALICIOUS_FILES -gt 0 ] || [ $MALICIOUS_PROCS -gt 0 ] || [ $CRON_SUSPICIOUS -gt 0 ]; then
    HAS_MALICIOUS=1
fi

# IOC 深度问题 → 需要清理
HAS_IOC=0
if [ $MEMFD_FOUND -gt 0 ] || [ $KWORKER_FOUND -gt 0 ] || [ $DELETED_FOUND -gt 0 ] || [ $MINER_FOUND -gt 0 ] || [ $PERSISTENCE_FOUND -gt 0 ] || [ $LD_PRELOAD_FOUND -gt 0 ] || [ $NEZHA_SUSPICIOUS -gt 0 ]; then
    HAS_IOC=1
fi

# nezha-agent 被替换 → 需要完全卸载
if [ $NEZHA_TAMPERED -gt 0 ]; then
    NEED_UNINSTALL=1
fi

# 输出结论
echo ""
if [ $ALERT -eq 0 ]; then
    log_info "检测结果: 未发现已知入侵痕迹 ✅"
else
    log_warn "检测结果: 发现异常项 ⚠️"
fi

if [ $NEED_UNINSTALL -eq 1 ]; then
    log_error "哪吒 Agent 二进制已被替换 → 将完全卸载"
else
    log_info "哪吒 Agent 二进制正常 → 保留"
fi

# ============================================================
# Part E: 执行清理
# ============================================================
log_step "Part E: 执行清理"

if [ $ALERT -eq 0 ]; then
    log_info "无需清理，一切正常"
else
    # E1: 终止恶意进程（不含 nezha-agent）
    log_info "终止恶意进程..."
    KILLED=0
    for pattern in '/tmp/b' '/tmp/.a' '103.106.228.23' '86.54.82.179' 'ice.sh' 'attack_method'; do
        PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            echo "$PIDS" | xargs kill -9 2>/dev/null || true
            log_info "  已终止: $pattern ($PIDS)"
            KILLED=$((KILLED + 1))
        fi
    done
    PIDS=$(pgrep -f '/tmp/probe-agent' 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill -9 2>/dev/null || true
        log_info "  已终止: 假 probe-agent ($PIDS)"
        KILLED=$((KILLED + 1))
    fi
    # 挖矿进程
    if pgrep -x xmrig >/dev/null 2>&1; then
        pkill -9 xmrig 2>/dev/null || true
        log_info "  已终止: xmrig"
        KILLED=$((KILLED + 1))
    fi
    # SystemLoger
    if pgrep -x SystemLoger >/dev/null 2>&1; then
        pkill -9 SystemLoger 2>/dev/null || true
        log_info "  已终止: SystemLoger"
        KILLED=$((KILLED + 1))
    fi
    # memfd 内存马
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        if ls -l /proc/$pid/exe 2>/dev/null | grep -qi "memfd"; then
            CMD=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
            kill -9 "$pid" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_info "  已终止: memfd PID $pid cmd=$CMD"
                KILLED=$((KILLED + 1))
            else
                log_error "  终止失败: memfd PID $pid"
            fi
        fi
    done
    if [ $KILLED -gt 0 ]; then
        log_info "共终止 $KILLED 组进程"
    else
        log_info "无需终止进程"
    fi

    # E2: 删除恶意文件
    log_info "删除恶意文件..."
    for f in /tmp/b /tmp/.a /tmp/probe-agent; do
        if [ -f "$f" ]; then
            rm -f "$f" 2>/dev/null || true
            log_info "  已删除: $f"
        fi
    done
    # 挖矿目录
    if [ -d "/root/c3pool" ]; then
        rm -rf /root/c3pool 2>/dev/null || true
        log_info "  已删除: /root/c3pool"
    fi
    if [ -f "/etc/systemd/system/c3pool_miner.service" ]; then
        rm -f /etc/systemd/system/c3pool_miner.service 2>/dev/null || true
        log_info "  已删除: c3pool_miner.service"
    fi
    # systemlog 持久化
    if [ -d "/opt/systemlog" ]; then
        rm -rf /opt/systemlog 2>/dev/null || true
        log_info "  已删除: /opt/systemlog"
    fi
    if [ -f "/etc/systemd/system/systemlog.service" ]; then
        rm -f /etc/systemd/system/systemlog.service 2>/dev/null || true
        log_info "  已删除: systemlog.service"
    fi

    # E3: 清理可疑 cron
    if [ $CRON_SUSPICIOUS -eq 1 ]; then
        log_info "清理可疑定时任务..."
        crontab -l 2>/dev/null | grep -viE 'probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack_method|curl.*wget|base64' | crontab - 2>/dev/null || true
        log_info "  已清理 crontab"
        for f in /etc/cron.d/*; do
            [ -f "$f" ] || continue
            if grep -qE 'probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack_method|curl.*wget|base64' "$f" 2>/dev/null; then
                rm -f "$f"
                log_info "  已删除: $f"
            fi
        done
    fi

    # E4: 完全卸载 nezha-agent（仅在被替换时）
    if [ $NEED_UNINSTALL -eq 1 ]; then
        log_info "执行 nezha-agent 完全卸载..."

        PIDS=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
        if [ -n "$PIDS" ]; then
            echo "$PIDS" | xargs kill -9 2>/dev/null || true
            log_info "  已终止 nezha-agent: $PIDS"
        fi

        if [ -d "/opt/nezha/agent" ]; then
            rm -rf /opt/nezha/agent 2>/dev/null || true
            log_info "  已删除: /opt/nezha/agent"
        fi
        for f in /usr/local/bin/nezha-agent /usr/bin/nezha-agent /usr/local/sbin/nezha-agent; do
            if [ -f "$f" ]; then
                rm -f "$f" 2>/dev/null || true
                log_info "  已删除: $f"
            fi
        done

        NEZHA_SERVICES=$(find /etc/systemd/system /usr/lib/systemd/system -name 'nezha-agent*' -type f 2>/dev/null || true)
        for svc in $NEZHA_SERVICES; do
            svc_name=$(basename "$svc")
            systemctl stop "$svc_name" 2>/dev/null || true
            systemctl disable "$svc_name" 2>/dev/null || true
            rm -f "$svc"
            log_info "  已移除服务: $svc_name"
        done

        for svc in $(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | grep -i nezha | awk '{print $1}'); do
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_info "  已停止服务: $svc"
        done

        systemctl daemon-reload 2>/dev/null || true
        log_info "已重载 systemd"
    else
        log_info "哪吒 Agent 未被替换，保留不卸载"
    fi

    # E5: SSH 后门公钥清理（gary@gary）
    if [ -f ~/.ssh/authorized_keys ]; then
        GARY_COUNT=$(grep -ci 'gary' ~/.ssh/authorized_keys 2>/dev/null || echo '0')
        if [ "$GARY_COUNT" -gt 0 ] 2>/dev/null; then
            log_info "清理 SSH 后门公钥 (含 gary 的公钥 $GARY_COUNT 条)..."
            BACKUP=~/.ssh/authorized_keys.bak.$(date +%s)
            cp ~/.ssh/authorized_keys "$BACKUP"
            log_info "  已备份到: $BACKUP"
            grep -vi 'gary' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp 2>/dev/null
            mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
            REMAINING=$(grep -c '^ssh-' ~/.ssh/authorized_keys 2>/dev/null || echo '0')
            log_info "  清理后公钥数: $REMAINING"
        else
            log_info "authorized_keys 无 gary 公钥"
        fi
    fi

    # E6: ld.so.preload 劫持
    if [ $LD_PRELOAD_FOUND -gt 0 ]; then
        log_warn "发现 ld.so.preload 劫持，请手动检查并删除"
    fi
fi

# ============================================================
# Part F: 最终验证
# ============================================================
log_step "Part F: 最终验证"

CLEAN=1
for f in /tmp/b /tmp/.a /tmp/probe-agent; do
    [ -f "$f" ] && { log_error "文件仍存在: $f"; CLEAN=0; }
done
REMAINING=$(pgrep -f '/tmp/b|/tmp/.a|/tmp/probe-agent|103\.106\.228\.23|86\.54\.82\.179|ice\.sh|attack_method|xmrig|SystemLoger' 2>/dev/null || true)
[ -n "$REMAINING" ] && { log_error "仍有残留进程: $REMAINING"; CLEAN=0; }
if [ $NEED_UNINSTALL -eq 1 ]; then
    REMAINING=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
    [ -n "$REMAINING" ] && { log_error "仍有 nezha-agent 进程: $REMAINING"; CLEAN=0; }
fi
[ $CLEAN -eq 1 ] && log_info "清理验证通过" || log_error "清理验证未完全通过"

# ============================================================
# 完成
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   检测+清理完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
if [ $NEED_UNINSTALL -eq 1 ]; then
    log_warn "哪吒 Agent 已完全卸载，请手动重新安装"
else
    log_info "哪吒 Agent 保留"
fi
log_warn "C2 服务器: 86.54.82.179 / 103.106.228.23 / 68.183.181.185"
echo ""
