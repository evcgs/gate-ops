# 🚢 gate-ops · example 发版台账（跨 agent 共享，append-only）

> 每次发版/回滚后由执行 agent 追加一行并 git 提交。本文件是所有宿主 agent 共读的部署历史真源。

| 时间 | 目标 | 结果 | 验收 | 备份文件（回滚点） | 健康检查 | 操作 agent | 证据 | 备注 |
|---|---|---|---|---|---|---|---|---|
| 2026-01-01 10:00 | backend | 成功 | 通过（readiness 200） | gateo_backend_app_bak_20260101_100000.tar.gz | {"status":"ok"} | <your-agent> | evidence/example/20260101_100000_backend/ | 示例行：真实部署历史请在本表追加，永不删除旧行 |
