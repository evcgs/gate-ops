# Phase 3 · release（发布）

## 目标

按项目档案的模式，把本地代码变成远端运行中的服务，并取得远端验证。

## 前置条件

- backup 已完成，**回滚基准文件名已记录在案**
- preflight 已通过
- **用户确认闸门已通过**（见下方第 0 步）

## 操作手册

### 第 0 步 · 发版计划 + 用户确认闸门（v3.1 三段式硬闸门，不可跳过）

```bash
# 1) 生成发版计划（只读，永不部署；有效期默认 30 分钟）
PROJECT=<名> bash scripts/gateo-plan.sh backend           # 或 frontend admin|h5|all
```

2) 把计划摘要呈给用户确认并**等明确同意**（如"确认，你执行"）。确认消息四要素 + 计划 ID：

```markdown
确认发版后端吗？（计划 ID：<plan-id>，有效期 30 分钟）
- 目标：myapp-backend（container-sync）
- 将覆盖云端：routes.py、topics_service.py 等 3 个文件（= 期望发版清单）
- 备份：脚本将自动云端备份（sha256+现场指纹校验，无有效备份不覆盖），文件名发版后回填台账
回复确认后执行；想先看差异就回复"先不发版"。
```

3) 确认通过后执行计划——**计划 ID 就是用户同意的凭据**，apply 会校验"确认的 ID = 当前计划"，且计划生成后配置或源码任一方被改动即拒绝：

```bash
PROJECT=<名> bash scripts/gateo-apply.sh <计划文件路径> <计划ID>
# 例行发版把确认过的差异清单写进档案/环境 DEPLOY_EXPECT_DIFFS 后再 plan——
# 预检校验"实际差异 ⊆ 期望清单"放行，从此不需要 FORCE=1
```

- ⚠️ 计划过期（默认 30 分钟）或 fingerprint 不符 → 重新 plan、重新确认，**不得沿用旧确认**
- 直接跑 `deploy-backend.sh`/`deploy-frontend.sh` 会被硬拒绝（提示缺少发版计划）——这是设计；补走 plan→确认→apply，不要绕

唯一豁免：health 失败后的自动回滚（`04-health.md` / SKILL.md 铁律 6 已授权）。

### 第 1 步 · 执行发布（由 gateo-apply 内部转交）

```bash
# frontend（static 模式）：构建→预检→备份→tar 全量发布→远端 index.html 验证
# backend：预检→备份（sha256）→覆盖前三重校验→rsync 全量同步→重启/重载→readiness
# 均由 gateo-apply.sh 调起，无需手动执行 deploy 脚本
```

### 发布模式全景（DEPLOY_MODE，档案字段）★权威参照表

| 模式 | 状态 | 典型场景 | 发布动作 | 本方资产例子 |
|---|---|---|---|---|
| `static` | ✅ 已实现 | 前端静态站 | 构建 → tar/rsync 到 Nginx 目录 | project-a admin/h5 |
| `container-sync` | ✅ 已实现（backend 默认） | 容器常驻，代码直灌 | rsync 构建源 → 容器先清后灌 → restart | 销售培训系统 |
| `compose-build` | ✅ 已实现（v3） | compose 项目，改代码要重构建 | rsync 源码到 RSYNC_DEST → `cd PROJECT_DIR && $COMPOSE_CMD up -d --build` | 内容型项目、服务型系统、project-c |
| `custom` | ✅ 已实现（v3） | 万能兜底 | 服务器上执行档案 `DEPLOY_CUSTOM_CMD` | 兜底 |
| `process` | ✅ 已实现（v2.1） | 无容器，进程管理器托管 | rsync 源码到 RSYNC_DEST → 执行档案 `DEPLOY_RELOAD_CMD`（`pm2 reload` / `systemctl restart`） | 传统 Node/Python 主机 |
| `git-archive` | ⏸ 预留（roadmap B-1） | 服务器连不上 git（国内常态） | 本地 `git archive <tag> \| ssh tar xf`，tag 为版本基准可追溯 | 本服务器适合 |
| `git-pull` | ⏸ 预留 | 服务器能连 git 仓库 | `git fetch && git reset --hard <tag>` + build + restart | 团队 CI/CD 标准做法 |
| `ci-trigger` | ⏸ 预留 | GitHub Actions/GitLab CI/Jenkins | 只触发流水线 + 盯状态；回滚 = 重发上一 artifact | 未来接公司流水线 |
| `serverless` | ⏸ 预留 | 云函数/Vercel/SCF | 本地构建 → 云 CLI deploy | 小工具类 |

**n8n 兼容说明（两层拆分）**：宿主升级（n8n 本体）= compose-build 模式；工作流资产发布（workflow JSON）= git 版本化 + n8n API 导入（roadmap B-2 `n8n-workflow`），回滚 = 导回旧版 JSON。Dify/Coze 等工作流平台同此思路。

### 多机滚动发布（DEPLOY_TARGETS，v2.1）

- 档案设 `DEPLOY_TARGETS="root@ip1 root@ip2 ..."`（空格分隔，同集群同配置），**仅 container-sync / process 模式**可用
- 执行顺序：逐台 备份（含 md5/dirfp）→ 覆盖前校验 → 发布 → 重启/重载 → 健康检查；**任一台失败立即停止（fail-fast）**，已完成的机器保持新版本，失败机按脚本提示单独回滚
- 预检同样逐台跑（`DEPLOY_TARGETS` 存在时 precheck 自动循环）——集群不允许"部分机器会被覆盖坏代码"
- 每台服务器的 IP/密钥登记在 `~/.gateo/credentials.sh`（或档案 `GATEO_CRED_FILE` 指定的凭据文件），多机时凭据文件内定义多个 `CRED_*_SERVER` 变量，档案把变量拼进 `DEPLOY_TARGETS`
- 版本一致性：滚动完成后必须抽查**每一台**的健康检查输出（脚本已逐台打印），台账目标列记录全部目标

接入 compose 型项目（如内容型项目）在 A 实现前的临时做法：预检/备份/台账/记忆照常使用，发布动作由 agent 按该项目既定命令执行并在台账备注实际命令。

## 失败处置（按退出码分流）

| 退出码 | 含义 | 处置 |
|---|---|---|
| 1（构建失败） | 编译/打包错误 | 取构建日志尾部报给用户，**不重试**，等修码 |
| 1（预检未过） | 见 `01-preflight.md` | 走预检失败处置 |
| 1（备份失败） | 见 `02-backup.md` | 走备份失败处置 |
| 1（健康检查失败） | 见 `04-health.md` | **先 rollback 再排查** |
| 2 | 参数错误 | 修正调用 |

## 输出物

- 发布完成提示（含站点 URL / 构建源 / 容器路径）
- 远端验证结果（frontend：`index.html` 存在性校验）
- 本次发布**变更内容**线索（agent 应记录：本次发了什么功能/修了什么问题——这是 acceptance 阶段组织测试的输入）

## Agent 检查点

- [ ] **用户确认闸门已通过**（确认消息含四要素：目标/覆盖资产/备份/模式），确认原文已记入会话日志
- [ ] 严禁绕过脚本做单文件 cat 管道部署后端（历史事故教训）
- [ ] 记录"本次发布内容摘要"供 acceptance 使用
- [ ] 发布完成 ≠ 发版完成；必须继续 health → acceptance
