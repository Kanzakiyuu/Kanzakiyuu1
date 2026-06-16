#!/bin/bash
# ============================================================
# 哪吒 Agent 恶意清理脚本 v2.1
# 检测 nezha-agent 是否被替换，只在确认被替换时才完全卸载
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
echo -e "${GREEN}   哪吒 Agent 恶意清理脚本 v2.1${NC}"
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

# 列出 nezha-agent 进程但不判定为恶意
NEZHA_PIDS=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
if [ -n "$NEZHA_PIDS" ]; then
    log_info "发现 nezha-agent 进程: $NEZHA_PIDS"
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
log_step "Step 3: 检测 nezha-agent 二进制完整性"

NEZHA_TAMPERED=0
NEZHA_AGENT_PATH=""

# 查找 nezha-agent 二进制
for dir in /opt/nezha/agent /usr/local/bin /usr/bin /usr/local/sbin; do
    if [ -f "$dir/nezha-agent" ]; then
        NEZHA_AGENT_PATH="$dir/nezha-agent"
        break
    fi
done

if [ -z "$NEZHA_AGENT_PATH" ]; then
    log_info "未找到 nezha-agent 二进制（可能已卸载或未安装）"
else
    log_info "找到 nezha-agent: $NEZHA_AGENT_PATH"

    # 检查 1: 进程的 exe 是否被删除（最明确的被替换证据）
    for pid in $NEZHA_PIDS; do
        EXE_PATH=$(readlink /proc/$pid/exe 2>/dev/null || echo '')
        if echo "$EXE_PATH" | grep -q '(deleted)'; then
            log_error "二进制已被删除但进程仍在运行: $EXE_PATH"
            NEZHA_TAMPERED=1
        fi
    done

    # 检查 2: 文件是否被替换为其他内容（通过 strings 检查是否包含 nezha 特征）
    STRINGS_CHECK=$(strings "$NEZHA_AGENT_PATH" 2>/dev/null | grep -ciE 'nezha|nezhahq|dashboard' || echo '0')
    if [ "$STRINGS_CHECK" -lt 3 ]; then
        log_error "二进制中未发现 nezha 特征字符串，可能被替换为其他程序"
        NEZHA_TAMPERED=1
    else
        log_info "二进制包含 nezha 特征字符串 ($STRINGS_CHECK 处)"
    fi

    # 检查 3: 文件大小（正常的 nezha-agent 通常 5-20MB）
    FILE_SIZE=$(stat -c%s "$NEZHA_AGENT_PATH" 2>/dev/null || echo '0')
    log_info "二进制大小: $FILE_SIZE bytes"
    if [ "$FILE_SIZE" -lt 500000 ] 2>/dev/null; then
        log_error "二进制异常小（< 500KB），可能被替换"
        NEZHA_TAMPERED=1
    fi

    # 检查 4: 是否为合法 ELF 格式
    FILE_TYPE=$(file "$NEZHA_AGENT_PATH" 2>/dev/null || echo '')
    if echo "$FILE_TYPE" | grep -qi 'ELF'; then
        log_info "文件格式正常: $FILE_TYPE"
    else
        log_error "文件格式异常: $FILE_TYPE"
        NEZHA_TAMPERED=1
    fi

    # 检查 5: 文件 md5 是否为已知恶意哈希
    MD5=$(md5sum "$NEZHA_AGENT_PATH" 2>/dev/null | awk '{print $1}')
    log_info "MD5: $MD5"
    for BAD_HASH in "5bf237efebf9d6980031cef42f220e74" "17e98a0d5a0a44d265740837716b02d0"; do
        if [ "$MD5" = "$BAD_HASH" ]; then
            log_error "MD5 匹配已知恶意哈希: $MD5"
            NEZHA_TAMPERED=1
        fi
    done

    # 检查 6: 进程的 cmdline 是否正常（应包含 -c 和 config 路径）
    for pid in $NEZHA_PIDS; do
        CMDLINE=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || echo '')
        if ! echo "$CMDLINE" | grep -q '\-c.*config'; then
            log_warn "PID $pid 启动参数异常: $CMDLINE"
        fi
    done
fi

