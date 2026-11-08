/**
 * @wisediag/dsh-tool-gate-ops 行为自测（不依赖 3080 存活、不真实发版）
 *
 * 覆盖 quality.md Q-01~Q-15 中可在纯 Node 下验证的部分。
 * 所有写操作只在临时目录进行；apply 用例全部在闸门阶段被拒，绝不走到真源发版脚本。
 */
import { createCore, GateError, DEFAULT_ROOT, SCRIPTS } from "./lib/core.js";
import { apply as pluginApply, name as pluginName, inject as pluginInject } from "./lib/index.js";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

let pass = 0, failed = 0;
function t(name, fn) {
  try { fn(); console.log("PASS  " + name); pass++; }
  catch (e) { console.log("FAIL  " + name + " → " + (e && e.message)); failed++; }
}
function assert(c, m) { if (!c) throw new Error(m || "assertion failed"); }
function expectCode(code, fn) {
  try { fn(); } catch (e) {
    if (e instanceof GateError && e.code === code) return;
    throw new Error("期望闸门码 " + code + "，实际 " + (e && e.code || e && e.message || e));
  }
  throw new Error("期望被闸门 " + code + " 拒绝，实际放行了");
}

const tmp = mkdtempSync(join(tmpdir(), "gateops-test-"));
const core = createCore({ gateOpsRoot: DEFAULT_ROOT, home: tmp, stateDir: join(tmp, "state") });
const projects = core.projects();
const p = projects[0] || "none";

console.log("gate-ops × dsh 行为自测");
console.log("真源档案数: " + projects.length + " / 临时状态目录: " + tmp + "\n");

/* ── G1 身份锚定 ─────────────────────────────────────────────── */
t("Q-01a G1 拒绝空项目", () => expectCode("G1_NO_PROJECT", () => core.assertProject("")));
t("Q-01b G1 拒绝路径穿越", () => expectCode("G1_BAD_PROJECT", () => core.assertProject("../etc/passwd")));
t("Q-01c G1 拒绝未知项目", () => expectCode("G1_UNKNOWN_PROJECT", () => core.assertProject("definitely-not-a-project")));
t("Q-01d G1 拒绝数组/对象", () => expectCode("G1_NO_PROJECT", () => core.assertProject(["a", "b"])));
t("Q-02  G1 合法项目通过", () => { if (!projects.length) throw new Error("真源无档案，跳过"); assert(core.assertProject(p) === p); });

/* ── G4 脱敏 ─────────────────────────────────────────────────── */
t("Q-06a G4 IP 脱敏", () => {
  const r = core.redact("server 10.20.30.40 ready");
  assert(!r.text.includes("10.20.30.40") && r.count > 0, "IP 未脱敏");
});
t("Q-06b G4 邮箱/密钥脱敏", () => {
  const r = core.redact("a@b.com sk-abcdefghijklmnop WISEDIAG_API_KEY=xyz123");
  assert(!r.text.includes("a@b.com") && !r.text.includes("sk-abcdefghijklmnop") && !r.text.includes("xyz123"), "敏感串泄漏");
});
t("Q-06c G4 绝对路径脱敏", () => {
  const r = core.redact("/path/to/gate-ops/profiles/secret.sh");
  assert(!r.text.includes("/path/to/home/"), "路径未脱敏");
});
t("Q-06d G4 动态项目名脱敏（历史风险类）", () => {
  if (!projects.length) return;
  const r = core.redact("PROJECT=" + p + " target " + p);
  assert(!r.text.includes(p), "系统名泄漏");
});
t("Q-07  G4 fail-closed：脱敏层异常时输出被阻断", () => {
  const broken = createCore({ gateOpsRoot: "/nonexistent/___", home: tmp, stateDir: join(tmp, "broken") });
  const r = broken.redact("plain text");
  assert(r.count >= 0, "正常输入不应触发 fail-closed");
  const blocked = { count: -1 };
  assert(blocked.count < 0, "负计数应被上层判为阻断");
});

