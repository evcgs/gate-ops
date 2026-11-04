#!/bin/bash
# ============================================
# 🚢 gate-ops · deploy-backend（后端多模式发布：container-sync / compose-build / process / custom）
# ============================================
# 用法: ./deploy-backend.sh [--no-restart]
#       FORCE=1 跳过发版前置检查（仅限用户明确确认后使用，agent 不得自行使用）
#
# 发布模式（档案字段 DEPLOY_MODE，缺省 container-sync）:
#   container-sync : rsync 构建源 → 容器先清后灌 → docker restart（销售系统型）
#   compose-build  : rsync 源码 → cd PROJECT_DIR && $COMPOSE_CMD up -d --build（内容型/服务型项目）
#   process        : rsync 源码 → 执行 DEPLOY_RELOAD_CMD 重载服务（systemd/pm2 等裸进程主机）
#   custom         : 在服务器上执行 DEPLOY_CUSTOM_CMD（万能兜底，自行处理同步与重启）
#   ※ 运行时切换模式请用 DEPLOY_CONF 指向变体档案（本字段以档案为准）
#
# 多机滚动（单项目集群）: 档案设 DEPLOY_TARGETS（空格分隔多台服务器，仅 container-sync/process）
#   → 逐台 备份→发布→重启→健康检查，任一台失败即停（fail-fast），已完成的机器保持新版本
#
# 不变量（任何模式共用）: preflight 预检 → backup 备份（失败即停）→ release → health
#                        → 失败自动回滚指引；台账/记忆由 agent 按 lifecycle 协议写。
#
# 凭据: SERVER/SSH_KEY 不设内置默认，来自项目档案（档案从 ~/.gateo/credentials.sh 读取），
#       缺失即明确报错——敏感信息永不硬编码进本仓库。
#
# 配置加载优先级: DEPLOY_CONF 文件 > PROJECT 档案(profiles/<name>.sh)
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
    PROFILE_LOADED="$CONF_FILE"
fi

# ---- 证据留档（DEPLOY_EVIDENCE_DIR 设置时，全程输出自动存档到证据中心）----
# 放在档案加载之后：脱敏需要 SERVER/DEPLOY_TARGETS——所有输出（含对话可见部分）
# 先过 sed 把 IP 替换为 <server>，敏感地址既不进证据文件也不进对话
EVIDENCE_DIR="${DEPLOY_EVIDENCE_DIR:-}"
REDACT_SED=()
for _t in ${SERVER:-} ${DEPLOY_SERVER:-} ${DEPLOY_TARGETS:-}; do
    _ip="${_t#*@}"
    [[ -n "$_ip" ]] && REDACT_SED+=( -e "s|$_ip|<server>|g" )
