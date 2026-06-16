#!/bin/bash
# ============================================================
# 哪吒 Agent 恶意清理脚本 v2.0
# 智能检测：检查 agent 是否被替换，完全卸载或仅清理恶意文件
# 适用于通过哪吒面板任务下发执行
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
echo -e "${GREEN}   哪吒 Agent 恶意清理脚本 v2.0${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ============================================================
# Step 1: 检测恶意文件
# ============================================================
log_step "Step 1: 检测恶意文件"

MALICIOUS_FILES=0
for f in /tmp/b /tmp/.a /tmp/probe-agent; do
    if [ -f "$f" ]; then
        FILE_SIZE=$(stat -c%s "$f" 2>/dev/null || echo '?')
        log_warn "发现恶意文件: $f ($FILE_SIZE bytes)"
        MALICIOUS_FILES=$((MALICIOUS_FILES + 1))
    fi
done

if [ $MALICIOUS_FILES -eq 0 ]; then
    log_info "未发现恶意文件"
fi

# ============================================================
# Step 2: 检测恶意进程
# ============================================================
log_step "Step 2: 检测恶意进程"

MALICIOUS_PROCS=0

for pattern in '/tmp/b' '/tmp/.a' '103.106.228.23' '86.54.82.179' 'ice.sh' 'attack_method'; do
    PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        log_warn "恶意进程 ($pattern): $PIDS"
        MALICIOUS_PROCS=$((MALICIOUS_PROCS + 1))
    fi
done

PIDS=$(pgrep -f '/tmp/probe-agent' 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    log_warn "假 probe-agent 进程: $PIDS"
    MALICIOUS_PROCS=$((MALICIOUS_PROCS + 1))
fi

# 检查 nezha-agent 进程
NEZHA_PIDS=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
if [ -n "$NEZHA_PIDS" ]; then
    log_warn "发现 nezha-agent 进程: $NEZHA_PIDS"
    for pid in $NEZHA_PIDS; do
        EXE_PATH=$(readlink /proc/$pid/exe 2>/dev/null || echo 'unknown')
        log_info "  PID $pid → $EXE_PATH"
    done
else
    log_info "未发现 nezha-agent 进程"
fi

# ============================================================
# Step 3: 检测 nezha-agent 二进制是否被替换
# ============================================================
log_step "Step 3: 检测 nezha-agent 二进制"

NEZHA_TAMPERED=0
NEZHA_AGENT_PATH=""
NEZHA_AGENT_CONFIG=""

# 查找所有 nezha-agent 二进制
for dir in /opt/nezha/agent /usr/local/bin /usr/bin /usr/local/sbin; do
    if [ -f "$dir/nezha-agent" ]; then
        NEZHA_AGENT_PATH="$dir/nezha-agent"
        break
    fi
done

if [ -z "$NEZHA_AGENT_PATH" ]; then
    log_info "未找到 nezha-agent 二进制（可能已卸载）"
else
    log_info "找到 nezha-agent: $NEZHA_AGENT_PATH"

    # 检查 1: 文件是否被删除（但进程还在运行）
    for pid in $NEZHA_PIDS; do
        EXE_PATH=$(readlink /proc/$pid/exe 2>/dev/null || echo '')
        if echo "$EXE_PATH" | grep -q '(deleted)'; then
            log_error "二进制已被删除但进程仍在运行: $EXE_PATH"
            NEZHA_TAMPERED=1
        fi
    done

    # 检查 2: 文件大小是否异常（正常的 nezha-agent 通常 > 5MB）
    FILE_SIZE=$(stat -c%s "$NEZHA_AGENT_PATH" 2>/dev/null || echo '0')
    if [ "$FILE_SIZE" -lt 1000000 ] 2>/dev/null; then
        log_error "二进制文件异常小: $FILE_SIZE bytes（正常应 > 5MB）"
        NEZHA_TAMPERED=1
    fi

    # 检查 3: 是否为合法 ELF 格式
    FILE_TYPE=$(file "$NEZHA_AGENT_PATH" 2>/dev/null || echo '')
    if echo "$FILE_TYPE" | grep -qi 'ELF'; then
        log_info "文件格式正常: ELF"
    else
        log_error "文件格式异常: $FILE_TYPE"
        NEZHA_TAMPERED=1
    fi

    # 检查 4: 最近修改时间（如果最近被修改则可疑）
    MTIME=$(stat -c%Y "$NEZHA_AGENT_PATH" 2>/dev/null || echo '0')
    NOW=$(date +%s)
    DIFF=$(( NOW - MTIME ))
    if [ "$DIFF" -lt 86400 ]; then
        HOURS=$(( DIFF / 3600 ))
        log_warn "二进制在最近 ${HOURS} 小时内被修改过"
        NEZHA_TAMPERED=1
    fi

    # 检查 5: 检查进程的 cmdline 是否正常
    for pid in $NEZHA_PIDS; do
        CMDLINE=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || echo '')
        if echo "$CMDLINE" | grep -q '\-c'; then
            CONFIG_PATH=$(echo "$CMDLINE" | grep -oP '\-c\s+\K\S+')
            if [ -n "$CONFIG_PATH" ]; then
                NEZHA_AGENT_CONFIG="$CONFIG_PATH"
                if [ -f "$CONFIG_PATH" ]; then
                    log_info "配置文件存在: $CONFIG_PATH"
                else
                    log_error "配置文件不存在: $CONFIG_PATH"
                    NEZHA_TAMPERED=1
                fi
            fi
        fi
    done
