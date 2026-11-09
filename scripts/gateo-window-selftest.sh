#!/bin/bash
# gate-ops · 窗口与 guard 本地行为自测（002 新增脚本）
# 用法: bash scripts/gateo-window-selftest.sh
# 性质: 纯本地，临时目录 + 临时密钥，不碰 ~/.gateo / ~/.ssh / 服务器 / dsh
# 覆盖: quality.md Q-01~Q-16；Q-14 依赖 T-15（dsh 插件 finally），本批次标 SKIP
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_approval.sh"

OPEN="$SCRIPT_DIR/gateo-window-open.sh"
CLOSE="$SCRIPT_DIR/gateo-window-close.sh"
GUARD="$SCRIPT_DIR/deploy-guard.sh"

TMP=$(mktemp -d /tmp/gateops-guard-selftest.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

SECRET_LOCAL="$TMP/guard.secret"
SECRET_SERVER="$TMP/home/guard.secret"
mkdir -p "$TMP/home" "$TMP/plans"
printf '%s' "$(openssl rand -hex 32)" > "$SECRET_LOCAL"
cp "$SECRET_LOCAL" "$SECRET_SERVER"
chmod 600 "$SECRET_LOCAL" "$SECRET_SERVER"
printf 'shadow' > "$TMP/home/guard.mode"
chmod 600 "$TMP/home/guard.mode"

export GATEO_GUARD_SECRET_FILE="$SECRET_LOCAL"
export GUARD_HOME="$TMP/home"
export GATEO_WINDOW_ALLOWED_KIND=backend
export GATEO_WINDOW_MIN_REMAIN=600

PREFIX_OPEN="__GATEOPS_OPEN__"
PREFIX_CLOSE="__GATEOPS_CLOSE__"
PREFIX_STATUS="__GATEOPS_STATUS__"

PASS=0
FAIL=0
SKIP=0
ok()   { printf '  %-4s %s\n' "PASS" "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  %-4s %s\n' "FAIL" "$1"; FAIL=$((FAIL + 1)); }
skp()  { printf '  %-4s %s\n' "SKIP" "$1"; SKIP=$((SKIP + 1)); }
expect_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (预期拒绝却通过)"; else ok "$d"; fi; }
expect_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
guard_run()   { env SSH_ORIGINAL_COMMAND="$1" GUARD_HOME="$TMP/home" bash "$GUARD"; }
field()       { printf '%s' "$1" | cut -d'|' -f"$2"; }

make_plan() {
    local f="$1" project="$2" kind="$3" expiry="$4" now
    now=$(date +%s)
    {
        printf 'GATEO_PLAN_FORMAT=%q\n' 1
        printf 'GATEO_PLAN_CREATED_EPOCH=%q\n' "$(( now - 60 ))"
        printf 'GATEO_PLAN_EXPIRES_EPOCH=%q\n' "$expiry"
        printf 'GATEO_PLAN_TS=%q\n' "20261106_193000"
        printf 'GATEO_PLAN_PROJECT=%q\n' "$project"
        printf 'GATEO_PLAN_ENV=%q\n' "prod"
        printf 'GATEO_PLAN_KIND=%q\n' "$kind"
        printf 'GATEO_PLAN_TARGET=%q\n' "backend"
        printf 'GATEO_PLAN_MODE=%q\n' "compose-build"
    } > "$f"
    chmod 600 "$f"
}

NOW=$(date +%s)
EXP_OK=$(( NOW + 1800 ))
PLAN_OK="$TMP/plans/ok.plan"
PLAN_TAMPER="$TMP/plans/tamper.plan"
PLAN_EXPIRED="$TMP/plans/expired.plan"
PLAN_FRONTEND="$TMP/plans/frontend.plan"
PLAN_SHORT="$TMP/plans/short.plan"

make_plan "$PLAN_OK" project-compose backend "$EXP_OK"
ID_OK=$(gateo_plan_id "$PLAN_OK")
cp "$PLAN_OK" "$PLAN_TAMPER"
make_plan "$PLAN_EXPIRED" project-compose backend "$(( NOW - 10 ))"
make_plan "$PLAN_FRONTEND" project-compose frontend "$EXP_OK"
make_plan "$PLAN_SHORT" project-compose backend "$(( NOW + 300 ))"

printf 'gate-ops 窗口 / guard 本地自测\n'
printf '临时目录: %s\n\n' "$TMP"

# Q-01 有效已确认计划开窗
TOKEN=$(bash "$OPEN" "$PLAN_OK" "$ID_OK" 2>/dev/null)
if [ -n "$TOKEN" ] && [ "${TOKEN%.*}" != "$TOKEN" ]; then
    ok "Q-01 有效已确认计划签发窗口凭证"
else
    bad "Q-01 有效已确认计划签发窗口凭证"
fi

# Q-02 计划被篡改
printf 'GATEO_PLAN_TAMPERED=1\n' >> "$PLAN_TAMPER"
expect_fail "Q-02 计划文件被篡改后拒绝开窗" bash "$OPEN" "$PLAN_TAMPER" "$ID_OK"

# Q-03 计划过期
ID_EXPIRED=$(gateo_plan_id "$PLAN_EXPIRED")
expect_fail "Q-03 计划已过期拒绝开窗" bash "$OPEN" "$PLAN_EXPIRED" "$ID_EXPIRED"

# Q-04 kind 不符
ID_FRONTEND=$(gateo_plan_id "$PLAN_FRONTEND")
expect_fail "Q-04 kind 非 backend 拒绝开窗" bash "$OPEN" "$PLAN_FRONTEND" "$ID_FRONTEND"

# Q-05 剩余有效期不足下限
ID_SHORT=$(gateo_plan_id "$PLAN_SHORT")
expect_fail "Q-05 计划剩余有效期低于 600s 拒绝开窗" bash "$OPEN" "$PLAN_SHORT" "$ID_SHORT"

# Q-06 窗口到期时刻复用计划的 EXPIRES_EPOCH
EXP_IN_TOKEN=$(field "${TOKEN%.*}" 8)
if [ "$EXP_IN_TOKEN" = "$EXP_OK" ]; then
    ok "Q-06 窗口到期时刻等于计划 EXPIRES_EPOCH"
else
    bad "Q-06 窗口到期时刻等于计划 EXPIRES_EPOCH (得到 $EXP_IN_TOKEN)"
fi

# Q-07 伪造签名
case "$TOKEN" in
    *0) TOKEN_BADSIG="${TOKEN%?}1" ;;
    *)  TOKEN_BADSIG="${TOKEN%?}0" ;;
