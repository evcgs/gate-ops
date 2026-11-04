#!/bin/bash
# gate-ops approval manifest helpers. Source from plan/apply/deploy scripts.

gateo_sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "gate-ops: shasum/sha256sum unavailable" >&2
        return 1
    fi
}

gateo_sha256_text() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    else
        return 1
    fi
}

gateo_config_digest() {
    local kind="$1" target="$2" mode="$3" material
    material=$(printf '%s\n' \
        "kind=$kind" \
        "target=$target" \
        "mode=$mode" \
        "server=${DEPLOY_SERVER:-${SERVER:-}}" \
        "targets=${DEPLOY_TARGETS:-}" \
        "ssh_key=${DEPLOY_SSH_KEY:-${SSH_KEY:-}}" \
        "backup=${DEPLOY_BACKUP_DIR:-${BACKUP_DIR:-}}" \
        "container=${DEPLOY_CONTAINER:-${CONTAINER:-}}" \
        "build_src=${DEPLOY_BUILD_SRC:-${BUILD_SRC:-}}" \
        "project_dir=${DEPLOY_PROJECT_DIR:-${PROJECT_DIR:-}}" \
        "rsync_dest=${DEPLOY_RSYNC_DEST:-${RSYNC_DEST:-}}" \
        "reload=${DEPLOY_RELOAD_CMD:-}" \
        "custom=${DEPLOY_CUSTOM_CMD:-}" \
        "remote_admin=${DEPLOY_REMOTE_ADMIN:-${REMOTE_ADMIN_DIR:-}}" \
        "remote_h5=${DEPLOY_REMOTE_H5:-${REMOTE_H5_DIR:-}}" \
        "health_url=${DEPLOY_HEALTH_URL:-${HEALTH_URL:-}}" \
        "health_cmd=${DEPLOY_HEALTH_CMD:-${HEALTH_CMD:-}}" \
        "readiness_url=${DEPLOY_READINESS_URL:-${READINESS_URL:-}}" \
        "readiness_cmd=${DEPLOY_READINESS_CMD:-${READINESS_CMD:-}}")
    gateo_sha256_text "$material"
}

gateo_source_digest() {
    local source_dir="$1"
    [[ -d "$source_dir" ]] || { printf 'MISSING\n'; return 0; }
    (
        cd "$source_dir"
        find . -type f ! -path './.git/*' ! -path './node_modules/*' -print \
            | LC_ALL=C sort \
            | while IFS= read -r f; do
                printf '%s\0' "$f"
                gateo_sha256_file "$f"
            done
    ) | if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        sha256sum | awk '{print $1}'
    fi
}

gateo_plan_id() {
    local digest
    digest=$(gateo_sha256_file "$1") || return 1
    printf 'GTO-%s\n' "$(printf '%s' "$digest" | cut -c1-20)"
}

gateo_load_plan() {
    local plan_file="$1" supplied_id="$2" computed_id now
    [[ -f "$plan_file" ]] || { echo "❌ 发布计划不存在: $plan_file" >&2; return 1; }
    computed_id=$(gateo_plan_id "$plan_file") || return 1
    if [[ "$supplied_id" != "$computed_id" ]]; then
        echo "❌ 发布计划 ID 不匹配（计划可能被修改，或确认的不是当前计划）" >&2
        echo "   用户确认: ${supplied_id:-<空>} / 当前计划: $computed_id" >&2
        return 1
    fi

    # The ID is a digest of the complete file. Source only after the caller-provided,
    # human-approved ID matches that digest. Plan files are generated mode 0600.
    # shellcheck disable=SC1090
    source "$plan_file"
    [[ "${GATEO_PLAN_FORMAT:-}" == "1" ]] || { echo "❌ 不支持的计划格式" >&2; return 1; }
    now=$(date +%s)
    if [[ ! "${GATEO_PLAN_EXPIRES_EPOCH:-}" =~ ^[0-9]+$ ]] || (( now > GATEO_PLAN_EXPIRES_EPOCH )); then
        echo "❌ 发布计划已过期，请重新生成计划并重新确认" >&2
        return 1
    fi
    export GATEO_VERIFIED_PLAN_ID="$computed_id"
    export GATEO_PLAN_TS GATEO_PLAN_KIND GATEO_PLAN_TARGET GATEO_PLAN_MODE
    if [[ -n "${GATEO_PLAN_EXPECTED_DIFFS:-}" && "${GATEO_PLAN_EXPECTED_DIFFS}" != "-" ]]; then
        export DEPLOY_EXPECT_DIFFS="$GATEO_PLAN_EXPECTED_DIFFS"
    fi
}

gateo_require_plan() {
    local expected_kind="$1" expected_target="$2" expected_mode="$3" source_dir="${4:-}"
    local plan_file="${GATEO_APPROVED_PLAN_FILE:-}" plan_id="${GATEO_APPROVED_PLAN_ID:-}"
    local current_server current_target_set current_server_hash current_source_hash current_config_hash
    [[ -n "$plan_file" && -n "$plan_id" ]] || {
        echo "❌ 缺少已确认的发布计划，直接调用部署脚本已被禁止。" >&2
        echo "   先运行 gateo-plan.sh，再把用户确认的计划 ID 交给 gateo-apply.sh。" >&2
        return 1
    }
    gateo_load_plan "$plan_file" "$plan_id" || return 1
    [[ "$GATEO_PLAN_KIND" == "$expected_kind" ]] || { echo "❌ 计划类型不匹配" >&2; return 1; }
    [[ "$GATEO_PLAN_TARGET" == "$expected_target" ]] || { echo "❌ 计划目标不匹配" >&2; return 1; }
    [[ "$GATEO_PLAN_MODE" == "$expected_mode" ]] || { echo "❌ 发布模式已变化，请重新生成计划" >&2; return 1; }
    [[ "${GATEO_PLAN_PROJECT:-}" == "${PROJECT:-}" ]] || { echo "❌ PROJECT 已变化，请重新生成计划" >&2; return 1; }
    [[ "${GATEO_PLAN_ENV:-}" == "${GATEO_ENV:-unmarked}" ]] || { echo "❌ 环境标注已变化，请重新生成计划" >&2; return 1; }
    current_server="${DEPLOY_SERVER:-${SERVER:-}}"
    current_target_set="${DEPLOY_TARGETS:-$current_server}"
    current_server_hash=$(gateo_sha256_text "$current_target_set") || return 1
    [[ "${GATEO_PLAN_SERVER_HASH:-}" == "$current_server_hash" ]] || { echo "❌ 目标服务器配置已变化，请重新生成计划" >&2; return 1; }
    current_config_hash=$(gateo_config_digest "$expected_kind" "$expected_target" "$expected_mode") || return 1
    [[ "${GATEO_PLAN_CONFIG_HASH:-}" == "$current_config_hash" ]] || { echo "❌ 发布配置在确认后发生变化，请重新生成计划" >&2; return 1; }
    current_source_hash=$(gateo_source_digest "$source_dir") || return 1
    [[ "${GATEO_PLAN_SOURCE_HASH:-}" == "$current_source_hash" ]] || { echo "❌ 本地源码在确认后发生变化，请重新生成计划" >&2; return 1; }
    echo "🔐 确认闸门通过: $GATEO_VERIFIED_PLAN_ID"
}