fi

# ============================================================
# Step 4: 检查定时任务
# ============================================================
log_step "Step 4: 检查定时任务"

CRON_SUSPICIOUS=0
CRONJOBS=$(crontab -l 2>/dev/null | grep -iE 'nezha|probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack' || true)
if [ -n "$CRONJOBS" ]; then
    log_warn "发现可疑 crontab 条目:"
    echo "$CRONJOBS"
    CRON_SUSPICIOUS=1
fi

for f in /etc/cron.d/*; do
    [ -f "$f" ] || continue
    if grep -qE 'nezha|probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack' "$f" 2>/dev/null; then
        log_warn "可疑 cron 文件: $f"
        CRON_SUSPICIOUS=1
    fi
done

if [ $CRON_SUSPICIOUS -eq 0 ]; then
    log_info "定时任务正常"
fi

# ============================================================
# Step 5: 综合判断
# ============================================================
log_step "Step 5: 综合判断"

NEED_FULL_CLEANUP=0
REASONS=""

if [ $MALICIOUS_FILES -gt 0 ]; then
    NEED_FULL_CLEANUP=1
    REASONS="${REASONS}\n  - 发现恶意文件 (/tmp/b, /tmp/.a 等)"
fi

if [ $MALICIOUS_PROCS -gt 0 ]; then
    NEED_FULL_CLEANUP=1
    REASONS="${REASONS}\n  - 发现恶意进程 (DDoS bot, ice.sh 等)"
fi

if [ $NEZHA_TAMPERED -gt 0 ]; then
    NEED_FULL_CLEANUP=1
    REASONS="${REASONS}\n  - 哪吒 Agent 二进制已被替换/篡改"
fi

if [ $CRON_SUSPICIOUS -gt 0 ]; then
    REASONS="${REASONS}\n  - 发现可疑定时任务"
fi

if [ $NEED_FULL_CLEANUP -eq 1 ]; then
    log_error "检测到入侵，需要完全清理:"
    echo -e "$REASONS"
else
    log_info "未检测到入侵，仅清理恶意文件"
fi

# ============================================================
# Step 6: 执行清理
# ============================================================
log_step "Step 6: 执行清理"

# --- 6.1: 终止恶意进程 ---
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

# 如果需要完全清理，也终止 nezha-agent 进程
if [ $NEED_FULL_CLEANUP -eq 1 ]; then
    PIDS=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill -9 2>/dev/null || true
        log_info "  已终止: nezha-agent ($PIDS)"
        KILLED=$((KILLED + 1))
    fi
fi

if [ $KILLED -gt 0 ]; then
    log_info "共终止 $KILLED 组进程"
else
    log_info "无需终止进程"
fi

# --- 6.2: 删除恶意文件 ---
log_info "删除恶意文件..."
for f in /tmp/b /tmp/.a /tmp/probe-agent; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log_info "  已删除: $f"
    fi
done

# --- 6.3: 完全清理（仅在被替换时）---
if [ $NEED_FULL_CLEANUP -eq 1 ]; then
    log_info "执行完全清理..."

    # 删除 nezha-agent 安装目录
    for dir in /opt/nezha/agent; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            log_info "  已删除: $dir"
        fi
    done

    # 删除其他位置的二进制
    for f in /usr/local/bin/nezha-agent /usr/bin/nezha-agent /usr/local/sbin/nezha-agent; do
        if [ -f "$f" ]; then
            rm -f "$f"
            log_info "  已删除: $f"
        fi
    done

    # 清理 systemd 服务
    log_info "清理 systemd 服务..."
    NEZHA_SERVICES=$(find /etc/systemd/system /usr/lib/systemd/system -name 'nezha-agent*' -type f 2>/dev/null || true)
    for svc in $NEZHA_SERVICES; do
        svc_name=$(basename "$svc")
        systemctl stop "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "$svc"
        log_info "  已移除服务: $svc_name"
    done

    # 停止所有运行中的 nezha 相关服务
    for svc in $(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | grep -i nezha | awk '{print $1}'); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        log_info "  已停止服务: $svc"
    done

    systemctl daemon-reload 2>/dev/null || true
    log_info "已重载 systemd"
else
    log_info "跳过完全清理（哪吒 Agent 未被替换）"
fi

# --- 6.4: 清理定时任务 ---
log_info "清理可疑定时任务..."
if [ $CRON_SUSPICIOUS -eq 1 ]; then
    crontab -l 2>/dev/null | grep -viE 'nezha|probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack' | crontab - 2>/dev/null || true
    log_info "  已清理 crontab"

    for f in /etc/cron.d/*; do
        [ -f "$f" ] || continue
        if grep -qE 'nezha|probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack' "$f" 2>/dev/null; then
            rm -f "$f"
            log_info "  已删除: $f"
        fi
    done
fi

# ============================================================
# Step 7: 清理验证
# ============================================================
log_step "Step 7: 清理验证"

CLEAN=1

# 检查恶意文件
for f in /tmp/b /tmp/.a /tmp/probe-agent; do
    if [ -f "$f" ]; then
        log_error "文件仍存在: $f"
        CLEAN=0
    fi
done

# 检查恶意进程
REMAINING=$(pgrep -f '/tmp/b|/tmp/.a|/tmp/probe-agent|103\.106\.228\.23|86\.54\.82\.179|ice\.sh|attack_method' 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
    log_error "仍有残留进程: $REMAINING"
    CLEAN=0
fi

# 如果完全清理，检查 nezha-agent
if [ $NEED_FULL_CLEANUP -eq 1 ]; then
    REMAINING=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
    if [ -n "$REMAINING" ]; then
        log_error "仍有 nezha-agent 进程: $REMAINING"
        CLEAN=0
    fi
    if [ -d "/opt/nezha/agent" ]; then
        log_error "安装目录仍存在: /opt/nezha/agent"
        CLEAN=0
    fi
fi

if [ $CLEAN -eq 1 ]; then
    log_info "清理验证通过"
else
    log_error "清理验证未完全通过，请手动检查"
fi

# ============================================================
# 完成
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   清理完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
if [ $NEED_FULL_CLEANUP -eq 1 ]; then
    log_warn "哪吒 Agent 已完全卸载，请手动重新安装新版本"
    log_warn "安装命令: bash <(curl -sL https://raw.githubusercontent.com/nezhahq/agent/main/script/install.sh) -s <面板地址>:<端口> -p <密钥>"
else
    log_info "哪吒 Agent 未被替换，已保留"
fi
log_warn "C2 服务器已知: 86.54.82.179 / 103.106.228.23 / 68.183.181.185"
echo ""
