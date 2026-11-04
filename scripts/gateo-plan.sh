#!/bin/bash
# Generate a short-lived release manifest. This command never deploys.
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_approval.sh"

KIND=${1:-}
TARGET=${2:-}
case "$KIND" in
    backend) TARGET="backend" ;;
    frontend)
        TARGET=${TARGET:-all}
        case "$TARGET" in admin|h5|all) ;; *) echo "用法: gateo-plan.sh frontend [admin|h5|all]"; exit 2 ;; esac
        ;;
    *) echo "用法: gateo-plan.sh <backend|frontend> [admin|h5|all]"; exit 2 ;;
esac

CONF_FILE="${DEPLOY_CONF:-}"
if [[ -z "$CONF_FILE" && -n "${PROJECT:-}" ]]; then
    [[ -f "$SCRIPT_DIR/../profiles/${PROJECT}.sh" ]] && CONF_FILE="$SCRIPT_DIR/../profiles/${PROJECT}.sh"
fi
if [[ -n "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

MODE="${DEPLOY_MODE:-container-sync}"
if [[ "$KIND" == "frontend" ]]; then MODE="static"; fi
case "$MODE" in container-sync|compose-build|process|custom|static) ;; *) echo "❌ 未知发布模式: $MODE"; exit 2 ;; esac

NOW_EPOCH=$(date +%s)
TTL="${GATEO_PLAN_TTL:-1800}"
[[ "$TTL" =~ ^[0-9]+$ ]] && (( TTL >= 60 && TTL <= 86400 )) || { echo "❌ GATEO_PLAN_TTL 必须为 60..86400 秒"; exit 2; }
EXPIRES_EPOCH=$((NOW_EPOCH + TTL))
PLAN_TS=$(date +%Y%m%d_%H%M%S)
PLAN_DIR="${GATEO_PLAN_DIR:-$HOME/.gateo/plans}"
mkdir -p "$PLAN_DIR"
chmod 700 "$PLAN_DIR" 2>/dev/null || true
TMP_PLAN=$(mktemp "$PLAN_DIR/.gateo-plan.XXXXXX")

EXPECTED_DIFFS="${DEPLOY_EXPECT_DIFFS:-}"

# —— 内嵌 precheck 只读干跑（v3.1.1，2026-11-04 project-a 实录教训）——
# 目的：把文件级差异清单直接呈进计划，让"确认覆盖资产"落到具体文件，
# 避免用户确认一次 → apply 时 precheck 发现未声明差异 → 被迫二次 plan。
# 只读、不部署；precheck 失败不阻塞计划生成（apply 前置检查仍会硬校验）。
# 设 GATEO_PLAN_SKIP_PRECHECK=1 可跳过（离线生成计划结构时用）。
PRECHECK_NOTE=""
if [[ "$KIND" == "backend" && -z "${GATEO_PLAN_SKIP_PRECHECK:-}" ]]; then
    PC_RC=0
    PC_OUT=$(bash "$SCRIPT_DIR/precheck-deploy.sh" backend 2>&1) || PC_RC=$?
    if printf '%s' "$PC_OUT" | grep -qE "云端与本地完全一致|全部落在期望发版清单内"; then
        PC_STATE="ok"
    elif [[ $PC_RC -eq 0 ]]; then
        PC_STATE="ok"
    elif printf '%s' "$PC_OUT" | grep -q "清单之外"; then
        PC_STATE="outside"
    elif printf '%s' "$PC_OUT" | grep -q "云端与本地不一致"; then
        PC_STATE="diffs"
    else
        PC_STATE="unavailable"
    fi
    PC_LIST=""
    PC_COUNT=0
    if [[ "$PC_STATE" == "diffs" || "$PC_STATE" == "outside" ]]; then
        PC_LIST=$(printf '%s\n' "$PC_OUT" | sed -n 's/^[[:space:]]*•[[:space:]]*//p' | sed '/^[[:space:]]*$/d' | head -50)
        PC_COUNT=$(printf '%s\n' "$PC_LIST" | grep -c . || true)
    fi
fi

if [[ "$KIND" == "backend" && -z "$EXPECTED_DIFFS" ]]; then
    EXPECTED_DIFFS="-"
    case "${PC_STATE:-}" in
        ok)
            DIFF_SUMMARY="precheck 干跑：云端与本地完全一致（无差异）" ;;
        diffs)
            DIFF_SUMMARY="precheck 实测差异 ${PC_COUNT} 项：$(printf '%s' "$PC_LIST" | tr '\n' ' ')｜确认这些差异属本次待发内容后，建议带 DEPLOY_EXPECT_DIFFS=「文件1,文件2」重新生成计划以固定范围（路径=下列清单原样）" ;;
        *)
            DIFF_SUMMARY="差异清单不可用（precheck 未通过或离线；apply 前置检查仍会硬校验）" ;;
    esac
elif [[ "$KIND" == "backend" ]]; then
    # 已声明期望差异：校验实测差异是否全部在声明内，清单外差异提前暴露
    case "${PC_STATE:-}" in
        diffs)
            OUTSIDE=""
            while IFS= read -r _f; do
                [[ -z "$_f" ]] && continue
                if ! printf '%s' "$EXPECTED_DIFFS" | tr ',' '\n' | grep -qxF "$_f"; then
                    OUTSIDE="${OUTSIDE}${_f} "
                fi
            done <<< "$PC_LIST"
            if [[ -z "$OUTSIDE" ]]; then
                DIFF_SUMMARY="已声明 ${EXPECTED_DIFFS}；precheck 实测差异 ${PC_COUNT} 项全部在声明内 ✅"
            else
                DIFF_SUMMARY="⚠️ 清单外差异（apply 会被拦，请补进 DEPLOY_EXPECT_DIFFS 后重新 plan）：${OUTSIDE}"
            fi
            ;;
        outside)
            DIFF_SUMMARY="⚠️ precheck 实测存在清单外差异（apply 会被拦，请补进 DEPLOY_EXPECT_DIFFS 后重新 plan）：$(printf '%s' "$PC_LIST" | tr '\n' ' ')" ;;
        ok)
            DIFF_SUMMARY="已声明 ${EXPECTED_DIFFS}；precheck 干跑通过（无清单外差异）" ;;
        *)
            DIFF_SUMMARY="已声明 ${EXPECTED_DIFFS}；差异清单不可用（apply 前置检查仍会硬校验）" ;;
    esac
