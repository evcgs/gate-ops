# Changelog · gate-ops

格式参考 Keep a Changelog；本技能变更按 roadmap-plan 治理规则记录（中等变更以上必记）。
（历史条目中提到的 specs/、release-spec、roadmap-spec 为改名前旧称，现统一为 plans/、release-plan、roadmap-plan——2026-11-03 用户裁定弃用外来命名，改用本技能自有命名。）

## 更名记录

- **2026-11-03：release-deploy → gate-ops**（用户裁定）。定位语：**流程为路、闸门为门、证据为痕**——闸门驱动的发版运维（No gate, no ship）。同步动作：目录/主文件 name/描述、三端软链重建（~/.workbuddy、~/.claude、~/.codex）、全库引用替换、真实链路回归（precheck 只读预检 ✔ / rollback list ✔ / build-index ✔）。

## [3.5.0] — 2026-11-09

### Added（服务器运行时升级支持 · runtime-upgrade）

- **第 8 个过程剧本 `processes/runtime-upgrade.md`**：PHP/语言/软件包源码重编译的专项流程——只读核查 → 按变更对象备份 → 长耗时后台编译 → 版本校验 → `/index.php` 回归 → 台账
- **`BACKUP_TARGETS`**：备份按变更对象（空格分隔绝对路径），设了则覆盖 RSYNC_DEST 备份——修复「改 php.ini 却备份了 RSYNC_DEST 小目录」的失配
- **`VERSION_CHECK_CMD` + `VERSION_EXPECT`**：编译后版本校验，实际 ≠ 期望即判失败——修复「7.4.34 实际 7.4.33 才发现」的镜像标签漂移
- deploy-backend.sh：custom 模式新增版本校验步骤；备份 echo 支持按变更对象展示

### Fixed（开源导出链 · 2026-11-09）

- **双语义隔离**：`scripts/gateo-export.sh` 移除内部项目代号的全局匿名化映射，改为 7 条登记语境的精确替换；shell 内建延时命令原样保留，修复导出包 8 处探活间隔 / 锁心跳 / 回滚等待 / 并发用例被改写后运行时报 `command not found` 的问题。未登记的新语境由终检 fail-closed 拦截。
- **通用 IP 终检**：终检新增通用 IPv4 类别检测与具体值白名单（8 个值 / 22 处），白名单外一律中止并报出文件 + 行；真实公网出口 IP 与内网网关在导出层泛化为 `<client-ip>` / `<gateway>`，真源保留原值。
- **脱敏文档口径**：`integrations/dsh/SANITIZATION.md` §1 / §3 / §4 / §5 与实测扫描结果对齐。

## [3.4.0] — 2026-11-09

### Added（DSH Agent 四步研发闭环 + 窗口编排 + 部署守卫）

- **003 四步研发闭环**：`scripts/gateo-evidence-verify.sh`（测试证据准入校验 + append-only 证据 seal）、`scripts/gateo-record-append.sh`（发版台账显式补录，操作 agent=DSH）
- **002 窗口编排**：`scripts/gateo-window-open.sh` / `gateo-window-close.sh` / `gateo-window-selftest.sh`（临时开窗凭证签发，默认关闭）
- **deploy-guard**：`scripts/deploy-guard.sh` + `integrations/deploy-guard/`（部署守卫）

## [3.3.0] — 2026-11-04

### Added（publish 过程剧本：对外发布与脱敏）

- **第 7 个过程剧本 `processes/publish.md`**（对外发布 / 开源发布 / 公众号发布）：确立"对外发布本质是一次发版"——目标仓库=生产环境，脱敏=数据安全，发布后复审=验收探活
- **发布后独立复审为强制终点**（v3.3.0 核心闸门）：首次开源发布靠用户追问才发现泄漏——发布即终点是失败模式；复审必须用独立宽词表直扫远端，0 命中才闭环
- **匿名化映射表升级为可审计产物**：真实项目名→代号（project-a~h）、业务词→通用词（内容库→内容库、用户→用户、内部表名→泛称）、路径→~/user-home；导出器自动套用映射
- **提交元数据检查**（阶段 5）：git author/committer 邮箱一律 noreply，历史含个人邮箱须 amend/squash 后推送
- processes/README 注册表扩至七过程；SKILL.md 任务入口节同步
- gateo-export.sh：匿名化层从临时对话规则固化为导出管线步骤；敏感词终检扩至 20 类（项目名词典+业务词+路径+邮箱+人名）

