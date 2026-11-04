# 🚢 gate-ops 安装说明（v2.1.0）

闸门驱动的发版/回滚运维技能（No gate, no ship）。
主文件 `SKILL.md`，目录名 = 技能名，解压后放到对应 agent 的技能目录即可。

## 安装位置（按宿主 agent 选择）

| 宿主 | 技能目录 | 说明 |
|---|---|---|
| WorkBuddy | `~/.workbuddy/skills/gate-ops/` | 用户级，全项目可用 |
| Claude Code | `~/.claude/skills/gate-ops/` | 用户级，SKILL.md 自动发现 |
| Codex CLI | `~/.codex/skills/gate-ops/` | 与 Claude 同构；若你的 Codex 版本不自动发现 skills，在 `~/.codex/AGENTS.md` 加一行：`需要发版/回滚/部署时，先读 ~/.codex/skills/gate-ops/SKILL.md 并严格遵循` |

### 方式一：一键装配（推荐，v3.2.0 起，借鉴 spec-kit `specify init`）

在真源仓库内执行，软链即安装（多端共享同一真源，改一处全端生效），装完自动自检：

```bash
cd ~/user-home/agent-skills/gate-ops
bash scripts/gateo-init.sh --integration workbuddy   # 或 claude / codex
bash scripts/gateo-init.sh --integration generic /path/to/agent/skills/gate-ops  # 任意宿主
bash scripts/gateo-init.sh --list                    # 查看全部集成
```

### 方式二：zip 解压（分发包场景）

```bash
unzip gate-ops-vX.Y.Z.zip -d <上表对应目录的父目录>/
# 例（Codex）: unzip gate-ops-vX.Y.Z.zip -d ~/.codex/skills/
```

## 装完先跑这三条（只读，无副作用）

```bash
cd <技能目录>/gate-ops   # 或 skills/gate-ops，视解压层级
bash scripts/build-index.sh                              # 台账总目录聚合（验证脚本可执行）
PROJECT=project-a bash scripts/precheck-deploy.sh backend    # 预期 exit 2：无凭据文件的明确报错（见下）
PROJECT=project-a bash scripts/rollback.sh list              # 同上，验证报错路径
```

## ⚠️ 凭据机制（v2.1 安全设计，必读）

- 本包**不含任何服务器 IP / SSH 密钥**。内置档案（project-a / project-compose）引用
  `~/.gateo/credentials.sh`，该文件只存在于作者机器上
- 因此直接跑发版会得到明确报错并退出（exit 2）——这是**设计行为**，不是安装失败
- 要接你自己的服务器：
  1. `cp profiles/template.sh profiles/<你的项目>.sh` 并填写
  2. 创建凭据文件并登记：`mkdir -p ~/.gateo && chmod 700 ~/.gateo && cat > ~/.gateo/credentials.sh`：
     ```bash
     CRED_<你的项目>_SERVER="root@你的服务器"
     CRED_<你的项目>_SSH_KEY="$HOME/.ssh/你的私钥"
     ```
     `chmod 600 ~/.gateo/credentials.sh`（此文件永不入库、不入对话、不随包分发）
  3. `PROJECT=<你的项目> bash scripts/precheck-deploy.sh backend <本地源码目录>` 试跑

## 快速了解技能

- 首读：`SKILL.md`（定位、铁律、快速开始）
- 流程细节：`lifecycle/00-overview.md`（八阶段 + 闸门 + 产物总表）
- 真实使用样例：`records/`（台账）、`evidence/`（发版证据，IP 已脱敏）
- 历史教训：`references/mac-traps.md`
