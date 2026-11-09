#!/bin/bash
# gate-ops · 服务器端部署闸门（002 新增脚本，自包含，不依赖任何本地 gate-ops 脚本）
#
# 部署位置: ~/.gateops/deploy-guard.sh (0700)
# authorized_keys 追加行:
#   command="<HOME>/.gateops/deploy-guard.sh" ssh-ed25519 AAAA... gateops-project-compose-shadow
#
# 运行形态: sshd 的 forced command 会忽略客户端命令，把它放进 SSH_ORIGINAL_COMMAND。
#   因此控制子命令用固定前缀分流（精确前缀匹配，不做命令语义解析、不做部署命令白名单）：
#     __GATEOPS_OPEN__   <token>   开窗
#     __GATEOPS_CLOSE__  <token>   关窗
#     __GATEOPS_STATUS__           只读状态
#     其它                        部署命令：校验窗口后原样 exec
#
# 红线: 不读 stdin；不解析 / 不改写 / 不白名单化部署命令；日志不含命令原文与敏感词。
# 模式: ~/.gateops/guard.mode = shadow（默认，不拒绝任何命令）| enforce（窗口无效即拒绝）
# 异常: 影子模式告警后仍原样执行；强制模式 fail-closed。
# 兼容: bash 3.2+，仅依赖 openssl / coreutils。

GUARD_HOME=${GUARD_HOME:-$HOME/.gateops}
SECRET_FILE="$GUARD_HOME/guard.secret"
WINDOW_FILE="$GUARD_HOME/window"
NONCE_FILE="$GUARD_HOME/nonce.used"
MODE_FILE="$GUARD_HOME/guard.mode"
LOG_FILE="$GUARD_HOME/guard.log"

PREFIX_OPEN="__GATEOPS_OPEN__"
PREFIX_CLOSE="__GATEOPS_CLOSE__"
PREFIX_STATUS="__GATEOPS_STATUS__"

CMD=${SSH_ORIGINAL_COMMAND:-}

mkdir -p "$GUARD_HOME" 2>/dev/null || true
chmod 700 "$GUARD_HOME" 2>/dev/null || true

# 仅从文件读取，绝不读 stdin
hmac_hex() {
    local payload="$1" secret
    command -v openssl >/dev/null 2>&1 || return 1
    [ -f "$SECRET_FILE" ] || return 1
    secret=$(cat "$SECRET_FILE") || return 1
    [ -n "$secret" ] || return 1
    printf '%s' "$payload" | openssl dgst -sha256 -hmac "$secret" 2>/dev/null | awk '{print $NF}'
}

