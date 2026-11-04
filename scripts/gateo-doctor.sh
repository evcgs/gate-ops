#!/bin/bash
# Read-only local validation for a gate-ops project profile.

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROFILE_DIR="$SCRIPT_DIR/../profiles"
ERRORS=0
WARNINGS=0

ok() { printf 'OK   %s\n' "$1"; }
warn() { printf 'WARN %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf 'FAIL %s\n' "$1"; ERRORS=$((ERRORS + 1)); }

usage() {
    echo "Usage: PROJECT=<name> bash scripts/gateo-doctor.sh"
    echo "   or: DEPLOY_CONF=/absolute/profile.sh bash scripts/gateo-doctor.sh"
    echo "Deep mode: bash scripts/gateo-doctor.sh --deep            # 全项目跨产物一致性体检"
    echo "           PROJECT=<name> bash scripts/gateo-doctor.sh --deep   # 单项目"
}

# ---- --deep：跨产物一致性体检（spec-kit cross-artifact analysis 方法论移植，v3.2.0）----
# 校验档案/标记/台账/人读档案/回执五类产物互相一致 + git 归属漂移信号。只读。
deep_scan() {
    local prof="$1"
    local name
    name=$(basename "$prof" .sh)
    [[ "$name" == "template" ]] && return 0
    (
        GATEO_DOCTOR=1
        # shellcheck disable=SC1090
        source "$prof" >/dev/null 2>&1
        # 1) MARKERS_FILE 引用完整性
        mf="${MARKERS_FILE:-}"
        if [[ -z "$mf" ]]; then
            echo "WARN $name: MARKERS_FILE 未配置"
        elif [[ ! -f "$mf" ]]; then
            echo "FAIL $name: MARKERS_FILE 引用的文件不存在（档案已引用但文件缺失，project-b 复核实录教训）"
        elif ! grep -qEv '^[[:space:]]*(#|$)' "$mf" 2>/dev/null; then
            echo "WARN $name: MARKERS_FILE 存在但为空（无有效标记）"
        else
            echo "OK   $name: markers 文件存在且非空"
        fi
        # 2) 本地路径存在性
        for _v in LOCAL_APP_DIR PROJECT_ROOT; do
            _val="${!_v:-}"
            [[ -z "$_val" ]] && continue
            [[ ! -d "$_val" ]] && echo "FAIL $name: $_v 指向的本地目录不存在"
        done
        # 3) 台账
        if [[ ! -f "$SCRIPT_DIR/../records/$name.md" ]]; then
            echo "FAIL $name: 台账 records/$name.md 缺失（有档案必有台账）"
        else
            echo "OK   $name: 台账存在"
        fi
        # 4) 人读档案
        [[ ! -f "$SCRIPT_DIR/../profiles/$name-deploy-notes.md" ]] && \
            echo "WARN $name: 人读档案 profiles/$name-deploy-notes.md 缺失"
        # 5) 审计回执身份声明（v3.1.1 铁律）
        _rec="$SCRIPT_DIR/../profiles/$name-audit-receipt.md"
        if [[ -f "$_rec" ]] && ! grep -q "本次系统=" "$_rec"; then
            echo "WARN $name: 审计回执缺第一行身份声明（本次系统=<X> · 身份依据=…）"
        fi
        # 6) git 归属漂移信号：本系统产物在工作区未提交
        _repo="$SCRIPT_DIR/.."
        if git -C "$_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            _dirty=$(git -C "$_repo" status --porcelain | grep -E "profiles/${name}[.-]|records/${name}\.md|feature-markers-${name}\.txt" || true)
            if [[ -n "$_dirty" ]]; then
                echo "WARN $name: 仓库存在本项目未提交产物（归属漂移信号，project-compose/project-c 实录教训）：$(printf '%s\n' "$_dirty" | wc -l | tr -d ' ') 个文件"
            fi
        fi
    )
}

if [[ "${1:-}" == "--deep" ]]; then
    echo "🚢 gate-ops · doctor --deep（跨产物一致性体检，只读）"
    if [[ -n "${PROJECT:-}" ]]; then
        [[ -f "$PROFILE_DIR/${PROJECT}.sh" ]] || { echo "FAIL profile 不存在: $PROFILE_DIR/${PROJECT}.sh"; exit 2; }
        PROFS="$PROFILE_DIR/${PROJECT}.sh"
    else
        PROFS=$(ls "$PROFILE_DIR"/*.sh 2>/dev/null)
        [[ -n "$PROFS" ]] || { echo "FAIL 无档案: $PROFILE_DIR"; exit 2; }
    fi
    OUT_ALL=""
    for _p in $PROFS; do
        _out=$(deep_scan "$_p")
        OUT_ALL+=$_out$'\n'
    done
    printf '%s' "$OUT_ALL"
    _fails=$(printf '%s\n' "$OUT_ALL" | grep -c '^FAIL' || true)
    _warns=$(printf '%s\n' "$OUT_ALL" | grep -c '^WARN' || true)
    echo "deep result: FAIL=$_fails WARN=$_warns"
    [[ "$_fails" -eq 0 ]] && exit 0 || exit 1
fi

CONF_FILE="${DEPLOY_CONF:-}"
if [[ -z "$CONF_FILE" && -n "${PROJECT:-}" ]]; then
    CONF_FILE="$PROFILE_DIR/${PROJECT}.sh"
fi
if [[ -z "$CONF_FILE" ]]; then
    usage
    exit 2
fi
if [[ ! -f "$CONF_FILE" ]]; then
    echo "FAIL profile not found: $CONF_FILE"
    exit 2
fi
if ! bash -n "$CONF_FILE"; then
    echo "FAIL profile has shell syntax errors: $CONF_FILE"
    exit 2
fi

# Profiles are trusted configuration code. GATEO_DOCTOR lets a profile avoid any
# optional runtime action; well-formed profiles only assign variables and source credentials.
GATEO_DOCTOR=1
# shellcheck disable=SC1090
source "$CONF_FILE"

MODE="${DEPLOY_MODE:-}"
ENV_NAME="${GATEO_ENV:-}"
SERVER_EFFECTIVE="${DEPLOY_SERVER:-${SERVER:-}}"
SSH_KEY_EFFECTIVE="${DEPLOY_SSH_KEY:-${SSH_KEY:-}}"
BACKUP_EFFECTIVE="${DEPLOY_BACKUP_DIR:-${BACKUP_DIR:-}}"
LOCAL_EFFECTIVE="${DEPLOY_APP_DIR:-${LOCAL_APP_DIR:-}}"
PROJECT_EFFECTIVE="${DEPLOY_PROJECT_DIR:-${PROJECT_DIR:-}}"
RSYNC_EFFECTIVE="${DEPLOY_RSYNC_DEST:-${RSYNC_DEST:-}}"
CONTAINER_EFFECTIVE="${DEPLOY_CONTAINER:-${CONTAINER:-}}"
BUILD_EFFECTIVE="${DEPLOY_BUILD_SRC:-${BUILD_SRC:-}}"
HEALTH_URL_EFFECTIVE="${DEPLOY_HEALTH_URL:-${HEALTH_URL:-}}"
HEALTH_CMD_EFFECTIVE="${DEPLOY_HEALTH_CMD:-${HEALTH_CMD:-}}"
READINESS_URL_EFFECTIVE="${DEPLOY_READINESS_URL:-${READINESS_URL:-}}"
READINESS_CMD_EFFECTIVE="${DEPLOY_READINESS_CMD:-${READINESS_CMD:-}}"
TARGETS_EFFECTIVE="${DEPLOY_TARGETS:-}"
SSH_OPTS_EFFECTIVE="${DEPLOY_SSH_OPTS:-${SSH_OPTS:-}}"

echo "gate-ops doctor (local, read-only)"
echo "profile: ${CONF_FILE##*/}"

for cmd in bash ssh rsync tar; do
    if command -v "$cmd" >/dev/null 2>&1; then ok "local command available: $cmd"; else fail "missing local command: $cmd"; fi
done
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    ok "SHA-256 implementation available"
else
    fail "missing SHA-256 implementation (sha256sum or shasum)"
fi

case "$MODE" in
    container-sync|compose-build|process|custom) ok "DEPLOY_MODE=$MODE" ;;
    "") fail "DEPLOY_MODE is required" ;;
    *) fail "unsupported DEPLOY_MODE=$MODE" ;;