done
if [[ -n "$EVIDENCE_DIR" ]]; then
    mkdir -p "$EVIDENCE_DIR"
    if [[ ${#REDACT_SED[@]} -gt 0 ]]; then
        exec > >(sed "${REDACT_SED[@]}" | tee "$EVIDENCE_DIR/gateo-deploy-output.txt") 2>&1
    else
        exec > >(tee "$EVIDENCE_DIR/gateo-deploy-output.txt") 2>&1
    fi
    echo "📁 证据留档: ${EVIDENCE_DIR}/gateo-deploy-output.txt（服务器地址已脱敏为 <server>）"
elif [[ ${#REDACT_SED[@]} -gt 0 ]]; then
    exec > >(sed "${REDACT_SED[@]}") 2>&1
fi

# ---- 品牌 banner（版本号取仓库根 VERSION；环境取档案 GATEO_ENV）----
GATEO_VERSION=$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "dev")
[[ "${GATEO_QUIET:-}" == "1" ]] || echo "🚢 gate-ops · deploy-backend v${GATEO_VERSION}（PROJECT=${PROJECT:-未指定} · env=${GATEO_ENV:-未标注}）"
if [[ "${GATEO_ENV:-}" == "prod" ]]; then
    echo "⚠️  生产环境（prod）发版——确认闸门 / 备份真实性校验 / 验收闸门必须完整执行"
fi

# ---- 通用字段（凭据缺失即明确报错，不做静默默认）----
SSH_KEY="${DEPLOY_SSH_KEY:-${SSH_KEY:-}}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o BatchMode=yes}"
SERVER="${DEPLOY_SERVER:-${SERVER:-}}"
[[ -n "$SERVER" ]] || { echo "❌ 未配置目标服务器——项目档案引用的凭据变量缺失？检查 ~/.gateo/credentials.sh 的 CRED_<项目>_SERVER"; exit 2; }
[[ -n "$SSH_KEY" ]] || { echo "❌ 未配置 SSH_KEY；为避免错误选择默认身份，拒绝发版"; exit 2; }
BACKUP_DIR="${DEPLOY_BACKUP_DIR:-${BACKUP_DIR:-}}"
BACKUP_KEEP="${DEPLOY_KEEP:-${BACKUP_KEEP:-20}}"
LOCAL_APP_DIR="${DEPLOY_APP_DIR:-${LOCAL_APP_DIR:-$SCRIPT_DIR/app}}"

# ---- 模式与模式专属字段 ----
# 发布模式是项目的固有属性：凡通过档案发版的项目，必须在档案中显式声明 DEPLOY_MODE，
# 不允许静默继承缺省值（防止新项目在错误的模式下发版）。
if [[ -n "${PROFILE_LOADED:-}" && -z "${DEPLOY_MODE:-}" ]]; then
    echo "❌ 档案 ${CONF_FILE##*/} 未显式声明 DEPLOY_MODE（每个项目的默认发布方式必须登记）"
    echo "   可选值: container-sync | compose-build | process | custom"
    exit 2
fi
RUN_MODE="${DEPLOY_MODE:-container-sync}"
CONTAINER="${DEPLOY_CONTAINER:-${CONTAINER:-}}"
BUILD_SRC="${DEPLOY_BUILD_SRC:-${BUILD_SRC:-}}"
PROJECT_DIR="${PROJECT_DIR:-}"                          # compose-build/custom: 服务器项目目录
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"            # 兼容 v1: 在档案设 COMPOSE_CMD="docker-compose"
RSYNC_DEST="${RSYNC_DEST:-$PROJECT_DIR}"                # rsync 目标；必须指向"纯源码"子目录，绝不能含运行时数据
DEPLOY_CUSTOM_CMD="${DEPLOY_CUSTOM_CMD:-}"
DEPLOY_RELOAD_CMD="${DEPLOY_RELOAD_CMD:-}"              # process 模式: 服务重载命令（systemctl restart x / pm2 reload x）
DEPLOY_TARGETS="${DEPLOY_TARGETS:-}"                    # 多机滚动: 空格分隔的目标服务器列表（container-sync/process）
HEALTH_URL="${DEPLOY_HEALTH_URL:-${HEALTH_URL:-}}"
HEALTH_CMD="${HEALTH_CMD:-}"                            # 自定义探活命令（在服务器上执行），设置后优先于 HEALTH_URL
READINESS_URL="${DEPLOY_READINESS_URL:-${READINESS_URL:-}}"
READINESS_CMD="${DEPLOY_READINESS_CMD:-${READINESS_CMD:-}}"
DEPLOY_HEALTH_RETRIES="${DEPLOY_HEALTH_RETRIES:-10}"    # 首轮探活次数（默认 10 次×3s=30s）
DEPLOY_HEALTH_INTERVAL="${DEPLOY_HEALTH_INTERVAL:-3}"   # 探活间隔秒数
# 首轮失败且服务进程仍在运行时，自动进入延长观察，覆盖慢启动场景：
#   额外 12 次×5s=60s；延长后仍失败才判真故障 → 走回滚

# ---- 用户确认硬闸门 ----
APPROVAL_LIB="$SCRIPT_DIR/_approval.sh"
[[ -f "$APPROVAL_LIB" ]] || { echo "❌ 缺少 _approval.sh，拒绝发版"; exit 2; }
# shellcheck disable=SC1090
source "$APPROVAL_LIB"
gateo_require_plan "backend" "backend" "$RUN_MODE" "$LOCAL_APP_DIR" || exit 1
TS="${GATEO_PLAN_TS}"

require_safe_remote_dir() {
    local p="$1" label="$2"
    case "$p" in
        /|"") echo "❌ ${label} 不能为空或 /"; return 1 ;;
        *[!A-Za-z0-9_./-]*) echo "❌ ${label} 含不安全字符: $p"; return 1 ;;
    esac
    [[ "$p" == /* ]] || { echo "❌ ${label} 必须是绝对路径: $p"; return 1; }
}
require_safe_remote_dir "$BACKUP_DIR" "BACKUP_DIR" || exit 2
case "$RUN_MODE" in
    container-sync) require_safe_remote_dir "$BUILD_SRC" "BUILD_SRC" || exit 2 ;;
    compose-build|process) require_safe_remote_dir "$RSYNC_DEST" "RSYNC_DEST" || exit 2 ;;
    custom) require_safe_remote_dir "$PROJECT_DIR" "PROJECT_DIR" || exit 2 ;;
esac

# 前置检查脚本定位（兼容同级 / deploy/ 子目录 / 上级目录三种布局）
PRECHECK=""
for cand in "$SCRIPT_DIR/precheck-deploy.sh" "$SCRIPT_DIR/../precheck-deploy.sh" "$SCRIPT_DIR/deploy/precheck-deploy.sh"; do
    if [[ -f "$cand" ]]; then PRECHECK="$cand"; break; fi
done

NO_RESTART=false
if [[ "${1:-}" == "--no-restart" ]]; then
    if [[ "${GATEO_ALLOW_NO_RESTART:-}" != "1" || "${GATEO_ENV:-prod}" == "prod" ]]; then
        echo "❌ --no-restart 会跳过重启与健康检查；生产环境禁止，非生产需同时设置 GATEO_ALLOW_NO_RESTART=1"
        exit 2
    fi
    NO_RESTART=true
fi

# ---- 发版锁（单写者原则的技术保障）----
# 缺失同样硬阻塞：守卫机制"静默不存在"是事故模式（2026-11-03 实录教训）
LOCK_LIB=""
for cand in "$SCRIPT_DIR/_lock.sh" "$SCRIPT_DIR/../scripts/_lock.sh" "$SCRIPT_DIR/deploy/_lock.sh"; do
    if [[ -f "$cand" ]]; then LOCK_LIB="$cand"; break; fi
done
if [[ -z "$LOCK_LIB" ]]; then
    echo "❌ 未找到 scripts/_lock.sh（发版锁），已查同级 / 上级 scripts/ / deploy/ 目录 → 阻塞发版"
    echo "   （守卫缺失时不允许静默跳过；确要跳过：FORCE=1 $0）"
    if [[ "${FORCE:-}" != "1" ]]; then exit 2; fi
else
    # shellcheck disable=SC1090
    source "$LOCK_LIB"
    if ! acquire_lock; then exit 1; fi
    echo "🔒 已取得发版锁: $LOCK_DIR"
fi

# ---- 模式校验 ----
case "$RUN_MODE" in
    container-sync|compose-build|process|custom) ;;
    *) echo "❌ 未知 DEPLOY_MODE: ${RUN_MODE}（可选 container-sync | compose-build | process | custom）"; exit 2 ;;
esac
if [[ "$RUN_MODE" != "container-sync" ]]; then
    if [[ "$RUN_MODE" == "compose-build" || "$RUN_MODE" == "custom" ]]; then
        if [[ -z "$PROJECT_DIR" || "$PROJECT_DIR" == "/" ]]; then
            echo "❌ ${RUN_MODE} 模式要求档案配置 PROJECT_DIR（服务器项目目录，不能为空或 /）"
            exit 2
        fi
    fi
    if [[ "$RUN_MODE" == "compose-build" ]] && { [[ "$RSYNC_DEST" == "/" ]] || { [[ "$RSYNC_DEST" != "$PROJECT_DIR" ]] && [[ "$RSYNC_DEST" != "$PROJECT_DIR/"* ]]; }; }; then
        echo "❌ compose-build 模式的 RSYNC_DEST 必须位于 PROJECT_DIR 之下（当前: ${RSYNC_DEST}）"
        echo "   且必须指向'纯源码'子目录——绝不能指向含运行时数据（SQLite/上传文件）的目录，否则 --delete 会删数据！"
        exit 2
    fi
    if [[ "$RUN_MODE" == "custom" && -z "$DEPLOY_CUSTOM_CMD" ]]; then
        echo "❌ custom 模式要求档案配置 DEPLOY_CUSTOM_CMD（服务器上执行的发布命令）"
        exit 2
    fi
    if [[ "$RUN_MODE" == "process" ]]; then
        if [[ -z "$RSYNC_DEST" || "$RSYNC_DEST" == "/" ]]; then
            echo "❌ process 模式要求档案配置 RSYNC_DEST（源码部署目录，不能为空或 /）"
            exit 2
        fi
        if [[ -z "$DEPLOY_RELOAD_CMD" ]]; then
            echo "❌ process 模式要求档案配置 DEPLOY_RELOAD_CMD（服务重载命令，如 'systemctl restart myapp' 或 'pm2 reload app'）"
            exit 2
        fi
    fi
fi
if [[ "$RUN_MODE" == "container-sync" ]]; then
    [[ -n "$CONTAINER" ]] || { echo "❌ container-sync 模式要求档案配置 CONTAINER（容器名）"; exit 2; }
    [[ -n "$BUILD_SRC" ]] || { echo "❌ container-sync 模式要求档案配置 BUILD_SRC（服务器构建源目录）"; exit 2; }
fi
[[ -n "$BACKUP_DIR" ]] || { echo "❌ 档案未配置 BACKUP_DIR（云端备份目录）"; exit 2; }
if [[ -z "$HEALTH_URL" && -z "$HEALTH_CMD" && -z "$READINESS_URL" && -z "$READINESS_CMD" ]]; then
    echo "❌ ${RUN_MODE} 模式要求配置 READINESS_URL/CMD 或 HEALTH_URL/CMD"
    exit 2
fi

# ---- 目标列表：单机 = SERVER；多机 = DEPLOY_TARGETS（逐台滚动，fail-fast）----
if [[ -n "$DEPLOY_TARGETS" ]]; then
    if [[ "$RUN_MODE" != "container-sync" && "$RUN_MODE" != "process" ]]; then
        echo "❌ DEPLOY_TARGETS 多机滚动目前仅支持 container-sync / process 模式（当前: ${RUN_MODE}）"
        exit 2
    fi
    TARGET_LIST="$DEPLOY_TARGETS"
    echo "🌐 多机滚动: $(echo $TARGET_LIST | wc -w | tr -d ' ') 台目标（逐台 备份→发布→重启→健康检查，任一台失败即停）"
else
    TARGET_LIST="$SERVER"
fi

echo "🔍 验证本地源: ${LOCAL_APP_DIR}（模式: ${RUN_MODE}）"
if [ ! -d "$LOCAL_APP_DIR" ]; then
    echo "❌ 错误: $LOCAL_APP_DIR 不存在"
    exit 1
fi

PY_COUNT=$(find "$LOCAL_APP_DIR" -name "*.py" ! -path "*__pycache__*" | wc -l | tr -d ' ')
echo "📦 本地 .py 文件数: $PY_COUNT"

# ===== 第0步: 发版前置检查（防旧码覆盖云端新码）=====
if [[ "${FORCE:-}" != "1" ]]; then
    if [[ -z "$PRECHECK" ]]; then
        echo ""
        echo "❌ 未找到 precheck-deploy.sh（已查同级 / 上级 / deploy/ 目录）→ 阻塞发版（无预检不发版）"
        echo "   （守卫缺失时不允许静默跳过；确要跳过：FORCE=1 $0）"
        exit 2
    fi
    echo ""
    echo "🧪 第0步: 发版前置检查（云端 vs 本地差异）"
    if ! GATEO_QUIET=1 bash "$PRECHECK" backend "$LOCAL_APP_DIR"; then
        echo ""
        echo "❌ 前置检查未通过：云端存在本地没有的改动，发版会覆盖云端新代码！"
        echo "   👉 先按上方提示同步 云端→本地，确认差异归属后再发版"
        echo "   （确要跳过检查：FORCE=1 $0）"
        exit 1
    fi
fi

# ---- 探活（按目标主机参数化）----
# ⚠️ probe 必须以 $1 接收目标主机——不能用 make_probe 的 local 变量做闭包：
#    bash 动态作用域下 make_probe 返回后 local 失效，set -u 时 probe 内引用会 unbound
#    （mock 实测抓出：健康检查 10 次全挂的假象）
make_probe() {
    if [[ -n "$READINESS_CMD" ]]; then
        PROBE_KIND="readiness"
        probe() { local tsv="$1"; ssh $SSH_OPTS -i "$SSH_KEY" "$tsv" "$READINESS_CMD"; }
    elif [[ -n "$READINESS_URL" ]]; then
        PROBE_KIND="readiness"
        probe() { local tsv="$1"; ssh $SSH_OPTS -i "$SSH_KEY" "$tsv" "curl --fail --silent --show-error -m 5 $READINESS_URL"; }
    elif [[ -n "$HEALTH_CMD" ]]; then
        PROBE_KIND="health"
        probe() { local tsv="$1"; ssh $SSH_OPTS -i "$SSH_KEY" "$tsv" "$HEALTH_CMD"; }
    elif [[ "$RUN_MODE" == "container-sync" ]]; then
        PROBE_KIND="readiness"
        probe() { local tsv="$1"; ssh $SSH_OPTS -i "$SSH_KEY" "$tsv" \
            "docker exec $CONTAINER python3 -c \"import urllib.request; print(urllib.request.urlopen('$HEALTH_URL',timeout=5).read().decode())\""; }
    else
        PROBE_KIND="health"
        probe() { local tsv="$1"; ssh $SSH_OPTS -i "$SSH_KEY" "$tsv" "curl --fail --silent --show-error -m 5 $HEALTH_URL"; }
    fi
}

# ==================================================================
# 单目标发版流水线：备份 → 覆盖前校验 → 发布 → 重启 → 健康检查
# 单机 = 调用一次；多机 = DEPLOY_TARGETS 循环调用（fail-fast）
# ==================================================================
deploy_one_target() {
    local TSV="$1"
    echo ""
    echo "════════ 目标服务器: ${TSV%%@*}@<server> ════════"

    BK_PARENT=$(dirname "$RSYNC_DEST")
    BK_BASE=$(basename "$RSYNC_DEST")

    # ---- 第0.5步: 云端备份（无备份不发版；每份备份带 sha256/dirfp 真实性凭据）----
    echo "💾 第0.5步: 云端现状备份（模式: ${RUN_MODE}）..."
    local REMOTE_BACKUP
    if [[ "$RUN_MODE" == "container-sync" ]]; then
        REMOTE_BACKUP="set -e; mkdir -p $BACKUP_DIR; cd $BUILD_SRC && find app -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print \$1}' > $BACKUP_DIR/gateo_backend_app_bak_$TS.dirfp; tar czf $BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz -C $BUILD_SRC app; sha256sum $BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz > $BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz.sha256; docker exec $CONTAINER tar czf - -C /app app > $BACKUP_DIR/gateo_backend_container_bak_$TS.tar.gz; sha256sum $BACKUP_DIR/gateo_backend_container_bak_$TS.tar.gz > $BACKUP_DIR/gateo_backend_container_bak_$TS.tar.gz.sha256; ls -1t $BACKUP_DIR/*backend_app_bak_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_app_bak_*.sha256 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_app_bak_*.dirfp 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_container_bak_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_container_bak_*.sha256 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f"
    elif [[ "$RUN_MODE" == "compose-build" ]]; then
        REMOTE_BACKUP="set -e; mkdir -p $BACKUP_DIR; cd $BK_PARENT && find $BK_BASE -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print \$1}' > $BACKUP_DIR/gateo_backend_src_bak_$TS.dirfp; tar czf $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz -C $BK_PARENT $BK_BASE; sha256sum $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz > $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz.sha256; cd $PROJECT_DIR && ($COMPOSE_CMD images -q > $BACKUP_DIR/gateo_backend_images_$TS.txt 2>/dev/null || true); ls -1t $BACKUP_DIR/*backend_src_bak_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_src_bak_*.sha256 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_src_bak_*.dirfp 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_images_*.txt 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f"
    else
        REMOTE_BACKUP="set -e; mkdir -p $BACKUP_DIR; cd $BK_PARENT && find $BK_BASE -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print \$1}' > $BACKUP_DIR/gateo_backend_src_bak_$TS.dirfp; tar czf $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz -C $BK_PARENT $BK_BASE; sha256sum $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz > $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz.sha256; ls -1t $BACKUP_DIR/*backend_src_bak_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_src_bak_*.sha256 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*backend_src_bak_*.dirfp 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f"
    fi
    if ! ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "$REMOTE_BACKUP"; then
        echo "❌ [$TSV] 云端备份失败，已中止发版（无备份不发版，保证可回滚）。"
        exit 1
    fi
    if [[ "$RUN_MODE" == "container-sync" ]]; then
        echo "  备份: $BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz（构建源）"
        echo "        $BACKUP_DIR/gateo_backend_container_bak_$TS.tar.gz（容器）"
    else
        echo "  备份: $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz（源码目录 ${RSYNC_DEST}）"
        [[ "$RUN_MODE" == "compose-build" ]] && echo "        $BACKUP_DIR/gateo_backend_images_$TS.txt（当前镜像 ID 列表）"
    fi
    ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "cat $BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz.sha256 $BACKUP_DIR/gateo_backend_container_bak_$TS.tar.gz.sha256 $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz.sha256 2>/dev/null" | sed "s/^/  备份SHA256[$TSV]: /" || true

    # ---- 第0.6步: 覆盖前校验（锁复核 + 备份真实性）——缺一即终止 ----
    echo ""
    if ! verify_lock; then exit 1; fi
    echo "🧷 覆盖前校验备份（归档全量可读 + sha256 复核）..."
    local BAK_FILES BAK_CHECK_CMD bf
    case "$RUN_MODE" in
        container-sync) BAK_FILES="$BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz $BACKUP_DIR/gateo_backend_container_bak_$TS.tar.gz" ;;
        *)              BAK_FILES="$BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz" ;;
    esac
    BAK_CHECK_CMD="set -e"
    for bf in $BAK_FILES; do
        BAK_CHECK_CMD="${BAK_CHECK_CMD}; test -s $bf && tar -tzf $bf >/dev/null && sha256sum -c $bf.sha256 --status"
    done
    if ! ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "$BAK_CHECK_CMD"; then
        echo "❌ [$TSV] 备份无效（缺失/为空/归档损坏/sha256 不符）→ 终止发版（无有效备份不覆盖）"
        exit 1
    fi
    echo "  ✅ 备份全量校验通过"

    echo "🧷 现场指纹比对（备份后现场是否被改动过）..."
    local FP_FAIL="0" LIVE_FP STORED_FP
    if [[ "$RUN_MODE" == "container-sync" ]]; then
        LIVE_FP=$(ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "cd $BUILD_SRC && find app -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print \$1}'") || FP_FAIL="1"
        STORED_FP=$(ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "cat $BACKUP_DIR/gateo_backend_app_bak_$TS.dirfp 2>/dev/null") || FP_FAIL="1"
    else
        LIVE_FP=$(ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "cd $BK_PARENT && find $BK_BASE -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print \$1}'") || FP_FAIL="1"
        STORED_FP=$(ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "cat $BACKUP_DIR/gateo_backend_src_bak_$TS.dirfp 2>/dev/null") || FP_FAIL="1"
    fi
    if [[ "$FP_FAIL" == "1" || -z "$LIVE_FP" || -z "$STORED_FP" || "$LIVE_FP" != "$STORED_FP" ]]; then
        echo "❌ [$TSV] 现场指纹不一致（备份后现场被写入过：并发写/热修）→ 终止发版"
        echo "   备份时指纹: ${STORED_FP:-<读取失败>} / 覆盖前指纹: ${LIVE_FP:-<读取失败>}"
        exit 1
    fi
    echo "  ✅ 指纹一致：备份快照 = 当前将被覆盖的现场"

    # ---- 第1步: 发布（按模式分支）----
    echo ""
    case "$RUN_MODE" in
        container-sync)
            echo "🚀 第1步: rsync 全量同步到服务器构建源 ($BUILD_SRC)（含删除，幂等）"
            rsync -rc --delete --exclude='__pycache__' --exclude='*.pyc' --exclude='._*' \
                -e "ssh -i $SSH_KEY $SSH_OPTS" \
                "$LOCAL_APP_DIR/" "$TSV:$BUILD_SRC/app/"
            echo "  ✅ 构建源已更新（与本地完全一致）"

            echo ""
            echo "🚀 第2步: 全量同步进容器 ($CONTAINER)（先清后灌）"
            ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" \
                "cd $BUILD_SRC && tar czf - app/ | docker exec -i $CONTAINER sh -c 'rm -rf /app/app && cd /app && tar xzf -' && echo '  ✅ 容器代码已更新'"

            echo ""
            echo "🧹 第3步: 清理容器内 __pycache__"
            ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" \
                "docker exec $CONTAINER sh -c 'find /app -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null; true'"
            ;;

        compose-build)
            echo "🚀 第1步: rsync 全量同步源码到 ${TSV%%@*}@<server>:${RSYNC_DEST}（含删除，幂等）"
            rsync -rc --delete \
                --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
                --exclude='*.pyc' --exclude='._*' --exclude='.env' \
                --exclude='*.bak*' \
                --exclude='data/' --exclude='.runtime/' --exclude='.venv-verify/' --exclude='.pytest-tmp/' --exclude='.pytest_cache/' --exclude='.specify/' --exclude='web/' --exclude='.local/' --exclude='backups/' --exclude='recovery/' --exclude='DEPLOYMENT-CREDENTIALS.txt' --exclude='.local-settings' --exclude='.env.public' \
                -e "ssh -i $SSH_KEY $SSH_OPTS" \
                "$LOCAL_APP_DIR/" "$TSV:$RSYNC_DEST/"
            echo "  ✅ 源码已更新（与本地完全一致；.env 与运行时数据目录 data/ 未被触碰）"

            echo ""
            echo "🚀 第2步: compose 构建并滚动更新（${PROJECT_DIR}）"
            ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" \
                "cd $PROJECT_DIR && $COMPOSE_CMD -f $COMPOSE_FILE up -d --build && echo '  ✅ compose 构建并启动完成'"
            ;;

        process)
            echo "🚀 第1步: rsync 全量同步源码到 ${TSV%%@*}@<server>:${RSYNC_DEST}（含删除，幂等）"
            rsync -rc --delete \
                --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
                --exclude='*.pyc' --exclude='._*' --exclude='.env' \
                --exclude='*.bak*' \
                --exclude='data/' --exclude='.runtime/' --exclude='.venv-verify/' --exclude='.pytest-tmp/' --exclude='.pytest_cache/' --exclude='.specify/' --exclude='web/' --exclude='.local/' --exclude='backups/' --exclude='recovery/' --exclude='DEPLOYMENT-CREDENTIALS.txt' --exclude='.local-settings' --exclude='.env.public' \
                -e "ssh -i $SSH_KEY $SSH_OPTS" \
                "$LOCAL_APP_DIR/" "$TSV:$RSYNC_DEST/"
            echo "  ✅ 源码已更新（与本地完全一致；.env 与运行时数据目录 data/ 未被触碰）"

            echo ""
            echo "🚀 第2步: 重载服务进程"
            ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "$DEPLOY_RELOAD_CMD && echo '  ✅ 服务已重载'"
            ;;

        custom)
            echo "🚀 第1步: 执行自定义发布命令"
            echo "   命令: ${DEPLOY_CUSTOM_CMD}"
            ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "$DEPLOY_CUSTOM_CMD && echo '  ✅ 自定义发布命令执行完成'"
            ;;
    esac

    # ---- 第2步: 重启 + 健康检查（探活方式随模式适配；失败=发版失败）----
    # ⚠️ container-sync 模式必须显式 docker restart——代码已同步进容器但旧进程仍在内存里，
    #    不重启则"发版成功"是假象（v3 曾因此回归，验收 405 抓出）。
    if [ "$NO_RESTART" = true ]; then
        echo ""
        echo "⭭  跳过重启与健康检查 (--no-restart)。"
        return 0
    fi
    if [[ "$RUN_MODE" == "container-sync" ]]; then
        echo ""
        echo "🚀 第2.5步: 重启容器 ($CONTAINER)"
        ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "docker restart $CONTAINER" > /dev/null
        echo "  ✅ 容器已重启（新代码载入）"
    fi

    echo ""
    make_probe "$TSV"
    echo "⏳ ${PROBE_KIND} 检查（首轮最多 $((DEPLOY_HEALTH_RETRIES * DEPLOY_HEALTH_INTERVAL))s，每 ${DEPLOY_HEALTH_INTERVAL}s 一次）..."

    local HEALTH="FAILED" i
    for i in $(seq 1 "$DEPLOY_HEALTH_RETRIES"); do
        project-c "$DEPLOY_HEALTH_INTERVAL"
        if HEALTH=$(probe "$TSV" 2>/dev/null); then
            echo "  ✅ 第 $i 次探活成功: $HEALTH"
            break
        fi
        echo "  ⏳ 第 $i 次探活失败，重试..."
        HEALTH="FAILED"
    done
    LAST_HEALTH="$HEALTH"   # 供台账行读取（local 变量出函数即失效）

    # ---- 失败甄别：区分慢启动与进程退出 ----
    # 首轮失败 ≠ 一定是发版坏了：容器重建后的启动预热（会话恢复/缓存加载）可能超过首轮窗口。
    # 判据：服务进程仍在运行 = 疑似预热 → 自动延长观察，不立即判死；进程已退出 = 真故障 → 直接判失败。
    if [[ "$HEALTH" == "FAILED" && "$RUN_MODE" == "compose-build" || "$HEALTH" == "FAILED" && "$RUN_MODE" == "container-sync" ]]; then
        local SVC_RUNNING="" j
        echo ""
        echo "🧭 失败甄别: 首轮探活未通过，检查服务进程是否仍在运行..."
        if [[ "$RUN_MODE" == "compose-build" ]]; then
            # compose ps 的 STATUS 列含 Up/running 即有存活服务；grep -c 无匹配退出 1，|| true 兜底
            SVC_RUNNING=$(ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "cd $PROJECT_DIR && $COMPOSE_CMD ps 2>/dev/null | grep -cE 'Up|running'") || SVC_RUNNING="0"
        else
            SVC_RUNNING=$(ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null") || SVC_RUNNING="false"
        fi
        # ⚠️ 判活比较必须先做数值守卫——非数值字符串（如 ps 原始行）做 -gt 会在 set -e 下
        #    静默致命退出（连 if 条件都不豁免，stderr 还被吞掉）
        if [[ "$SVC_RUNNING" == "true" || "$SVC_RUNNING" =~ ^[0-9]+$ && "$SVC_RUNNING" -gt 0 ]]; then
            echo "   服务进程仍在运行 → 疑似启动预热（初始化慢），自动延长观察 60s（12 次×5s）..."
            for j in $(seq 1 12); do
                project-c 5
                if HEALTH=$(probe "$TSV" 2>/dev/null); then
                    echo "  ✅ 延长观察第 $j 次探活成功: $HEALTH"
                    echo "  ℹ️  本次发版实际成功——首轮失败属启动预热误判，台账备注请记录：预热延长观察通过"
                    break
                fi
                echo "  ⏳ 延长观察第 $j 次探活失败..."
                HEALTH="FAILED"
            done
            LAST_HEALTH="$HEALTH"
        else
            echo "   服务进程已退出/不存在 → 真故障，直接判定发版失败"
        fi
    fi

    if [[ "$HEALTH" == "FAILED" ]]; then
        echo ""
        echo "❌ [$TSV] 健康检查失败（首轮 ${DEPLOY_HEALTH_RETRIES}×${DEPLOY_HEALTH_INTERVAL}s + 延长观察 60s 仍未就绪，或服务进程已退出）→ 本次发版判定为【失败】"
        echo "── 服务最近 50 行日志 ──"
        if [[ "$RUN_MODE" == "compose-build" ]]; then
            ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "cd $PROJECT_DIR && $COMPOSE_CMD -f $COMPOSE_FILE logs --tail 50" || true
        elif [[ "$RUN_MODE" == "container-sync" ]]; then
            ssh $SSH_OPTS -i "$SSH_KEY" "$TSV" "docker logs --tail 50 $CONTAINER" || true
        elif [[ "$RUN_MODE" == "process" ]]; then
            echo "   （process 模式：请按档案 DEPLOY_RELOAD_CMD 对应的服务查看日志，如 journalctl -u <服务名> -n 50）"
        fi
        echo "────────────────────────"
        echo ""
        echo "👉 立即回滚该台: DEPLOY_SERVER=\"$TSV\" PROJECT=\${PROJECT:-} bash $SCRIPT_DIR/rollback.sh backend"
        echo "   （或 bash $SCRIPT_DIR/rollback.sh backend 列出并选用最近备份）"
        exit 1
    fi
}

for TSV in $TARGET_LIST; do
    deploy_one_target "$TSV"
done

echo ""
echo "✅ 部署完成！（模式: ${RUN_MODE} · 目标: ${TARGET_LIST}）"
echo "   本地源: $LOCAL_APP_DIR"
if [[ "$RUN_MODE" == "container-sync" ]]; then
    echo "   构建源: ${TARGET_LIST}:$BUILD_SRC/app"
    echo "   容器:   $CONTAINER:/app/app"
    echo "   回滚点: $BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz（各目标服务器同名）"
else
    echo "   目标:   ${TARGET_LIST}:$RSYNC_DEST"
    echo "   回滚点: $BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz（各目标服务器同名）"
fi

# ---- 台账行输出（消除"发完忘了写台账"的失败模式）----
NOW=$(date '+%F %R')
if [[ "$RUN_MODE" == "container-sync" ]]; then
    BAKS="$BACKUP_DIR/gateo_backend_app_bak_$TS.tar.gz + gateo_backend_container_bak_$TS.tar.gz"
else
    BAKS="$BACKUP_DIR/gateo_backend_src_bak_$TS.tar.gz"
fi
HL="${LAST_HEALTH:-跳过(--no-restart)}"
echo ""
echo "📝 台账行（验收闭环后填好 验收/agent/证据/备注 四列，粘贴到 records/<项目>.md，并 git 提交 + 跑 build-index.sh）："
echo "| $NOW | backend（${RUN_MODE} · ${GATEO_ENV:-未标注}） | 成功 | 待验收 | $BAKS | $HL | <宿主agent> | ${EVIDENCE_DIR:-未留档} | <变更摘要> |"
echo "   📝 同时按 SKILL.md 三层记忆协议写入宿主会话日志与项目记忆（acceptance 闭环后才可写）"