cmd_hash() {
    if command -v openssl >/dev/null 2>&1; then
        printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-12
    else
        printf 'na'
    fi
}

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# 日志字段: ts|planId|nonce|decision|reason|cmdLen|cmdHash12
# 不含命令原文；cmdHash12 为不可逆指纹，用于对账而非判定。
write_log() {
    local plan="$1" nonce="$2" decision="$3" reason="$4" ts clen chash
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    clen=${#CMD}
    chash=$(cmd_hash "$CMD")
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$ts" "$plan" "$nonce" "$decision" "$reason" "$clen" "$chash" \
        >> "$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

verify_token() {
    local token="$1" payload sig expected
    payload="${token%.*}"
    sig="${token##*.}"
    [ -n "$payload" ] || return 1
    [ -n "$sig" ] || return 1
    [ "$payload" != "$token" ] || return 1
    case "$sig" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ ${#sig} -eq 64 ] || return 1
    expected=$(hmac_hex "$payload") || return 1
    [ "$sig" = "$expected" ] || return 1
    printf '%s' "$payload"
}

guard_mode() {
    local m
    m=$(cat "$MODE_FILE" 2>/dev/null || printf 'shadow')
    [ "$m" = "enforce" ] && { printf 'enforce'; return 0; }
    printf 'shadow'
}

nonce_used() {
    [ -f "$NONCE_FILE" ] || return 1
    grep -Fqx "$1" "$NONCE_FILE" 2>/dev/null
}

mark_nonce() {
    printf '%s\n' "$1" >> "$NONCE_FILE" 2>/dev/null || return 1
    chmod 600 "$NONCE_FILE" 2>/dev/null || true
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

do_open() {
    local token="$1" payload v plan nonce expiry now tmp
    payload=$(verify_token "$token") || {
        echo "deploy-guard: 窗口凭证验签失败" >&2
        write_log none none deny "bad-signature"
        return 1
    }
    v=$(field "$payload" 1)
    [ "$v" = "v1" ] || { echo "deploy-guard: 凭证版本不符" >&2; write_log none none deny "bad-version"; return 1; }
    plan=$(field "$payload" 2)
    nonce=$(field "$payload" 7)
    expiry=$(field "$payload" 8)
    is_uint "$expiry" || { echo "deploy-guard: 凭证到期时刻非法" >&2; return 1; }
    now=$(date +%s)
    if [ "$expiry" -le "$now" ]; then
        echo "deploy-guard: 窗口已过期" >&2
        write_log "$plan" "$nonce" deny "expired"
        return 1
    fi
    if nonce_used "$nonce"; then
        echo "deploy-guard: nonce 重放被拒" >&2
        write_log "$plan" "$nonce" deny "replay"
        return 1
    fi
    tmp=$(mktemp "$GUARD_HOME/.window.XXXXXX" 2>/dev/null) || {
        echo "deploy-guard: 无法创建窗口临时文件" >&2
        return 1
    }
    printf '%s\n' "$token" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$WINDOW_FILE" || { rm -f "$tmp"; return 1; }
    mark_nonce "$nonce" || true
    write_log "$plan" "$nonce" allow "window-opened"
    printf 'deploy-guard: 窗口已开启 plan=%s expiry=%s\n' "$plan" "$expiry"
}

do_close() {
    local token="$1" payload v plan nonce expiry now
    payload=$(verify_token "$token") || {
        echo "deploy-guard: 关窗凭证验签失败" >&2
        write_log none none deny "close-bad-signature"
        return 1
    }
    v=$(field "$payload" 1)
    [ "$v" = "v1c" ] || { echo "deploy-guard: 关窗凭证版本不符" >&2; return 1; }
    plan=$(field "$payload" 3)
    nonce=$(field "$payload" 4)
    expiry=$(field "$payload" 5)
    is_uint "$expiry" || return 1
    now=$(date +%s)
    if [ "$expiry" -lt "$now" ]; then
        echo "deploy-guard: 关窗凭证已过期" >&2
        write_log "$plan" "$nonce" deny "close-expired"
        return 1
    fi
    if nonce_used "$nonce"; then
        echo "deploy-guard: 关窗 nonce 重放被拒" >&2
        return 1
    fi
    mark_nonce "$nonce" || true
    rm -f "$WINDOW_FILE" 2>/dev/null || true
    write_log "$plan" "$nonce" allow "window-closed"
    printf 'deploy-guard: 窗口已关闭 plan=%s\n' "$plan"
}

do_status() {
    local mode token payload expiry plan now valid
    mode=$(guard_mode)
    valid=0
    plan=none
    expiry=none
    if [ -f "$WINDOW_FILE" ]; then
        token=$(cat "$WINDOW_FILE" 2>/dev/null || printf '')
        payload=$(verify_token "$token") && {
            expiry=$(field "$payload" 8)
            plan=$(field "$payload" 2)
            now=$(date +%s)
            if is_uint "$expiry" && [ "$expiry" -ge "$now" ]; then
                valid=1
            fi
        }
    fi
    printf 'mode=%s windowValid=%s plan=%s expiry=%s\n' "$mode" "$valid" "$plan" "$expiry"
}

do_forced() {
    local mode token payload expiry plan nonce now valid reason decision secret_ok
    mode=$(guard_mode)
    valid=0
    plan=none
    nonce=none
    reason="no-valid-window"

    if [ -f "$WINDOW_FILE" ]; then
        token=$(cat "$WINDOW_FILE" 2>/dev/null || printf '')
        payload=$(verify_token "$token") || payload=""
        if [ -n "$payload" ]; then
            expiry=$(field "$payload" 8)
            plan=$(field "$payload" 2)
            nonce=$(field "$payload" 7)
            now=$(date +%s)
            if ! is_uint "$expiry"; then
                reason="window-unverifiable"
            elif [ "$expiry" -lt "$now" ]; then
                reason="expired"
            else
                valid=1
                reason="ok"
            fi
        else
            reason="window-unverifiable"
        fi
    fi

    # guard 自身降级：影子模式仍执行，强制模式 fail-closed
    secret_ok=1
    command -v openssl >/dev/null 2>&1 || secret_ok=0
    [ -f "$SECRET_FILE" ] || secret_ok=0
    if [ "$secret_ok" -ne 1 ]; then
        reason="guard-degraded"
        valid=0
    fi

    # 影子 / 强制的拒绝语义必须可区分：影子记「本会拒绝」，强制记「已拒绝」。
    # 否则 quality N-01/N-02 的 P2 判定与 E-06 按日志对账会把真实拒绝读成影子记录。
    decision="allow"
    if [ "$valid" -ne 1 ]; then
        if [ "$mode" = "enforce" ]; then
            decision="deny"
        else
            decision="deny-would-be"
        fi
    fi
    write_log "$plan" "$nonce" "$decision" "$reason"

    if [ "$mode" = "enforce" ] && [ "$valid" -ne 1 ]; then
        echo "deploy-guard: 无有效发布窗口，命令被拒绝 (reason=${reason})" >&2
        exit 1
    fi

    # 红线：原样交给 sh；脚本本身不读 stdin，stdin 完整留给目标命令
    exec /bin/sh -c "$CMD"
}

case "$CMD" in
    "$PREFIX_OPEN "*)
        do_open "${CMD#$PREFIX_OPEN }"
        exit $?
        ;;
    "$PREFIX_CLOSE "*)
        do_close "${CMD#$PREFIX_CLOSE }"
        exit $?
        ;;
    "$PREFIX_STATUS"|"$PREFIX_STATUS "*)
        do_status
        exit $?
        ;;
esac

if [ -z "$CMD" ]; then
    echo "deploy-guard: 未收到 SSH_ORIGINAL_COMMAND" >&2
    exit 0
fi

do_forced
