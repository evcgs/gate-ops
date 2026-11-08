#!/usr/bin/env node
/**
 * 003 · 负例矩阵 N-1~N-6 × A/B 双路径（loop-negative）
 *
 * A 路径：经 001 插件真实 defineTool 入口（gateops_plan / gateops_apply.execute）
 * B 路径：绕过 persona 与工具层，直接 createCore() 调 core.plan() / core.apply()
 * 两条路径都必须被拒且错误码可区分；任一放行即判 AC-02 未达。
 *
 * 全程 REPLICA 逐字副本 + 真源 gateo-evidence-verify.sh，零服务器、零真源写入。
 * 用法: node tests/loop-negative.mjs
 */
import { spawnSync } from "node:child_process";
import {
  mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync,
  rmSync, chmodSync, readdirSync, cpSync, appendFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const SRC = process.env.GATEOPS_ROOT || "/path/to/gate-ops";
const CORE = process.env.GATEOPS_DSH_CORE || "/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/core.js";
const PLUGIN = process.env.GATEOPS_DSH_PLUGIN || "/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops/lib/index.js";
const PROJECT = "gateops-loop-neg";

const T = mkdtempSync(join(tmpdir(), "gateops-loop-neg-"));
const REPLICA = join(T, "gateops-src");
const PLAN_DIR = join(T, "plans");

let pass = 0, fail = 0, caseNo = 0;
function t(name, fn) {
  try { fn(); console.log("PASS  " + name); pass++; }
  catch (e) { console.log("FAIL  " + name + " → " + (e && e.message)); fail++; }
}
function assert(c, m) { if (!c) throw new Error(m || "assertion failed"); }

function buildReplica() {
  for (const d of ["scripts", "profiles", "records", "evidence"]) mkdirSync(join(REPLICA, d), { recursive: true });
  for (const f of readdirSync(join(SRC, "scripts")).filter((x) => x.endsWith(".sh"))) {
    cpSync(join(SRC, "scripts", f), join(REPLICA, "scripts", f));
    chmodSync(join(REPLICA, "scripts", f), 0o755);
  }
  cpSync(join(SRC, "SKILL.md"), join(REPLICA, "SKILL.md"));
  if (existsSync(join(SRC, "VERSION"))) cpSync(join(SRC, "VERSION"), join(REPLICA, "VERSION"));
  writeFileSync(join(REPLICA, "records", PROJECT + ".md"), "# 负例矩阵隔离台账\n");
  writeFileSync(join(REPLICA, "profiles", PROJECT + ".sh"), [
    "#!/bin/bash",
    'DEPLOY_MODE="custom"',
    'GATEO_ENV="prod"',
    'SERVER="local@127.0.0.1"',
    `GATEO_PLAN_DIR="${PLAN_DIR}"`,
    'GATEO_PLAN_TTL=1800',
    'GATEO_PLAN_SKIP_PRECHECK=1',
    `LOCAL_APP_DIR="${join(T, "app")}"`,
    "",
  ].join("\n"));
  mkdirSync(PLAN_DIR, { recursive: true });
  mkdirSync(join(T, "app"), { recursive: true });
  writeFileSync(join(T, "app", "index.html"), "baseline\n");
}

function baseRec(over = {}) {
  const now = new Date();
  return {
    v: 1, project: PROJECT, scopePaths: ["index.html"],
    suite: "loop-negative:fixture",
    result: { exit: 0, failed: 0, passed: 3, skipped: 0 },
    sourceHash: createHash("sha256").update("index.html:baseline").digest("hex"),
    timestamp: now.toISOString(),
    expiresAt: new Date(now.getTime() + 1800000).toISOString(),
    ...over,
  };
}

const { createCore } = await import(pathToFileURL(CORE).href);
const { apply: pluginApply } = await import(pathToFileURL(PLUGIN).href);

function makeCase() {
  caseNo++;
  const dir = join(T, "case-" + caseNo);
  const stateDir = join(dir, "state");
  const evidenceDir = join(stateDir, "evidence");
  mkdirSync(evidenceDir, { recursive: true });
  const config = {
    gateOpsRoot: REPLICA, home: dir, stateDir, evidenceDir,
    loopSourceRoot: "-", recordEnabled: false, timeoutMs: 120000,
  };
  const core = createCore(config);
  const tools = {};
  pluginApply({ tools: { register: (x) => { tools[x.name] = x; } } }, config);
  return { core, tools, evidenceDir, stateDir };
}

function seal(c, rec) {
  const r = spawnSync("bash", [
    join(REPLICA, "scripts", "gateo-evidence-verify.sh"),
    "seal", PROJECT, c.evidenceDir, JSON.stringify(rec),
  ], { encoding: "utf8", timeout: 30000 });
  assert(r.status === 0, "seal 失败: " + String(r.stderr || r.stdout || ""));
  return JSON.parse(String(r.stdout).trim().split("\n").find((s) => s.startsWith("GATEO_EVIDENCE ")).slice("GATEO_EVIDENCE ".length));
}

function planA(c) {
  return Promise.resolve(c.tools.gateops_plan.execute({ project: PROJECT, kind: "backend", expect_diffs: "-" }));
}
function planB(c) { return c.core.plan(PROJECT, "backend", undefined, "-"); }
async function applyA(c, over = {}) {
  const r = await c.tools.gateops_apply.execute({
    project: PROJECT, plan_id: over.plan_id, confirm_token: over.confirm_token,
    user_confirm_text: over.user_confirm_text, scope_confirmed: true, scope_digest: over.scope_digest,
  });
  return typeof r === "string" ? JSON.parse(r) : r;
}
function applyB(c, over = {}) {
  try { c.core.apply(PROJECT, over.plan_id, over.confirm_token, over.user_confirm_text, true, over.scope_digest); }
  catch (e) { return { ok: false, code: e.code }; }
  return { ok: true };
}

async function codeOf(fn) {
  try {
    let r = await fn();
    if (typeof r === "string") { try { r = JSON.parse(r); } catch { /* 保持原样 */ } }
    if (r && r.ok === false) return r.code || "UNKNOWN";
    return "ALLOWED";
  } catch (e) {
    return e.code || "THROWN_" + String(e.message).slice(0, 40);
  }
}

buildReplica();
console.log("003 负例矩阵 · N-1~N-6 × A/B 双路径\n");

// ── N-1 无证据 ───────────────────────────────────────────────────────
{
  const cA = makeCase(), cB = makeCase();
  const a = await codeOf(() => planA(cA));
  const b = await codeOf(() => planB(cB));
  t("N-1/A 工具入口：无证据 plan 被 E_NO_EVIDENCE 拒绝", () => assert(a === "E_NO_EVIDENCE", "实际 " + a));
  t("N-1/B 绕过 persona 直调 core：无证据 plan 被 E_NO_EVIDENCE 拒绝", () => assert(b === "E_NO_EVIDENCE", "实际 " + b));
}

// ── N-2 证据过期 ─────────────────────────────────────────────────────
{
  const expired = baseRec({
    timestamp: new Date(Date.now() - 7200000).toISOString(),
    expiresAt: new Date(Date.now() - 3600000).toISOString(),
  });
  const cA = makeCase(), cB = makeCase();
  seal(cA, expired); seal(cB, expired);
  const a = await codeOf(() => planA(cA));
  const b = await codeOf(() => planB(cB));
  t("N-2/A 工具入口：过期证据被 E_EXPIRED 拒绝", () => assert(a === "E_EXPIRED", "实际 " + a));
  t("N-2/B 绕过 persona 直调 core：过期证据被 E_EXPIRED 拒绝", () => assert(b === "E_EXPIRED", "实际 " + b));
}

// ── N-3 证据篡改（改字段但不重算哈希）─────────────────────────────────
{
  const cA = makeCase(), cB = makeCase();
  for (const c of [cA, cB]) {
    const ev = seal(c, baseRec());
    const f = join(c.evidenceDir, PROJECT + ".jsonl");
    const rec = JSON.parse(readFileSync(f, "utf8").trim().split("\n").pop());
    rec.result.passed = 999;
    appendFileSync(f, JSON.stringify(rec) + "\n");
    void ev;
  }
  const a = await codeOf(() => planA(cA));
  const b = await codeOf(() => planB(cB));
  t("N-3/A 工具入口：篡改证据被 E_HASH_MISMATCH 拒绝", () => assert(a === "E_HASH_MISMATCH", "实际 " + a));
  t("N-3/B 绕过 persona 直调 core：篡改证据被 E_HASH_MISMATCH 拒绝", () => assert(b === "E_HASH_MISMATCH", "实际 " + b));
}

// ── N-4 项目 / 绑定与计划不一致 ───────────────────────────────────────
{
  const cA = makeCase(), cB = makeCase();
  for (const c of [cA, cB]) {
    seal(c, baseRec());
    const f = join(c.evidenceDir, PROJECT + ".jsonl");
    const rec = JSON.parse(readFileSync(f, "utf8").trim().split("\n").pop());
    rec.project = "some-other-project"; // append-only 追加错配证据行
    appendFileSync(f, JSON.stringify(rec) + "\n");
  }
  const a0 = await codeOf(() => planA(cA));
  const b0 = await codeOf(() => planB(cB));
  t("N-4/A 工具入口：证据 project 与计划不一致被 E_BINDING_MISMATCH 拒绝", () => assert(a0 === "E_BINDING_MISMATCH", "实际 " + a0));
  t("N-4/B 绕过 persona 直调 core：证据 project 与计划不一致被 E_BINDING_MISMATCH 拒绝", () => assert(b0 === "E_BINDING_MISMATCH", "实际 " + b0));
}
{
  const cA = makeCase(), cB = makeCase();
  const out = [];
  for (const c of [cA, cB]) {
    seal(c, baseRec());
    const r = c.core.plan(PROJECT, "backend", undefined, "-");
    assert(r.ok, "前置 plan 失败");
    // append-only 追加一条范围摘要不同的绑定，模拟计划与证据错配
    appendFileSync(join(c.evidenceDir, "bindings.jsonl"), JSON.stringify({
      v: 1, planId: r.planId, project: PROJECT, evidenceHash: "0".repeat(64),
      sourceHash: "0".repeat(64), planScopeDigest: "deadbeef", boundAt: new Date().toISOString(),
    }) + "\n");
    out.push({ plan_id: r.planId, confirm_token: r.confirmToken, scope_digest: r.scopeDigest, user_confirm_text: `确认执行发布计划 ${r.planId}` });
  }
  const a = await codeOf(() => applyA(cA, out[0]));
  const b = await codeOf(() => applyB(cB, out[1]));
  t("N-4/A 工具入口：绑定范围摘要错配被 E_BINDING_MISMATCH 拒绝", () => assert(a === "E_BINDING_MISMATCH", "实际 " + a));
  t("N-4/B 绕过 persona 直调 core：绑定范围摘要错配被 E_BINDING_MISMATCH 拒绝", () => assert(b === "E_BINDING_MISMATCH", "实际 " + b));
}

// ── N-5 测试失败但哈希自洽 ───────────────────────────────────────────
{
  const cA = makeCase(), cB = makeCase();
  const bad = baseRec({ result: { exit: 1, failed: 1, passed: 2, skipped: 0 } });
  seal(cA, bad); seal(cB, bad);
  const a = await codeOf(() => planA(cA));
  const b = await codeOf(() => planB(cB));
  t("N-5/A 工具入口：测试失败证据被 E_TEST_FAILED 拒绝", () => assert(a === "E_TEST_FAILED", "实际 " + a));
  t("N-5/B 绕过 persona 直调 core：测试失败证据被 E_TEST_FAILED 拒绝", () => assert(b === "E_TEST_FAILED", "实际 " + b));
}

// ── N-6 证据有效但缺用户确认原话 / planId ──────────────────────────────
{
  const cA = makeCase(), cB = makeCase();
  const out = [];
  for (const c of [cA, cB]) {
    seal(c, baseRec());
    const r = c.core.plan(PROJECT, "backend", undefined, "-");
    assert(r.ok, "前置 plan 失败");
    out.push({ plan_id: r.planId, confirm_token: r.confirmToken, scope_digest: r.scopeDigest, user_confirm_text: "顺便发了吧" });
  }
  const a = await codeOf(() => applyA(cA, out[0]));
  const b = await codeOf(() => applyB(cB, out[1]));
  t("N-6/A 工具入口：缺确认原话仍按铁律 4 拒绝 G2_CONFIRM_TEXT", () => assert(a === "G2_CONFIRM_TEXT", "实际 " + a));
  t("N-6/B 绕过 persona 直调 core：缺确认原话仍按铁律 4 拒绝 G2_CONFIRM_TEXT", () => assert(b === "G2_CONFIRM_TEXT", "实际 " + b));
  const noPlanA = await codeOf(() => applyA(cA, { ...out[0], plan_id: "GTO-" + "0".repeat(20) }));
  const noPlanB = await codeOf(() => applyB(cB, { ...out[1], plan_id: "GTO-" + "0".repeat(20) }));
  t("N-6/A 工具入口：无有效声明计划被 G2_NO_DECLARATION 拒绝", () => assert(noPlanA === "G2_NO_DECLARATION", "实际 " + noPlanA));
  t("N-6/B 绕过 persona 直调 core：无有效声明计划被 G2_NO_DECLARATION 拒绝", () => assert(noPlanB === "G2_NO_DECLARATION", "实际 " + noPlanB));
}

console.log("\n" + "=".repeat(56));
console.log("负例矩阵: " + pass + " 通过 / " + fail + " 失败（A/B 双路径）");
console.log("=".repeat(56));
try { rmSync(T, { recursive: true, force: true }); } catch { /* 清理失败不影响结论 */ }
console.log("清理: " + (existsSync(T) ? "未完成" : "临时目录已删除"));
process.exit(fail === 0 ? 0 : 1);
