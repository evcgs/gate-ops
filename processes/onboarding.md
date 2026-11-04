# 接入剧本（onboarding：新系统接入 / 已接入系统复核）

> 五阶段规程。终点 = 档案 + 标记 + 台账接入行 + 审计回执；**接入完成 ≠ 自动发版**。
> 复核场景（系统已接入）：只补缺口 + 自验 + 出回执，流程同五阶段但不重写已有产物。

## 阶段 1 · 部署事实收集

- 读用户提供的部署档案/回执；无则现场收集（服务器 compose/Dockerfile、容器状态、健康端点、目录结构、本地源码位置）
- **bind mount 数据安全预判**：列出全部持久化路径，判定是否在 RSYNC_DEST/BUILD_SRC 之内（细节见 `references/config-schema.md` 接入 checklist）

## 阶段 2 · P0 数据安全检查（project-b 事故教训，不可跳过）

按 config-schema 五步 checklist 走完：列持久化路径 → 逐个判定 → 处置（移出 / 确认排除覆盖）→ precheck 干跑验证数据目录不在差异清单 → 写进项目文档。
改过共享脚本必须重跑 `tests/run.sh`（11 项全过）。

## 阶段 3 · 自主接入产物

- 凭据登记：`~/.gateo/credentials.sh` 追加 `CRED_<项目>_*`（复用同机变量，无明文；**验证用 `grep -c` 查存在性，严禁 echo 变量值**）
- 本地源码 git 管理：`git init` + 基线 commit（多会话归属前提；secrets/cache 排除）
- 档案 `profiles/<项目>.sh`（`DEPLOY_MODE`/`GATEO_ENV`/`E2E_MODE` 显式声明）+ 标记 `scripts/feature-markers-<项目>.txt`（真实 UI/API 字符串）+ 人读档案 `profiles/<项目>-deploy-notes.md` + 台账 `records/<项目>.md` 接入行
- **收尾纪律**：`git add` 仅限本系统文件；提交后必跑 `git status` 确认无本系统残留文件（两次实录教训：声称已提交但漏文件）

## 阶段 4 · 四项自验

1. `gateo-doctor.sh` PASS（0 警告）
2. `tests/run.sh` 11/11
3. 真实 `precheck-deploy.sh backend`：连通 + 差异清单**逐条判定归属**（方向口诀见铁律 2）
4. `gateo-plan.sh backend`：只读生成计划（未 apply）

## 阶段 5 · 审计回执

回执第一行 = 身份声明（`本次系统=<X> · 身份依据=用户消息指定/用户确认`）；含五段：字段清单 / bind mount 结论 / 四项自验 / 差异归属 / 遗留待办；全程脱敏。
