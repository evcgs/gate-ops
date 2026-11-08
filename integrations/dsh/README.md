# dsh · DeepSeek Harness 集成

> **能力可以下放给 Agent，「能不能发版」不能。**
>
> 本目录是 gate-ops 在 DSH（DeepSeek Harness）工作台上的完整接入代码：两个工具插件、一个岗位预设、两个真源证据脚本，以及可复跑的验证矩阵。
>
> 版本基线：gate-ops `3.3.0` · 集成快照 `2026-11-08` · 状态：**可用，但为可选受控通道**（见「边界」）

---

## 1. 解决什么问题

AI coding agent 已经能读代码、改代码、跑测试、生成发版计划。能力越强，越要回答一个问题：**最后那一下「发版」，谁说了算？**

写在系统提示词里的「请务必先测试」不是闸门——模型可以忘、可以绕、可以在被要求「直接发」时自行放宽。这套集成给出的答案是：

> 把「能不能发版」从人的自觉，变成代码的判断。

具体做法不是加规范，而是在**唯一入口**上加一道无法绕过的前置：`plan()` 与 `apply()` 调用真源 `gateo-evidence-verify.sh` 做证据准入，没有有效的端到端测试证据就直接拒绝。绕过 persona、绕过工具层、直接调 `core.plan()` 一样被拦。

```
// plugins/dsh-tool-gate-ops/lib/core.js
// 003 FR-04：测试证据硬前置。放在真源 plan 之前，绕过 persona 直接调工具同样被拦。
const ev = evidenceCheck("plan", p);
```

源码里还留了一句注释，是这套设计的关键：

```js
// 不设关闭开关：开关即旁路，与 AC-02 负例矩阵冲突。
```

---

## 2. 目录结构

| 路径 | 内容 |
|---|---|
| `plugins/dsh-tool-gate-ops/` | 001 主插件：7 个工具（4 只读 / 3 写入且两段式确认）、G1~G8 约束层、`test-gateops.mjs` |
| `plugins/dsh-tool-gate-ops-loop/` | 003 四步闭环插件：3 个原子工具、路径白名单、证据生成、append-only 台账 |
| `presets/release-engineer/` | 「GateOps 研发闭环岗」persona：只做编排与留痕，不写任何判定逻辑 |
| `scripts/gateo-evidence-verify.sh` | 真源：测试证据准入（`seal` / `plan` / `apply` 三模式，fail-closed） |
| `scripts/gateo-record-append.sh` | 真源：台账 append-only 追加 + 聚合索引重建 |
| `config/*.example.yml` | 脱敏后的 cordis 挂载配置样例 |
| `tests/loop-e2e.mjs` | 四步闭环隔离式端到端矩阵（14/0） |
| `tests/loop-negative.mjs` | 负例矩阵 N-1~N-6 × A/B 双路径（16/0） |
| `ARCHITECTURE.md` | 三层判定权、四步闭环、代码级硬前置的设计说明 |
| `VERIFICATION.md` | 验证数据与如实声明（含未闭合边界） |
| `SANITIZATION.md` | 本发布副本与本地真源的逐项差异 |

---

## 3. 三层判定权

| 层 | 组件 | 职责 | 不做什么 |
|---|---|---|---|
| 第 1 层 · 原子能力 | `dsh-tool-gate-ops-loop` | 按白名单改源码、跑真实 E2E、生成证据、转发台账 | **不判定能不能发版** |
| 第 2 层 · 证据准入 | `gateo-evidence-verify.sh` | 校验哈希、有效期、项目绑定、测试退出码 | 不决定放行，只决定「能否进入发令链」 |
| 第 3 层 · 发版放行 | 真源 `_approval.sh::gateo_load_plan` / `gateo_require_plan` | 计划 ID = 文件 SHA-256、TTL、config digest、source digest 四重硬校验 | 不接受任何 JS 层传来的「已通过」 |

