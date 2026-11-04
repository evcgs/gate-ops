#!/bin/bash
# ============================================
# 🚢 gate-ops · deploy-frontend（前端静态 dist 全量发布）
# ============================================
# 用法: ./deploy-frontend.sh [admin|h5|all]
#       FORCE=1 跳过发版前置检查（仅限用户明确确认后使用，agent 不得自行使用）
#
# 流程: 构建(失败即停) → 前置检查 → 云端备份(失败即停,自动保留最近N份)
#       → tar 管道全量部署 → 远端部署结果验证
#
# 配置加载优先级: DEPLOY_CONF 文件 > PROJECT 档案(profiles/<name>.sh)
#                 > 环境变量(DEPLOY_*) > 内置默认
# 可用环境变量:
#   DEPLOY_SERVER / DEPLOY_SSH_KEY / DEPLOY_NODE_BIN / DEPLOY_PROJECT_ROOT
#   DEPLOY_BACKUP_DIR / DEPLOY_KEEP / DEPLOY_CONF / PROJECT
# ============================================

set -euo pipefail

# ---- 证据留档（DEPLOY_EVIDENCE_DIR 设置时，全程输出自动存档到证据中心）----
EVIDENCE_DIR="${DEPLOY_EVIDENCE_DIR:-}"
if [[ -n "$EVIDENCE_DIR" ]]; then
    mkdir -p "$EVIDENCE_DIR"
    exec > >(tee "$EVIDENCE_DIR/gateo-deploy-output.txt") 2>&1
    echo "📁 证据留档: ${EVIDENCE_DIR}/gateo-deploy-output.txt"
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET=${1:-all}
case "$TARGET" in
    admin|h5|all) ;;
    *) echo "❌ 未知前端目标: ${TARGET}（可选 admin|h5|all）"; exit 2 ;;
esac

# ---- 配置档案加载 ----
CONF_FILE="${DEPLOY_CONF:-}"
if [[ -z "$CONF_FILE" && -n "${PROJECT:-}" ]]; then
    for cand in "$SCRIPT_DIR/profiles/${PROJECT}.sh" "$SCRIPT_DIR/../profiles/${PROJECT}.sh"; do
        if [[ -f "$cand" ]]; then CONF_FILE="$cand"; break; fi
    done
fi

# ---- 品牌 banner（配置加载后，确保环境标注与生产警示准确）----
GATEO_VERSION=$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "dev")
[[ "${GATEO_QUIET:-}" == "1" ]] || echo "🚢 gate-ops · deploy-frontend v${GATEO_VERSION}（PROJECT=${PROJECT:-未指定} · env=${GATEO_ENV:-未标注}）"
if [[ "${GATEO_ENV:-}" == "prod" ]]; then
    echo "⚠️  生产环境（prod）发版——确认闸门 / 备份真实性校验 / 验收闸门必须完整执行"
