#!/bin/bash
# gate-ops · 发布窗口显式关闭（002 新增脚本，不修改任何既有脚本）
# 用法: bash gateo-window-close.sh <planId>
# 输出: stdout 单行 close token，供 guard 的 __GATEOPS_CLOSE__ 子命令消费
# 说明: 由 dsh 插件 gateops_apply 的 finally 分支调用；关窗凭证 60s 短时效 + 一次性 nonce
# 兼容: bash 3.2
set -euo pipefail

PLAN_ID=${1:-}
if [[ -z "$PLAN_ID" ]]; then
    echo "用法: gateo-window-close.sh <planId>" >&2
    exit 2
fi
if [[ ! "$PLAN_ID" =~ ^GTO-[0-9a-f]{20}$ ]]; then
    echo "planId 格式非法" >&2
    exit 1
fi

SECRET_FILE=${GATEO_GUARD_SECRET_FILE:-$HOME/.gateo/guard.secret}
if [[ ! -f "$SECRET_FILE" ]]; then
    echo "窗口密钥不存在，无法签发关窗凭证" >&2
    exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
    echo "缺少 openssl，无法签发关窗凭证" >&2
    exit 1
fi
PERM=$(stat -f '%Lp' "$SECRET_FILE" 2>/dev/null || stat -c '%a' "$SECRET_FILE" 2>/dev/null || echo "")
if [[ -n "$PERM" && "$PERM" != "600" && "$PERM" != "400" ]]; then
    echo "窗口密钥权限应为 0600" >&2
    exit 1
fi

NOW=$(date +%s)
EXP=$(( NOW + 60 ))
NONCE=$(openssl rand -hex 16 2>/dev/null || printf '%s-%s-%s' "$$" "$RANDOM" "$NOW")

PAYLOAD="v1c|close|${PLAN_ID}|${NONCE}|${EXP}"
SECRET=$(cat "$SECRET_FILE")
SIG=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')
if [[ ! "$SIG" =~ ^[0-9a-f]{64}$ ]]; then
    echo "签名生成失败" >&2
    exit 1
fi

printf '%s.%s\n' "$PAYLOAD" "$SIG"
printf '[关窗凭证已签发] plan=%s 凭证有效至=%s\n' "$PLAN_ID" "$EXP" >&2