esac
expect_fail "Q-07 伪造 HMAC 签名被拒" guard_run "$PREFIX_OPEN $TOKEN_BADSIG"

# Q-08 nonce 重放
if guard_run "$PREFIX_OPEN $TOKEN" >/dev/null 2>&1 && \
   ! guard_run "$PREFIX_OPEN $TOKEN" >/dev/null 2>&1; then
    ok "Q-08 同一 nonce 重放被拒"
else
    bad "Q-08 同一 nonce 重放被拒"
fi

# Q-09 payload 字段被增改
PAY="${TOKEN%.*}"
SIG="${TOKEN##*.}"
PAY_BAD="${PAY/|project-compose|/|evil|}"
TOKEN_BADPAY="${PAY_BAD}.${SIG}"
expect_fail "Q-09 窗口凭证字段被篡改后验签失败" guard_run "$PREFIX_OPEN $TOKEN_BADPAY"

# Q-10 窗口文件 0600 且零敏感词
if [ -f "$TMP/home/window" ]; then
    WPERM=$(stat -f '%Lp' "$TMP/home/window" 2>/dev/null || stat -c '%a' "$TMP/home/window" 2>/dev/null || echo "")
    WCONTENT=$(cat "$TMP/home/window")
    if [ "$WPERM" = "600" ] && \
       ! printf '%s' "$WCONTENT" | grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}|@|/Users|/www|SECRET|KEY='; then
        ok "Q-10 窗口文件 0600 且不含凭据/IP/路径"
    else
        bad "Q-10 窗口文件 0600 且不含凭据/IP/路径 (perm=$WPERM)"
    fi
