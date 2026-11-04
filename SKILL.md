---
name: gate-ops
description: 闸门驱动的通用发版/回滚技能（面向 AI Agent 设计）。当用户要求发布、部署、上线、发版、回滚前端或后端服务，或排查"健康检查失败/发版覆盖云端新代码/丢功能"问题时使用；也可说"用 gate-ops 发版/验收/回滚"。核心机制：三段式发版（gateo-plan 生成计划 → 用户确认计划 ID → gateo-apply 指纹校验后执行，确认闸门密码学强制）+ 八阶段生命周期（preflight→plan→approval→backup→apply→readiness→acceptance→ledger/memory）+ 闸门体系（发版锁防并发带心跳、备份 sha256 三重校验、验收闭环是记忆硬闸门）+ 证据中心。覆盖：前端构建发布、后端多模式发布（container-sync/compose-build/process/custom）与多机集群滚动发布、多环境标注（prod/staging/dev）、凭据集中存档（~/.gateo/credentials.sh，敏感信息不入库不入对话且输出自动脱敏）、发版前置检查（防旧码覆盖云端 + 防丢功能标记 + 期望差异清单）、云端自动备份、精确快照回滚、健康检查失败甄别（启动预热自动延长观察）、浏览器 E2E 验收、发版后三层记忆写入协议。
argument-hint: "[admin|h5|all|backend|rollback ...]"
---

# 🚢 gate-ops · 闸门驱动的发版/回滚技能

> **流程为路、闸门为门、证据为痕**——没确认不发版、没备份不覆盖、没验收不写记忆。
> No gate, no ship.

**本技能为 AI Agent 设计**：所有脚本退出码语义明确（0=成功，非0=失败）、失败即停（`set -euo pipefail`）、每步输出结构化可解析、危险操作（FORCE=1）有硬性禁令。你（agent）是这套脚本的执行者和汇报者，不是绕过者。

## 快速开始（v3.1：计划 → 用户确认 → 执行，三段式硬闸门）

```bash
# 第0步·连通性自检（每次发版前先跑，5 秒确认 key/服务器/权限都通，
# 避免"Permission denied 后全盘搜密钥"的时间黑洞——2026-11-03 实录教训。
# IP/密钥路径从 ~/.gateo/credentials.sh 读取，不在本文件出现）
source ~/.gateo/credentials.sh && ssh -i "$CRED_MYAPP_SSH_KEY" "$CRED_MYAPP_SERVER" "docker ps" | head -3

# 第1步·生成发版计划（只读，永不部署；输出计划摘要 + 确认 ID，有效期默认 30 分钟）
PROJECT=project-a bash scripts/gateo-plan.sh backend           # 后端
PROJECT=project-a bash scripts/gateo-plan.sh frontend admin    # 前端 admin|h5|all

# 第2步·把计划摘要呈给用户确认（目标/模式/变更资产/回滚点 + 计划 ID），拿到明确同意后：
PROJECT=project-a bash scripts/gateo-apply.sh <计划文件路径> <用户确认的计划ID>
#    apply 内部校验配置指纹与源码指纹——计划生成后任何一方被改动即拒绝执行
# ⚠️ 直接跑 deploy-backend.sh / deploy-frontend.sh 会被硬拒绝（提示缺少发版计划）——这是设计，不是故障

# 回滚（不受计划闸门限制；真故障回滚越快越好）
PROJECT=project-a bash scripts/rollback.sh list
PROJECT=project-a bash scripts/rollback.sh backend              # 最近一次备份
PROJECT=project-a bash scripts/rollback.sh frontend admin       # 前端最近备份
```

连通性自检失败时的排查顺序：key 文件存在且权限 600？→ 服务器地址对？→ 有没有多个 key（`ls ~/.ssh/`）需要 `-i` 显式指定？确认通了再进发版流程。

## 项目档案机制（多项目复用）

配置加载优先级：`DEPLOY_CONF=/path/x.sh` > `PROJECT=<名>`（读 `profiles/<名>.sh`）> `DEPLOY_*` 环境变量 > 内置默认。

