# 项目配置契约（接入必读）

新项目接入、变更发布模式、或排查配置优先级问题时阅读本参考。

## 配置解析顺序（优先级从高到低）

1. 本次调用传入的运行时 `DEPLOY_*` 环境变量
2. `DEPLOY_CONF=/绝对路径/profile.sh`
3. `PROJECT=<名>`，选取 `profiles/<名>.sh`
4. 下文记载的显式安全默认

档案必须使用默认保留形式 `VALUE="${DEPLOY_VALUE:-<档案值>}"`，不得覆盖运行时变量。**没有**任何应用专属的路径/主机/容器/URL 内置默认。

档案是受信任的可执行配置。只允许赋值语句：可以 source 凭据文件，但不得连接主机、改动文件、启动服务或打印密钥。**每次改档案后必须跑 `bash scripts/gateo-doctor.sh`。**

## 凭据与 SSH

主机身份与私钥路径只存 `${GATEO_CRED_FILE:-$HOME/.gateo/credentials.sh}`（权限 600）。档案只引用凭据变量名，不含凭据字面值。

SSH 主机校验强制启用。`known_hosts` 通过可信渠道的指纹预先登记；`StrictHostKeyChecking=no` 与 `UserKnownHostsFile=/dev/null` 是无效的生产配置。

## 通用必填字段

| 字段 | 取值 / 不变量 |
|---|---|
| `DEPLOY_MODE` | `container-sync` / `compose-build` / `process` / `custom` |
| `GATEO_ENV` | `prod` / `staging` / `dev` |
| `E2E_MODE` | `auto` / `always` / `off` |
| `SERVER` 或 `DEPLOY_TARGETS` | 至少一个目标；输出中一律脱敏 |
| `BACKUP_DIR` | 云端绝对路径，绝不允许可为 `/` |
| `CLOUD_APP` | 云端后端源码目录（backend 预检 rsync 干跑对比目标，无内置默认） |
| `LOCAL_APP_DIR` | 存在的本地源码目录 |
| `READINESS_URL`/`READINESS_CMD` 或 `HEALTH_URL`/`HEALTH_CMD` | 发布闸门；HTTP 探活必须拒绝 4xx/5xx |

## 模式专属字段

| 模式 | 必填字段 | 安全不变量 |
|---|---|---|
| `container-sync` | `CONTAINER`、`BUILD_SRC` | 构建源与容器目标都可版本化/完整恢复 |
| `compose-build` | `PROJECT_DIR`、`RSYNC_DEST` | `RSYNC_DEST` 严格位于 `PROJECT_DIR` 之下，且**不含运行时数据**（见下方 bind mount 检查项） |
| `process` | `RSYNC_DEST`、`DEPLOY_RELOAD_CMD` | 目标目录纯代码；重载命令幂等 |
| `custom` | `PROJECT_DIR`、`DEPLOY_CUSTOM_CMD` | 自定义命令须自行实现备份、执行、就绪、精确回滚四项契约；可选 `BACKUP_TARGETS`（按变更对象备份）+ `VERSION_CHECK_CMD`/`VERSION_EXPECT`（版本校验） |

所有云端路径必须是非 `/` 的绝对路径。参与 `--delete` 同步的目录**绝不能含数据库、上传文件、生成状态、密钥或用户数据**。

## 服务器运行时升级（runtime-upgrade）字段（v3.5.0 起）

| 字段 | 类型 | 说明 |
|---|---|---|
| `BACKUP_TARGETS` | 空格分隔绝对路径 | 备份对象（按变更对象）；设了则覆盖 RSYNC_DEST 的备份源 |
| `VERSION_CHECK_CMD` | 命令 | 输出实际版本号（如 `php -r 'echo PHP_VERSION;'`） |
| `VERSION_EXPECT` | 字符串 | 期望版本号；与 VERSION_CHECK_CMD 输出不一致则判失败 |

三者均为可选：空值 = 不启用（对既有发版零影响）。用于 PHP/语言/软件包源码重编译场景，配合 `processes/runtime-upgrade.md`。

## ⚠️ 本地源码必须 git 管理（多会话协作前提，接入必查项）

**背景（2026-11-04，project-b）**：多会话并行修改同一项目源码是常态（各自领任务）。本地源码无 git 时，"这个差异是谁改的"无法判定——预检只能报出文件清单，报不出归属；并行修改互相覆盖时无痕可查。**git worktree/合并属于源码版本控制的职责，gate-ops（发版闸门）不做也不应做**——但把源码纳入 git 是接入的前置条件：

1. **接入时检查**：`LOCAL_APP_DIR`/`PROJECT_ROOT` 必须在 git 仓库内；无则先 `git init && git add -A && git commit -m "baseline"` 定格基线，再开始接入
2. **多会话纪律**：并行修改允许；**每个会话完成一段工作即 commit**（信息写明改了什么）——发版前 `git diff` / `git log` 即可判定差异归属，预检报出的清单逐条对应到提交
3. **发版闸门衔接**：归属不明的差异（未提交且不知来源）按 `01-preflight.md` 失败处置处理：判定前不得发版，判定结论写进台账
4. **不适用豁免**：极小工具类项目可豁免，但预检差异全部依赖人工归属，风险自担

## ⚠️ Bind mount 与运行时数据（接入必查项，project-b 事故教训）

**事故背景（2026-11-04，project-b）**：运行时数据 `data/`（生产 SQLite + API 密钥文件）经 compose volumes bind mount 位于 `RSYNC_DEST=/www/wwwroot/project-b/app` **之内**，且本地源码恰好**没有** `data/` 目录——标准 compose-build 的 `rsync --delete` 首次发版就会**把生产数据库整目录删除**。"RSYNC_DEST 看起来是纯源码"是错觉：纯不纯不由目录名决定，由 compose 的 volumes 挂载决定。

