#!/bin/bash
# ============================================================
# 哪吒 Agent 恶意清理脚本
# 清除 DDoS 僵尸程序 + 假 probe-agent + 所有 nezha-agent
# 适用于通过哪吒面板任务下发执行
# ============================================================

set -e

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
echo -e "${GREEN}   哪吒 Agent 恶意清理脚本 v1.0${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ------------------------------ Step 1: 杀进程 ------------------------------
log_step "Step 1: 终止恶意进程"

# 杀 DDoS 僵尸进程
KILLED=0
for pattern in '/tmp/b' '/tmp/.a' '103.106.228.23' '86.54.82.179' 'ice.sh' 'attack_method'; do
    PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        log_warn "发现恶意进程匹配: $pattern → PIDs: $PIDS"
        echo "$PIDS" | xargs kill -9 2>/dev/null || true
        KILLED=$((KILLED + 1))
    fi
done

# 杀假 probe-agent（伪装的）
PIDS=$(pgrep -f '/tmp/probe-agent' 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    log_warn "发现假 probe-agent → PIDs: $PIDS"
    echo "$PIDS" | xargs kill -9 2>/dev/null || true
    KILLED=$((KILLED + 1))
fi

# 杀所有 nezha-agent 进程
PIDS=$(pgrep -f 'nezha-agent' 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    log_warn "发现 nezha-agent 进程 → PIDs: $PIDS"
    echo "$PIDS" | xargs kill -9 2>/dev/null || true
    KILLED=$((KILLED + 1))
fi

if [ $KILLED -gt 0 ]; then
    log_info "已终止 $KILLED 组恶意进程"
else
    log_info "未发现运行中的恶意进程"
fi

# ------------------------------ Step 2: 删文件 ------------------------------
log_step "Step 2: 删除恶意文件"

# DDoS 相关
for f in /tmp/b /tmp/.a /tmp/probe-agent; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log_info "已删除: $f"
    fi
done

# 删除 nezha-agent 安装目录
NEZHA_DIRS="/opt/nezha/agent"
for dir in $NEZHA_DIRS; do
    if [ -d "$dir" ]; then
        # 检查是否包含 nezha-agent 二进制
        if [ -f "$dir/nezha-agent" ] || ls "$dir"/nezha-agent* >/dev/null 2>&1; then
            rm -rf "$dir"
            log_info "已删除: $dir"
        fi
    fi
done

# 检查其他位置的 nezha-agent
for f in /usr/local/bin/nezha-agent /usr/bin/nezha-agent /usr/local/sbin/nezha-agent; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log_info "已删除: $f"
    fi
done

# ------------------------------ Step 3: 清 systemd ------------------------------
log_step "Step 3: 清理 systemd 服务"

# 找到所有 nezha-agent 相关的 service 文件
NEZHA_SERVICES=$(find /etc/systemd/system /usr/lib/systemd/system -name 'nezha-agent*' -type f 2>/dev/null || true)

if [ -n "$NEZHA_SERVICES" ]; then
    for svc in $NEZHA_SERVICES; do
        svc_name=$(basename "$svc")
        systemctl stop "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "$svc"
        log_info "已移除服务: $svc_name"
    done
    systemctl daemon-reload 2>/dev/null || true
    log_info "已重载 systemd"
else
    log_info "未发现 nezha-agent 服务文件"
fi

# 额外清理：扫描所有 nezha 相关的 running service
for svc in $(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | grep -i nezha | awk '{print $1}'); do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    log_info "已停止服务: $svc"
done

# ------------------------------ Step 4: 清 crontab ------------------------------
log_step "Step 4: 检查定时任务"

CRONJOBS=$(crontab -l 2>/dev/null | grep -iE 'nezha|probe-agent|ice\.sh|103\.106\.228|86\.54\.82' || true)
if [ -n "$CRONJOBS" ]; then
    log_warn "发现可疑 crontab 条目:"
    echo "$CRONJOBS"
    crontab -l 2>/dev/null | grep -viE 'nezha|probe-agent|ice\.sh|103\.106\.228|86\.54\.82' | crontab - 2>/dev/null || true
    log_info "已清理可疑 crontab 条目"
else
    log_info "crontab 无可疑条目"
fi

# 检查 /etc/cron.d/
for f in /etc/cron.d/*; do
    [ -f "$f" ] || continue
    if grep -qE 'nezha|probe-agent|ice\.sh|103\.106\.228|86\.54\.82' "$f" 2>/dev/null; then
        log_warn "发现可疑 cron 文件: $f"
        rm -f "$f"
        log_info "已删除: $f"
    fi
done

# ------------------------------ Step 5: 验证 ------------------------------
log_step "Step 5: 清理验证"

# 检查进程
REMAINING=$(pgrep -f 'nezha-agent|/tmp/b|/tmp/.a|/tmp/probe-agent|103\.106\.228\.23|86\.54\.82\.179' 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
    log_error "仍有残留进程: $REMAINING"
else
    log_info "无残留恶意进程 ✓"
fi

# 检查文件
for f in /tmp/b /tmp/.a /tmp/probe-agent /opt/nezha/agent/nezha-agent; do
    if [ -f "$f" ]; then
        log_error "文件仍存在: $f"
    fi
done
log_info "恶意文件检查完毕 ✓"

# 检查服务
REMAINING_SVC=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | grep -i nezha || true)
if [ -n "$REMAINING_SVC" ]; then
    log_error "仍有 nezha 服务在运行:"
    echo "$REMAINING_SVC"
else
    log_info "无残留 nezha 服务 ✓"
fi

# ------------------------------ 完成 ------------------------------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   清理完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
log_info "恶意进程、文件、服务、定时任务已全部清理"
log_warn "请手动安装新的哪吒 Agent"
log_warn "C2 服务器已知: 86.54.82.179 / 103.106.228.23 / 68.183.181.185"
echo ""
