# Phase 4 · health（健康检查）

## 目标

证明服务已**就绪**。区分三层：liveness（进程活着）< readiness（能安全接收流量）< acceptance（功能正确）。health/readiness 只回答前两层，功能正确由 acceptance 证明。

## 前置条件

- release 已完成

## 操作手册

- backend：deploy 流程内置——首轮每 3s 探活一次、默认 10 次（30s，可用档案 `DEPLOY_HEALTH_RETRIES`/`DEPLOY_HEALTH_INTERVAL` 调整）。**优先用 `READINESS_URL`/`READINESS_CMD`，未配置回退 `HEALTH_URL`/`HEALTH_CMD`**；HTTP 探活自动 fail-on-error（任何 4xx/5xx 判失败，v3.1 修复了"连上 500 也算成功"的漏洞）
- **失败甄别（内置，2026-11-03 内容型项目实录驱动）**：首轮失败且服务进程仍在运行（compose-build 查 `compose ps`、container-sync 查 `docker inspect`）→ 自动延长观察 60s（12 次×5s）——容器重建后的启动预热（会话恢复/缓存加载）可能超过首轮窗口，属**探活时序误判**，不是代码故障；延长后通过 = 发版成功，台账备注记"预热延长观察通过"
- frontend：deploy-frontend.sh 发布后校验远端 `index.html` 存在
- 补充探查（health 通过但行为可疑时）：
  ```bash
  ssh <server> docker logs --tail 50 <container>
  ssh <server> docker ps | grep <container>   # 确认没有重启循环
  ```

## 失败处置（甄别后分两路）

**真故障**（延长观察后仍失败，或服务进程已退出）：

1. **立即执行 `rollback.sh backend`**（默认恢复最近备份，回滚自带健康检查），不要反复重试发版脚本
2. 回滚成功后再排查根因：容器日志、依赖服务、配置项
3. 排查结论记入 ledger 备注

**疑似预热超窗**（延长观察 60s 后仍未就绪，但 agent 只读诊断发现服务实际健康——探活 200、容器 Up、启动日志正常）：

1. **不得自行决定"不回滚、转验收"**——把诊断证据完整报给用户（探活返回、容器状态、实际预热耗时）
2. 经用户明确同意"不回滚、转验收"后才继续 acceptance
3. 决策与用户确认原文记入台账备注（如"预热 90s 超窗，用户同意不回滚转验收"）
4. 若该项目预热常态化偏长，把档案 `DEPLOY_HEALTH_RETRIES`/`DEPLOY_HEALTH_INTERVAL` 调大（如 20×5s），让下次发版走正常闸门而非每次靠人工授权

## 输出物

- 探活成功输出（第几次通过 + 健康端点返回内容摘要）
- 或：失败 + 容器最近 50 行日志（脚本自动打印）

## Agent 检查点

- [ ] health 失败禁止向用户报"部署成功"
- [ ] 失败先看脚本甄别结论：延长观察通过=成功（台账记"预热延长观察通过"）；真故障先回滚、后排查，顺序不可反
- [ ] 疑似预热超窗时：只读诊断可以做，"不回滚"必须用户授权，确认原文进台账
- [ ] health 通过 ≠ 发版完成；必须继续 acceptance
