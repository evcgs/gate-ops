# 架构 · 三层判定权与代码级硬前置

> 一句话：**Agent 负责把事情做完，闸门负责决定能不能往外发。**

---

## 1. 为什么需要分层

把「发版判定」写进 Agent 的系统提示词，会碰到三个无法回避的问题：

| 问题 | 表现 |
|---|---|
| 提示词可协商 | 用户一句「别测了，直接发」，模型可能自行放宽 |
| 状态不可验证 | 「我测过了」是自然语言断言，没有进程退出码、没有哈希 |
| 责任不可追溯 | 出事后无法回答「当时依据哪份证据放行」 |

所以判定权不能放在模型里，也不能放在调用方手里，必须放在一段**模型改不动、调用方绕不过**的代码里。

---

## 2. 三层判定权

```
┌─────────────────────────────────────────────────────────────┐
│ 第 1 层 · 原子能力           dsh-tool-gate-ops-loop           │
│   改源码 / 跑 E2E / 生成证据 / 转发台账                        │
│   ✗ 不判定能不能发版                                          │
└───────────────────────────┬─────────────────────────────────┘
                            │ GATEO_TEST_RESULT（结构化）
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 2 层 · 证据准入           gateo-evidence-verify.sh         │
│   seal / plan / apply 三模式                                  │
│   哈希 · 有效期 · 项目 · 源码指纹 · 范围摘要                    │
│   ✗ 不决定放行，只决定「能否进入发令链」                        │
└───────────────────────────┬─────────────────────────────────┘
                            │ GATEO_EVIDENCE {evidenceHash, sourceHash}
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 3 层 · 发版放行           _approval.sh::gateo_load_plan    │
│   计划 ID = 文件 SHA-256 · TTL · config digest · source digest │
│   备份 → 部署 → 探活 → 台账                                    │
│   ✓ 唯一可以说「放行」的地方                                   │
└─────────────────────────────────────────────────────────────┘
```

真源脚本里的注释把边界写死：

```bash
# 判定权分层：本脚本只做「测试证据准入」校验与绑定比对；
# 「能不能发版」的最终判定仍在 _approval.sh::gateo_load_plan / gateo_require_plan。
```

**只加入口，不搬逻辑**：001 主插件不在 JS 中重写任何闸门判定，只以 `spawnSync` + 脚本白名单调用真源。双实现必然漂移，桥接比重写安全。

---

## 3. 代码级硬前置：把闸门焊在两个唯一入口

`core.js` 新增 `evidenceCheck(mode, project, argv)`，并在 `plan()` / `apply()` 各调一次：

```js
// 003 FR-04：测试证据硬前置。放在真源 plan 之前，绕过 persona 直接调工具同样被拦。
const ev = evidenceCheck("plan", p);
```

```js
const evApplied = evidenceCheck("apply", p, [planId, rec.scopeDigest, loopSourceRoot]);
```

`apply()` 的入参里带 `scopeDigest`，是为了让「计划覆盖的源码范围」与「被测时的源码范围」逐字绑定：

```python
if (b.get("project") != project
        or b.get("evidenceHash") != rec["evidenceHash"]
        or b.get("sourceHash") != rec["sourceHash"]
        or b.get("planScopeDigest") != plan_scope_digest):
    die("E_BINDING_MISMATCH", "计划与证据绑定不一致（项目/证据/源码/范围摘要）")
```

三条设计约束：

1. **前置放在唯一入口**：有旁路，就等于没有闸门。
2. **不设关闭开关**：开关即旁路。
3. **失败即拒绝（fail-closed）**：拿不到 `GATEO_EVIDENCE` 结构化输出、脚本非 0 退出、输出无法解析，一律 `throw GateError`。

---

## 4. 不采信自报

`loop.js` 的 `test()` 只认两样东西：真实进程退出码，以及套件自己打印的一行结构化输出。

```js
const line = out.split("\n").map((s) => s.trim())
  .find((s) => s.startsWith("GATEO_TEST_RESULT "));
if (!line) {
  throw new LoopError("L_RESULT_UNPARSEABLE",
    "E2E 未输出 GATEO_TEST_RESULT，拒绝生成证据（不采信自报通过）");
}
```

证据判定同样「先验哈希，再验结果」，保证两类负例可区分：

```python
want = rec.get("evidenceHash")
if not want or want != rec_hash(rec):
    die("E_HASH_MISMATCH", "evidenceHash 不匹配，证据可能被篡改")
r = rec.get("result") or {}
if r.get("exit") != 0 or r.get("failed") != 0 or not isinstance(r.get("passed"), int) or r["passed"] < 1:
    die("E_TEST_FAILED", "测试结果未通过（exit/failed/passed 不达标）")
```

- 篡改字段不重算哈希 → `E_HASH_MISMATCH`
- 哈希自洽但测试确实失败 → `E_TEST_FAILED`

两者混成一个「失败」，负例矩阵就失去意义。

---

## 5. 路径与脱敏：把约束写进代码，而不是写进规范

- `projectRoots` / `suites` **只来自配置**，工具入参不能指定任意路径或任意命令。
- `safePath()` 双重校验：防 `..` 越界，并用 `realpathSync` 阻断符号链接逃逸。
- `edit()` 的返回值把根目录直接写成常量：

```js
return { ok: true, path: rel, root: "[REDACTED]" };
```

- 证据与绑定文件 **append-only**：不覆盖、不删除、不改写历史行；遇到无法解析的历史行直接 `E_HASH_MISMATCH` / `E_BINDING_MISMATCH`，而不是跳过。
- 证据 **30 分钟有效期**（`E_EXPIRED`），避免「上午测过、下午拿同一份证据发版」。

---

## 6. 负例矩阵为什么用 A/B 双路径

| 路径 | 走法 | 验证什么 |
|---|---|---|
| A | 经 001 插件真实 `defineTool` 入口（`gateops_plan` / `gateops_apply.execute`） | 正常角色编排下被拦 |
| B | 绕过 persona 与工具层，直接 `createCore()` 调 `core.plan()` / `core.apply()` | 闸门是**代码级**的，不是靠提示词自觉 |

N-1 无证据 plan、N-2 证据过期、N-3 篡改字段、N-4 项目/范围错配、N-5 测试失败但哈希自洽、N-6 缺确认原话，六类负例在 A/B 两条路径上共 `16 通过 / 0 失败`。

> **正常流程全绿说明不了什么，负例全拒才算数。**

---

## 7. 六条可复用原则

1. 判断权分层：能力下放，判定权留在独立真源。
2. 只加入口，不搬逻辑：桥接比重写安全。
3. 前置放在唯一入口：有旁路就等于没有闸门。
4. 不采信自报：只认退出码与结构化输出。
5. 证据可绑定、会过期：把测试、计划、源码指纹钉在一起。
6. 拿绕过路径做验证：负例全拒才算数。

这六条脱离 gate-ops 与 DSH 也成立。
