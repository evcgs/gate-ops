#!/bin/bash
# ============================================
# 🚢 gate-ops · build-index（聚合 records/*.md → records/_index.md 总目录）
# ============================================
# 用法: bash scripts/build-index.sh
# 作用: 读取 records/ 下所有项目台账，生成按时间倒序的全局发版索引
#       （总目录页——"今天/本周所有项目发了什么"一屏可查，追踪入口）。
# 台账是单项目真源（append-only），本脚本只做聚合，不改台账。
# 每次发版写完台账后跑一次（或由 agent 在 ledger 阶段自动执行）。
# ============================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---- 品牌 banner ----
GATEO_VERSION=$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "dev")
echo "🚢 gate-ops · build-index v${GATEO_VERSION}"

RECORDS_DIR="$SCRIPT_DIR/../records"
INDEX_FILE="$RECORDS_DIR/_index.md"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

for f in "$RECORDS_DIR"/*.md; do
    base=$(basename "$f")
    [[ "$base" == "_index.md" ]] && continue
    project="${base%.md}"
    # 只取数据行（以 "| 20xx-" 开头），在时间列后插入项目列：
    # 原行 | 时间 | 目标 | ...  →  | 时间 | 项目 | 目标 | ...
    grep -E '^\| 20[0-9]{2}-' "$f" 2>/dev/null | while IFS= read -r row; do
        printf '%s' "$row" | awk -v p="$project" '{
            n = split($0, a, "|")
            t = a[2]; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
            printf "| %s | %s ", t, p
            for (i = 3; i <= n; i++) printf "| %s", a[i]
            print ""
        }'
    done >> "$TMP" || true
done

# 按时间（第2列，YYYY-MM-DD HH:MM）倒序
SORTED=$(sort -t'|' -k2,2r "$TMP" 2>/dev/null || cat "$TMP")

{
    echo "# 发版总目录（跨项目全局索引，自动生成）"
    echo ""
    echo "> 由 scripts/build-index.sh 聚合 records/*.md 生成——**勿手改本文件**，改各项目台账后重跑脚本。"
    echo "> 追踪入口：任意一行 → 该项目台账（records/<项目>.md）→ 证据目录（evidence/<项目>/<发版目录>/）。"
    echo ""
    echo "| 时间 | 项目 | 目标 | 结果 | 验收 | 备份文件（回滚点） | 健康检查 | 操作 agent | 证据 | 备注 |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
    if [[ -n "$SORTED" ]]; then
        echo "$SORTED"
    fi
} > "$INDEX_FILE"

COUNT=$(grep -cE '^\|[[:space:]]*20[0-9]{2}-' "$INDEX_FILE" || true)
echo "✅ 总目录已生成: ${INDEX_FILE}（${COUNT} 条发版记录）"