**设计原则：只加入口，不搬逻辑。** 闸门逻辑在 gate-ops 真源 shell 里只有一份，JS 侧不重写。双实现必然漂移，桥接比重写安全。

详见 [ARCHITECTURE.md](ARCHITECTURE.md)。

---

## 4. 快速开始

> 前置：已安装 gate-ops 真源（[INSTALL.md](../../INSTALL.md)）、Node.js 18+、DSH 工作台。
> 本目录是**源码快照**，不是 DSH 的自动发现目录；需按宿主机制挂载两个插件。

```bash
# 1. 把两个插件放到 DSH 的 plugin/ 下（或软链）
ln -s "$PWD/plugins/dsh-tool-gate-ops"      "$DSH_ROOT/plugin/@wisediag/dsh-tool-gate-ops"
ln -s "$PWD/plugins/dsh-tool-gate-ops-loop" "$DSH_ROOT/plugin/@wisediag/dsh-tool-gate-ops-loop"

# 2. 把两个证据脚本并入真源 scripts/（或让 gateOpsRoot 指向包含它们的目录）
cp scripts/gateo-evidence-verify.sh "$GATEOPS_ROOT/scripts/" && chmod +x "$GATEOPS_ROOT/scripts/gateo-evidence-verify.sh"
cp scripts/gateo-record-append.sh   "$GATEOPS_ROOT/scripts/" && chmod +x "$GATEOPS_ROOT/scripts/gateo-record-append.sh"

# 3. 按样例改写配置（所有路径均为占位符，必须替换）
cp config/dsh-tool-gate-ops.example.yml      "$DSH_ROOT/plugin/@wisediag/dsh-tool-gate-ops/cordis.patch.yml"
cp config/dsh-tool-gate-ops-loop.example.yml "$DSH_ROOT/plugin/@wisediag/dsh-tool-gate-ops-loop/cordis.patch.yml"

# 4. 把 preset 放进 .agent-presets/release-engineer/，重启 DSH web profile 后探活工具面
```

**⚠️ 配置改完先探活，再动手。** 本项目验证过程中最大的时间成本不在闭环本身，而是「工具没挂载上」——重启 web 后才生效。先确认本轮可用工具清单，工具不可用就停下，不要凭记忆重造工具契约。

### 环境变量

| 变量 | 用途 | 默认（占位，必须覆盖） |
|---|---|---|
| `GATEOPS_ROOT` | gate-ops 真源根目录 | `/path/to/gate-ops` |
| `DSH_HOME` | DSH 运行态目录 | `/path/to/dsh-home` |
| `GATEOPS_DSH_CORE` | `core.js` 绝对路径（仅测试脚本用） | `/path/to/dsh/plugin/.../core.js` |
| `GATEOPS_DSH_LOOP` | `loop.js` 绝对路径（仅 E2E 脚本用） | `/path/to/dsh/plugin/.../loop.js` |
| `GATEOPS_DSH_PLUGIN` | `index.js` 绝对路径（仅负例脚本用） | `/path/to/dsh/plugin/.../index.js` |

所有路径也可通过 `cordis.patch.yml` 的 `config` 注入，优先级高于环境变量。

---

## 5. 四步研发闭环

一次需求从源码到台账，顺序不可倒置：

1. **改本地源码** —— `gateops_loop_edit`：项目名只取自本轮用户明确指定，且必须在 `projectRoots` 白名单内；`safePath()` 防 `..` 越界与符号链接逃逸；返回值把根目录写成 `[REDACTED]`。
2. **跑真实端到端测试** —— `gateops_loop_test`：**不采信自报通过**。只认真实进程退出码与 `GATEO_TEST_RESULT` 结构化输出；没有这行输出就拒绝生成证据。
3. **DSH 发令** —— `gateops_plan` → 用户复述确切计划 ID 并同意覆盖范围 → `gateops_apply`。用户未复述计划 ID 一律不发令。
4. **GateOps 记录版本** —— `gateops_loop_record`：显式转发，操作主体如实记为 `DSH`；台账只追加，不改写历史行。

