# 集成层（integrations，v3.2.0 起）

> 借鉴 spec-kit 的 38-agent 集成方法论：**同一真源 + 每宿主一个薄适配**，无锁定的安装路径。
> 一键装配：`bash scripts/gateo-init.sh --integration <name>`（真源仓库内执行，装完自动自检）。

| 集成 | 宿主 | 装配位置 | 特殊动作 |
|---|---|---|---|
| workbuddy | WorkBuddy | `~/.workbuddy/skills/gate-ops` 软链 | 无（技能自动发现） |
| claude | Claude Code | `~/.claude/skills/gate-ops` 软链 | 无（SKILL.md 自动发现） |
| codex | Codex CLI | `~/.codex/skills/gate-ops` 软链 | 追加一行指引到 `~/.codex/AGENTS.md` |
| generic | 任意 agent | 自定义目录（`--integration generic <dir>`） | 宿主若无技能发现机制，在其系统提示/AGENTS 类文件加一行：需要发版/回滚/部署时先读该目录 SKILL.md 并严格遵循 |

## 设计原则

1. **软链即安装**：所有宿主指向同一真源仓库——版本升级、档案新增、剧本调整一处生效，多端零同步成本
2. **薄适配**：每个集成的差异只有"装到哪 + 需不需要指引行"，无 fork、无复制
3. **装完自检**：init 脚本自动跑三条只读检查（脚本可执行 / 语法 / SKILL.md 在位）
4. **凭据与宿主无关**：`~/.gateo/credentials.sh` 独立于任何宿主，跨 agent 共享同一套服务器凭据