# ============================================================
# Step 4: 检查定时任务
# ============================================================
log_step "Step 4: 检查定时任务"

CRON_SUSPICIOUS=0
CRONJOBS=$(crontab -l 2>/dev/null | grep -iE 'probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack_method' || true)
if [ -n "$CRONJOBS" ]; then
    log_warn "发现可疑 crontab 条目:"
    echo "$CRONJOBS"
    CRON_SUSPICIOUS=1
fi

for f in /etc/cron.d/*; do
    [ -f "$f" ] || continue
    if grep -qE 'probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack_method' "$f" 2>/dev/null; then
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

# 恶意文件/进程：需要清理
HAS_MALICIOUS=0
if [ $MALICIOUS_FILES -gt 0 ] || [ $MALICIOUS_PROCS -gt 0 ] || [ $CRON_SUSPICIOUS -gt 0 ]; then
    HAS_MALICIOUS=1
fi

if [ $HAS_MALICIOUS -eq 1 ]; then
    log_warn "检测到恶意文件/进程，执行清理"
fi

# nezha-agent 是否需要卸载：仅在二进制被替换时
if [ $NEZHA_TAMPERED -gt 0 ]; then
    log_error "哪吒 Agent 二进制已被替换/篡改，需要完全卸载"
else
    log_info "哪吒 Agent 二进制正常，保留不卸载"
fi

# ============================================================
# Step 6: 执行清理
# ============================================================
log_step "Step 6: 执行清理"

# --- 6.1: 终止恶意进程（不包含 nezha-agent） ---
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

if [ $KILLED -gt 0 ]; then
    log_info "共终止 $KILLED 组恶意进程"
else
    log_info "无需终止恶意进程"
fi

# --- 6.2: 删除恶意文件（始终执行） ---
log_info "删除恶意文件..."
for f in /tmp/b /tmp/.a /tmp/probe-agent; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log_info "  已删除: $f"
    fi
done

# --- 6.3: 清理可疑定时任务（始终执行） ---
if [ $CRON_SUSPICIOUS -eq 1 ]; then
    log_info "清理可疑定时任务..."
    crontab -l 2>/dev/null | grep -viE 'probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack_method' | crontab - 2>/dev/null || true
    log_info "  已清理 crontab"

    for f in /etc/cron.d/*; do
        [ -f "$f" ] || continue
        if grep -qE 'probe-agent|ice\.sh|103\.106\.228|86\.54\.82|attack_method' "$f" 2>/dev/null; then
            rm -f "$f"
            log_info "  已删除: $f"
        fi
    done
fi

# --- 6.4: 完全清理 nezha-agent（仅在二进制被替换时） ---
if [ $NEZHA_TAMPERED -eq 1 ]; then
    log_info "执行 nezha-agent 完全卸载..."

    # 终止所有 nezha-agent 进程
    PIDS=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill -9 2>/dev/null || true
        log_info "  已终止 nezha-agent 进程: $PIDS"
    fi

    # 删除安装目录
    if [ -d "/opt/nezha/agent" ]; then
        rm -rf /opt/nezha/agent
        log_info "  已删除: /opt/nezha/agent"
    fi

    # 删除其他位置的二进制
    for f in /usr/local/bin/nezha-agent /usr/bin/nezha-agent /usr/local/sbin/nezha-agent; do
        [ -f "$f" ] && rm -f "$f" && log_info "  已删除: $f"
    done

    # 清理 systemd 服务
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
    log_info "哪吒 Agent 未被替换，保留不卸载"
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

# 如果完全卸载了 nezha-agent，检查残留
if [ $NEZHA_TAMPERED -eq 1 ]; then
    REMAINING=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
    if [ -n "$REMAINING" ]; then
        log_error "仍有 nezha-agent 进程: $REMAINING"
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
if [ $NEZHA_TAMPERED -eq 1 ]; then
    log_warn "哪吒 Agent 已完全卸载，请手动重新安装新版本"
else
    log_info "哪吒 Agent 未被替换，已保留"
fi
log_warn "C2 服务器已知: 86.54.82.179 / 103.106.228.23 / 68.183.181.185"
echo ""
