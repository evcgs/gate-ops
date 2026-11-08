# 集成层（integrations，v3.2.0 起）

> 借鉴 spec-kit 的 38-agent 集成方法论：**同一真源 + 每宿主一个薄适配**，无锁定的安装路径。
> 一键装配：`bash scripts/gateo-init.sh --integration <name>`（真源仓库内执行，装完自动自检）。

| 集成 | 宿主 | 装配位置 | 特殊动作 |
|---|---|---|---|
| workbuddy | WorkBuddy | `~/.workbuddy/skills/gate-ops` 软链 | 无（技能自动发现） |
| claude | Claude Code | `~/.claude/skills/gate-ops` 软链 | 无（SKILL.md 自动发现） |
| codex | Codex CLI | `~/.codex/skills/gate-ops` 软链 | 追加一行指引到 `~/.codex/AGENTS.md` |
| generic | 任意 agent | 自定义目录（`--integration generic <dir>`） | 宿主若无技能发现机制，在其系统提示/AGENTS 类文件加一行：需要发版/回滚/部署时先读该目录 SKILL.md 并严格遵循 |
| **dsh** | DeepSeek Harness | [`integrations/dsh/`](dsh/README.md) 源码快照，手动挂载两个工具插件 | **代码级集成，非软链**：需按样例配置 `gateOpsRoot` / 项目白名单 / E2E 套件，重启 web profile 后先探活工具面再动手 |

## 设计原则

1. **软链即安装**：所有宿主指向同一真源仓库——版本升级、档案新增、剧本调整一处生效，多端零同步成本
2. **薄适配**：每个集成的差异只有"装到哪 + 需不需要指引行"，无 fork、无复制
3. **装完自检**：init 脚本自动跑三条只读检查（脚本可执行 / 语法 / SKILL.md 在位）
4. **凭据与宿主无关**：`~/.gateo/credentials.sh` 独立于任何宿主，跨 agent 共享同一套服务器凭据

## 代码级集成：dsh

前四行是「技能发现」型集成，只需软链；[`dsh/`](dsh/README.md) 是**代码级集成**，因为它要在 DSH 的工具层加装「测试证据硬前置」：

- 两个工具插件 + 一个岗位预设 + 两个真源证据脚本 + 可复跑的验证矩阵，完整开源；
- `plan()` / `apply()` 两个唯一入口调用 `evidenceCheck()`，没有有效 E2E 证据直接拒绝，绕过 persona 直调工具同样被拦；
- **判定权仍只在 gate-ops 真源 shell**，JS 侧不重写任何闸门逻辑；
- 默认路径全是占位符，未配置即 fail-closed；发布副本已脱敏，逐项差异见 [`dsh/SANITIZATION.md`](dsh/SANITIZATION.md)。

> 一句话概括：**能力可以下放给 Agent，「能不能发版」不能。**