- 内置档案：`profiles/project-a.sh`（销售培训系统）、`profiles/project-compose.sh`（AI 内容型项目）
- 新项目接入：`cp profiles/template.sh profiles/<新项目名>.sh` 并填写（发布模式、环境标注、容器、构建源、路径、就绪/健康探活、功能标记文件），然后跑 `bash scripts/gateo-doctor.sh` 做离线体检（配置契约详见 `references/config-schema.md`），**无需改任何脚本**
- ⚠️ **compose-build / process 模式接入必查 bind mount**：运行时数据目录（数据库/上传/密钥）若位于 RSYNC_DEST 之内，`rsync --delete` 会删生产数据——接入 checklist 见 `references/config-schema.md` 的"Bind mount 与运行时数据"节（project-b 事故教训）
- 技能自带行为测试：`bash tests/run.sh`（11 项：审批防篡改/脱敏/精确回滚/锁驱逐等），改脚本后必须全过

## 凭据与安全（集中存档约定）

- **服务器 IP / SSH 密钥路径只写在 `~/.gateo/credentials.sh`**（权限 600，已被 `.gitignore` 排除，永不入库、永不入对话、永不入台账与证据）
- 档案只引用变量名：`SERVER="${CRED_<项目>_SERVER:-}"`、`SSH_KEY="${CRED_<项目>_SSH_KEY:-}"`；新项目接入时在凭据文件追加一组 `CRED_<项目>_*` 变量
- 档案可用 `GATEO_CRED_FILE` 指向其他凭据文件（默认 `~/.gateo/credentials.sh`）
- 所有脚本对 `SERVER` 缺失做硬校验（exit 2 并提示检查凭据文件）——不再有任何硬编码默认值
- **输出脱敏**：deploy-backend 全程输出（含证据文件与对话可见部分）先过 sed，把 IP 替换为 `<server>`；precheck 的排查提示命令用 `<目标主机>`/`<SSH_KEY>` 占位——敏感地址既不进证据也不进对话
- **向用户汇报、写台账/证据/记忆时一律不出现 IP 与密钥路径**，用项目名/域名指代

## 命名规范（品牌统一约定）

| 对象 | 命名 | 示例 |
|---|---|---|
| 技能名 | `gate-ops` | 目录 `~/agent-skills/gate-ops`，主文件 `SKILL.md` 的 `name: gate-ops` |
| 服务器产物 | `gateo_` 前缀 | `gateo_backend_app_bak_<TS>.tar.gz`（+ .sha256/.dirfp 边车）、`gateo_frontend_<站点>_bak_<TS>.tar.gz` |
| 证据产物 | `gateo-` 前缀 | 目录 `gateo-<日期>_<TS>_<目标>/`，文件 `gateo-deploy-output.txt` / `gateo-acceptance-report.md` / `gateo-e2e-<描述>.png` |
| 发版锁 | `/tmp/gateo-release-locks/` | 项目子目录 = `PROJECT` 名 |
| 四大目录 | 固定 | `records/`（台账+总目录）· `evidence/`（证据）· `plans/`（大版本规划）· `lifecycle/`（阶段手册） |
| 识别符 | 🚢 | 脚本 banner、台账/总目录标题；口号 "No gate, no ship" |

- **任何位置 `grep gateo` 可找齐本技能生成的全部产物**；无前缀的历史备份（2026-11-03 前）rollback 新旧通吃
- 版本号：仓库根 `VERSION` 文件（语义化版本），所有脚本 banner 自动读取并打印

## 环境变量速查

