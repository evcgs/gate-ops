# 🚢 gate-ops

**闸门驱动的 AI Agent 发版运维技能。** _No gate, no ship（无闸门，不启航）。_

> [!NOTE]
> English docs: [README.md](README.md)

AI 编码 Agent 写代码很强，把代码发砸也"很强"：`rsync --delete` 删掉生产库、覆盖云端热修、跳过备份、健康检查失败却宣布成功。**gate-ops** 把运维纪律做成 Agent **无法绕过的硬闸门**——每一条规则都长自一次真实生产事故。

---

## 为什么是闸门，而不是提示词

靠提示词约束（"部署时请小心"）恰恰在关键时刻失效。gate-ops 把每个教训固化为**可执行的闸门**：

| 真实事故 | 产出的闸门 |
|---|---|
| `rsync --delete` 把同步目标内的生产 SQLite 库整目录删除 | bind-mount 数据安全 checklist + 全局排除 + 发版前实测验证 |
| Agent 宣布"部署成功"而旧进程仍在运行 | 就绪探活（`READINESS_URL/CMD`）三层语义：liveness / readiness / acceptance；HTTP 4xx/5xx = 失败 |
| 健康检查 30 秒报失败，应用其实还在预热（约 60 秒） | 失败甄别：进程存活 → 自动延长观察 60 秒再谈回滚 |
| 计划在确认与执行之间被篡改 | 不可变计划 manifest：配置指纹 + 源码指纹 SHA-256 + 有效期 + 确切计划 ID 确认 |
| 两个会话并发发版 | nonce 发版锁 + 心跳 + 主机校验 |
| 会话凭"历史记忆"接错了系统 | 身份锚定铁律（铁律 0）+ 回执第一行强制身份声明 |
| 回执声称"已提交"而文件漏在工作区 | 跨产物一致性体检（`gateo-doctor --deep`） |

## 核心机制

- **三段式发版（硬闸门）**：`gateo-plan`（只读计划：配置指纹、源码指纹、变更摘要、计划 ID、30 分钟有效期）→ **用户确认计划 ID** → `gateo-apply`（校验未被篡改后才执行）。直接跑部署脚本会被**设计性拒绝**。
- **预检 + 期望差异**：只读校验和干跑；差异清单直接嵌进计划摘要——**确认什么就覆盖什么**；清单外差异阻断发版。
- **精确快照回滚**：恢复前 sha256/md5 边车校验；先清空再解包（无 tar 覆盖残留）；回滚不需要计划闸门（真故障越快越好）。
- **跨产物一致性体检**：`gateo-doctor --deep` 校验档案、功能标记、台账、人读档案、审计回执相互一致**且与 git 现实一致**。
- **多项目档案**：一个仓库运维同机多系统，端口/容器/目录强隔离。
- **脱敏凭据**：服务器 IP 与密钥只存 `~/.gateo/credentials.sh`（600，永不入库）；回执与日志只见 `<server>`。

## 七个过程，独立入口

借鉴 spec-kit 的 process-presets：每个过程有独立入口、闸门与**终点**；跨越过程边界必须由用户显式指令发起。

| 过程 | 用途 | 终点 |
|---|---|---|
| `release`（core） | 闸门链发版 | 验收通过 + 台账行 + 记忆写入 |
| `rollback` | 真故障恢复 | 恢复 + 台账行 |
| `onboarding` | 新系统接入 / 复核 | 档案 + 标记 + 台账行 + 审计回执 |
| `data-change` | 数据库内容变更 / 批量生成 | `gateo_data_*` 备份 + 台账行 |
| `audit` | 只读审计 / 复核 | 回执——**绝不**自动转入发版 |
| `hotfix` | 线上 bug：根因评估 → 范围化修复 → 验证留痕 | 根因 + 修复 + 回归检查 |
| `publish` | 对外发布 / 开源发布 / 公众号发布（脱敏） | 发布后复审通过 + 台账行 |

详见 [`processes/README.md`](processes/README.md)。

## 快速开始

