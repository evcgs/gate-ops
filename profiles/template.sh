#!/bin/bash
# ============================================
# 项目档案模板 — 新项目接入时复制为 profiles/<项目名>.sh 并填写
# 用法: PROJECT=<项目名> bash deploy-backend.sh
# 所有值都可用环境变量 DEPLOY_* 覆盖（优先级: 环境变量 > 档案 > 内置默认）
# ============================================

# ---- 发布模式（四选一，缺省 container-sync）----
# container-sync: 容器常驻代码直灌（需 CONTAINER + BUILD_SRC）
# compose-build : compose 项目重构建（需 PROJECT_DIR + RSYNC_DEST + HEALTH_URL/CMD）
# process       : 裸进程主机 rsync + 服务重载（需 RSYNC_DEST + DEPLOY_RELOAD_CMD + HEALTH_URL/CMD）
# custom        : 万能兜底（需 PROJECT_DIR + DEPLOY_CUSTOM_CMD + HEALTH_URL/CMD）
# ※ 运行时切换模式请用 DEPLOY_CONF 指向变体档案
DEPLOY_MODE="container-sync"

# ---- 运行环境标注（进 banner / 台账 / 证据；prod 会触发生产警示行）----
GATEO_ENV="prod"   # prod | staging | dev

# ---- 凭据集中存档（敏感信息不进本仓库、不进对话）----
# IP / 密钥只写在 ~/.gateo/credentials.sh（chmod 600，已被 .gitignore 排除），
# 档案只引用变量名；新项目在该文件追加一组 CRED_<项目>_* 即可。
GATEO_CRED_FILE="${GATEO_CRED_FILE:-$HOME/.gateo/credentials.sh}"
# shellcheck disable=SC1090
[[ -f "$GATEO_CRED_FILE" ]] && source "$GATEO_CRED_FILE"
SERVER="${CRED_<项目>_SERVER:-}"      # ← 换成凭据文件里登记的变量名
SSH_KEY="${CRED_<项目>_SSH_KEY:-}"

# ---- 浏览器端到端验收模式（接入时与用户确认；随时可改，改完即生效）----
# auto  : 前端发版必做 E2E；后端发版影响页面行为才做（推荐缺省）
# always: 所有发版都做浏览器 E2E
# off   : 关闭（文件级验收放行），台账验收列必须如实记"部分验证（无浏览器 E2E）"
# 详见 references/browser-e2e.md
E2E_MODE="auto"

SERVER="root@your-server-ip"
SSH_KEY="$HOME/.ssh/your_key"

# ---- container-sync 模式字段 ----
CONTAINER="your-container-name"
BUILD_SRC="/www/wwwroot/your-project/package/deploy/backend"

# ---- compose-build / custom 模式字段 ----
PROJECT_DIR="/www/wwwroot/your-project"        # 服务器项目目录（compose 命令的执行目录）
COMPOSE_FILE="docker-compose.yml"              # 相对 PROJECT_DIR 的 compose 文件名
COMPOSE_CMD="docker compose"                   # v1 语法的服务器改为 "docker-compose"
RSYNC_DEST="/www/wwwroot/your-project/app"     # rsync 目标，必须在 PROJECT_DIR 之下（process 模式为
                                               # 独立部署目录即可），且必须是"纯源码"子目录——
                                               # 绝不能含 SQLite/上传等运行时数据（--delete 会删
                                               # 数据！）；.env 永远不会被覆盖
DEPLOY_RELOAD_CMD=""                           # process 模式: 服务重载命令，如
                                               # "systemctl restart myapp" 或 "pm2 reload myapp"
DEPLOY_CUSTOM_CMD=""                           # custom 模式: 服务器上执行的发布命令（不得硬编码密钥）
BACKUP_TARGETS=""                             # 备份按变更对象（空格分隔绝对路径）；设了则覆盖 RSYNC_DEST 备份（runtime-upgrade 用）
VERSION_CHECK_CMD=""                            # 版本校验：输出实际版本的命令（如 php -r 'echo PHP_VERSION;'）
VERSION_EXPECT=""                               # 版本校验：期望版本号；与 VERSION_CHECK_CMD 输出不一致则 fail

# ---- 多机滚动（可选，仅 container-sync / process 模式）----
# 设为空格分隔的多台服务器列表（同集群同配置），发布时逐台 备份→发布→重启→健康检查，
# 任一台失败即停（fail-fast）。留空 = 单机发布（用上面 SERVER）
# 例: DEPLOY_TARGETS="root@10.0.0.11 root@10.0.0.12"
DEPLOY_TARGETS=""

# ---- 备份 ----
BACKUP_DIR="/www/wwwroot/your-project/backup"
BACKUP_KEEP=20

# ---- 健康检查（二选一；compose/custom/process 模式必填其一）----
# v3.1 起推荐配置 READINESS_*（就绪探活）：HTTP 探活自动 fail-on-error，任何 4xx/5xx 判失败；
# 未配置时回退 HEALTH_*。健康（活着）≠ 就绪（能接流量）≠ 验收（功能正确）
READINESS_URL="http://localhost:<port>/health" # 就绪探活地址（服务器视角 host curl）
READINESS_CMD=""                               # 优先级更高：服务器上执行的自定义就绪命令
HEALTH_URL=""                                  # 回退：liveness 探活（READINESS_* 未配置时使用）
HEALTH_CMD=""                                  # 回退：自定义探活命令
# 示例: READINESS_CMD="curl -sf -m 5 http://localhost:8080/health"

# ---- 本机路径 ----
# 前端项目根：含 admin/ h5/ 或其他前端目录
PROJECT_ROOT="/path/to/local/source"
LOCAL_APP_DIR="$PROJECT_ROOT/deploy/backend/app"  # 后端本地源码目录（compose 模式=整个源码子树）

# ---- 前端（static 模式）----
REMOTE_ADMIN_DIR="/www/wwwroot/your-project/admin"
REMOTE_H5_DIR="/www/wwwroot/your-project/h5"
SITE_ADMIN_URL="https://your-domain.com/admin/"
SITE_H5_URL="https://your-domain.com/"
MARKERS_FILE="$SCRIPT_DIR/feature-markers.txt"    # 建议复制到项目专属路径后按项目维护

NODE_BIN=""