| 变量 | 作用 |
|---|---|
| `DEPLOY_CONF` | 直接指定档案文件路径 |
| `PROJECT` | 选择 profiles/ 下档案名 |
| `GATEO_ENV` | 运行环境标注（prod/staging/dev），进 banner/台账/证据；prod 触发生产警示 |
| `GATEO_CRED_FILE` | 凭据文件路径（默认 `~/.gateo/credentials.sh`，见"凭据与安全"节） |
| `DEPLOY_SERVER` / `DEPLOY_SSH_KEY` | 目标服务器 / SSH 私钥（单机覆盖用） |
| `DEPLOY_TARGETS` | 多机滚动目标列表（空格分隔，仅 container-sync/process 模式；逐台 备份→发布→重启→健康，fail-fast） |
| `DEPLOY_MODE` | 发布模式覆盖（container-sync/compose-build/process/custom；档案必须显式声明） |
| `DEPLOY_RELOAD_CMD` | process 模式服务重载命令（如 `systemctl restart myapp` / `pm2 reload myapp`） |
| `DEPLOY_EXPECT_DIFFS` | 预检期望差异清单（逗号分隔，例行发版免 FORCE，见铁律 1） |
| `DEPLOY_PROJECT_ROOT` / `DEPLOY_APP_DIR` | 本地前端项目根 / 后端 app 目录 |
| `DEPLOY_NODE_BIN` | npm 可执行文件（默认 PATH 中的 npm） |
| `DEPLOY_CONTAINER` / `DEPLOY_BUILD_SRC` / `DEPLOY_HEALTH_URL` | 容器名 / 服务器构建源 / 健康检查 URL |
| `DEPLOY_READINESS_URL` / `DEPLOY_READINESS_CMD` | 就绪探活（v3.1 推荐，fail-on-error 拒绝 4xx/5xx；未配置回退 HEALTH_*） |
| `DEPLOY_HEALTH_RETRIES` / `DEPLOY_HEALTH_INTERVAL` | 首轮探活次数 / 间隔秒数（默认 10×3s=30s；失败且进程在运行时自动延长观察 60s） |
| `GATEO_PLAN_TTL` | 发版计划有效期秒数（默认 1800，范围 60..86400） |
| `DEPLOY_BACKUP_DIR` / `DEPLOY_KEEP` | 备份目录 / 保留份数（默认 20） |
| `DEPLOY_EVIDENCE_DIR` | 证据目录（设置后脚本全程输出自动留档 `gateo-deploy-output.txt`） |
| `E2E_MODE` | 浏览器 E2E 档位临时覆盖（auto/always/off，单次发版有效） |
| `FORCE=1` | ⛔ 跳过前置检查，见下方铁律 |

## Agent 行为铁律（必须遵守）

0. **身份锚定（先于一切动作）**：接入/复核/审计/发版任务的目标系统**只能来自用户当前消息的明确指定**。历史记忆、台账记录、技能文档提及（如"project-b P0 教训"）、端口占用、同机其他系统等线索**只能用于验证用户指定的系统，绝不能用于推断或指派任务**（2026-11-04 实录教训：某会话因任务书未写系统名，凭记忆自行推断成 project-b 并执行了整套复核）。候选系统为零个或多个、或与你的记忆冲突时，**必须先询问用户**，得到明确答复后才能开工。开工第一行输出：`本次系统=<X>（依据：用户指定/用户确认）`。

1. **禁止自行使用 `FORCE=1`**。前置检查未通过 = 发现了真实风险，你必须把差异清单完整报告给用户，等用户明确说出"强制发版"或"跳过检查"后才能加 `FORCE=1`。网络/SSH 故障导致的检查失败同样禁止用 FORCE 绕过——先修连通性。
   **例行发版不需要 FORCE**：差异=本次待发内容是常态，在确认闸门里与用户确认期望差异清单后，用 `DEPLOY_EXPECT_DIFFS="文件1,文件2"` 传入发版命令，预检会校验"实际差异 ⊆ 期望清单"后放行；只有出现**清单外**差异或用户明确授权跳过全部检查时才允许 FORCE=1（用 FORCE 的发版，台账备注必须记录原因与用户确认）。
   **⚠️ 路径基准（2026-11-04 project-b 实录教训）**：`DEPLOY_EXPECT_DIFFS` 的路径**相对 LOCAL_APP_DIR**，即 precheck 差异清单的原样路径；**不是 git 仓库根的路径**——两者经常不同（如 git 内 `app/app/api/auth.py` = 差异清单里的 `app/api/auth.py`）。直接从 precheck 差异清单复制，不要从 git status 换算。`DEPLOY_EXPECT_DIFFS` 必须在 **gateo-plan 时**传入（写入计划 manifest，apply 自动携带），不是 apply 时才加。
