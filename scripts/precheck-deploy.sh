#!/bin/bash
# ============================================
# 🚢 gate-ops · precheck-deploy（发版前置检查）
# ============================================
#
# 目的：规避用陈旧本地源码覆盖云端新版本的事故。
#
# 检查内容：
#   backend  : rsync 校验和干跑对比 云端 vs 本地，
#              列出"云端有但本地没有/不同"的文件（发版会被本地覆盖）。
#   frontend : 功能标记检查——云端 dist 中存在的关键功能字符串
#              （清单见 feature-markers.txt），本地构建产物
#              必须同样包含，否则阻塞。
#
# 安全语义（v2）：
#   - 检查工具自身失败（SSH 断连、rsync 出错）= 检查不通过，阻塞发版。
#     绝不允许"查不了"被当成"查过了没差异"。
#
# 用法:
#   precheck-deploy.sh backend [本地app目录]
#     可带 DEPLOY_EXPECT_DIFFS="f1,f2"（期望差异清单，相对 app 根）：
#     差异 ⊆ 清单 → 通过（例行发版用这个，无需 FORCE）；出现清单外差异 → 阻塞
#   precheck-deploy.sh frontend <本地dist目录> <云端assets目录>
#
# 返回: 0=通过  1=有阻塞差异或检查本身失败  2=参数错误
# 跳过: FORCE=1 环境变量（仅限用户明确确认后使用，agent 不得自行使用）
#
# 配置加载优先级: DEPLOY_CONF 文件 > PROJECT 档案(profiles/<name>.sh)
#                 > 环境变量(DEPLOY_*) > 内置默认
# ============================================

set -uo pipefail

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

# ---- 品牌 banner（被 deploy 脚本调用时经 GATEO_QUIET=1 静音）----
GATEO_VERSION=$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "dev")
[[ "${GATEO_QUIET:-}" == "1" ]] || echo "🚢 gate-ops · precheck-deploy v${GATEO_VERSION}（PROJECT=${PROJECT:-未指定} · env=${GATEO_ENV:-未标注}）"
if [[ "${GATEO_ENV:-}" == "prod" ]]; then
    echo "⚠️  生产环境（prod）发版——确认闸门 / 备份真实性校验 / 验收闸门必须完整执行"
fi

SSH_KEY="${DEPLOY_SSH_KEY:-${SSH_KEY:-}}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o BatchMode=yes}"
SERVER="${DEPLOY_SERVER:-${SERVER:-}}"
[[ -n "$SERVER" ]] || { echo "❌ 未配置目标服务器——项目档案引用的凭据变量缺失？检查 ~/.gateo/credentials.sh 的 CRED_<项目>_SERVER"; exit 2; }
[[ -n "$SSH_KEY" ]] || { echo "❌ 未配置 SSH_KEY，拒绝执行无法确定身份的预检"; exit 2; }
REDACT_SED=()
for _t in "$SERVER" ${DEPLOY_TARGETS:-}; do
    _host="${_t#*@}"
    [[ -n "$_host" ]] && REDACT_SED+=( -e "s|$_host|<server>|g" )
