#!/bin/bash
# ============================================
# 🚢 gate-ops · rollback（回滚工具，多发布模式感知）
# ============================================
# 能上线不算完，能回滚才算稳。
#
# 用法:
#   rollback.sh list                              # 列出云端可用备份（最新在前）
#   rollback.sh frontend <admin|h5> [备份文件名]   # 恢复前端（默认最近一次备份）
#   rollback.sh backend [备份文件名]               # 恢复后端（按备份类型自动选择路径）
#
# backend 回滚路径按备份文件名自动判定:
#   backend_app_bak_*  → container-sync 型: 构建源恢复 → 容器先清后灌 → docker restart
#   backend_src_bak_*  → 按档案 DEPLOY_MODE 分支:
#                          compose-build/custom → 源码恢复 → $COMPOSE_CMD up -d --build
#                          process              → 源码恢复 → 执行 DEPLOY_RELOAD_CMD 重载
#   恢复后统一做健康检查。
#
# 配置加载优先级: DEPLOY_CONF > PROJECT 档案(profiles/<name>.sh)
#                 > 环境变量(DEPLOY_*) > 内置默认
# ============================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---- 配置档案加载（先于 banner——GATEO_ENV 等档案字段要进 banner）----
CONF_FILE="${DEPLOY_CONF:-}"
if [[ -z "$CONF_FILE" && -n "${PROJECT:-}" ]]; then
    for cand in "$SCRIPT_DIR/profiles/${PROJECT}.sh" "$SCRIPT_DIR/../profiles/${PROJECT}.sh"; do
        if [[ -f "$cand" ]]; then CONF_FILE="$cand"; break; fi
    done
