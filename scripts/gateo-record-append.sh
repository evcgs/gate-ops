#!/bin/bash
# ============================================
# 003 · gateo-record-append（发版台账 append-only 自动写入；真源纯新增）
# ============================================
# 用法: bash gateo-record-append.sh <project> <planId> [evidenceHash]
# 作用: 向 records/<project>.md 追加一行（操作 agent = DSH），再跑 build-index.sh 聚合。
#       build-index.sh 会整体重写 records/_index.md；本脚本只在该副本/真源内执行，
#       003 首验一律落在 REPLICA 逐字副本，真源既有 diff 保持 0 字节。
# 纪律: 不改写、不重排、不删除任何历史行；台账缺文件时 fail-closed 拒绝。
# ============================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

fail() { printf '%s: %s\n' "$1" "$2" >&2; exit 1; }

PROJECT="${1:-}"
PLAN_ID="${2:-}"
EVIDENCE_HASH="${3:--}"

if ! printf '%s' "$PROJECT" | grep -Eq '^[A-Za-z0-9_-]{1,64}$'; then
    fail E_BAD_ARGS "project 非法"
fi
if ! printf '%s' "$PLAN_ID" | grep -Eq '^[A-Za-z0-9._-]{8,128}$'; then
    fail E_BAD_ARGS "planId 非法"
fi

RECORD="$ROOT/records/$PROJECT.md"
INDEX_SCRIPT="$ROOT/scripts/build-index.sh"

[[ -f "$RECORD" ]] || fail E_NO_RECORD "项目台账不存在，拒绝自动写入（不新建历史台账）"
[[ -f "$INDEX_SCRIPT" ]] || fail E_BAD_ENV "build-index.sh 缺失"

STAMP=$(date '+%Y-%m-%d %H:%M')
EVIDENCE_TAG="ev-${EVIDENCE_HASH:0:12}"
LINE="| $STAMP | $PROJECT | 成功 | 浏览器 E2E 通过 | $PLAN_ID | READY | DSH | $EVIDENCE_TAG | 003 DSH Agent 四步闭环自动追加 |"

# append-only：只追加，不触碰已有字节
printf '%s\n' "$LINE" >> "$RECORD"

# 聚合索引（派生产物，可由脚本重放复现）
bash "$INDEX_SCRIPT" >/dev/null 2>&1 || fail E_INDEX_FAILED "build-index.sh 执行失败"

printf 'GATEO_RECORD ok project=%s planId=%s agent=DSH evidence=%s\n' "$PROJECT" "$PLAN_ID" "$EVIDENCE_TAG"
