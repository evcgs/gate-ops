#!/bin/bash
# gate-ops · 发布窗口签发（002 新增脚本，不修改任何既有脚本）
# 用法: bash gateo-window-open.sh <计划文件> <用户确认的计划ID>
# 输出: stdout 单行 token = <payload>.<hmac-sha256-hex>；摘要走 stderr，不落盘 token
# 判定权: 完全复用 scripts/_approval.sh::gateo_load_plan，不重造第二套校验
# 兼容: bash 3.2（本机实测 3.2.57），不使用关联数组 / mapfile / nameref
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_approval.sh"

PLAN_FILE=${1:-}
PLAN_ID=${2:-}
if [[ -z "$PLAN_FILE" || -z "$PLAN_ID" ]]; then
    echo "用法: gateo-window-open.sh <计划文件> <用户确认的计划ID>" >&2
    exit 2
fi

SECRET_FILE=${GATEO_GUARD_SECRET_FILE:-$HOME/.gateo/guard.secret}
MIN_REMAIN=${GATEO_WINDOW_MIN_REMAIN:-600}
ALLOWED_KIND=${GATEO_WINDOW_ALLOWED_KIND:-backend}

if [[ ! -f "$SECRET_FILE" ]]; then
    echo "窗口密钥不存在，拒绝开窗" >&2
    exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
    echo "缺少 openssl，拒绝开窗" >&2
    exit 1
fi
PERM=$(stat -f '%Lp' "$SECRET_FILE" 2>/dev/null || stat -c '%a' "$SECRET_FILE" 2>/dev/null || echo "")
if [[ -n "$PERM" && "$PERM" != "600" && "$PERM" != "400" ]]; then
    echo "窗口密钥权限应为 0600，拒绝开窗" >&2
    exit 1
fi

# 唯一判定入口：计划 ID / 文件哈希 / 格式 / TTL 全部由真源承担
gateo_load_plan "$PLAN_FILE" "$PLAN_ID"

P_PLAN=${GATEO_VERIFIED_PLAN_ID:-}
P_PROJECT=${GATEO_PLAN_PROJECT:-}
P_KIND=${GATEO_PLAN_KIND:-}
P_TARGET=${GATEO_PLAN_TARGET:-}
P_MODE=${GATEO_PLAN_MODE:-}
P_EXPIRY=${GATEO_PLAN_EXPIRES_EPOCH:-}

check_field() {
    local v="$1" n="$2"
    if [[ -z "$v" || ! "$v" =~ ^[A-Za-z0-9_.-]+$ ]] || (( ${#v} > 128 )); then
        echo "窗口字段非法或过长: $n" >&2
        return 1
    fi
}
check_field "$P_PLAN" "planId" || exit 1
check_field "$P_PROJECT" "project" || exit 1
check_field "$P_KIND" "kind" || exit 1
check_field "$P_TARGET" "target" || exit 1
check_field "$P_MODE" "mode" || exit 1

if [[ "$P_KIND" != "$ALLOWED_KIND" ]]; then
    echo "窗口仅允许 kind=${ALLOWED_KIND}，当前 ${P_KIND}" >&2
    exit 1
fi
if [[ ! "$P_EXPIRY" =~ ^[0-9]+$ ]]; then
    echo "计划缺少合法到期时刻" >&2
    exit 1
fi

NOW=$(date +%s)
REMAIN=$(( P_EXPIRY - NOW ))
if (( REMAIN < MIN_REMAIN )); then
    echo "计划剩余有效期 ${REMAIN}s 低于下限 ${MIN_REMAIN}s，请重新生成计划并重新确认" >&2
    exit 1
fi

NONCE=$(openssl rand -hex 16 2>/dev/null || printf '%s-%s-%s' "$$" "$RANDOM" "$NOW")
check_field "$NONCE" "nonce" || exit 1

# v1 字段顺序固定，全部经白名单校验，不含 IP / 邮箱 / 绝对路径 / 密钥值
PAYLOAD="v1|${P_PLAN}|${P_PROJECT}|${P_KIND}|${P_TARGET}|${P_MODE}|${NONCE}|${P_EXPIRY}"
SECRET=$(cat "$SECRET_FILE")
SIG=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')
if [[ ! "$SIG" =~ ^[0-9a-f]{64}$ ]]; then
    echo "签名生成失败" >&2
    exit 1
fi

printf '%s.%s\n' "$PAYLOAD" "$SIG"
printf '[窗口已签发] plan=%s project=%s kind=%s 到期=%s 剩余=%ss\n' \
    "$P_PLAN" "$P_PROJECT" "$P_KIND" "$P_EXPIRY" "$REMAIN" >&2
