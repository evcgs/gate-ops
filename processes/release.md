# 发版剧本（release：core 过程）

> 详细决策手册见 `lifecycle/00-overview.md` ~ `08-memory.md`（八阶段：preflight → backup → release → health → acceptance → rollback → ledger → memory）。
> 本文件只定义入口、闸门链与终点。

## 入口与闸门链

`gateo-plan`（只读计划，内嵌 precheck 差异清单）→ **用户确认计划 ID**（确认的是覆盖范围）→ `gateo-apply`（指纹校验/备份三重校验/同步/就绪探活）→ 验收（liveness/readiness/acceptance + E2E 按 E2E_MODE）→ 台账 + 记忆写入。

## 终点

验收通过 + 台账行（records/<项目>.md）+ build-index + gate-ops 仓库 git 提交 + 宿主记忆三层写入。
验收未过 = 走 `lifecycle/06-rollback.md`（铁律 6 甄别），不伪造终点。

## 与其他过程的边界

- 内容级数据操作（出题/批量生成）走 `data-change.md`，不混入发版计划
- 线上故障修复走 `hotfix.md` 入口（根因评估先行），但发版动作仍走本剧本链路
- 发版后发现下游产物过期（计划/缓存）→ 转 `data-change.md`，需用户指令