else
    bad "Q-10 窗口文件未生成"
fi

# Q-11 guard 不读 stdin，管道数据完整
STDIN_IN="gateops-stdin-integrity-0123456789"
STDIN_OUT=$(printf '%s' "$STDIN_IN" | guard_run "cat" 2>/dev/null)
if [ "$STDIN_OUT" = "$STDIN_IN" ]; then
    ok "Q-11 guard 不读 stdin，管道字节完整"
else
    bad "Q-11 guard 不读 stdin，管道字节完整"
fi

# Q-12 原样 exec（含空格 / 管道字符 / 引号）
CMD12="printf '%s' 'x y|z'"
OUT12=$(guard_run "$CMD12" 2>/dev/null)
if [ "$OUT12" = "x y|z" ]; then
    ok "Q-12 部署命令原样 exec 未被改写"
else
    bad "Q-12 部署命令原样 exec 未被改写 (得到 $OUT12)"
fi

# Q-13 关窗后窗口失效
CLOSE_TOKEN=$(bash "$CLOSE" "$ID_OK" 2>/dev/null)
guard_run "$PREFIX_CLOSE $CLOSE_TOKEN" >/dev/null 2>&1
ST13=$(guard_run "$PREFIX_STATUS" 2>/dev/null)
case "$ST13" in
    *windowValid=0*) ok "Q-13 关窗后窗口失效" ;;
    *) bad "Q-13 关窗后窗口失效 ($ST13)" ;;
esac

# Q-14 属 dsh 插件层，bash 夹具不覆盖。T-15 已实现，证据见：
#   dsh-tool-gate-ops/test-gateops.mjs Q-16W（apply 抛错时 finally 仍关窗）
#   deploy-guard/local-loop.mjs LC-11（core.js 真实开窗→关窗链路）
# 此处如实保留 SKIP，不用跨层断言凑全绿。
skp "Q-14 gateops_apply 异常路径 finally 关窗（跨层，已由 Q-16W / LC-11 覆盖）"

# Q-15 日志零敏感词
CMD15='echo 10.0.0.1 user@example.com ~/user-home/secret KEY=abcd1234'
guard_run "$CMD15" >/dev/null 2>&1
LOG15=$(cat "$TMP/home/guard.log" 2>/dev/null || printf '')
if printf '%s' "$LOG15" | grep -Eq '10\.0\.0\.1|user@example|~/user-home|abcd1234'; then
    bad "Q-15 日志零敏感词"
else
    ok "Q-15 日志零敏感词（仅长度与不可逆指纹）"
fi

# Q-16 guard 降级：影子仍执行 / 强制 fail-closed
cp "$SECRET_SERVER" "$TMP/secret.bak"
rm -f "$SECRET_SERVER"
OUT16=$(guard_run 'printf %s shadow-ok' 2>/dev/null)
printf 'enforce' > "$TMP/home/guard.mode"
if guard_run 'printf %s enforce-bad' >/dev/null 2>&1; then ENFORCE_BLOCKED=0; else ENFORCE_BLOCKED=1; fi
cp "$TMP/secret.bak" "$SECRET_SERVER"
chmod 600 "$SECRET_SERVER"
printf 'shadow' > "$TMP/home/guard.mode"
if [ "$OUT16" = "shadow-ok" ] && [ "$ENFORCE_BLOCKED" -eq 1 ]; then
    ok "Q-16 影子模式降级仍执行；强制模式 fail-closed"
else
    bad "Q-16 影子模式降级仍执行；强制模式 fail-closed (out=$OUT16 blocked=$ENFORCE_BLOCKED)"
fi

printf '\n汇总: %s 通过 / %s 失败 / %s 跳过\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