```bash
# 1. 安装（软链进 agent 的技能目录）
bash scripts/gateo-init.sh --integration workbuddy   # 或 claude / codex / generic / dsh
bash scripts/gateo-init.sh --list                    # 查看全部集成

# 2. 接入第一个项目（五阶段引导）
cp profiles/template.sh profiles/myapp.sh            # 填 DEPLOY_MODE、GATEO_ENV、E2E_MODE…
# 登记凭据（一次）：
mkdir -p ~/.gateo && chmod 700 ~/.gateo
cat > ~/.gateo/credentials.sh <<'EOF'
CRED_MYAPP_SERVER="user@your-server"
CRED_MYAPP_SSH_KEY="$HOME/.ssh/your_key"
EOF
chmod 600 ~/.gateo/credentials.sh

# 3. 发版（唯一受支持路径）
PROJECT=myapp bash scripts/gateo-plan.sh backend     # 只读计划 + 计划 ID + 差异清单
# → 与用户确认计划 ID →
PROJECT=myapp bash scripts/gateo-apply.sh <计划文件> <计划ID>

# 4. 离线体检
bash scripts/gateo-doctor.sh --deep                  # 跨产物一致性审计
bash tests/run.sh                                    # 11 项行为测试
```

## 集成层

与 spec-kit `specify init` 同一哲学：**同一真源 + 每宿主一个薄适配**。安装即软链——升级一处，全端生效。

| 集成 | 宿主 | 状态 |
|---|---|---|
| `workbuddy` | WorkBuddy | ✅ |
| `claude` | Claude Code | ✅ |
| `codex` | Codex CLI | ✅（自动追加 AGENTS.md 指引） |
| `generic` | 任意 agent | ✅ 逃生门 |
| `dsh` | DeepSeek Harness | ✅ 代码级集成（证据闸门发版；见 integrations/dsh/） |

新增一个集成的成本被刻意压到最低——一个路径、一条可选的后置提示、一项自检。欢迎 PR；目标是对齐 spec-kit 的 38 个集成广度。

## 误操作场景库——威胁模型

在"一句话 Agent 操作"时代（"全部发布"、"你看下这个系统"），最大风险不再是手滑，而是**语义越界、静默毁数与留痕缺失**。gate-ops 把每类真实误操作整理为"场景 → 根因 → 闸门"条目：

| 类别 | 典型场景（全部真实发生） | 挡住它的闸门 |
|---|---|---|
| **A · 语义越界** | 讨论被当成发版授权；Agent 凭"历史记忆"推断目标系统；审计产出自动转成发版 | 计划 ID 是唯一发版授权；铁律 0 身份锚定；过程边界解耦 |
| **B · 数据毁灭** | `rsync --delete` 删生产库；服务器独有密钥被误删；无效备份就覆盖 | bind-mount checklist；实测排除项；覆盖前三重备份校验 |
| **C · 状态误判** | "部署成功"但旧进程在跑；30 秒健康窗口误杀预热中应用；把本地待发内容误读为云端热修 | 三层就绪语义；预热甄别（自动延长 60s）；方向判定只认内容证据、不认 mtime |
| **D · 留痕缺失** | 回执声称"已提交"但文件未跟踪；共享脚本改动不声明；凭据被 echo 进日志 | 台账强制行；提交后 `git status` 检查 + `gateo-doctor --deep`；凭据验证只 `grep -c` 永不 echo |
| **E · 并发冲突** | 两个会话同时发版；并行改源码归属不明 | nonce 发版锁；发版单写者 + apply 前归属判定 |

完整手册（含自检命令与一句话时代口诀）：**[references/misoperations.md](references/misoperations.md)**

## 与 spec-kit 的互补

spec-kit 管**代码之前**（意图 → 规格 → 计划 → 实现 → 收敛），gate-ops 管**代码之后**（预检 → 计划 → 确认 → 执行 → 验收 → 回滚）。共享同一哲学——结构化过程、产物链、用户确认闸门、证据留痕——且天然可串联：用 spec-kit 收敛规格，用 gate-ops 闸门交付。

## 仓库结构

```
gate-ops/
├── SKILL.md               # 入口：铁律、快速开始、过程解耦
├── lifecycle/             # 八阶段发版手册（core 过程）
├── processes/             # 六过程剧本 + 注册表
├── references/            # 配置契约、环境陷阱、浏览器 E2E
├── profiles/              # 项目档案（template + 示例）
├── records/               # 跨 agent 共享发版台账
├── scripts/               # gateo-plan / apply / precheck / rollback / doctor / init / tests
├── integrations/          # 宿主适配（workbuddy / claude / codex / generic / dsh）
├── tests/                 # 11 项行为测试（防篡改、有效期、脱敏、回滚…）
└── docs/                  # GitHub Pages 站点
```

## 参与贡献

最好的 PR 是**教训**：如果你踩了一次生产事故，请补上"能阻止它的那个闸门"（先写测试），并在教训表加一行。

## 许可

MIT。
