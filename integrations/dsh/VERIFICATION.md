# 验证 · 数据与如实声明

> 本文只记录本机可复跑的结果与口径。**不把不同阶段的数字揉成一句「全部搞定」。**

---

## 1. 全量矩阵（连跑 2 次，全绿）

| 矩阵 | 口径 | 结果 |
|---|---|---|
| 001 插件行为自测 | `test-gateops.mjs` | `41 通过 / 0 失败` |
| 002 开窗 / 关窗 | 真实 SSH 通道 | `15 通过 / 0 失败 / 1 SKIP` |
| 本地四步闭环 | 隔离副本 | `12 通过 / 0 失败` |
| 离线冒烟 | `smoke-offline.mjs` | `6 通过 / 0 失败` |
| 003 四步闭环 E2E | `loop-e2e.mjs` | `14 通过 / 0 失败` |
| 负例矩阵 | `loop-negative.mjs`，N-1~N-6 × A/B | `16 通过 / 0 失败` |
| 聚合门禁 | `preflight` 类脚本 | `24 通过 / 6 失败`（6 个既有 FAIL 名单 `IDENTICAL`，不劣化） |
| 002 能力验证（真实 SSH） | `capability-e2e.mjs` | `14 / 14 × 2` |
| 面板 E2E（重启后） | 浏览器自动化 | `10 / 0 × 2` |
| preset 完整性 | 15 个预设 | `FAIL 0 / WARN 0 / INFO 0` |

---

## 2. 负例明细（16/16）

| 编号 | 负例 | 期望错误码 | A 路径 | B 路径 |
|---|---|---|---|---|
| N-1 | 无测试证据直接 `plan` | `E_NO_EVIDENCE` | 拒 | 拒 |
| N-2 | 证据过期（>30 分钟） | `E_EXPIRED` | 拒 | 拒 |
| N-3 | 篡改证据字段不重算哈希 | `E_HASH_MISMATCH` | 拒 | 拒 |
| N-4 | project 错配 / 绑定范围摘要错配 | `E_BINDING_MISMATCH` | 拒 | 拒 |
| N-5 | 测试失败但哈希自洽 | `E_TEST_FAILED` | 拒 | 拒 |
| N-6 | 缺确认原话 / 无有效声明计划 | `G2_CONFIRM_TEXT` / `G2_NO_DECLARATION` | 拒 | 拒 |

A 路径经 001 插件真实 `defineTool` 入口；B 路径绕过 persona 与工具层，直接 `createCore()` 调用。**两条都被拦住**，才证明闸门是代码级的。

另有一项有意设计，不是回归：所有 `gateops_plan` / `gateops_apply` 现在都必须有有效测试证据，否则即 N-1 拒绝。

---

## 3. 零副作用独立复核

| 项 | 结果 |
|---|---|
| gate-ops 真源既有文件 | `git diff` **0 字节** |
| 跨项目验证用脚本 | 18 个脚本逐一 SHA-256 比对，与真源一致 |
| 产品代码 | 5 项关键文件 mtime 零漂移 |
| 临时资产 | `/tmp/gateops-*` / `/tmp/cdp-gateops-*` / `/tmp/loop-demo-check-*` 全清 |
| 生产机 | 只读复核 11 项与基线一致，零持久副作用 |

跨项目验证采用「原样产品代码 + 真源逐字副本（REPLICA）」双轨：原样代码用于暴露真实缺陷，隔离副本只加最小诊断补丁用于定位，两者结论分开记录，不合并口径。

---

## 4. 验收状态（含时间线，避免旧结论被当成现状）

- 中途报告一度写明：**不宣称全量验收通过**。原因具体——AC-07 的「最近动态可见真实四步事件」依赖用户在外部终端重启 DSH web，并在真实会话走完四步，未做之前只能标「待复验」。
- 重启并真实走完四步后，`AC-01 ~ AC-10 全部闭合（10/10）`，003 四步研发闭环验收完成。面板「最近动态」6/6 kind 可见：`loop_edit / loop_test / loop_evidence / plan / apply / loop_record`，时间戳与 `bridge.jsonl` 一致。

> 一套发版体系最值钱的，不是全绿，是敢写待复验。

---

## 5. 边界不变（不得因验收完成而放松）

| 边界 | 状态 |
|---|---|
| 插件是**可选受控通道**，不是全局拦截器 | 未改变 |
| 服务器端强制（002 enforce） | **未实装**，不得切 `enforce` |
| 旧共用 key 旁路 | **未关闭** |
| `core.js` 无法物理验证「用户确认原话」确实来自用户 | 如实声明 |
| `loop-e2e.mjs` 部署执行面 | 隔离副本中的本地替身（保留真源 `gateo_load_plan` 校验）；真实 SSH 全链路由 `capability-e2e.mjs` 覆盖，两者合起来才构成完整真实链路 |
| 8 个生产项目 | 需发版时须重新配置并重新走计划确认链，本快照只登记 1 个隔离档案 |

---

## 6. 复跑

```bash
# 负例矩阵（无需浏览器）
GATEOPS_ROOT=/path/to/gate-ops \
GATEOPS_DSH_CORE=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/core.js \
GATEOPS_DSH_PLUGIN=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/index.js \
  node tests/loop-negative.mjs

# 001 行为自测
node plugins/dsh-tool-gate-ops/test-gateops.mjs

# 四步闭环 E2E（需要 Playwright + 本机 Chrome，见 tests/README.md）
GATEOPS_ROOT=/path/to/gate-ops \
GATEOPS_DSH_CORE=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/core.js \
GATEOPS_DSH_LOOP=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops-loop/lib/loop.js \
  node tests/loop-e2e.mjs
```

所有 `/path/to/...` 均为占位符，必须替换为真实路径。脚本默认 fail-closed：路径不对会直接失败，不会「降级通过」。
