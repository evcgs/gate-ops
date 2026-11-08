# 发布副本脱敏说明

> 本目录是 **PUBLIC 仓库的脱敏发布副本**。本地真源一行未改。
> 目的：把 DSH 侧改动代码完整开源，同时不带出本机用户名、内部项目名、内部主机、历史事件描述与凭据线索。

---

## 1. 发布前扫描口径

对全部待发布文本执行宽词表扫描，命中即处理，不靠肉眼抽查：

| 类别 | 词表样例 |
|---|---|
| 本机绝对路径 | `/Users/<user>/...`、`/home/<user>/...`、盘符路径 |
| 内部项目 / 站点名 | 内部档案名、站点域名、业务系统名 |
| 主机与网络 | 公网 / 内网 IP、SSH 别名、端口暴露面描述 |
| 身份与凭据 | 邮箱、QQ 号、账号昵称、UserID、token / AK 字样 |
| 内部事项 | 具体漏洞代号、内部事件日期与描述、拍板记录 |
| 备份与临时文件 | `*.bak-*`、adopt 备份、`backup/` 目录 |

发布前复扫结果：**CLEAN**（上述词表零命中）。

---

## 2. 逐项差异（相对本地真源）

| # | 文件 | 处理 |
|---|---|---|
| 1 | `plugins/dsh-tool-gate-ops/lib/core.js` | 3 处 `DEFAULT_ROOT` / `DEFAULT_HOME` / `HOME` 默认值由本机绝对路径改为占位符；新增 `GATEOPS_ROOT` 环境变量覆盖（1 行注释 + 2 个表达式） |
| 2 | `plugins/dsh-tool-gate-ops-loop/lib/loop.js` | `home` / `gateOpsRoot` / `HOME` 默认值泛型化；新增 `DSH_HOME` / `GATEOPS_ROOT` 环境变量覆盖 |
| 3 | `plugins/dsh-tool-gate-ops/lib/core.js` | 2 处注释中的内部历史事件描述改写为中性表述（「防止内部标识进入对外输出」「历史风险中外泄的正是系统名」） |
| 4 | `plugins/dsh-tool-gate-ops/test-gateops.mjs` | 1 个测试夹具路径与断言字符串泛型化；1 个用例名中的历史事件标签改为「历史风险类」 |
| 5 | `tests/loop-e2e.mjs` / `loop-negative.mjs` | 5 个绝对路径常量改为 `process.env.* || 占位符`；用法注释中的绝对路径改为相对路径；Playwright 导入由绝对路径改为包名 |
| 6 | `tests/loop-e2e.mjs` | 注释中「不碰某公网 IP」改为「不触碰任何外部主机」 |
| 7 | `cordis.patch.yml`（两份） | **不发布原件**，改为 `config/*.example.yml` 手写样例：路径全为占位符、项目名泛型化、内部事项描述删除 |
| 8 | `test-gateops.mjs` / `loop-e2e.mjs` | 测试夹具中的内部业务档案名共 11 处，按 CHANGELOG 的 `project-a~h` 映射约定泛型化为 `project-a` |
| 9 | `*.bak-*` / `backup/` / `agent.cordis.yml.bak-adopt-*` | **不发布** |
| 10 | 其余 8 个文件 | 与本地真源逐字一致（0 字节差异） |

**没有改动的部分**：所有判定逻辑、错误码、哈希算法、状态机、工具契约、persona 文本、验证断言、用例计数。`node --check` 覆盖全部 7 个 `.js` / `.mjs`，`bash -n` 覆盖全部 2 个 `.sh`，均通过。

---

## 3. 保留项（经判断不属于敏感信息）

- `@wisediag/*` 包作用域与 `WISEDIAG_*` 环境变量前缀：是包标识符 / 脱敏词典规则，不是私有数据；改名会破坏 `package.json` / `cordis.patch.yml` / 测试脚本之间的一致性。
- `gateops-loop-demo`、`demo-project`、`project-a` 等示例项目名：均为隔离验证用虚构名或代号。
- 测试数据中的 `10.20.30.40`、`a@b.com`、`sk-abcdefghijklmnop`、`127.0.0.1`：均为脱敏自测的**假串**，用于断言脱敏规则生效。
- 错误码、计划 ID 前缀、日志格式：属于公开接口契约。

---

## 4. 发布副本与真源的关系

```
本地真源（私有）  ──复制 + 脱敏──▶  integrations/dsh/（PUBLIC）
     ▲                                      │
     └──────── 逻辑一致，仅路径与措辞不同 ─────┘
```

- 发布副本中的 `/path/to/...` 是**故意的占位符**，不是可运行默认值；未配置即 fail-closed。
- 真源中的实际路径、项目白名单、套件登记、profile 配置**不在本仓库**，也不应被提交。
- 本快照对应 gate-ops `3.3.0`，验证日期 `2026-11-08`；后续真源演进不自动同步到这里。

---

## 5. 发布前终检清单

- [x] 宽词表敏感扫描零命中
- [x] 无 `.bak` / `backup` / 临时文件
- [x] 无凭据文件、无私钥、无 `.env`
- [x] 全部 JS / MJS `node --check` 通过
- [x] 全部 Shell `bash -n` 通过
- [x] 配置样例全部使用占位符
- [x] 逐文件 diff 复核，确认只改路径与措辞
- [x] 本地真源 `git diff` 未被本次发布操作改动