### Fixed

- 2026-11-04 首次开源发布泄漏事故闭环：CHANGELOG/references 真实案例列泄漏内部系统名 10+ 处、INSTALL 本机路径、提交作者个人邮箱——全部匿名化修复后强推，远端复扫 0 命中
- 导出器 sed 兼容性：toybox/GNU/BSD 三家 -i 与 \b 语义不一，改为 stdin→临时文件→mv 跨 flavor 写法

---
## [3.2.0] - 2026-11-04

### Added（spec-kit 方法论吸收批次）

- **跨产物一致性体检 `gateo-doctor.sh --deep`**（cross-artifact analysis 移植）：全库扫描档案/标记/台账/人读档案/回执五类产物一致性——MARKERS_FILE 引用完整性、本地路径存在性、台账缺失、人读档案缺失、回执身份声明、git 归属漂移信号（未提交产物）。首跑即命中当日全部真实漂移（project-compose 5 文件未提交 / project-c markers / 两份旧回执缺身份声明）。
- **过程剧本层 `processes/`**（process presets 移植）：六入口剧本注册表——release（core）/ rollback / onboarding / data-change / audit（只读终点纪律）/ hotfix（根因评估→范围化修复→验证留痕，新剧本）。入口解耦铁律：过程产出到下一过程必须由用户指令发起。
- **集成层 `integrations/` + 一键装配 `scripts/gateo-init.sh`**（spec-kit 38-agent 集成方法移植）：workbuddy/claude/codex/generic 四集成，软链即安装 + 装完自动自检 + codex AGENTS.md 指引行自动追加 + generic 任意宿主逃生门。
- SKILL.md 新增「任务入口与解耦」节与 processes/integrations 指引；INSTALL.md 支持一键装配。

## [3.1.1] - 2026-11-04

### Added（同日增补）
- **gateo-plan.sh 内嵌 precheck 只读干跑（2026-11-04 project-a 发布实录优化）**：backend 计划生成时自动跑一次 precheck，把文件级差异清单直接写进「覆盖资产」——未声明期望差异时呈现实测差异并提示带 `DEPLOY_EXPECT_DIFFS` 重新 plan；已声明时校验实测差异是否全部在声明内，**清单外差异在 plan 阶段提前暴露**（避免用户确认一次 → apply 被拦 → 被迫二次 plan）。precheck 失败不阻塞计划生成（apply 仍硬校验）；`GATEO_PLAN_SKIP_PRECHECK=1` 可跳过。真实四场景验证：未声明+有差异 / 声明全覆盖 / 声明遗漏（清单外暴露）/ 无差异。
- **SKILL.md 铁律 0 · 身份锚定**：接入/复核/审计/发版任务的目标系统只能来自用户当前消息的明确指定；历史记忆/台账/文档提及只能用于验证、不能用于推断指派；候选为零或多个时必须先询问用户；开工第一行复述"本次系统=X（依据）"。
- **审计/复核回执第一行强制身份声明**：`本次系统=<X> · 身份依据=用户消息指定/用户确认`——身份错位的回执扫第一行即可拦截。

### Added
- **config-schema.md 新增「内容级变更与数据备份」规范**：数据库内容变更/批量生成/数据修复等不发版操作不再游离于体系外——
  - 数据备份命名规范 `gateo_data_<project>_<desc>_<YYYYMMDD_HHMMSS>.<ext>`（品牌标志前缀，可 glob 检索，与代码备份 `gateo_backend_src_bak_*` 同族）；
  - 台账行约定：目标列 `data:` 前缀，兼容现有 9 列结构不新增列；
  - 回滚要点：先备份、再引用检查、后删除；下游联动检查（案例：project-a 每日计划时序缺陷）。
- `records/project-a.md` 按新规范补记 2026-11-04 内容库 210 道衍生题发布行（首个示范）。

## [3.1.0] - 2026-11-04

> 合并版：以 v2.1 中文主线为基座，吸收社区贡献版（gate-ops-v3.0.0.zip，另一 agent 基于本技能演进的 fork）的机制升级；SKILL.md/档案/台账/证据等中文与项目资产全部保留。