esac
case "$ENV_NAME" in
    prod|staging|dev) ok "GATEO_ENV=$ENV_NAME" ;;
    "") fail "GATEO_ENV is required" ;;
    *) fail "GATEO_ENV must be prod, staging, or dev" ;;
esac
case "${E2E_MODE:-}" in
    auto|always|off) ok "E2E_MODE=${E2E_MODE}" ;;
    "") fail "E2E_MODE is required" ;;
    *) fail "E2E_MODE must be auto, always, or off" ;;
esac

if [[ -n "$SERVER_EFFECTIVE" || -n "$TARGETS_EFFECTIVE" ]]; then
    ok "deployment target configured (value redacted)"
else
    fail "SERVER or DEPLOY_TARGETS is required"
fi
if [[ -n "$SSH_KEY_EFFECTIVE" ]]; then
    if [[ -f "$SSH_KEY_EFFECTIVE" ]]; then
        ok "SSH key exists (path redacted)"
        KEY_MODE=$(stat -f %Lp "$SSH_KEY_EFFECTIVE" 2>/dev/null || stat -c %a "$SSH_KEY_EFFECTIVE" 2>/dev/null || echo unknown)
        case "$KEY_MODE" in
            600|400) ok "SSH key permissions are restrictive" ;;
            unknown) warn "could not determine SSH key permissions" ;;
            *) warn "SSH key permissions should normally be 600 or 400" ;;
        esac
    else
        fail "configured SSH key does not exist (path redacted)"
    fi