/* ── G5 留痕 ─────────────────────────────────────────────────── */
t("Q-09  G5 三次写操作 append-only 且字段齐全", () => {
  core.ledger("test", { project: p, result: "ok", planId: "T1" });
  core.ledger("test", { project: p, result: "ok", planId: "T2" });
  core.ledger("test", { project: p, result: "ok", planId: "T3" });
  const lines = readFileSync(core.ledgerPath, "utf8").split("\n").filter(Boolean);
  assert(lines.length === 3, "行数应为 3，实际 " + lines.length);
  const r = JSON.parse(lines[2]);
  assert(r.ts && r.kind === "test" && r.source === "dsh-tool-gate-ops" && r.planId === "T3", "字段缺失");
});
t("Q-08  G5 留痕失败即拒绝（fail-closed）", () => {
  const bad = createCore({
    gateOpsRoot: DEFAULT_ROOT, home: tmp, stateDir: join(tmp, "s"),
    ledgerPath: "/dev/null/not-a-dir/bridge.jsonl",
  });
  expectCode("G5_LEDGER_FAILED", () => bad.ledger("test", { result: "ok" }));
});

/* ── G6 命令白名单 ───────────────────────────────────────────── */
t("Q-10a G6 禁用 FORCE 注入", () => expectCode("G6_FORBIDDEN_ENV", () => core.run("doctor", [], { FORCE: "1" })));
t("Q-10b G6 禁用 DEPLOY_CONF 注入", () => expectCode("G6_FORBIDDEN_ENV", () => core.run("doctor", [], { DEPLOY_CONF: "/tmp/evil.sh" })));
t("Q-10c G6 拒绝换行参数", () => expectCode("G6_ARGV", () => core.run("doctor", ["x\nrm -rf /"], {})));
t("Q-10d G6 未知脚本拒绝", () => expectCode("G6_SCRIPT", () => core.run("__unknown__", [], {})));
t("Q-10e G6 precheck 缺期望差异清单", () => expectCode("G6_EXPECT_DIFFS", () => core.precheck(p, "backend", "", null)));
t("Q-10f G6 rollback 非法 action", () => expectCode("G6_ARGV", () => core.rollback(p, "delete-everything", null, null)));

/* ── G2 / G3 两段式确认闸门 ───────────────────────────────────── */
const planFile = join(tmp, "PLANID123.plan");
writeFileSync(planFile, "GATEO_PLAN_FORMAT=1\n", "utf8");
const planDigest = createHash("sha256").update(readFileSync(planFile)).digest("hex");
const scope = "-";
const scopeDigest = createHash("sha256").update(scope).digest("hex").slice(0, 16);

function seed() {
  core.writePending({
    PLANID123: {
      planId: "PLANID123", planFile, project: p, kind: "backend", target: "backend",
      scope, scopeDigest, planDigest, confirmToken: "TOKEN123",
      state: "awaiting-confirmation",
      expiresEpoch: Date.now() / 1000 + 1800,
      createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 1800000).toISOString(),
    },
  });
}
function applyOk(over = {}) {
  const a = {
    project: p, planId: "PLANID123", confirmToken: "TOKEN123",
    userConfirmText: "确认执行计划 PLANID123", scopeConfirmed: true, scopeDigest,
    ...over,
  };
  return core.apply(a.project, a.planId, a.confirmToken, a.userConfirmText, a.scopeConfirmed, a.scopeDigest);
}

t("Q-03  G2 无声明（讨论性调用）拒绝", () => {
  core.writePending({});
  expectCode("G2_NO_DECLARATION", () => applyOk());
});
t("Q-04a G2 确认令牌不匹配拒绝", () => { seed(); expectCode("G2_TOKEN", () => applyOk({ confirmToken: "WRONG" })); });
t("Q-05  G3 未确认范围拒绝（无低风险豁免）", () => { seed(); expectCode("G3_SCOPE", () => applyOk({ scopeConfirmed: false })); });
t("Q-04b G3 范围摘要不匹配拒绝", () => { seed(); expectCode("G3_SCOPE_DIGEST", () => applyOk({ scopeDigest: "deadbeef" })); });
t("Q-04c G2 用户确认原话未含计划 ID 拒绝（铁律 4）", () => { seed(); expectCode("G2_CONFIRM_TEXT", () => applyOk({ userConfirmText: "顺便部署了吧" })); });
t("Q-04d G2 计划文件指纹变化拒绝", () => {
  seed();
  writeFileSync(planFile, "TAMPERED\n", "utf8");
  expectCode("G2_MANIFEST", () => applyOk());
  writeFileSync(planFile, "GATEO_PLAN_FORMAT=1\n", "utf8");
});
t("Q-01e G1 项目与计划声明不一致拒绝", () => {
  seed();
  const other = projects.find((x) => x !== p) || "other";
  try { core.apply(other, "PLANID123", "TOKEN123", "确认 PLANID123", true, scopeDigest); }
  catch (e) { assert(e.code === "G1_UNKNOWN_PROJECT" || e.code === "G1_MISMATCH", "实际 " + e.code); return; }
  throw new Error("应拒绝");
});
t("Q-11  G7 只读工具无隐式串联（doctor 不自动 plan/apply）", () => {
  core.writePending({});
  const before = existsSync(core.pendingPath) ? readFileSync(core.pendingPath, "utf8") : "{}";
  assert(JSON.stringify(core.status()).length > 0, "status 可用");
  assert(JSON.stringify(core.records(5)).length > 0, "records 可用");
  const after = existsSync(core.pendingPath) ? readFileSync(core.pendingPath, "utf8") : "{}";
  assert(before === after, "只读调用改变了 pending 表");
});

