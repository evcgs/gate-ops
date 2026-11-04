#!/bin/bash
# gateo-init.sh —— gate-ops 集成装配器（借鉴 spec-kit `specify init --integration` 方法论）
# 用法:
#   bash scripts/gateo-init.sh --integration workbuddy   # 软链到 ~/.workbuddy/skills/gate-ops
#   bash scripts/gateo-init.sh --integration claude      # 软链到 ~/.claude/skills/gate-ops
#   bash scripts/gateo-init.sh --integration codex       # 软链到 ~/.codex/skills/gate-ops + AGENTS.md 指引
#   bash scripts/gateo-init.sh --integration generic <目标技能目录>
#   bash scripts/gateo-init.sh --list                    # 列出支持的集成
# 真源仓库 = 本脚本所在仓库；安装一律用软链（多端共享同一真源，改一处全端生效）。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

list_integrations() {
    cat <<'EOF'
支持的集成（integrations/ 下各有详细说明）：
  workbuddy   WorkBuddy      ~/.workbuddy/skills/gate-ops
  claude      Claude Code    ~/.claude/skills/gate-ops
  codex       Codex CLI      ~/.codex/skills/gate-ops（+ AGENTS.md 指引行）
  generic     任意 agent     <你指定的技能目录>
EOF
}

case "${1:-}" in
    --list)
        list_integrations
        exit 0
        ;;
    --integration)
        INT=${2:-}
        case "$INT" in
            workbuddy|claude|codex|generic) ;;
            *) echo "❌ 未知集成: '${INT:-}'"; list_integrations; exit 2 ;;
        esac
        # 目标目录按集成说明解析
        case "$INT" in
            workbuddy) DEST="$HOME/.workbuddy/skills/gate-ops" ;;
            claude)    DEST="$HOME/.claude/skills/gate-ops" ;;
            codex)     DEST="$HOME/.codex/skills/gate-ops" ;;
            generic)   DEST="${3:?用法: --integration generic <目标技能目录>/gate-ops}" ;;
        esac
        if [[ -d "$DEST" && ! -L "$DEST" ]]; then
            echo "⚠️  $DEST 已存在且不是软链（可能是旧版解压安装）。"
            echo "   备份后移除再装软链？此操作需你确认：mv '$DEST' '${DEST}.bak.$(date +%Y%m%d%H%M%S)'"
            exit 1
        fi
        mkdir -p "$(dirname "$DEST")"
        ln -sfn "$REPO_DIR" "$DEST"
        echo "✅ gate-ops 已链接: $DEST -> $REPO_DIR"
        # 集成专属后置动作
        if [[ "$INT" == "codex" ]]; then
            AGENTS="$HOME/.codex/AGENTS.md"
            LINE="需要发版/回滚/部署时，先读 $DEST/SKILL.md 并严格遵循（gate-ops）"
            if [[ -f "$AGENTS" ]] && grep -qF "$DEST/SKILL.md" "$AGENTS"; then
                echo "ℹ️  AGENTS.md 已有指引行，跳过"
            else
                printf '\n%s\n' "$LINE" >> "$AGENTS"
                echo "✅ 已追加指引行到 $AGENTS"
            fi
        fi
        # 安装后自检（三条只读命令）
        echo "── 安装自检（只读）──"
        bash "$REPO_DIR/scripts/build-index.sh" >/dev/null && echo "OK   脚本可执行（build-index）" || echo "FAIL build-index 执行异常"
        bash -n "$REPO_DIR/scripts/deploy-backend.sh" && echo "OK   发版脚本语法通过" || echo "FAIL 发版脚本语法错误"
        [[ -f "$REPO_DIR/SKILL.md" ]] && echo "OK   SKILL.md 在位" || echo "FAIL SKILL.md 缺失"
        echo "提示：凭据在 ~/.gateo/credentials.sh（本包不含，接入新系统时按 profiles/template.sh 建）"
        ;;
    *)
        echo "用法: bash scripts/gateo-init.sh --integration <workbuddy|claude|codex|generic> [目标目录]"
        echo "      bash scripts/gateo-init.sh --list"
        exit 2
        ;;
esac
