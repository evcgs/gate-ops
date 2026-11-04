# Phase 7 · ledger（发版台账）

## 目标

维护**跨 agent 共享**的发版历史真源：任何 agent（WorkBuddy / Claude / Codex）读台账即可回答"这个项目最近发过什么、最近回滚点是哪个备份"。

## 前置条件

- acceptance 已闭环（通过 / 回滚 / 带瑕疵放行，三者皆是终态）

## 操作手册

台账文件：`records/<项目名>.md`（不存在则按下方表头创建）。**append-only**，每次发版/回滚追加一行，然后 git 提交：

```bash
cd ~/agent-skills && git add -A && git commit -m "deploy log: <项目> <结果>"
```

表结构（一行一次发版事件，9 列）：

```markdown
| 时间 | 目标 | 结果 | 验收 | 备份文件（回滚点） | 健康检查 | 操作 agent | 证据 | 备注 |
|---|---|---|---|---|---|---|---|---|
| 2026-11-03 13:30 | backend | 成功 | 通过(5/5) | gateo_backend_app_bak_20261103_133000.tar.gz | healthy | WorkBuddy | evidence/project-a/gateo-20261103_133000_backend | 发布XX功能 |
```

- `结果`：成功 / 回滚 / 失败（已中止，云端未破坏）
- `验收`：通过(n/n) / 部分验证(原因) / 未过-回滚 / 带瑕疵放行(说明) / 未验证（仅限无变更的空转发版）
- `操作 agent`：WorkBuddy / Claude / Codex / 人工
- `证据`：`evidence/<项目>/gateo-<发版目录>/` 相对路径（deploy-output + 验收报告 + E2E 截图）；证据中心上线前的历史行为 "-"
- 写完台账后跑 `bash scripts/build-index.sh` 刷新总目录 `records/_index.md`

## 失败处置

- 发版在 backup 前就中止（如 preflight 阻塞）：**不记台账**（没有产生线上事件），但向用户报告的差异清单要留档（会话日志即可）
- 发版已产生线上事件后失败/回滚：**必须记台账**，结果如实

## 输出物

- 台账新行 + git commit + 总目录刷新

## Agent 检查点

- [ ] 备份文件名从脚本输出原样摘录，不手写
- [ ] 验收列如实填写，禁止空着（空 = 未闭环，违反 05 的闸门规则）
- [ ] 台账与宿主会话日志是两层记录，**都要写**（见 08-memory）