else
    fail "SSH key is required; implicit default identities are not allowed"
fi
if [[ "$SSH_OPTS_EFFECTIVE" == *"StrictHostKeyChecking=no"* || "$SSH_OPTS_EFFECTIVE" == *"UserKnownHostsFile=/dev/null"* ]]; then
    fail "SSH host verification is disabled"
else
    ok "SSH host verification is not disabled"
fi

check_remote_dir() {
    label="$1"
    value="$2"
    if [[ -z "$value" ]]; then
        fail "$label is required"
    elif [[ "$value" != /* || "$value" == "/" ]]; then
        fail "$label must be an absolute non-root path"
    else
        ok "$label is an absolute non-root path (value redacted)"
    fi
}

check_remote_dir BACKUP_DIR "$BACKUP_EFFECTIVE"
if [[ -z "$LOCAL_EFFECTIVE" ]]; then
    fail "LOCAL_APP_DIR/DEPLOY_APP_DIR is required"
elif [[ ! -d "$LOCAL_EFFECTIVE" ]]; then
    fail "local source directory does not exist (path redacted)"
else
    ok "local source directory exists (path redacted)"
fi

case "$MODE" in
    container-sync)
        [[ -n "$CONTAINER_EFFECTIVE" ]] && ok "container name configured" || fail "CONTAINER is required"
        check_remote_dir BUILD_SRC "$BUILD_EFFECTIVE"
        ;;
    compose-build)
        check_remote_dir PROJECT_DIR "$PROJECT_EFFECTIVE"
        check_remote_dir RSYNC_DEST "$RSYNC_EFFECTIVE"
        if [[ -n "$PROJECT_EFFECTIVE" && ( "$RSYNC_EFFECTIVE" == "$PROJECT_EFFECTIVE" || "$RSYNC_EFFECTIVE" == "$PROJECT_EFFECTIVE"/* ) ]]; then
            ok "RSYNC_DEST is PROJECT_DIR or below it"
        else
            fail "RSYNC_DEST must be PROJECT_DIR or strictly below it"
        fi
        ;;
    process)
        check_remote_dir RSYNC_DEST "$RSYNC_EFFECTIVE"
        [[ -n "${DEPLOY_RELOAD_CMD:-}" ]] && ok "DEPLOY_RELOAD_CMD configured" || fail "DEPLOY_RELOAD_CMD is required"
        ;;
    custom)
        check_remote_dir PROJECT_DIR "$PROJECT_EFFECTIVE"
        [[ -n "${DEPLOY_CUSTOM_CMD:-}" ]] && ok "DEPLOY_CUSTOM_CMD configured" || fail "DEPLOY_CUSTOM_CMD is required"
        ;;
esac

if [[ -n "$READINESS_URL_EFFECTIVE" || -n "$READINESS_CMD_EFFECTIVE" || -n "$HEALTH_URL_EFFECTIVE" || -n "$HEALTH_CMD_EFFECTIVE" ]]; then
    ok "readiness probe configured"
else
    fail "DEPLOY_READINESS_URL/CMD or DEPLOY_HEALTH_URL/CMD is required"
fi
if [[ -n "$TARGETS_EFFECTIVE" && "$MODE" != "container-sync" && "$MODE" != "process" ]]; then
    fail "DEPLOY_TARGETS is only supported by container-sync/process"
fi

if [[ $ERRORS -gt 0 ]]; then
    echo "doctor result: FAIL ($ERRORS error(s), $WARNINGS warning(s))"
    exit 1
fi
echo "doctor result: PASS ($WARNINGS warning(s))"
exit 0