fi
if [[ -n "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

# ---- 品牌 banner（版本号取仓库根 VERSION）----
GATEO_VERSION=$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "dev")
echo "🚢 gate-ops · rollback v${GATEO_VERSION}（PROJECT=${PROJECT:-未指定} · env=${GATEO_ENV:-未标注}）"
if [[ "${GATEO_ENV:-}" == "prod" ]]; then
    echo "⚠️  生产环境（prod）回滚操作——将覆盖现行服务，确认目标备份无误"
fi

SSH_KEY="${DEPLOY_SSH_KEY:-${SSH_KEY:-}}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o BatchMode=yes}"
SERVER="${DEPLOY_SERVER:-${SERVER:-}}"
[[ -n "$SERVER" ]] || { echo "❌ 未配置目标服务器——项目档案引用的凭据变量缺失？检查 ~/.gateo/credentials.sh 的 CRED_<项目>_SERVER"; exit 2; }
[[ -n "$SSH_KEY" ]] || { echo "❌ 未配置 SSH_KEY，拒绝回滚"; exit 2; }
_server_host="${SERVER#*@}"
[[ -n "$_server_host" ]] && exec > >(sed "s|$_server_host|<server>|g") 2>&1
BACKUP_DIR="${DEPLOY_BACKUP_DIR:-${BACKUP_DIR:-}}"
CONTAINER="${DEPLOY_CONTAINER:-${CONTAINER:-}}"
BUILD_SRC="${DEPLOY_BUILD_SRC:-${BUILD_SRC:-}}"
PROJECT_DIR="${PROJECT_DIR:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
RSYNC_DEST="${RSYNC_DEST:-$PROJECT_DIR}"
REMOTE_ADMIN_DIR="${DEPLOY_REMOTE_ADMIN:-${REMOTE_ADMIN_DIR:-}}"
REMOTE_H5_DIR="${DEPLOY_REMOTE_H5:-${REMOTE_H5_DIR:-}}"
HEALTH_URL="${DEPLOY_HEALTH_URL:-${HEALTH_URL:-}}"
HEALTH_CMD="${HEALTH_CMD:-}"
DEPLOY_MODE="${DEPLOY_MODE:-}"                # 档案字段: src 型恢复后的重建方式由此决定
DEPLOY_RELOAD_CMD="${DEPLOY_RELOAD_CMD:-}"    # process 模式: 服务重载命令

run_ssh() {
    ssh $SSH_OPTS -i "$SSH_KEY" "$SERVER" "$@"
}

require_safe_remote_dir() {
    local p="$1" label="$2"
    case "$p" in
        /|"") echo "❌ ${label} 不能为空或 /"; return 1 ;;
        *[!A-Za-z0-9_./-]*) echo "❌ ${label} 含不安全字符: $p"; return 1 ;;
    esac
    [[ "$p" == /* ]] || { echo "❌ ${label} 必须是绝对路径: $p"; return 1; }
}

normalize_backup_path() {
    local p="$1"
    [[ "$p" == /* ]] || p="$BACKUP_DIR/$p"
    case "$p" in
        *..*|*[!A-Za-z0-9_./+-]*) echo "❌ 备份路径含不安全字符: $p" >&2; return 1 ;;
    esac
    case "$p" in
        "$BACKUP_DIR"/*) ;;
        *) echo "❌ 备份必须位于 BACKUP_DIR 内: $BACKUP_DIR" >&2; return 1 ;;
    esac
    printf '%s\n' "$p"
}

verify_backup() {
    local bak="$1"
    run_ssh "set -e; test -s $bak; tar -tzf $bak >/dev/null; if test -f $bak.sha256; then sha256sum -c $bak.sha256 --status; elif test -f $bak.md5; then md5sum -c $bak.md5 --status; else echo 'missing checksum sidecar' >&2; exit 1; fi"
}

# 统一探活：HEALTH_CMD 优先；否则按备份类型选 curl（src 型）/ 容器内 python3（app 型）
probe() {
    local bak_type="$1"
    if [[ -n "$HEALTH_CMD" ]]; then
        run_ssh "$HEALTH_CMD"
    elif [[ "$bak_type" == "src" ]]; then
        [[ -n "$HEALTH_URL" ]] || { echo "（未配置 HEALTH_URL，跳过探活）" >&2; return 0; }
        run_ssh "curl --fail --silent --show-error -m 5 $HEALTH_URL"
    else
        run_ssh "docker exec $CONTAINER python3 -c \"import urllib.request; print(urllib.request.urlopen('$HEALTH_URL',timeout=5).read().decode())\""
    fi
}

CMD=${1:-list}
require_safe_remote_dir "$BACKUP_DIR" "备份目录" || exit 2
case "$CMD" in
    list)
        echo "📋 云端备份列表 (${SERVER%%@*}@<server>:$BACKUP_DIR)"
        run_ssh "ls -1ht $BACKUP_DIR 2>/dev/null | head -40"
        echo ""
        echo "备份类型: gateo_backend_app_bak_*/backend_app_bak_*=容器直灌型 | gateo_backend_src_bak_*/backend_src_bak_*=compose/custom 型 | gateo_frontend_*_bak_*/frontend_*_bak_*=前端（gateo_ 前缀=新命名，无前缀=历史备份，均可回滚）"
        echo "恢复方式: bash $0 frontend admin|h5 [备份文件名]  /  bash $0 backend [备份文件名]"
        ;;

    frontend)
        name=${2:?用法: rollback.sh frontend <admin|h5> [备份文件名]}
        case "$name" in
            admin) remote_dir=$REMOTE_ADMIN_DIR ;;
            h5)    remote_dir=$REMOTE_H5_DIR ;;
            *) echo "❌ 未知前端目标: ${name}（可选 admin|h5）"; exit 2 ;;
        esac
        bak=${3:-}
        if [[ -z "$bak" ]]; then
            bak=$(run_ssh "ls -1t $BACKUP_DIR/gateo_frontend_${name}_bak_*.tar.gz $BACKUP_DIR/frontend_${name}_bak_*.tar.gz 2>/dev/null | head -1")
            [[ -n "$bak" ]] || { echo "❌ 无可用备份"; exit 1; }
        fi
        bak=$(normalize_backup_path "$bak") || exit 2
        require_safe_remote_dir "$remote_dir" "前端恢复目录" || exit 2
        verify_backup "$bak" || { echo "❌ 备份完整性校验失败，拒绝回滚"; exit 1; }
        echo "⏪ 恢复 $name ← $bak"
        run_ssh "set -e; mkdir -p $remote_dir; find $remote_dir -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar xzf $bak -C $remote_dir; echo '✅ 前端已精确回滚: '$remote_dir"
        ;;

    backend)
        bak=${2:-}
        if [[ -z "$bak" ]]; then
            bak=$(run_ssh "ls -1t $BACKUP_DIR/gateo_backend_app_bak_*.tar.gz $BACKUP_DIR/backend_app_bak_*.tar.gz $BACKUP_DIR/gateo_backend_src_bak_*.tar.gz $BACKUP_DIR/backend_src_bak_*.tar.gz 2>/dev/null | head -1")
            [[ -n "$bak" ]] || { echo "❌ 无可用备份"; exit 1; }
        fi
        bak=$(normalize_backup_path "$bak") || exit 2
        BK_BASE=$(basename "$bak")
        case "$BK_BASE" in
            *backend_src_bak_*) BAK_TYPE="src" ;;
            *backend_app_bak_*) BAK_TYPE="app" ;;
            *) echo "⚠️  无法从文件名识别备份类型（${BK_BASE}），按 container-sync 型处理"; BAK_TYPE="app" ;;
        esac
        verify_backup "$bak" || { echo "❌ 备份完整性校验失败，拒绝回滚"; exit 1; }
        echo "⏪ 恢复后端 ← ${bak}（类型: ${BAK_TYPE}）"
        if [[ "$BAK_TYPE" == "src" ]]; then
            require_safe_remote_dir "$RSYNC_DEST" "源码恢复目录" || exit 2
            if [[ "$DEPLOY_MODE" == "process" ]]; then
                [[ -n "$DEPLOY_RELOAD_CMD" ]] || { echo "❌ process 模式回滚需要档案配置 DEPLOY_RELOAD_CMD"; exit 2; }
                RSYNC_PARENT=$(dirname "$RSYNC_DEST")
                echo "   步骤: 源码恢复($RSYNC_DEST) → 重载服务(DEPLOY_RELOAD_CMD) → 健康检查"
                run_ssh "set -e; find $RSYNC_DEST -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar xzf $bak -C $RSYNC_PARENT; $DEPLOY_RELOAD_CMD"
            else
                [[ -n "$PROJECT_DIR" ]] || { echo "❌ src 型备份回滚需要档案配置 PROJECT_DIR（compose 重建目录）"; exit 2; }
                RSYNC_PARENT=$(dirname "$RSYNC_DEST")
                echo "   步骤: 源码恢复($RSYNC_DEST) → compose 重建 → 健康检查"
                run_ssh "set -e; find $RSYNC_DEST -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar xzf $bak -C $RSYNC_PARENT; cd $PROJECT_DIR && $COMPOSE_CMD -f $COMPOSE_FILE up -d --build"
            fi
        else
            echo "   步骤: 构建源恢复 → 容器先清后灌 → 重启 → 健康检查"
            require_safe_remote_dir "$BUILD_SRC" "构建源目录" || exit 2
            run_ssh "set -e; find $BUILD_SRC/app -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar xzf $bak -C $BUILD_SRC; tar czf - -C $BUILD_SRC app | docker exec -i $CONTAINER sh -c 'rm -rf /app/app && cd /app && tar xzf -'; docker restart $CONTAINER"
        fi
        echo "⏳ 等待健康检查..."
        project-c 8
        if probe "$BAK_TYPE"; then
            echo "✅ 后端已回滚且健康检查通过"
        else
            echo "⚠️  回滚操作已完成，但健康检查未通过。排查:"
            if [[ "$BAK_TYPE" == "src" && "$DEPLOY_MODE" == "process" ]]; then
                echo "    （process 模式：按 DEPLOY_RELOAD_CMD 对应的服务查看日志，如 journalctl -u <服务名> -n 50）"
            elif [[ "$BAK_TYPE" == "src" ]]; then
                echo "    ssh $SERVER 'cd $PROJECT_DIR && $COMPOSE_CMD logs --tail 50'"
            else
                echo "    ssh $SERVER docker logs --tail 50 $CONTAINER"
            fi
            exit 1
        fi
        ;;

    *)
        echo "用法: rollback.sh list"
        echo "      rollback.sh frontend <admin|h5> [备份文件名]"
        echo "      rollback.sh backend [备份文件名]"
        exit 2
        ;;
esac