fi
if [[ -n "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

SSH_KEY="${DEPLOY_SSH_KEY:-${SSH_KEY:-}}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o BatchMode=yes}"
SERVER="${DEPLOY_SERVER:-${SERVER:-}}"
[[ -n "$SERVER" ]] || { echo "❌ 未配置目标服务器——项目档案引用的凭据变量缺失？检查 ~/.gateo/credentials.sh 的 CRED_<项目>_SERVER"; exit 2; }
[[ -n "$SSH_KEY" ]] || { echo "❌ 未配置 SSH_KEY；为避免错误选择默认身份，拒绝发版"; exit 2; }
_server_host="${SERVER#*@}"
[[ -n "$_server_host" ]] && exec > >(sed "s|$_server_host|<server>|g") 2>&1
BACKUP_DIR="${DEPLOY_BACKUP_DIR:-${BACKUP_DIR:-}}"
BACKUP_KEEP="${DEPLOY_KEEP:-${BACKUP_KEEP:-20}}"
NODE_BIN="${DEPLOY_NODE_BIN:-${NODE_BIN:-npm}}"

# 项目根：环境变量 > 档案 > 自动探测（脚本与 admin/h5 同级，或在其上级）
if [[ -n "${DEPLOY_PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$DEPLOY_PROJECT_ROOT"
elif [[ -n "${PROJECT_ROOT:-}" ]]; then
    :
elif [[ -d "$SCRIPT_DIR/admin" ]]; then
    PROJECT_ROOT="$SCRIPT_DIR"
else
    PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi

# 前置检查脚本定位（兼容同级 / deploy/ 子目录 / 上级目录三种布局）
PRECHECK=""
for cand in "$SCRIPT_DIR/precheck-deploy.sh" "$SCRIPT_DIR/deploy/precheck-deploy.sh" "$SCRIPT_DIR/../precheck-deploy.sh"; do
    if [[ -f "$cand" ]]; then PRECHECK="$cand"; break; fi
done

# 远端目标目录（档案可覆盖）
REMOTE_ADMIN_DIR="${DEPLOY_REMOTE_ADMIN:-${REMOTE_ADMIN_DIR:-}}"
REMOTE_H5_DIR="${DEPLOY_REMOTE_H5:-${REMOTE_H5_DIR:-}}"

# ---- 用户确认硬闸门：直接调用部署脚本不得覆盖生产 ----
APPROVAL_LIB="$SCRIPT_DIR/_approval.sh"
[[ -f "$APPROVAL_LIB" ]] || { echo "❌ 缺少 _approval.sh，拒绝发版"; exit 2; }
# shellcheck disable=SC1090
source "$APPROVAL_LIB"
case "$TARGET" in
    admin) APPROVED_SOURCE_DIR="$PROJECT_ROOT/admin" ;;
    h5) APPROVED_SOURCE_DIR="$PROJECT_ROOT/h5" ;;
    all) APPROVED_SOURCE_DIR="$PROJECT_ROOT" ;;
esac
gateo_require_plan "frontend" "$TARGET" "static" "$APPROVED_SOURCE_DIR" || exit 1
TS="${GATEO_PLAN_TS}"

# ---- 发版锁（单写者原则的技术保障）----
# 缺失同样硬阻塞：守卫机制"静默不存在"是事故模式（2026-11-03 实录教训）
LOCK_LIB=""
for cand in "$SCRIPT_DIR/_lock.sh" "$SCRIPT_DIR/../scripts/_lock.sh" "$SCRIPT_DIR/deploy/_lock.sh"; do
    if [[ -f "$cand" ]]; then LOCK_LIB="$cand"; break; fi
done
if [[ -z "$LOCK_LIB" ]]; then
    echo "❌ 未找到 scripts/_lock.sh（发版锁），已查同级 / 上级 scripts/ / deploy/ 目录 → 阻塞发版"
    echo "   （守卫缺失时不允许静默跳过；确要跳过：FORCE=1 $0 ${TARGET}）"
    if [[ "${FORCE:-}" != "1" ]]; then exit 2; fi
else
    # shellcheck disable=SC1090
    source "$LOCK_LIB"
    if ! acquire_lock; then exit 1; fi
    echo "🔒 已取得发版锁: $LOCK_DIR"
fi

# 前端站点展示地址（档案可覆盖，仅用于完成提示）
SITE_ADMIN_URL="${DEPLOY_SITE_ADMIN_URL:-${SITE_ADMIN_URL:-未配置}}"
SITE_H5_URL="${DEPLOY_SITE_H5_URL:-${SITE_H5_URL:-未配置}}"

deploy_frontend() {
    local name=$1
    local src_dir=$2
    local remote_dir=$3
    local build_log="/tmp/deploy_frontend_${name}_$TS.log"

    case "$remote_dir" in
        /|"") echo "❌ 不安全的远端目录: ${remote_dir:-<空>}"; exit 2 ;;
        *[!A-Za-z0-9_./-]*) echo "❌ 远端目录含不安全字符: $remote_dir"; exit 2 ;;
    esac
    case "$BACKUP_DIR" in
        /|"") echo "❌ 不安全的备份目录: ${BACKUP_DIR:-<空>}"; exit 2 ;;
        *[!A-Za-z0-9_./-]*) echo "❌ 备份目录含不安全字符: $BACKUP_DIR"; exit 2 ;;
    esac

    echo ""
    echo "🏗️  构建 $name ..."
    cd "$src_dir"
    if ! "$NODE_BIN" run build > "$build_log" 2>&1; then
        echo "❌ $name 构建失败，已中止发版。日志尾部："
        tail -20 "$build_log"
        exit 1
    fi
    tail -5 "$build_log"
    if [[ ! -d dist || -z "$(ls -A dist 2>/dev/null)" ]]; then
        echo "❌ $name 构建产物 dist/ 不存在或为空，已中止（防旧产物误发）。"
        exit 1
    fi

    echo ""
    echo "🧪 前置检查 ${name}（云端功能标记 vs 本地构建产物）..."
    if [[ "${FORCE:-}" != "1" ]]; then
        if [[ -z "$PRECHECK" ]]; then
            echo "❌ 未找到 precheck-deploy.sh（已查同级 / deploy/ / 上级目录）→ 阻塞发版（无预检不发版）"
            echo "   （守卫缺失时不允许静默跳过；确要跳过：FORCE=1 $0 ${TARGET}）"
            exit 2
        fi
        if ! GATEO_QUIET=1 bash "$PRECHECK" frontend "$src_dir/dist" "$remote_dir/assets"; then
            echo ""
            echo "❌ 前置检查未通过（详见上方），已中止发版。"
            echo "   👉 本地源码缺云端已有功能（如 SSO），先补齐源码再发版"
            echo "   （确要跳过检查：FORCE=1 $0 ${TARGET}）"
            exit 1
        fi
    fi

    echo ""
    echo "💾 云端现状备份（可回滚，失败即中止发版）..."
    if ! ssh $SSH_OPTS -i "$SSH_KEY" "$SERVER" \
        "set -e; mkdir -p $BACKUP_DIR $remote_dir; cd $remote_dir && find . -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print \$1}' > $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.dirfp; tar czf $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz -C $remote_dir .; sha256sum $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz > $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz.sha256; ls -1t $BACKUP_DIR/*frontend_${name}_bak_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*frontend_${name}_bak_*.sha256 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; ls -1t $BACKUP_DIR/*frontend_${name}_bak_*.dirfp 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f"; then
        echo "❌ 云端备份失败，已中止发版（无备份不发版，保证可回滚）。"
        exit 1
    fi
    echo "  备份: $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz"
    ssh $SSH_OPTS -i "$SSH_KEY" "$SERVER" "cat $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz.sha256 2>/dev/null" | sed 's/^/  备份SHA256: /' || true

    # ---- 覆盖前三重校验：锁复核 + 归档全量可读/sha256 复核 + 现场指纹比对（缺一即终止）----
    if ! verify_lock; then exit 1; fi
    echo "  🧷 覆盖前校验备份（归档全量可读 + sha256 复核）..."
    if ! ssh $SSH_OPTS -i "$SSH_KEY" "$SERVER" \
        "set -e; test -s $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz && tar -tzf $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz >/dev/null && sha256sum -c $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.tar.gz.sha256 --status"; then
        echo "❌ 备份无效（缺失/为空/归档损坏/sha256 不符）→ 终止发版（无有效备份不覆盖）"
        echo "   排查：备份目录磁盘空间/挂载、上一步备份命令输出。修复后重新发版（重新生成备份）。"
        exit 1
    fi
    echo "  🧷 现场指纹比对（备份后现场是否被改动过）..."
    LIVE_FP=$(ssh $SSH_OPTS -i "$SSH_KEY" "$SERVER" "cd $remote_dir && find . -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print \$1}'") || LIVE_FP=""
    STORED_FP=$(ssh $SSH_OPTS -i "$SSH_KEY" "$SERVER" "cat $BACKUP_DIR/gateo_frontend_${name}_bak_$TS.dirfp 2>/dev/null") || STORED_FP=""
    if [[ -z "$LIVE_FP" || -z "$STORED_FP" || "$LIVE_FP" != "$STORED_FP" ]]; then
        echo "❌ 现场指纹不一致（${remote_dir} 在备份后被写入过：并发写/热修）→ 终止发版"
        echo "   本次备份可能不代表当前现场。先确认指纹变动来源，再重新走完整发版流程（重新备份）。"
        echo "   备份时指纹: ${STORED_FP:-<读取失败>} / 覆盖前指纹: ${LIVE_FP:-<读取失败>}"
        exit 1
    fi
    echo "  ✅ 备份全量校验通过（sha256 一致 + 现场指纹一致）"

    echo ""
    echo "🚀 部署 $name → ${SERVER%%@*}@<server>:$remote_dir"
    COPYFILE_DISABLE=1 tar czf - -C "$src_dir/dist" . \
        | ssh $SSH_OPTS -i "$SSH_KEY" "$SERVER" \
            "set -e; mkdir -p $remote_dir; find $remote_dir -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; cd $remote_dir; tar xzf -; find . -name '._*' -delete; test -f index.html; echo '  ✅ 已原子快照式部署（旧文件已清理）'"
    echo "  ✅ $name 部署完成"
}