### Added（吸收自 v3.0 fork，全部经其自带 11 项行为测试验证）
- **三段式发版硬闸门**：`gateo-plan.sh`（只读生成发版计划：配置指纹 SHA256 + 源码指纹 + 变更摘要 + 确认 ID，默认 30 分钟 TTL）→ 用户确认计划 ID → `gateo-apply.sh` 校验"计划未篡改/未过期/配置与源码指纹一致"后转交 deploy 执行。**确认闸门从协议约定升级为密码学强制**；直接跑 deploy 脚本被硬拒绝
- **精确快照回滚**：恢复前先清空目标目录再解包（frontend/src/app 三路），修复 v2.1 "tar 覆盖解包不删新增文件、回滚后残留新版本"的真实弱点；回滚前强制校验备份边车（sha256/md5），缺失即拒绝
- **就绪探活 READINESS_URL/CMD**（优先于 HEALTH_*）：HTTP 探活 fail-on-error，任何 4xx/5xx 判失败——修复 v2.1 "curl -s 连上 500 也算探活成功"的真实漏洞；health（活着）/readiness（就绪）/acceptance（功能正确）三层语义写进 04-health
- **发版锁升级**：nonce + 15s 心跳 + 主机校验（活锁不被 TTL 误回收、死锁可安全回收、跨机锁不混淆）
- **备份校验升级 md5 → sha256**（历史 md5 边车回滚双兼容）
- **SSH 加固**：precheck/deploy 弃用 `StrictHostKeyChecking=no`，改 `accept-new` + `BatchMode`（禁止为便利关闭 host-key 校验）
- **路径安全守卫** `require_safe_remote_dir`：BACKUP_DIR/BUILD_SRC/RSYNC_DEST/PROJECT_DIR 非空、非 /、字符白名单、绝对路径
- **--no-restart 收紧**：prod 环境禁止，非 prod 需显式 GATEO_ALLOW_NO_RESTART=1
- **正式测试框架**：`tests/run.sh` 11 项行为测试（审批防篡改与过期、输出脱敏、HTTP 500 拒绝、精确回滚、锁驱逐与死锁回收、档案安全 source）——改脚本后必须全过
- **gateo-doctor.sh 档案离线体检** + `references/config-schema.md` 配置契约文档
- `--no-restart` 前置防崩修复、RSYNC_DEST 归属检查收紧为 `$PROJECT_DIR/`* 前缀

### Kept（v2.1 主线保留，fork 中缺失的部分）
- SKILL.md 中文版（🚢 品牌定位语、命名规范节、铁律体系、三端记忆协议）——fork 的英文重写未采用，仅增补三段式工作流
- 内置档案 project-a/project-compose、records/ 台账、evidence/ 证据、plans/（fork 为纯分发骨架已剥离）
- 健康甄别延长观察（fork 实际已保留，此前审查误判为移除——BSD grep `\|` 陷阱再次自伤，已用 grep -E 复核）
- 多机滚动 deploy_one_target / DEPLOY_TARGETS（同上，fork 已保留）
- project-a 功能标记迁至 `scripts/feature-markers-project-a.txt`（通用 `feature-markers.txt` 改为空模板，通用技能不内置业务标记）

### Fixed
- v2.1 precheck banner 全角括号（fork 已修，随合并入版）

### Added（多服务器 / 多环境扩展，用户裁定"3、4、5 都需要支持"）
- **健康检查失败甄别 + 延长观察**：首轮探活失败且服务进程仍在运行（compose-build 查 `compose ps`、container-sync 查 `docker inspect`）→ 判定为疑似启动预热（容器重建后会话恢复等初始化超窗，实录中 ~1 分钟才就绪，30s 窗口误判失败）→ 自动延长观察 60s（12×5s）；延长后通过 = 发版成功（台账备注记"预热延长观察通过"）；延长后仍失败或进程已退出 = 真故障 → 走回滚
- **探活窗口档案化**：`DEPLOY_HEALTH_RETRIES`/`DEPLOY_HEALTH_INTERVAL`（默认 10×3s=30s），预热常态化偏长的项目可直接调大
- **铁律 6 修订（回滚纪律细化）**：健康检查失败先甄别再回滚——脚本甄别自动放行"预热延长观察通过"；"疑似预热超窗但实际健康"场景 agent 只读诊断可以做，但"不回滚、转验收"必须用户明确同意，确认原文记台账；堵住两个漏洞：盲目回滚（撤掉正常代码）与以"先诊断"为由跳过回滚纪律
- 04-health.md 失败处置改两路分流（真故障/疑似预热超窗），Agent 检查点同步