elif [[ "$KIND" == "frontend" ]]; then
    EXPECTED_DIFFS="-"
    DIFF_SUMMARY="static dist 全量替换: ${TARGET}"
else
    DIFF_SUMMARY="$EXPECTED_DIFFS"
fi

SERVER_VALUE="${DEPLOY_SERVER:-${SERVER:-}}"
TARGET_SET="${DEPLOY_TARGETS:-$SERVER_VALUE}"
SERVER_HASH=$(gateo_sha256_text "$TARGET_SET")
CONFIG_HASH=$(gateo_config_digest "$KIND" "$TARGET" "$MODE")
if [[ "$KIND" == "backend" ]]; then
    SOURCE_DIR="${DEPLOY_APP_DIR:-${LOCAL_APP_DIR:-$SCRIPT_DIR/app}}"
else
    if [[ -n "${DEPLOY_PROJECT_ROOT:-}" ]]; then
        _project_root="$DEPLOY_PROJECT_ROOT"
    elif [[ -n "${PROJECT_ROOT:-}" ]]; then
        _project_root="$PROJECT_ROOT"
    else
        _project_root="$SCRIPT_DIR/.."
    fi
    case "$TARGET" in
        admin) SOURCE_DIR="$_project_root/admin" ;;
        h5) SOURCE_DIR="$_project_root/h5" ;;
        all) SOURCE_DIR="$_project_root" ;;
    esac
fi
SOURCE_HASH=$(gateo_source_digest "$SOURCE_DIR")

BACKUP_DIR_VALUE="${DEPLOY_BACKUP_DIR:-${BACKUP_DIR:-<profile-backup-dir>}}"
case "$KIND:$MODE" in
    backend:container-sync) BACKUP_NAME="gateo_backend_app_bak_${PLAN_TS}.tar.gz + gateo_backend_container_bak_${PLAN_TS}.tar.gz" ;;
    backend:*) BACKUP_NAME="gateo_backend_src_bak_${PLAN_TS}.tar.gz" ;;
    frontend:*)
        if [[ "$TARGET" == "all" ]]; then
            BACKUP_NAME="gateo_frontend_admin_bak_${PLAN_TS}.tar.gz + gateo_frontend_h5_bak_${PLAN_TS}.tar.gz"
        else
            BACKUP_NAME="gateo_frontend_${TARGET}_bak_${PLAN_TS}.tar.gz"
        fi
        ;;
esac

{
    printf 'GATEO_PLAN_FORMAT=%q\n' "1"
    printf 'GATEO_PLAN_CREATED_EPOCH=%q\n' "$NOW_EPOCH"
    printf 'GATEO_PLAN_EXPIRES_EPOCH=%q\n' "$EXPIRES_EPOCH"
    printf 'GATEO_PLAN_TS=%q\n' "$PLAN_TS"
    printf 'GATEO_PLAN_PROJECT=%q\n' "${PROJECT:-}"
    printf 'GATEO_PLAN_ENV=%q\n' "${GATEO_ENV:-unmarked}"
    printf 'GATEO_PLAN_KIND=%q\n' "$KIND"
    printf 'GATEO_PLAN_TARGET=%q\n' "$TARGET"
    printf 'GATEO_PLAN_MODE=%q\n' "$MODE"
    printf 'GATEO_PLAN_SERVER_HASH=%q\n' "$SERVER_HASH"
    printf 'GATEO_PLAN_CONFIG_HASH=%q\n' "$CONFIG_HASH"
    printf 'GATEO_PLAN_SOURCE_HASH=%q\n' "$SOURCE_HASH"
    printf 'GATEO_PLAN_EXPECTED_DIFFS=%q\n' "$EXPECTED_DIFFS"
    printf 'GATEO_PLAN_DIFF_SUMMARY=%q\n' "$DIFF_SUMMARY"
    printf 'GATEO_PLAN_BACKUP=%q\n' "$BACKUP_DIR_VALUE/$BACKUP_NAME"
} > "$TMP_PLAN"
chmod 600 "$TMP_PLAN"
PLAN_ID=$(gateo_plan_id "$TMP_PLAN")
PLAN_FILE="$PLAN_DIR/${PLAN_ID}.plan"
mv "$TMP_PLAN" "$PLAN_FILE"

echo "📋 发布计划已生成（尚未部署）"
echo "   计划 ID: $PLAN_ID"
echo "   目标: $KIND/$TARGET"
echo "   环境/模式: ${GATEO_ENV:-unmarked}/$MODE"
echo "   覆盖资产: $DIFF_SUMMARY"
echo "   预定备份: $BACKUP_DIR_VALUE/$BACKUP_NAME"
echo "   有效期: ${TTL}s"
echo "   计划文件: $PLAN_FILE"
echo "用户确认以上范围后执行："
echo "  bash $SCRIPT_DIR/gateo-apply.sh '$PLAN_FILE' '$PLAN_ID'"