2. **差异方向口诀：本地多 = 待发版（正常）；云端多 = 先同步 云端→本地（事故信号）**。precheck 报差异 ≠ 事故：若差异是本地已知、尚未发版的工作，确认归属后正常发版即可；若云端存在你不知道的改动（热修/他人部署），才是事故信号。注意 tar 发版会把本地 mtime 带上云端，**云端 mtime 不能证明有人在服务器上改过文件**。
3. **单写者原则**：同一时间只允许一个会话**发版**，其他会话对云端只读；**并行修改本地源码允许**（多会话各领任务是常态），但前提是源码已 git 管理（见 `references/config-schema.md` 接入检查项）且各会话分段 commit——**发版前差异归属必须判定并记录进台账**，归属不明（未提交且不知来源）的差异不得发版。**发版锁已内置**（`scripts/_lock.sh`）：deploy 脚本会拒绝并发发版，锁 30 分钟未释放自动回收；若上次发版会话异常中断，按脚本输出提示手动清锁后重试。
4. **发版只走标准链路**（gateo-plan → 用户确认 → gateo-apply，已带计划闸门+预检+备份）；任何"直接上服务器改文件"的操作都是违规，直接跑 deploy 脚本会被计划闸门硬拒绝——**补生成计划并走确认，而不是绕过**。分析/诊断/规划不构成发版授权。
5. **脚本退出码非 0 时不要盲目重试**。读失败输出定位原因（构建错误→报给用户；前置检查差异→走铁律1+方向口诀；备份失败→查磁盘/权限；健康检查失败→走铁律6）。
6. **后端健康检查失败先甄别、再决定回滚**（2026-11-03 内容型项目实录修订）：
   - **脚本已内置失败甄别**：首轮探活失败但服务进程仍在运行（compose ps / docker inspect 确认）→ 自动延长观察 60s（疑似启动预热）；延长后通过 = 发版成功，台账备注记"预热延长观察通过"；延长后仍失败或进程已退出 = 真故障
   - **真故障立即回滚**：`rollback.sh backend`（默认恢复最近备份），回滚成功后把失败日志（脚本已自动打印）报告给用户
   - **延长窗口仍不够的特殊情况**（预热超过 90s 等）：agent 可以做只读诊断（手动探活/容器状态/启动日志），但**不得自行决定"不回滚、转验收"**——必须把诊断证据（探活 200、容器状态、耗时）报给用户，经用户明确同意后才继续验收，决策与用户确认原文记入台账
   - 回滚纪律的例外只有两处：脚本判定"预热延长观察通过"（自动放行），与用户明确同意不回滚（人工授权）
7. **严禁单文件 cat 管道部署后端**——只能用本技能的全量脚本（这是历史事故教训）。
8. **无有效备份不覆盖**：脚本在覆盖动作前做三重硬校验，任一失败即终止发版（exit 1）——①发版锁复核（锁被清/被他人持有 → 拒绝，防双会话并发覆盖）；②备份真实性：归档**全量可读**（`tar -tzf` 读完整流，截断/损坏即失败）+ **md5 复核**（备份时生成的 `.md5` 边车文件，`md5sum -c` 核对备份自创建后未被改动）；③**现场指纹比对**：备份时记录被备份目录的内容指纹（`.dirfp`），覆盖前重算比对——不一致说明备份后现场被写入过（并发写/热修），本次备份可能不代表当前现场。备份命令"没报错"≠备份可用，校验通过后把备份文件名和 md5 记入记忆（见下）。
9. 前端功能检查通过后若云端有新功能标记缺失，先同步代码而不是跳过。
10. **关键环节必须触发用户确认提醒（确认闸门，v3.1 起由计划机制强制）**：
    - **发版执行前**：先 `gateo-plan.sh` 生成计划（含目标/模式/变更资产/回滚点/计划 ID），把摘要呈给用户确认；`gateo-apply.sh` 校验"用户确认的计划 ID = 当前计划"才会执行——**计划的配置指纹与源码指纹在确认后任一方被改动即拒绝执行**，改过就重新生成、重新确认
    - 确认消息仍须包含四要素：**目标**（发哪个端/哪个容器）、**将覆盖的云端资产**（计划列出的差异）、**备份机制声明**（回滚点）、**发布模式**，外加**计划 ID**
    - **验收中向生产库写数据前**同样先确认（纪律见 `lifecycle/05-acceptance.md`）
    - agent 不得以"用户已经说过要发版"为由跳过——用户说的是**意图**，确认的是**范围**（到底覆盖哪些云端文件）
    - **无低风险豁免（2026-11-03 用户裁定）**：纯前端/样式类/小改动发版同样走确认闸门——确认框成本几秒，但它是"覆盖范围用户说了算"的执行点。
    - 唯一豁免：health 失败后的自动回滚（铁律 6 已授权，紧急场景不设闸门，拖延风险更大）。