### Added（多服务器 / 多环境扩展，2026-11-03 用户裁定"3、4、5 都需要支持"）

> 注：上小节"健康检查失败甄别"与本节同属 2.1.0，2026-11-03 同日两次迭代定版。

- **process 发布模式（裸进程主机）**：rsync 源码到 RSYNC_DEST（compose 式排除，.env 永不触碰）→ 执行档案 `DEPLOY_RELOAD_CMD` 重载服务（systemd/pm2）→ host curl 健康检查；失败日志提示 journalctl；回滚时 src 型备份按 `DEPLOY_MODE==process` 自动走"恢复+重载"分支
### Docs（2026-11-04，project-b 接入审计沉淀）
- **`references/config-schema.md` 归化为中文并新增"Bind mount 与运行时数据"接入必查项**（project-b 事故教训）：运行时数据目录位于 RSYNC_DEST 之内且本地缺失时，`rsync --delete` 会删生产数据；接入 checklist 五步（列 volumes → 判定位置 → 移出或确认排除覆盖 → precheck 干跑验证 → 写入项目文档与发版纪律）；SKILL.md 接入段同步强化提示

### Docs（2026-11-04 11:45，project-b 首次正式发布实录优化）
- **SKILL.md 铁律 1 补 EXPECT_DIFFS 路径基准**：相对 LOCAL_APP_DIR（=precheck 差异清单原样路径），非 git 仓库根路径——两者常不同（project-b 嵌套结构 git 内 `app/app/api/auth.py` = 清单 `app/api/auth.py`），从 precheck 输出直接复制勿从 git status 换算；且必须在 gateo-plan 时传入（进 manifest 指纹），非 apply 时
- **01-preflight.md 新增"归属判定的标准手法"**（对方 agent 实战手法沉淀）：ssh 抓云端文件与本地 diff 比对特征 → 结论必须落盘（档案未决事项更新 + 台账备注），判定不留痕=没判；判定后才允许 plan
- **01-preflight.md 新增"多会话并行修改（常态，非事故）"节**：其他会话进行中的差异不纳入本次 EXPECT_DIFFS（发半成品上生产）
- project-b 首次正式发版成功（计划 GTO-70005e6205a39a0b00b9，auth.py 登录页文案上线，档案未决事项已闭环，git 基线 8a56d38）

## [2.1.0] - 2026-11-03

### Added（多服务器 / 多环境扩展 + 健康甄别，2026-11-03 两次迭代定版）

- **多机滚动发布 DEPLOY_TARGETS**（仅 container-sync/process）：空格分隔目标列表，deploy-backend 逐台 备份→覆盖前校验→发布→重启→健康检查（`deploy_one_target()` 封装，fail-fast，失败机给出单台回滚命令）；precheck 同步支持逐台预检，任一台清单外差异即整体阻塞
- **凭据集中存档**（用户提议，安全收口）：服务器 IP/SSH 密钥只写 `~/.gateo/credentials.sh`（chmod 600，`.gitignore` 排除，永不入库/入对话/入台账）；档案只引用 `CRED_<项目>_SERVER/SSH_KEY` 变量名；4 个脚本清除全部硬编码默认值，SERVER 缺失 exit 2 并提示检查凭据文件
- **多环境标注 GATEO_ENV**（prod/staging/dev）：进 banner/台账/证据，prod 触发生产警示行
- `profiles/template.sh` 补齐：GATEO_ENV / GATEO_CRED_FILE 凭据引用块 / DEPLOY_RELOAD_CMD / DEPLOY_TARGETS 字段说明

### Fixed
- precheck banner 全角括号拼在引号外（v2.0 重写残留）

## [2.0.0] - 2026-11-03

> gate-ops 更名后的首个定版：闸门驱动的发版运维（流程为路、闸门为门、证据为痕）。

### Added（2.0.0 定版内容）
- **品牌统一**：VERSION 文件（2.0.0，语义化版本）；全部脚本统一 `🚢 gate-ops · <组件> v<版本>` banner（deploy 调 precheck 时 GATEO_QUIET=1 静音）；SKILL.md 新增"命名规范"节（gate-ops / gateo_ / gateo- / 四大目录 / 🚢 识别符约定）；台账与总目录标题带 🚢