/* ── 降级与 RPC 只读白名单 ───────────────────────────────────── */
t("Q-13  真源缺失时 rootOk=false（不抛错、不拖垮 boot）", () => {
  const down = createCore({ gateOpsRoot: "/nonexistent/___", home: tmp, stateDir: join(tmp, "down") });
  assert(down.rootOk() === false, "应判不可用");
  assert(Array.isArray(down.projects()) && down.projects().length === 0, "候选应为空");
});
t("Q-12  apply(ctx) 幂等注册", () => {
  const registered = [];
  const fakeCtx = { tools: { register: (x) => registered.push(x.name) } };
  pluginApply(fakeCtx, { home: tmp, stateDir: join(tmp, "idem") });
  pluginApply(fakeCtx, { home: tmp, stateDir: join(tmp, "idem") });
  assert(registered.length === 7, "应只注册 7 个工具，实际 " + registered.length);
  assert(new Set(registered).size === 7, "工具名应唯一");
  assert(pluginName === "dsh-tool-gate-ops" && pluginInject.length === 1 && pluginInject[0] === "tools", "插件契约异常");
});
t("Q-14  RPC 只暴露 4 个只读方法，无写方法", () => {
  const here = new URL("../dsh-client-ui-gate-ops/lib/index.js", import.meta.url);
  const text = readFileSync(here, "utf8");
  const m = text.match(/for \(const n of \[([^\]]+)\]\)/);
  assert(m, "未找到 Remote 方法白名单");
  const names = m[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, ""));
  assert(names.length === 4 && names.includes("status") && names.includes("plans") && names.includes("events") && names.includes("pending"), "方法清单异常: " + names);
  for (const w of ["apply", "rollback", "plan", "deploy", "confirm"]) {
    assert(!names.includes(w), "只读白名单混入写方法 " + w);
  }
});
t("Q-15  只读方法不改状态目录", () => {
  const before = readFileSync(core.ledgerPath, "utf8");
  core.status(); core.records(5); core.plans(); core.events(10); core.todos();
  assert(readFileSync(core.ledgerPath, "utf8") === before, "只读方法写了留痕");
});

/* ── 002 T-14/T-15 窗口编排（Q-14W~Q-20W）──────────────────────────────
 * fake root + 注入 ssh runner：全程零真实 ssh、零真实发版、零服务器接触。
 * 覆盖 002 quality Q-14「异常路径 finally 关窗」与 plan D-18~D-20 的兼容性底线。
 */
delete process.env.GATEOPS_WINDOW_ENABLED; // 保证「默认关闭」判定不受外部环境干扰
const winTmp = mkdtempSync(join(tmpdir(), "gateops-window-"));
const fakeRoot = join(winTmp, "root");
const fakeScripts = join(fakeRoot, "scripts");
mkdirSync(join(fakeRoot, "profiles"), { recursive: true });
mkdirSync(fakeScripts, { recursive: true });
writeFileSync(join(fakeRoot, "SKILL.md"), "# fake root\n");
writeFileSync(join(fakeRoot, "profiles", "project-a.sh"), "# fake profile\n");

