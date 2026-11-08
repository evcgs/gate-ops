# 验证脚本说明

三个脚本都是**只读隔离式**：在 `mkdtempSync` 临时目录里构造 gate-ops 逐字副本（REPLICA）与假项目，不写真源、不连服务器、不重启任何服务。

| 脚本 | 覆盖 | 期望结果 |
|---|---|---|
| `../plugins/dsh-tool-gate-ops/test-gateops.mjs` | 001 插件 G1~G8 约束层行为自测 | `41 / 0` |
| `loop-negative.mjs` | N-1~N-6 × A/B 双路径负例 | `16 / 0` |
| `loop-e2e.mjs` | 四步闭环端到端（含真实浏览器 E2E） | `14 / 0` |

---

## 通用前置

- Node.js 18+
- 本机存在完整 gate-ops 真源（含 `scripts/*.sh`、`SKILL.md`、`VERSION`）
- 两个插件的 `lib/*.js` 可从绝对路径读取

## 环境变量

| 变量 | 用于 | 说明 |
|---|---|---|
| `GATEOPS_ROOT` | 全部 | gate-ops 真源根目录 |
| `GATEOPS_DSH_CORE` | 全部 | `dsh-tool-gate-ops/lib/core.js` 绝对路径 |
| `GATEOPS_DSH_PLUGIN` | negative | `dsh-tool-gate-ops/lib/index.js` 绝对路径 |
| `GATEOPS_DSH_LOOP` | e2e | `dsh-tool-gate-ops-loop/lib/loop.js` 绝对路径 |

未设置时全部回落到 `/path/to/...` 占位符并**直接失败**（fail-closed），不会降级通过。

## 运行

```bash
# 无需浏览器
node ../plugins/dsh-tool-gate-ops/test-gateops.mjs

GATEOPS_ROOT=/path/to/gate-ops \
GATEOPS_DSH_CORE=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/core.js \
GATEOPS_DSH_PLUGIN=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/index.js \
  node loop-negative.mjs

# 需要 Playwright + 本机 Chrome
GATEOPS_ROOT=/path/to/gate-ops \
GATEOPS_DSH_CORE=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/core.js \
GATEOPS_DSH_LOOP=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops-loop/lib/loop.js \
  node loop-e2e.mjs
```

`loop-e2e.mjs` 通过包名 `playwright` 导入 `chromium`，需保证该包可被 Node 解析；默认浏览器路径为 macOS 的 Chrome 安装位置，其他平台请改 `CHROME` 常量。

---

## 已知的真实性边界（不夸大）

- `loop-e2e.mjs` 的 REPLICA 中，仅 `gateo-apply.sh` 的「部署执行面」被替换为本地替身，**保留真源 `gateo_load_plan` 的计划 ID / TTL 校验**；其余脚本逐字一致。
- 真实 SSH + guard + `deploy-backend.sh` 全链路由 `capability-e2e.mjs`（`14/14 ×2`）单独覆盖，不在本目录。两者合起来才构成完整真实链路。
- 脚本输出的是**隔离环境**结论，不等于你的生产环境已验证。上生产前请按本仓库三段式发版流程重新走一遍。