## 任务入口与解耦（processes/，v3.2.0 起）

七类过程各有独立入口与终点（剧本见 `processes/`）：**release**（发版，core）/ **rollback**（回滚）/ **onboarding**（接入与复核）/ **data-change**（内容级变更）/ **audit**（审计复核，只读）/ **hotfix**（线上故障前向修复）/ **publish**（对外发布与脱敏：GitHub 开源、官网、公众号、交付物——对外发布本质是一次发版，脱敏映射表是可审计产物，发布后独立复审是强制终点）。

- **入口解耦**：每个过程有自己的终点；过程产出到下一个过程的转化**必须由用户指令发起**——审计回执 ≠ 自动进入发版，接入完成 ≠ 自动发版，回滚成功 ≠ 自动修复。agent 不得以"顺手做完了"为由跨越过程边界。
- **跨过程衔接**在 `processes/README.md` 注册表中维护（如：hotfix 的前向修复走 release 链路；数据订正走 data-change）。

## 退出码语义

- `0` 发版/回滚成功
- `1` 前置检查未通过 / 构建失败 / 备份失败 / 健康检查失败（发版已中止，云端未被破坏，或已有备份可回滚）
- `2` 参数错误

## 各脚本流程（自动执行，无需你干预）

- `deploy-frontend.sh`：发版锁 → 构建（失败即停+产物非空校验）→ 功能标记前置检查 → 云端备份（失败即停，自动清理超量备份）→ tar 全量发布 → 远端 index.html 验证 → 打印台账行
- `gateo-plan.sh`：生成短期发版计划（默认 30 分钟 TTL）——只读，永不部署；输出配置指纹（SHA256）+ 源码指纹 + 变更摘要 + 确认 ID
- `gateo-apply.sh`：`<计划文件> <计划ID>`——校验计划未篡改/未过期/配置与源码指纹一致后，转交 deploy 脚本执行；是把"用户确认"变成硬闸门的关键环节
- `gateo-doctor.sh`：项目档案离线体检（不连服务器），新项目接入/改配置后必跑
- `deploy-backend.sh`：发版锁 → 前置检查（rsync 校验和干跑，防旧码覆盖；多机时逐台预检）→ 按模式发布（container-sync 双备份+先清后灌 / compose-build 源码+rebuild / process rsync+重载 / custom 自定义命令）→ 就绪/健康检查（fail-on-error 拒绝 4xx/5xx；首轮可配置，失败且进程在运行时自动延长观察 60s 甄别启动预热；真故障自动打印日志+回滚命令）→ 打印台账行；`DEPLOY_TARGETS` 多机时逐台滚动，任一台失败即停（fail-fast）
- `precheck-deploy.sh`：可独立运行；检查工具自身失败（SSH/rsync 出错）= 阻塞，绝不假通过；backend 支持 `DEPLOY_EXPECT_DIFFS` 期望差异清单（差异 ⊆ 清单 → 放行，例行发版免 FORCE）；`DEPLOY_TARGETS` 存在时逐台预检；**预检/发版锁脚本缺失时 deploy 脚本硬阻塞（exit 2），不允许静默跳过**
- `rollback.sh`：list / frontend / backend 三种模式；恢复前先清空目标目录再解包（**精确快照回滚**，不留新版本残留文件），备份边车（sha256/md5）校验失败即拒绝恢复；backend 按备份类型自动选路（app 型=容器直灌、src 型=compose 重建或 process 重载），回滚含健康检查
- `tests/run.sh`：11 项行为测试（审批防篡改与过期、输出脱敏、HTTP 500 拒绝、精确回滚、锁驱逐与死锁回收、档案安全 source）；**改任何脚本后必须全过再交付**

## 发版生命周期（八阶段）与分层文档

```
preflight → plan → approval → backup → apply → readiness → acceptance → [rollback] → ledger → memory
```