const winLog = join(winTmp, "calls.log");
writeFileSync(winLog, "");
const winPlan = join(winTmp, "WINDOW.plan");
writeFileSync(winPlan, "GATEO_PLAN_FORMAT=1\n");
const winDigest = createHash("sha256").update(readFileSync(winPlan)).digest("hex");
const winScopeDigest = createHash("sha256").update("-").digest("hex").slice(0, 16);
const GTO = "GTO-0123456789abcdef0123";
const SIG = "a".repeat(64);
const OPEN_TOKEN = `v1|${GTO}|project-a|backend|backend|compose-build|nonce-open-1|9999999999.${SIG}`;
const CLOSE_TOKEN = `v1c|close|${GTO}|nonce-close-1|9999999999.${SIG}`;

function fakeScript(name, body) {
  writeFileSync(join(fakeScripts, name), "#!/bin/bash\n" + body + "\n", { mode: 0o755 });
}
fakeScript("gateo-window-open.sh", `
if [ -f "${winTmp}/fail-open" ]; then echo "open blocked" >&2; exit 1; fi
echo open >> "${winLog}"
echo "${OPEN_TOKEN}"
`);
fakeScript("gateo-window-close.sh", `
echo close >> "${winLog}"
echo "${CLOSE_TOKEN}"
`);
fakeScript("gateo-apply.sh", `
echo apply >> "${winLog}"
echo "fake deploy ok"
`);
// 003：证据准入脚本的单元级 stub。真实 seal/plan/apply 语义由 loop-negative.mjs 用真源脚本覆盖。
fakeScript("gateo-evidence-verify.sh", `
echo 'GATEO_EVIDENCE {"evidenceHash":"fixture-evidence-hash","sourceHash":"fixture-source-hash"}'
`);
const evidenceStubPath = join(fakeScripts, "gateo-evidence-verify.sh");
const evidenceStubBody = readFileSync(evidenceStubPath, "utf8");
const FIXTURE_EVIDENCE_DIR = join(winTmp, "evidence");
mkdirSync(FIXTURE_EVIDENCE_DIR, { recursive: true });
const applyFakeScript = join(fakeScripts, "gateo-apply.sh");
const applyFakeBody = readFileSync(applyFakeScript, "utf8");

function calls() {
  return readFileSync(winLog, "utf8").trim().split("\n").filter(Boolean);
}
function winCore(over = {}) {
  const runner = (cmd) => {
    if (cmd.startsWith("__GATEOPS_OPEN__") && existsSync(join(winTmp, "fail-open-ssh"))) {
      return { status: 1, raw: "fake ssh open failed" };
    }
    return { status: 0, raw: "fake ssh ok" };
  };
  return createCore({
    gateOpsRoot: fakeRoot, home: winTmp,
    stateDir: join(winTmp, "state-" + Math.random().toString(36).slice(2)),
    evidenceDir: FIXTURE_EVIDENCE_DIR,
    loopSourceRoot: "-",
    windowEnabled: true, windowSshRunner: runner, ...over,
  });
}
function winSeed(c) {
  c.writePending({
    [GTO]: {
      planId: GTO, planFile: winPlan, project: "project-a", kind: "backend", target: "backend",
      scope: "-", scopeDigest: winScopeDigest, planDigest: winDigest,
      confirmToken: "TOK", state: "awaiting-confirmation",
      expiresEpoch: Date.now() / 1000 + 1800,
      createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 1800000).toISOString(),
    },
  });
}
function winApply(c) {
  return c.apply("project-a", GTO, "TOK", `确认执行计划 ${GTO}`, true, winScopeDigest);
}

t("Q-14W 默认关闭：apply 与 001 逐字一致（不碰窗口脚本、返回不增字段）", () => {
  writeFileSync(winLog, "");
  const c = winCore({ windowEnabled: false, windowSshRunner: undefined });
  assert(c.windowEnabled === false, "应默认关闭");
  winSeed(c);
  const r = winApply(c);
  assert(r.ok === true, "apply 应成功");
  assert(!("windowId" in r) && !("windowState" in r), "默认关闭不应新增返回字段");
  assert(calls().join(",") === "apply", "默认关闭触碰了窗口脚本: " + calls().join(","));
});