`plan()` / `apply()` 两个唯一入口都先调 `evidenceCheck()`，证据 30 分钟过期，且与项目、源码哈希、计划范围摘要三重绑定。

---

## 6. 错误码（负例可区分）

| 场景 | 错误码 |
|---|---|
| 无测试证据直接生成计划 / 执行 | `E_NO_EVIDENCE` |
| 证据过期 | `E_EXPIRED` |
| 篡改字段不重算哈希 | `E_HASH_MISMATCH` |
| 项目错配 / 绑定范围摘要错配 | `E_BINDING_MISMATCH` |
| 测试失败但哈希自洽 | `E_TEST_FAILED` |
| 参数 / 环境 / 源码缺失 | `E_BAD_ARGS` / `E_BAD_ENV` / `E_SOURCE_MISSING` |
| 缺确认原话 / 无有效声明计划 | `G2_CONFIRM_TEXT` / `G2_NO_DECLARATION` |

`E_HASH_MISMATCH` 与 `E_TEST_FAILED` 必须可区分：先验哈希、再验结果。哈希自洽但测试确实失败，才报 `E_TEST_FAILED`。

---

## 7. 验证

全量矩阵连跑 2 次全绿：

| 矩阵 | 结果 |
|---|---|
| 001 插件行为自测 | `41 / 0` |
| 003 四步闭环 E2E | `14 / 0` |
| 负例 N-1~N-6 × A/B 双路径 | `16 通过 / 0 失败` |
| 002 能力验证（真实 SSH） | `14 / 14 × 2` |
| 面板 E2E（重启后） | `10 / 0 × 2` |
| 离线冒烟 / 开窗 / 本地闭环 | `6 / 0`、`15 / 0 / 1 SKIP`、`12 / 0` |
| 聚合门禁 | `24 / 6`（6 个既有 FAIL 名单 `IDENTICAL`，不劣化） |

真源既有 diff **0 字节**；跨项目验证用原样产品代码与逐字副本，18 个脚本逐一做过 SHA-256 比对。完整口径与「不夸大」声明见 [VERIFICATION.md](VERIFICATION.md)。

复跑：

```bash
GATEOPS_ROOT=/path/to/gate-ops \
GATEOPS_DSH_CORE=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/core.js \
GATEOPS_DSH_PLUGIN=/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/index.js \
  node tests/loop-negative.mjs

node plugins/dsh-tool-gate-ops/test-gateops.mjs
```

`tests/loop-e2e.mjs` 另需 Playwright 与本机 Chrome，详见 [tests/README.md](tests/README.md)。

---

## 8. 边界（不夸大）

- 本集成是**可选受控通道**，不是全局拦截器：DSH 里不经过这些工具的操作不在覆盖范围内。
- 服务器端强制未实装；旧共用 key 旁路未关闭；**不得切 `enforce`**。
- `core.js` 无法物理验证「用户确认原话」确实来自用户而非模型自行编造。最终不可绕过的是真源 `gateo-apply.sh` 的 manifest 指纹与 TTL，以及计划 ID 只由 `plan` 声明产生。
- 部分端到端用例的「部署执行面」使用隔离副本中的本地替身（保留真源 `gateo_load_plan` 校验），真实 SSH 全链路由另一套能力验证覆盖，两者合起来才构成完整真实链路。
- 本目录为**脱敏发布副本**：路径为占位符、内部项目名已泛型化、少量注释改写为中性表述；逻辑与本地真源一致。逐项差异见 [SANITIZATION.md](SANITIZATION.md)。

---

## 9. 相关

- [gate-ops 主文档](../../README.zh-CN.md) · [集成层说明](../README.md) · [架构](ARCHITECTURE.md) · [验证](VERIFICATION.md)
- License: MIT（同仓库根 [LICENSE](../../LICENSE)）