if [[ "$TARGET" == "admin" || "$TARGET" == "all" ]]; then
    deploy_frontend "admin" "$PROJECT_ROOT/admin" "$REMOTE_ADMIN_DIR"
fi

if [[ "$TARGET" == "h5" || "$TARGET" == "all" ]]; then
    deploy_frontend "h5" "$PROJECT_ROOT/h5" "$REMOTE_H5_DIR"
fi

echo ""
echo "✅ 前端部署完成！"
echo "   Admin: $SITE_ADMIN_URL"
echo "   H5:    $SITE_H5_URL"

# ---- 台账行输出（消除"发完忘了写台账"的失败模式）----
NOW=$(date '+%F %R')
echo ""
echo "📝 台账行（验收闭环后填好 验收/agent/证据/备注 四列，粘贴到 records/<项目>.md，并 git 提交 + 跑 build-index.sh）："
if [[ "$TARGET" == "admin" || "$TARGET" == "all" ]]; then
    echo "| $NOW | frontend admin | 成功 | 待验收 | $BACKUP_DIR/gateo_frontend_admin_bak_$TS.tar.gz | HTTP $SITE_ADMIN_URL | <宿主agent> | ${EVIDENCE_DIR:-未留档} | <变更摘要> |"
fi
if [[ "$TARGET" == "h5" || "$TARGET" == "all" ]]; then
    echo "| $NOW | frontend h5 | 成功 | 待验收 | $BACKUP_DIR/gateo_frontend_h5_bak_$TS.tar.gz | HTTP $SITE_H5_URL | <宿主agent> | ${EVIDENCE_DIR:-未留档} | <变更摘要> |"
fi
echo "   📝 同时按 SKILL.md 三层记忆协议写入宿主会话日志与项目记忆（acceptance 闭环后才可写）"