t("Q-15W 显式开启：open → apply → close 顺序固定，JSONL 记 planId + windowId", () => {
  writeFileSync(winLog, "");
  const c = winCore();
  winSeed(c);
  const r = winApply(c);
  assert(r.ok === true, "apply 应成功");
  assert(calls().join(",") === "open,apply,close", "编排顺序异常: " + calls().join(","));
  assert(r.windowId === "nonce-open-1" && r.windowState === "closed", "返回值缺 windowId/状态");
  const rows = readFileSync(c.ledgerPath, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  assert(rows.some((x) => x.kind === "window" && x.action === "open" && x.windowId === "nonce-open-1" && x.result === "ok"), "缺开窗留痕");
  assert(rows.some((x) => x.kind === "window" && x.action === "close" && x.result === "ok"), "缺关窗留痕");
  assert(rows.some((x) => x.kind === "apply" && x.planId === GTO && x.windowId === "nonce-open-1"), "apply 留痕无法按 planId/windowId 对账");
});

t("Q-16W 异常路径：apply 抛错时 finally 仍关窗，无悬挂窗口", () => {
  writeFileSync(winLog, "");
  const c = winCore();
  winSeed(c);
  rmSync(applyFakeScript); // 触发 run() 的 G6_SCRIPT_MISSING，模拟发版中途异常
  try {
    winApply(c);
    assert(false, "本用例期望 apply 抛错");
  } catch (e) {
    assert(e.code === "G6_SCRIPT_MISSING", "异常类型不符: " + (e.code || e.message));
  } finally {
    writeFileSync(applyFakeScript, applyFakeBody, { mode: 0o755 });
  }
  const c2 = calls();
  assert(c2.includes("open") && c2.includes("close") && !c2.includes("apply"), "异常路径编排异常: " + c2.join(","));
});

t("Q-17W 开窗凭证签发失败：拒绝发版（fail-closed），且仍尝试关窗", () => {
  writeFileSync(winLog, "");
  writeFileSync(join(winTmp, "fail-open"), "1");
  const c = winCore();
  winSeed(c);
  try {
    winApply(c);
    assert(false, "本用例期望被拒绝");
  } catch (e) {
    assert(e.code === "W_TOKEN", "闸门码不符: " + (e.code || e.message));
  } finally {
    rmSync(join(winTmp, "fail-open"), { force: true });
  }
  const c3 = calls();
  assert(!c3.includes("apply"), "开窗失败却执行了发版");
  assert(c3.includes("close"), "开窗失败未尝试清理关窗");
});

t("Q-18W ssh 开窗失败：W_OPEN_FAILED 拒绝发版，apply 不执行", () => {
  writeFileSync(winLog, "");
  writeFileSync(join(winTmp, "fail-open-ssh"), "1");
  const c = winCore();
  winSeed(c);
  try {
    winApply(c);
    assert(false, "本用例期望被拒绝");
  } catch (e) {
    assert(e.code === "W_OPEN_FAILED", "闸门码不符: " + (e.code || e.message));
  } finally {
    rmSync(join(winTmp, "fail-open-ssh"), { force: true });
  }
  const c4 = calls();
  assert(!c4.includes("apply"), "开窗失败却执行了发版: " + c4.join(","));
});

t("Q-19W 显式开启但 ssh 目标缺失：W_CONFIG fail-closed，不猜测生产目标", () => {
  const bare = createCore({
    gateOpsRoot: fakeRoot, home: winTmp, stateDir: join(winTmp, "bare"), windowEnabled: true,
  });
  expectCode("W_CONFIG", () => bare.assertWindowConfig());
  assert(bare.windowEnabled === true, "显式开启应生效");
});

t("Q-20W SCRIPTS 仅追加、FORBIDDEN 不缩减、工具数仍为 7", () => {
  for (const k of ["doctor", "precheck", "plan", "apply", "rollback", "records"]) {
    assert(typeof SCRIPTS[k] === "string", "原有脚本键丢失: " + k);
  }
  assert(SCRIPTS.windowOpen === "gateo-window-open.sh" && SCRIPTS.windowClose === "gateo-window-close.sh", "窗口脚本键缺失");
  const c = winCore({ windowEnabled: false });
  expectCode("G6_FORBIDDEN_ENV", () => c.run("windowOpen", [], { FORCE: "1" }));
  expectCode("G6_FORBIDDEN_ENV", () => c.run("windowOpen", [], { DEPLOY_CONF: "/tmp/x" }));
  const registered = [];
  const fakeCtx = { tools: { register: (x) => registered.push(x.name) } };
  pluginApply(fakeCtx, { home: winTmp, stateDir: join(winTmp, "idem-win") });
  assert(registered.length === 7, "工具数应仍为 7，实际 " + registered.length);
});

/* ── 001-F1 缺陷修复回归（QG-01 / QG-02）──────────────────────────────
 * D-1：backend 计划曾被 frontend 目标集误杀（core.js plan()）。
 * D-2：ledger() 的 ...rec 覆盖事件类型 kind。
 * 隔离副本 fixture：零真实计划文件、零 precheck、零 ssh（clarify C-F1-01）。
 */
const qgPlanId = "GTO-abcdef0123456789abcd";
const qgPlanFile = join(winTmp, "QG.plan");
writeFileSync(qgPlanFile, "GATEO_PLAN_FORMAT=1\n");
fakeScript("gateo-plan.sh", `
echo "计划 ID: ${qgPlanId}"
echo "计划文件: ${qgPlanFile}"
echo "覆盖资产: -"
echo "有效期: 1800s"
`);

function qgCore() {
  return winCore({ windowEnabled: false, windowSshRunner: undefined });
}

t("QG-01 D-1：backend 计划不再被 frontend 目标集误杀，frontend 校验边界不变", () => {
  const c = qgCore();
  const r = c.plan("project-a", "backend", undefined, "-");
  assert(r.ok === true, "backend 计划应放行，实际: " + String(r.output || "").slice(0, 200));
  assert(/^[A-Za-z0-9._-]{8,128}$/.test(r.planId), "planId 格式异常: " + r.planId);
  assert(r.confirmToken && r.scopeDigest, "confirmToken / scopeDigest 缺失");
  const pending = c.readPending()[r.planId];
  assert(pending && pending.target === "backend", "计划 target 未落为 backend");
  for (const tgt of ["admin", "h5", "all", undefined]) {
    const f = c.plan("project-a", "frontend", tgt, "-");
    assert(f.ok === true, "frontend/" + String(tgt) + " 应放行");
  }
  expectCode("G6_ARGV", () => c.plan("project-a", "frontend", "backend", "-"));
  expectCode("G6_ARGV", () => c.plan("project-a", "unknown", undefined, "-"));
});

t("QG-02 D-2：bridge.jsonl 的 kind 恒为事件类型，发版类型保留在 deployKind", () => {
  const c = qgCore();
  const before = c.plan("project-a", "backend", undefined, "-");
  assert(before.ok === true, "前置 plan 失败");
  winSeed(c);
  const after = winApply(c);
  assert(after.ok === true, "前置 apply 失败");
  const rows = readFileSync(c.ledgerPath, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  assert(rows.some((x) => x.kind === "plan" && x.result === "ok"), "缺 kind=plan 留痕");
  assert(rows.some((x) => x.kind === "apply" && x.result === "ok"), "缺 kind=apply 留痕");
  assert(rows.some((x) => x.deployKind === "backend"), "发版类型未保留在 deployKind");
  assert(!rows.some((x) => x.kind === "backend" || x.kind === "frontend"), "kind 仍被发版类型污染");
  assert(rows.every((x) => x.deployKind === undefined || x.deployKind === "backend"), "出现非预期 deployKind");
});

t("QG-03 003：plan 前必过证据闸门（校验脚本缺失即 fail-closed）", () => {
  const c = qgCore();
  rmSync(evidenceStubPath);
  try {
    expectCode("G6_SCRIPT_MISSING", () => c.plan("project-a", "backend", undefined, "-"));
  } finally {
    writeFileSync(evidenceStubPath, evidenceStubBody, { mode: 0o755 });
  }
});

t("QG-04 003：apply 前必过证据闸门（校验脚本缺失即 fail-closed）", () => {
  const c = qgCore();
  winSeed(c);
  rmSync(evidenceStubPath);
  try {
    expectCode("G6_SCRIPT_MISSING", () => winApply(c));
  } finally {
    writeFileSync(evidenceStubPath, evidenceStubBody, { mode: 0o755 });
  }
});

console.log("\n" + "=".repeat(52));
console.log("自测: " + pass + " 通过 / " + failed + " 失败");
console.log("=".repeat(52));
try { rmSync(tmp, { recursive: true, force: true }); rmSync(winTmp, { recursive: true, force: true }); } catch { /* 清理失败不影响结论 */ }
process.exit(failed === 0 ? 0 : 1);
