#!/bin/bash
# ============================================
# 🚢 gate-ops · _lock（发版锁，单写者原则的技术保障；被 deploy 脚本 source 调用）
# ============================================
# 防止多个 agent 会话在同一时间对同一项目并发发版
# （2026-11-03 实录：两个会话在一小时内先后发版同一项目，靠人眼发现，无技术拦截）。
#
# 用法：在 deploy 脚本中 source 本文件后调用 acquire_lock；
#       acquire_lock 成功时会注册 EXIT trap 自动释放（含脚本异常退出）。
#
# 原理：mkdir 是原子操作，同一目录只能被创建一次。
#       锁超过 LOCK_TTL 秒（默认 1800 = 30 分钟）视为陈旧，自动回收。
#
# 手动清锁（确认无并发发版时，例如上次发版会话已异常中断）：
#   rm -rf "${DEPLOY_LOCK_DIR:-/tmp/agent-release-locks}/${PROJECT:-default}"
#
# ⚠️ 必须以 bash 运行（脚本 shebang 已是 bash，勿用 zsh source）：
#   zsh 对"函数体内设置的 EXIT trap"会在函数返回时立即触发，
#   导致锁刚建立就被 release_lock 清掉（互斥失效）——已实测复现。
# ============================================

LOCK_DIR_BASE="${DEPLOY_LOCK_DIR:-/tmp/gateo-release-locks}"
LOCK_KEY="${PROJECT:-default}"
LOCK_DIR="$LOCK_DIR_BASE/$LOCK_KEY"
LOCK_TTL="${DEPLOY_LOCK_TTL:-1800}"
LOCK_HEARTBEAT_INTERVAL="${DEPLOY_LOCK_HEARTBEAT_INTERVAL:-15}"
LOCK_NONCE=""
LOCK_HEARTBEAT_PID=""

lock_now_host() {
    hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown
}

lock_new_nonce() {
    local n
    n=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [[ -n "$n" ]] || n="$$-$(date +%s)"
    printf '%s\n' "$n"
}

acquire_lock() {
    mkdir -p "$LOCK_DIR_BASE"
    if [[ -d "$LOCK_DIR" ]]; then
        # macOS(BSD) 与 Linux(GNU) stat 语法不同，双兼容取 mtime
        local lock_mtime now holder owner_host owner_pid current_host live=0
        lock_mtime=$(stat -f %m "$LOCK_DIR/heartbeat" 2>/dev/null || stat -c %Y "$LOCK_DIR/heartbeat" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
        now=$(date +%s)
        holder=$(cat "$LOCK_DIR/owner" 2>/dev/null || echo '未知')
        owner_host=$(printf '%s' "$holder" | awk -F'|' '{print $2}')
        owner_pid=$(printf '%s' "$holder" | awk -F'|' '{print $3}')
        current_host=$(lock_now_host)
        if [[ "$owner_host" == "$current_host" && "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
            live=1
        fi
        if (( now - ${lock_mtime:-0} > LOCK_TTL )); then
            if [[ "$live" == "1" ]]; then
                echo "❌ 发版锁心跳虽过期，但持锁进程仍存活（PID $owner_pid）→ 禁止自动抢锁"
            else
                echo "⚠️  回收确认失活的发版锁（心跳>${LOCK_TTL}s，持锁者: $holder）"
                rm -rf "$LOCK_DIR"
            fi
        fi
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local holder
        holder=$(cat "$LOCK_DIR/owner" 2>/dev/null || echo '未知会话')
        echo "❌ 检测到进行中的发版（锁持有者: ${holder}）→ 拒绝并发发版"
        echo "   规则：同一时间只允许一个会话发版同一项目（单写者原则）。"
        echo "   若确认无并发发版，先手动清锁再重试："
        echo "     rm -rf $LOCK_DIR"
        return 1
    fi
    LOCK_NONCE=$(lock_new_nonce)
    printf '%s|%s|%s|%s|%s\n' "$LOCK_NONCE" "$(lock_now_host)" "$$" "${USER:-agent}" "$(date '+%F %T')" > "$LOCK_DIR/owner"
    touch "$LOCK_DIR/heartbeat"
    (
        while [[ -d "$LOCK_DIR" ]] && [[ "$(cut -d'|' -f1 "$LOCK_DIR/owner" 2>/dev/null)" == "$LOCK_NONCE" ]]; do
            touch "$LOCK_DIR/heartbeat" 2>/dev/null || exit 0
            sleep "$LOCK_HEARTBEAT_INTERVAL"
        done
    ) &
    LOCK_HEARTBEAT_PID=$!
    trap release_lock EXIT
    return 0
}

release_lock() {
    [[ -n "${LOCK_HEARTBEAT_PID:-}" ]] && kill "$LOCK_HEARTBEAT_PID" 2>/dev/null || true
    [[ -n "${LOCK_HEARTBEAT_PID:-}" ]] && wait "$LOCK_HEARTBEAT_PID" 2>/dev/null || true
    if [[ -n "${LOCK_NONCE:-}" && "$(cut -d'|' -f1 "$LOCK_DIR/owner" 2>/dev/null)" == "$LOCK_NONCE" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    trap - EXIT
}

# 覆盖前锁复核：确认锁仍在本进程手中。
# 场景：脚本开头取锁后，若锁被人手动清掉、另一会话抢到新锁，
#       本脚本若继续执行就会形成双会话并发覆盖——必须在覆盖动作前再验一次。
verify_lock() {
    if [[ ! -f "$LOCK_DIR/owner" ]]; then
        echo "❌ 发版锁复核失败（锁已不存在或被清除）→ 终止发版"
        echo "   可能有其他会话已清锁并取得新锁发版中。请确认无并发发版后重新走完整流程。"
        return 1
    fi
    local recorded recorded_nonce
    recorded=$(cat "$LOCK_DIR/owner" 2>/dev/null)
    recorded_nonce=$(printf '%s' "$recorded" | cut -d'|' -f1)
    if [[ -z "${LOCK_NONCE:-}" || "$recorded_nonce" != "$LOCK_NONCE" ]]; then
        echo "❌ 发版锁复核失败（持锁者已变更: ${recorded}）→ 终止发版"
        echo "   当前锁由其他会话持有，禁止覆盖。"
        return 1
    fi
    echo "🔒 锁复核通过（持锁者: ${recorded}）"
    return 0
}
