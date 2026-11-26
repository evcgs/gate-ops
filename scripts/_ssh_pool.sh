#!/bin/bash
# ============================================
# 🚢 gate-ops · _ssh_pool（SSH 连接复用，消除密集新建握手被中间链路限流）
# ============================================
# 背景（2026-11-20 WKA 实录）：云安全网关对高频新建 SSH 连接限流，
# 脚本内十余次独立 SSH 握手会在 kex 阶段被 RST（kex_exchange_identification:
# Connection reset by peer）。受控实验：快速新建 30 次失败 14 次，
# ControlMaster 复用 30 次失败 0 次。
#
# 用法：在 deploy/precheck/rollback 脚本的 SSH_OPTS 定义之后 source 本文件，
#       然后调用 ssh_pool_init；脚本退出时 trap 自动清理主连接与 socket。
#
# 设计原则：
#   - 默认启用（这是修复的目的），但尊重显式配置：用户已在 SSH_OPTS 里带
#     ControlPath/ControlMaster 时不重复注入；GATEO_SSH_POOL=0 可整体关闭。
#   - 建主连接失败时静默降级为原 SSH_OPTS，不阻断发版（非所有环境都有限流）。
#   - socket 路径按 PROJECT+PID 唯一，并发项目互不影响；EXIT trap 清理。
#   - 不使用 zsh（EXIT trap 语义不同，见 _lock.sh 注释）。
# ============================================

SSH_POOL_SOCKET=""
SSH_POOL_ACTIVE=0

ssh_pool_init() {
    [[ "${GATEO_SSH_POOL:-1}" == "1" ]] || return 0
    # 尊重用户显式指定的连接复用配置
    case "${SSH_OPTS:-}" in
        *ControlPath*|*ControlMaster*) return 0 ;;
    esac
    local server="${DEPLOY_SERVER:-${SERVER:-}}"
    local key="${DEPLOY_SSH_KEY:-${SSH_KEY:-}}"
    [[ -n "$server" && -n "$key" ]] || return 0

    local base="/tmp/gateo-sshpool"
    mkdir -p "$base" 2>/dev/null || return 0
    chmod 700 "$base" 2>/dev/null || true
    SSH_POOL_SOCKET="$base/${PROJECT:-default}-$$.sock"
    rm -f "$SSH_POOL_SOCKET" 2>/dev/null || true

    # 建主连接：ServerAlive 保活；失败则降级（不阻断）
    if ssh -M -S "$SSH_POOL_SOCKET" -fN \
        -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -i "$key" "$server" >/dev/null 2>&1; then
        SSH_OPTS="${SSH_OPTS} -o ControlMaster=no -o ControlPath=${SSH_POOL_SOCKET}"
        SSH_POOL_ACTIVE=1
        # 无 lock 的脚本（precheck/rollback）靠此 trap 清理；
        # 有 lock 的脚本（deploy）由 _lock.sh 的 release_lock 主动调用 cleanup。
        trap ssh_pool_cleanup EXIT
        [[ "${GATEO_QUIET:-}" == "1" ]] || echo "🔗 SSH 连接复用已启用（socket: ${SSH_POOL_SOCKET##*/}）"
    else
        SSH_POOL_SOCKET=""
        SSH_POOL_ACTIVE=0
        [[ "${GATEO_QUIET:-}" == "1" ]] || echo "⚠️  SSH 主连接建立失败，降级为逐次新建（可能触发链路限流）"
    fi
    return 0
}

ssh_pool_cleanup() {
    [[ "$SSH_POOL_ACTIVE" == "1" && -n "$SSH_POOL_SOCKET" ]] || return 0
    local server="${DEPLOY_SERVER:-${SERVER:-}}"
    ssh -O exit -S "$SSH_POOL_SOCKET" "$server" >/dev/null 2>&1 || true
    rm -f "$SSH_POOL_SOCKET" 2>/dev/null || true
    SSH_POOL_ACTIVE=0
    return 0
}