- **acceptance（验收闭环）是发版完成的定义**：health 只证明服务活着，acceptance 以"本次发布内容"为输入组织定向验收，通过后才算 done。**验收含浏览器端到端实测（E2E_MODE 档案控制档位，接入时与用户确认，随时可调）**：能力前置检查 → 变更点真实页面验证 → 截图留证 → 强刷复验，详见 `references/browser-e2e.md`
- **release 执行前有用户确认闸门**（铁律 10）：将覆盖哪些云端资产（preflight 差异清单），必须用户明确同意后才执行——"要发版"是意图，确认的是范围；**无低风险豁免**，纯前端/样式类同样要确认
- `memory` 的硬闸门：acceptance 未闭环（通过/回滚/带瑕疵放行）前，禁止写记忆、禁止报完成
- 详细规则按需深读 `lifecycle/00-overview.md` 起的九篇阶段手册（每篇六段结构：目标/前置条件/操作手册/失败处置/输出物/Agent 检查点）

**渐进披露三层**（分层阅读，避免文档债）：
1. 本文件 —— 例行发版只读这个
2. `lifecycle/*.md` —— 进入对应阶段或遇到异常时深读
3. `plans/<项目>/` —— 仅**大版本/高风险发版**：先产出 `<版本>-release-plan.md`（范围/风险/回滚基准/验收标准）经用户确认再执行；例行发版不写 plan，防文档债

## 发版后记忆写入（必做，不可跳过）

**前置闸门：acceptance 闭环之后才写。** 发版成功或回滚完成后，**立即**写入三处（缺一不可），让任何 agent 在下次会话能回答"最近发过什么版本、最近回滚点是哪个备份"：

0. **跨 agent 发版台账 + 证据目录（共享真源，最先写）**：
   - **发版命令带证据目录**：`DEPLOY_EVIDENCE_DIR=<技能目录>/evidence/<项目>/$(date +%Y%m%d_%H%M%S)_<目标> PROJECT=<项目> bash scripts/deploy-backend.sh`——脚本自动建目录并把**全程输出**（锁/预检/备份 md5/校验/健康检查）留档为 `gateo-deploy-output.txt`
   - 验收后在证据目录写 `gateo-acceptance-report.md`（六步法产物，例行发版也生成）；E2E 截图存同目录（约定见 `evidence/README.md`）
   - 向 `records/<项目名>.md` 追加台账行（deploy 脚本结尾会直接打印填好的行，补 验收/agent/证据/备注 四列即可粘贴），"证据"列填相对路径（如 `evidence/project-a/20261103_155241_backend`）
   - 跑 `bash scripts/build-index.sh` 刷新总目录 `records/_index.md`（跨项目全局索引，追踪入口）
   - git 提交（`cd ~/agent-skills && git add -A && git commit -m "deploy log: <项目> <结果>"`）。台账是所有 agent 共读的部署历史——WorkBuddy 发的版，Claude/Codex 也能查到回滚点
   ```markdown
   | 时间 | 目标 | 结果 | 验收 | 备份文件（回滚点） | 健康检查 | 操作 agent | 证据 | 备注 |
   |---|---|---|---|---|---|---|---|---|
   | 2026-11-03 13:30 | backend | 成功 | 通过(5/5) | gateo_backend_app_bak_20261103_133000.tar.gz | healthy | WorkBuddy | evidence/project-a/gateo-20261103_133000_backend | 发布XX功能 |
   ```
1. **宿主 agent 会话日志（append-only）**——按当前宿主 agent 的记忆体系落盘：
   - WorkBuddy：`{workspace}/.workbuddy/memory/YYYY-MM-DD.md` 追加一条
   - Claude Code：项目 `CLAUDE.md` 的"部署记录"小节
   - Codex：项目 `AGENTS.md` 的"部署记录"小节
   - 记录格式：`[HH:MM] 项目=<名> 目标=<...> 结果=<成功|回滚> 验收=<n/n> 备份=<文件名> 异常=<无|简述>`
2. **项目长期记忆**（若存在 `MEMORY.md` / `CLAUDE.md` / `AGENTS.md` 中的长期事实区）：更新最近回滚点文件名；若本次上线了新核心功能，把对应标记追加进 `scripts/feature-markers.txt`（或档案指定的 `MARKERS_FILE`）并说明。