### Added
- **证据中心 evidence/ + 发版总目录（用户裁定，多项目追踪闭环）**：①`evidence/<项目>/<日期>_<TS>_<目标>/` 集中存档每次发版的全套证据——`deploy-output.txt`（脚本全程输出留档，`DEPLOY_EVIDENCE_DIR` 环境变量即开）、`acceptance-report.md`（验收报告**例行发版也生成**，不再只有大版本）、E2E 截图；②台账加"证据"列（相对路径双向可查）；③`scripts/build-index.sh` 聚合 records/*.md 生成 `records/_index.md` 总目录（跨项目全局索引，时间倒序，"勿手改"自动生成页）；④追踪链：总目录 → 项目台账 → 证据目录。开发时实测踩中 mac-traps #1（$var+全角括号），按自家清单即修
- **specs/ 更名 plans/（用户裁定弃用外来命名）**：目录 specs/ → plans/，roadmap-spec.md → roadmap-plan.md，release-spec → release-plan，全库引用同步；CHANGELOG 历史条目保留旧称并加注说明
- **浏览器端到端验收（browser E2E）内置为档案级配置**（2026-11-03 用户裁定）：新增 `references/browser-e2e.md`——①E2E_MODE 三档（auto=前端必做/后端影响页面才做，推荐缺省；always；off=文件级放行但台账如实记"部分验证"），登记在项目档案、**新项目接入时与用户确认**、随时改档案调整（支持 E2E_MODE 环境变量单次覆盖）；②三端浏览器能力前置检查（WorkBuddy 内置浏览器 / Claude·Codex playwright MCP）与安装路径；③缺失时不得静默跳过不得标 ✅，报告用户二选一；④E2E 流程：变更点真实页面验证 → 截图存 `{项目工作区}/deploy-evidence/`（路径进台账）→ 强刷复验 → 角色差异各验。05-acceptance 升为六步（E2E 为第 4 步），00-overview 两表同步
- **确认闸门无低风险豁免**（用户裁定）：纯前端/样式类/小改动发版同样走确认闸门，写入铁律 10 与 00-overview 闸门表
- **预检期望差异清单 DEPLOY_EXPECT_DIFFS**（2026-11-03 两次发布实录驱动）：例行发版的差异=待发文件本身，旧逻辑一律阻塞 → FORCE=1 被常态化（15:52 发版实证）。新增声明式模式：确认闸门确认的差异清单传入 `DEPLOY_EXPECT_DIFFS`，precheck 校验"实际差异 ⊆ 期望清单"放行；清单外差异仍阻塞。FORCE=1 回归"仅用户明确授权的异常场景"，且台账备注必须留痕原因与确认人
- **确认闸门模板修正**：原模板要求确认消息含"备份文件名"，但备份在确认通过后才生成（agent 只能编造）→ 第 3 要素改为"备份机制声明"，具体文件名发版后回填台账
- **前端 SPA 最低验收标准**（05-acceptance）：必须核对 index.html 引用的 chunk 哈希 == 本次构建产物——"新文件在云端"≠"页面会加载它"（旧 index.html/浏览器缓存场景，16:08 列布局发布实录只验了文件存在）；视觉类变更须用户真机确认或截图比对，"样式类已包含"不算视觉验收
- **备份真实性三重校验（用户提议落地）**：备份时每份 tar 生成两个真实性凭据——`.md5` 边车（备份文件自身 md5，`md5sum -c --status` 复核防截断/篡改）+ `.dirfp` 现场指纹（`find -print0|sort -z|xargs -0 md5sum|md5sum`，覆盖前重算比对，不一致 = 备份后现场被并发写入/热修 → 终止重新备份）；覆盖前校验升级为：锁复核 + 归档全量可读（tar -tzf 读完整流）+ md5 复核 + 现场指纹比对，缺一即终止。备份 md5 打印进发版日志。本地冒烟 4 场景全过（归档+md5✔/现场未动✔/现场被改拦截✔/备份篡改拦截✔）。容器内备份不做现场指纹（容器不保证有 md5sum），归档级校验覆盖
- **发版前用户确认闸门**（铁律 10 + 03-release 第 0 步 + 00-overview 闸门表）：每次发版执行覆盖动作前，agent 必须向用户发出确认提醒（四要素：目标/将覆盖的云端资产/备份文件名/发布模式）并等明确同意——"要发版"是意图，确认的是范围（2026-11-03 另一会话实录中"确认发版后端（覆盖云端 h5/routes.py）吗？"确认框模式固化）。验收写生产库前同样确认；唯一豁免 = health 失败的自动回滚（紧急场景不设闸门）
- **阶段产物与日志总表**（00-overview）：八阶段每阶段的完成产物 → 落盘位置三级映射（T1 台账列 / T2 宿主会话日志 / T3 specs/），"产物只在脚本 stdout 里"不算完成；附"任何时刻能回答发版走到哪了"的可答性检查
- **发版锁**：新增 `scripts/_lock.sh`（mkdir 原子锁 + 30 分钟陈旧锁自动回收 + EXIT trap 自动释放），deploy-frontend/deploy-backend 发版前强制取锁，拒绝多 agent 会话并发发版——单写者原则从"口头规则"升级为技术保障（2026-11-03 两会话一小时内先后发版同一项目的实录驱动）。锁脚本必须以 bash 运行：zsh 对函数体内 EXIT trap 在函数返回时即触发，会导致锁提前释放（已实测复现，入 references/mac-traps.md）
- **脚本结尾自动打印台账行**：deploy 脚本成功后输出填好时间/目标/结果/备份文件/健康检查的 markdown 台账行（验收/agent/备注三列留空），消除"发完忘了写台账"失败模式（2026-11-03 另一会话发版漏写 records/project-a.md 实录驱动）
- **references/mac-traps.md**：macOS/bash 3.2 环境陷阱集中清单（多字节变量花括号、BSD grep `\|`、pipefail+grep -q 竞态、tar mtime 携带、BSD/GNU stat 差异、zsh EXIT trap 语义、v3 restart 回归复盘）
- **生产数据验收纪律**（lifecycle/05-acceptance.md）：先取 before 值再改 → 清理不得依赖假设路由（405≠成功）→ 无法安全清理选 skip-path → 恢复失败必须告警（2026-11-03 验收实录教训）
- **SKILL.md 快速开始加 SSH 连通性自检**：发版前 5 秒确认 key/服务器/权限，避免"Permission denied 后全盘搜密钥"的时间黑洞（另一会话实录）
- **首个 compose 型项目接入：project-compose**（AI 内容型项目）：profiles/project-compose.sh（DEPLOY_MODE=compose-build，RSYNC_DEST 锁定 app/ 纯源码子树，data/、data-dir/、.env 隔离在外，HEALTH_URL=localhost:5002/api/health 实测 200）；本地基线 prod-sync-20261103（241 文件，云端→本位拉取，app.js md5 一致）；只读预检通过（退出码 0）。教训入档：compose 档案必须显式登记 CLOUD_APP（预检对比目标），否则回落 project-a 默认产生虚假差异（2026-11-03）
- **rsync 排除增强**：compose 模式与 precheck backend 增加 `*.bak_*`/`*.bak`/`.git`/`node_modules` 排除——保护服务器侧历史补丁备份不被 --delete 清除（2026-11-03）
- **发布方式强制登记**：凡通过档案发版的项目，档案必须显式声明 `DEPLOY_MODE`（container-sync/compose-build/custom），未声明即拒绝发版（退出码 2）——发布方式是项目固有属性，禁止静默继承缺省值；`profiles/project-a.sh` 已补显式声明；SKILL.md 接入流程将"确认并登记发布方式"列为第一步（2026-11-03）
- **多发布模式 v3**（roadmap A）：`DEPLOY_MODE` 三模式——`container-sync`（缺省，与 v2 逐字节等价）/ `compose-build`（rsync 源码→compose up -d --build，备份=源码目录+镜像 ID 清单，回滚=源码恢复+compose 重建）/ `custom`（服务器执行 DEPLOY_CUSTOM_CMD 万能兜底）；健康检查按模式适配（容器内 python3 / host curl / HEALTH_CMD 自定义）；rollback.sh 按备份文件名自动判型（backend_app_bak_*=容器直灌 / backend_src_bak_*=compose 型）；compose 模式硬性安全约束：RSYNC_DEST 必须在 PROJECT_DIR 之下且为纯源码子目录（防 --delete 删运行时数据），.env 永不覆盖
- lifecycle/ 八阶段生命周期手册（preflight/backup/release/health/acceptance/rollback/ledger/memory）+ 00-overview 状态机；acceptance 验收闭环为 memory 硬闸门（2026-11-03）
- 九模式发布全景权威参照表（lifecycle/03-release.md）：static、container-sync（已实现）+ compose-build、custom（实施中）+ process、git-archive、git-pull、ci-trigger、serverless（预留）+ n8n 两层兼容说明（2026-11-03）
- specs/_meta/roadmap-spec.md：升级路线规格（A 多模式 / C 验证链 / B 预留 / D 专家包）+ 5 条不变量（2026-11-03）
- specs/ 目录（大版本 release-spec 与验收报告存档）

### Changed
- 台账 records/<项目>.md 表结构增加"验收"列（2026-11-03）
- lifecycle/03-release.md 与 roadmap-spec 同步九模式全景与状态标注（2026-11-03）

### Fixed
- **P0 回归：v3 重写丢失 container-sync 模式 docker restart 步骤**——代码同步进容器但旧进程仍跑旧码，"发版成功"是假象（15:06 发版验收 405 抓出：/topics/batch-publish 落盘未生效，StartedAt 早于落盘时间）→ 恢复第 2.5 步显式 restart + 注释警示（commit e7ea6cf）
- precheck frontend 分支 `DIST="$2"` 缺参时 set -u 直接 unbound 崩溃（连用法都打不出）→ 改 `${2:-}`/`${3:-}` + 用法提示（另一会话实录："errored on $2: unbound variable"）
- **守卫缺失静默跳过**：PRECHECK 定位失败时 deploy 脚本静默跳过预检 → 改硬阻塞（exit 2，FORCE=1 可显式越过）；发版锁缺失同样硬阻塞——"守卫机制静默不存在"与"检查失败"同类，都不允许假通过
- precheck backend 差异输出补"单写者检查"提示行：差异可能来自并行会话，先确认归属再决定动作

## [1.0.0] - 2026-11-03

### Added
- 四脚本：deploy-frontend.sh / deploy-backend.sh / precheck-deploy.sh / rollback.sh（P0/P1 审计修复版：构建失败拦截、备份失败即停、健康检查重试+失败报错、rsync --delete 全量同步、发版前云端双备份）
- 配置档案机制：profiles/project-a.sh + template.sh（DEPLOY_CONF > PROJECT > DEPLOY_* > 内置默认）
- 跨 agent 发版台账 records/<项目>.md（WorkBuddy/Claude/Codex 共读真源）
- 记忆写入三层协议（台账 → 宿主会话日志 → 项目长期记忆 + 功能标记）
- Agent 行为铁律（禁自行 FORCE=1、health 失败先回滚、禁单文件管道部署后端）
- 三端软链安装：~/.workbuddy/skills、~/.claude/skills、~/.codex/skills → ~/agent-skills/gate-ops

### Fixed
- P0：precheck 网络/SSH 失败被吞成"检查通过"→ 检查自身失败=阻塞
- P0：backend 健康检查失败仍报成功 → 重试 10 次失败即退出 1 + 容器日志 + 回滚指引
- P0：frontend 构建失败被管道吞掉 → pipefail + dist 非空校验
- P1：backend 无云端备份 → 双备份 + 保留 20 份
- P1：tar 覆盖式"假全量" → rsync --delete + 容器先清后灌
- 技能布局：profiles/ 档案解析只查 $SCRIPT_DIR/profiles → 增加上级目录候选（C 验证链 C1 发现）
- 兼容性：bash 3.2 非 UTF-8 locale 下 `$var` 紧跟全角字符被解析为超长变量名（set -u 报 unbound）→ 7 处变量加花括号（C1 发现）
- 隐蔽竞态：`cat|grep -q` 管道在 pipefail 下，grep 提前退出致 cat 收 SIGPIPE(141)，匹配成功被误判"缺失"→ precheck 前端标记检查改 grep 直读文件列表（C1 发现，曾致 C1 误阻塞与 SSO 源码误判）
- **实战拦截复盘**：C1 两次被 precheck 阻塞，最终查明为上述竞态 bug 而非源码缺失——本地 admin 源码完整，全量 md5 45/45 与云端一致

### Verified
- precheck backend 真实连服干跑通过（云端与本地一致）
- rollback.sh list 真实连服通过
- WorkBuddy 技能管理接口确认技能已识别启用