done
[[ ${#REDACT_SED[@]} -eq 0 ]] || exec > >(sed "${REDACT_SED[@]}") 2>&1
CLOUD_APP="${DEPLOY_CLOUD_APP:-${CLOUD_APP:-}}"
MARKERS_FILE="${DEPLOY_MARKERS_FILE:-${MARKERS_FILE:-$SCRIPT_DIR/feature-markers.txt}}"

TARGET=${1:-}

if [[ "${FORCE:-}" == "1" ]]; then
    echo "⚠️  FORCE=1，跳过发版前置检查（风险自担）"
    exit 0
fi

# ---------- 后端：云端 vs 本地 校验和干跑（$2=目标服务器，支持多机逐台预检）----------
check_backend() {
    local local_app="$1" tsv="${2:-$SERVER}"
    local tsv_show="${tsv}"
    [[ "$tsv_show" == *@* ]] && tsv_show="${tsv_show%%@*}@<server>"   # 输出脱敏：IP 不进对话
    echo "── [后端] rsync 校验和干跑：${tsv_show} vs 本地"
    local diffs rc
    local errfile
    errfile=$(mktemp)
    diffs=$(rsync -rcn --out-format='%n' \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='._*' \
        --exclude='.git' --exclude='node_modules' \
        --exclude='*.bak*' \
        --exclude='.env' --exclude='.env.public' \
        --exclude='data/' --exclude='.runtime/' --exclude='.venv-verify/' --exclude='.pytest-tmp/' --exclude='.pytest_cache/' --exclude='.specify/' --exclude='web/' --exclude='.local/' --exclude='backups/' --exclude='recovery/' --exclude='DEPLOYMENT-CREDENTIALS.txt' --exclude='.local-settings' \
        -e "ssh -i $SSH_KEY $SSH_OPTS" \
        "$tsv:$CLOUD_APP/" "$local_app/" 2>"$errfile")
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "❌ [后端] 前置检查本身失败（rsync 退出码 ${rc}，无法确认云端状态）→ 阻塞发版"
        sed 's/^/    /' "$errfile" | head -10
        rm -f "$errfile"
        echo "    👉 先排查网络/SSH；确要跳过检查：FORCE=1"
        return 1
    fi
    rm -f "$errfile"
    if [[ -n "$diffs" ]]; then
        # ---- 期望差异模式（例行发版常态，2026-11-03 两次发版实录驱动）----
        # 例行发版的差异 = 本次待发文件本身，旧逻辑一律阻塞 → 每次正常发版都要 FORCE=1，
        # 把最危险的 bypass 变成日常操作。现改为声明式：
        #   DEPLOY_EXPECT_DIFFS="blueprints/h5/routes.py,x.py"（逗号分隔，相对 app 根）
        #   差异 ⊆ 期望清单 → 放行（预检仍保证"没有清单外的意外覆盖"）
        #   出现清单外差异 → 仍阻塞（可能是云端领先/本地未知改动）
        # FORCE=1 只留给用户明确授权跳过全部检查的异常场景。
        EXPECT="${DEPLOY_EXPECT_DIFFS:-${EXPECT_DIFFS:-}}"
        if [[ -n "$EXPECT" ]]; then
            # 注意：必须先声明为空数组再 read——bash 3.2 + set -u 下，
            # 未赋值数组的 ${#arr[@]} 也会报 unbound（2026-11-03 测试发现）
            local -a exp_items=()
            IFS=',' read -r -a exp_items <<< "$EXPECT" || true
            if [[ ${#exp_items[@]} -eq 0 ]]; then
                echo "❌ [后端] 期望差异清单为空但存在差异 → 阻塞（确认闸门未声明任何待发文件）"
                return 1
            fi
            local unexpected="" f e found
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                [[ "$f" == */ ]] && continue   # 目录条目自身无覆盖风险，由其下文件条目表达
                found=0
                for e in "${exp_items[@]}"; do
                    e="${e# }"; e="${e% }"   # 清单项首尾空格容错（agent 手写清单常见）
                    if [[ "$e" == "$f" ]]; then found=1; break; fi
                done
                if [[ $found -eq 0 ]]; then
                    unexpected="${unexpected}    • ${f}"$'\n'
                fi
            done <<< "$diffs"
            if [[ -z "$unexpected" ]]; then
                echo "✅ 后端：差异全部落在期望发版清单内（清单 ${#exp_items[@]} 项），无清单外覆盖"
                return 0
            fi
            echo "❌ [后端] 发现期望发版清单之外的差异 → 阻塞发版："
            echo "$unexpected"
            echo "    👉 清单外差异可能是云端领先（热修/他人部署）或本地未知改动，按方向口诀确认归属："
            echo "       归属为本次待发 → 把它加进 DEPLOY_EXPECT_DIFFS；归属为云端领先 → 先同步 云端→本地"
            return 1
        fi
        echo "⚠️  以下文件云端与本地不一致（先判断差异方向，再决定动作）："
        echo "$diffs" | sed 's/^/    • /'
        echo ""
        echo "    方向口诀：本地多 = 待发版（正常）；云端多 = 先同步 云端→本地（事故信号）"
        echo "    ⚠️ 单写者检查：这些差异是否来自另一个并行会话的工作？先与该会话/用户确认归属，再决定发版或同步"
        echo "    💡 例行发版（差异=本次待发内容）：确认闸门里声明 DEPLOY_EXPECT_DIFFS=\"文件1,文件2\" 即可通过，无需 FORCE=1"
        echo "    ① 本地领先：这些差异是你已知、尚未发版的本地工作 → 正常，确认归属后即可发版覆盖云端"
        echo "    ② 云端领先：云端存在你不知道的改动（热修/他人部署）→ 事故信号，先同步 云端→本地："
        echo "    rsync -avzc --exclude=__pycache__ --exclude='._*' -e \"ssh -i <SSH_KEY> $SSH_OPTS\" <目标主机>:$CLOUD_APP/ $local_app/"
        echo "    👉 判断依据：本地这份差异是否是你已知未发版的工作？（git diff / 会话记录 / 改动时间；"
        echo "       注意 tar 发版会把本地 mtime 带上云端，云端 mtime 不能证明有人在服务器上改过文件）"
        return 1
    fi
    echo "✅ 后端：云端与本地完全一致"
    return 0
}

# ---------- 前端：功能标记检查 ----------
check_front_dir() {
    local name="$1" local_dist="$2" remote_assets="$3"

    if [[ ! -d "$local_dist" ]]; then
        echo "❌ [$name] 本地构建产物目录不存在: $local_dist"
        return 1
    fi

    # 功能标记清单由项目显式维护；通用技能不内置业务标记。
    local markers=()
    if [[ -f "$MARKERS_FILE" ]]; then
        markers=($(grep -v '^\s*#' "$MARKERS_FILE" 2>/dev/null | grep -v '^\s*$' | tr -d '\r'))
    fi
    if [[ ${#markers[@]} -eq 0 ]]; then
        echo "ℹ️  项目未配置功能标记，跳过标记保留检查"
        return 0
    fi

    local fail=0
    local m cloud_has rc
    for m in "${markers[@]}"; do
        cloud_has=$(ssh -i "$SSH_KEY" $SSH_OPTS "$SERVER" \
            "grep -rls -e '$m' $remote_assets 2>/dev/null | head -1")
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "❌ [$name] 检查云端功能标记 [$m] 时 SSH 失败（退出码 ${rc}）→ 阻塞发版"
            fail=1
            continue
        fi
        if [[ -n "$cloud_has" ]]; then
            # 注意：不能用 cat|grep -q 管道——pipefail 下 grep 提前退出会令 cat 收 SIGPIPE(141)，
            # 匹配成功也被误判为缺失（竞态）。grep 直接吃文件列表无此问题。
            if ! grep -qs -e "$m" "$local_dist"/assets/*.js 2>/dev/null; then
                echo "❌ [$name] 云端含功能标记 [$m]（${cloud_has}），本地构建产物缺失 → 发版会丢功能！"
                fail=1
            else
                echo "✅ [$name] 功能标记 [$m] 本地已包含"
            fi
        fi
    done
    if [[ $fail -eq 0 ]]; then
        echo "✅ [$name] 功能标记检查通过（共 ${#markers[@]} 个标记）"
    fi
    return $fail
}

case "$TARGET" in
    backend)
        [[ -n "$CLOUD_APP" ]] || { echo "❌ backend 预检要求配置 CLOUD_APP/DEPLOY_CLOUD_APP"; exit 2; }
        LOCAL_APP="${2:-${LOCAL_APP_DIR:-$(cd "$SCRIPT_DIR/backend" 2>/dev/null && pwd)/app}}"
        # 多机滚动一致性：DEPLOY_TARGETS 存在时逐台预检（与 deploy-backend.sh 的目标列表同源），
        # 任一台出现清单外差异即整体阻塞——集群不允许"部分机器可覆盖、部分会被覆盖坏代码"
        if [[ -n "${DEPLOY_TARGETS:-}" ]]; then
            RC=0
            for TSV in $DEPLOY_TARGETS; do
                echo ""
                echo "🌐 预检目标: ${TSV%%@*}@<server>"
                check_backend "$LOCAL_APP" "$TSV" || RC=1
            done
            exit $RC
        fi
        check_backend "$LOCAL_APP"
        exit $?
        ;;
    frontend)
        # 注意：必须用 ${2:-} 形式——set -u 下 $2 无参会直接 unbound 崩溃，
        # 连"打印用法"的机会都没有（2026-11-03 实录：agent 调用缺参报 errored on $2）
        DIST="${2:-}"; REMOTE_ASSETS="${3:-}"
        if [[ -z "$DIST" || -z "$REMOTE_ASSETS" ]]; then
            echo "用法: precheck-deploy.sh frontend <本地dist目录> <云端assets目录>"
            exit 2
        fi
        check_front_dir "前端" "$DIST" "$REMOTE_ASSETS"
        exit $?
        ;;
    *)
        echo "用法: precheck-deploy.sh backend [本地app目录]"
        echo "      precheck-deploy.sh frontend <本地dist目录> <云端assets目录>"
        exit 2
        ;;
esac