## 召唤示例（提示词）

- 发版：「用 gate-ops 发版 project-a 后端」「PROJECT=project-a 发前端 admin」
- 验收：「对刚才这次发版做验收」（agent 按 `lifecycle/05-acceptance.md` 五步执行并出验收报告）
- 回滚：「project-a 后端刚发的有问题，回滚到上一个备份」
- 查历史：「project-a 最近发过哪些版本？最近回滚点是哪个备份？」→ 读 `records/project-a.md` + `rollback.sh list`
- 接入新项目：「把 `<项目名>` 接入 gate-ops：服务器 xxx，容器 xxx，构建源 xxx，健康检查 http://xxx，本地源码在 xxx」
- 看连接通性：「帮我确认 XX 项目能不能连上服务器发版」→ 只跑 `precheck-deploy.sh`（只读）

## 新项目接入（一句话半自动）

**触发提示词**：「把 `<项目名>` 接入 gate-ops」，并附上：服务器地址、SSH key 路径、容器名/项目目录、构建源路径、健康检查 URL、本地源码路径。agent 应自动完成：

1. **先确认并登记默认发布方式**：询问用户该项目用什么方式发布（container-sync / compose-build / process / custom），**必须在档案中显式写入 `DEPLOY_MODE`**——脚本会拒绝未声明模式的档案（发布方式是项目固有属性，禁止静默继承缺省值）
2. **确认并登记浏览器 E2E 模式**：询问用户验收档位（auto=前端必做/后端影响页面才做，推荐缺省；always；off），写入档案 `E2E_MODE`——之后随时可改档案调整，改完即生效
3. `cp profiles/template.sh profiles/<项目名>.sh`，填入用户确认的信息（含 `DEPLOY_MODE`、`E2E_MODE`）
4. 确认连通：`ssh -i <key> <server> "docker ps | grep <container>"`
5. `git add -A && git commit -m "onboard: <项目名>"` 并告知用户档案路径
6. 首次发版前先跑 `precheck-deploy.sh backend <本地app目录>` 确认云端状态；若该项目容器内路径、健康检查方式与本技能假设（`/app/app`、`python3 urllib`）不同，核对并微调脚本内的对应假设

**审计/复核回执的身份声明（强制，v3.1.1 起）**：任何审计回执、复核报告、接入报告的**第一行**必须写明：

```
本次系统=<项目代号/系统名> · 身份依据=用户消息指定 / 用户确认
```

- 身份依据只允许两种取值：用户消息明确指定，或经用户确认——**"根据历史记忆推断"不是合法依据**（铁律 0）。
- 该字段是用户审计回执的第一道检查点：身份错位的回执（系统写错、信息混入其他项目）扫一眼第一行即可拦截，不必逐条核对内容。

## 深入参考

- `lifecycle/00-overview.md` ~ `08-memory.md`：八阶段生命周期手册（状态机 + 每阶段决策手册）
- `processes/README.md`：过程剧本注册表（release/rollback/onboarding/data-change/audit/hotfix 六入口 + 入口解耦铁律）
- `integrations/README.md`：宿主集成层（workbuddy/claude/codex/generic，一键装配 `scripts/gateo-init.sh`）
- `references/environment.md`：销售培训系统服务器拓扑、端口占用、强隔离铁律（动服务器前必读）
- `references/mac-traps.md`：macOS/bash 3.2 环境陷阱清单（改脚本前必读：多字节变量、BSD grep、pipefail 竞态、tar mtime、zsh EXIT trap 等）
- `references/browser-e2e.md`：浏览器端到端验收规程（E2E_MODE 三档配置、三端能力前置检查与安装路径、截图留证流程）
- `profiles/project-a.sh` / `profiles/template.sh`：档案配置项说明
- `plans/`：大版本 release-plan 与路线规划存档（例行发版不使用；验收报告与截图统一存 `evidence/`）
- `evidence/`：证据中心（每项目 × 每次发版一个目录：脚本输出留档 + 验收报告 + E2E 截图；约定见 `evidence/README.md`，总目录 `records/_index.md` 由 `scripts/build-index.sh` 聚合生成）
