#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_approval.sh"

PLAN_FILE=${1:-}
PLAN_ID=${2:-}
if [[ -z "$PLAN_FILE" || -z "$PLAN_ID" ]]; then
    echo "用法: gateo-apply.sh <计划文件> <用户确认的计划ID>"
    exit 2
fi
gateo_load_plan "$PLAN_FILE" "$PLAN_ID"

export GATEO_APPROVED_PLAN_FILE="$PLAN_FILE"
export GATEO_APPROVED_PLAN_ID="$PLAN_ID"
[[ -n "${GATEO_PLAN_PROJECT:-}" ]] && export PROJECT="$GATEO_PLAN_PROJECT"

case "$GATEO_PLAN_KIND" in
    backend) exec bash "$SCRIPT_DIR/deploy-backend.sh" ;;
    frontend) exec bash "$SCRIPT_DIR/deploy-frontend.sh" "$GATEO_PLAN_TARGET" ;;
    *) echo "❌ 未知计划类型: $GATEO_PLAN_KIND"; exit 2 ;;
esac