**接入 checklist（compose-build / process 模式必做）**：

1. **列出全部持久化路径**：读服务器上的 `docker-compose.yml` volumes（或部署结构说明），列出每一个 bind mount 与持久化目录（数据库、上传、密钥文件、缓存、生成产物）
2. **逐个判定位置**：任一运行时数据路径位于 `RSYNC_DEST`（container-sync 则为 `BUILD_SRC` 同步范围）**之内** → 按优先级处置：
   - ① **首选移出**：把数据目录挪到 `RSYNC_DEST` 之外（如 `/www/wwwroot/<项目>/data`），compose volumes 同步改路径
   - ② 无法移出时确认被排除覆盖：gate-ops 已全局排除 `data/`（`deploy-backend.sh` 的 compose-build/process 两处 + `precheck-deploy.sh` 干跑）；若数据目录名不是 `data/`，必须在档案中追加针对性 exclude 并提请改脚本
   - ③ 本地**恰好存在**同名目录也不安全——那会把本地内容覆盖到云端（密钥文件尤其致命）
3. **验证**：改完档案跑 `precheck-deploy.sh backend` 干跑，**确认数据目录不出现在差异清单**；改过脚本则必须重跑 `bash tests/run.sh`（11 项全过）
4. **写进项目文档**：把数据目录位置、排除方式、单独备份策略（gate-ops 源码备份不含运行时数据，需项目自有备份互补）记入项目部署档案
5. **发版纪律**：确认排除规则仍在是每次 project-b 类项目发版前的固定动作（脚本被改动后尤甚）；严禁绕过 gate-ops 直接 `docker compose` 手动发版

**历史 md5 兼容**：v3.1 起备份边车为 sha256；更早的 `.md5` 边车在回滚时仍被接受。

## 内容级变更与数据备份（不发版的数据操作，v3.1.1 起）

**适用范围**：数据库内容变更、批量生成（衍生题/文案/画像）、种子重生成、数据修复、批量删除等**不改代码**的操作。此类操作**不走 gateo-plan 闸门**（闸门管代码发版），但必须按本节留痕——无备份不留痕的内容变更视同事故隐患。

**数据备份命名规范（品牌标志）**：

```
gateo_data_<project>_<desc>_<YYYYMMDD_HHMMSS>.<ext>
示例：gateo_data_project-a_db_20261104_143736.db
      gateo_data_project-b_data_20261105_090000.tar.gz   （目录类数据打包）
```

- `gateo_data_` 前缀三重作用：①品牌统一（与 `gateo_backend_src_bak_*` 代码备份同族）；②可被 `ls`/`find`/台账按 glob 一键检索（`gateo_data_*`）；③与项目自有备份、临时导出文件明确区分，防误删。
- `<desc>` 简短标注数据域（`db`/`data`/`uploads`/`kv`…），时间戳精确到秒。
- 存放位置跟随项目习惯（数据同目录或 `BACKUP_DIR`），**写进该项目部署档案**；备份先于变更执行（硬性，不可"先改后补"）。
- 内容级备份与 gate-ops 源码备份互补：源码备份永远不含运行时数据，数据变更的回滚点只在本节规范的备份文件里。

**台账行约定（兼容现有 9 列结构，不新增列）**：

| 列 | 内容级变更的写法 |
|---|---|
| 目标 | `data:<一句话描述>`（如 `data:内容库衍生题批量发布`） |
| 结果 | 影响范围量化（如 `内容库 274→484 道，210/210 成功`） |
| 验收 | 等价验证证据（如 `AI 预审 210/210 + 分类覆盖矩阵`） |
| 备份文件 | `gateo_data_*` 备份名（规范生效前的历史备份名如实记录，不追溯改名） |
| 健康检查 | 数据域复核（如 `C10 关卡 4 题上线`），或 `-（非服务变更）` |

**回滚要点**：内容回滚前先做**引用检查**——确认下游表/记录对被变更数据的引用为 0 再动手（如删除每日计划前先查 `引用记录表` 引用计数）。先备份、再检查、后删除，顺序不可倒。

**下游联动检查**：批量内容变更可能使已生成的下游产物过期（计划、缓存、索引、统计快照）。变更完成后必须核对下游物是否需要刷新并写入台账备注（案例：project-a 每日计划只在当天无计划时生成，内容发布后不自动刷新，需人工验证并重置——该缺陷修复前为固定检查项）。

## 计划与审批

计划命令产出计划 ID 与不可变 manifest：项目、环境、目标、模式、期望差异、源码指纹、备份名、有效期。执行要求用户确认后的**确切计划 ID**。manifest 被编辑、源码变化、配置变化、或超过有效期，计划即失效，必须重新生成计划并重新确认。

`FORCE=1` 不绕过审批、备份校验、路径守卫、主机校验、锁或就绪闸门。仅为历史兼容保留时，只能用于"用户明确授权的、已被如实报告的预检例外"。

## 多目标策略

`DEPLOY_TARGETS` 有序。当前实现逐台发布且就绪通过才推进。手动金丝雀：先创建并确认只含金丝雀目标的计划，完成验收后，再为其余目标创建第二个计划。失败时：

- 立即停止，不触碰下一台；
- 报告各台处于旧版/新版/失败/已回滚的哪种状态；
- 全部目标报告同一发布结果之前，不得宣称集群成功。
