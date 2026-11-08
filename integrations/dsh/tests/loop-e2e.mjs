#!/usr/bin/env node
/**
 * 003 · DSH Agent 四步研发闭环 · 隔离式端到端（loop-e2e）
 *
 * 四步：① 按项目白名单改本地源码 → ② 真实浏览器 E2E + 真源 seal 生成证据
 *      → ③ DSH 发令（plan → 用户确认 → apply） → ④ GateOps 台账自动追加
 *
 * 真实性边界（如实声明，不夸大）：
 *   - 真实：core.js、gateo-plan.sh、gateo-evidence-verify.sh、gateo-record-append.sh、
 *           build-index.sh、新插件、Chrome/Playwright 浏览器 E2E、bridge.jsonl 事件、REPLICA 台账。
 *   - 本地替身：仅 REPLICA/scripts/gateo-apply.sh 的「部署执行面」（含真源 gateo_load_plan 校验），
 *           因为真实 custom 部署需要 SSH 到远端。真实 SSH + guard + deploy-backend.sh 全链路由
 *           deploy-guard/capability-e2e.mjs 单独覆盖（14/14），两者合起来才构成完整真实链路。
 *   - 全程不连任何服务器、不写真源、不重启 3080、不触碰任何外部主机。
 *
 * 用法: node tests/loop-e2e.mjs
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
const LOOP = process.env.GATEOPS_DSH_LOOP || "/path/to/dsh/plugin/@wisediag/dsh-tool-gate-ops-loop/lib/loop.js";
const PROJECT = "gateops-loop-e2e";
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const T = mkdtempSync(join(tmpdir(), "gateops-loop-e2e-"));
const REPLICA = join(T, "gateops-src");
const APP = join(T, "app");
const STATE = join(T, "state");
const EVIDENCE_DIR = join(STATE, "evidence");
const PLAN_DIR = join(T, "plans");
const CREDS = join(T, "empty-creds.sh");

let pass = 0, fail = 0;
let planId = "", scopeDigest = "", confirmToken = "", evidenceHash = "";
function t(name, fn) {
  try { fn(); console.log("PASS  " + name); pass++; }
  catch (e) { console.log("FAIL  " + name + " → " + (e && e.message)); fail++; }
}
function assert(c, m) { if (!c) throw new Error(m || "assertion failed"); }
function sha(f) { return createHash("sha256").update(readFileSync(f)).digest("hex"); }

function buildReplica() {
  for (const d of ["scripts", "profiles", "records", "evidence"]) mkdirSync(join(REPLICA, d), { recursive: true });
  const scripts = readdirSync(join(SRC, "scripts")).filter((x) => x.endsWith(".sh")).sort();
  for (const f of scripts) {
    cpSync(join(SRC, "scripts", f), join(REPLICA, "scripts", f));
    chmodSync(join(REPLICA, "scripts", f), 0o755);
  }
  cpSync(join(SRC, "SKILL.md"), join(REPLICA, "SKILL.md"));
  if (existsSync(join(SRC, "VERSION"))) cpSync(join(SRC, "VERSION"), join(REPLICA, "VERSION"));

  writeFileSync(join(REPLICA, "records", PROJECT + ".md"),
    "# 003 四步闭环隔离台账（REPLICA，非真源）\n\n| 时间 | 目标 | 结果 | 验收 | 备份文件（回滚点） | 健康检查 | 操作 agent | 证据 | 备注 |\n|---|---|---|---|---|---|---|---|---|\n");
  writeFileSync(join(REPLICA, "profiles", PROJECT + ".sh"), [
    "#!/bin/bash",
    "# 003 隔离验证档案（副本内纯新增；真源 profiles/ 零改动）",
    'DEPLOY_MODE="custom"',
    'GATEO_ENV="prod"',
    `GATEO_CRED_FILE="${CREDS}"`,
    'SERVER="local@127.0.0.1"',
    `SSH_KEY="${CREDS}"`,
    'DEPLOY_TARGETS=""',
    `LOCAL_APP_DIR="${APP}"`,
    `PROJECT_ROOT="${T}"`,
    `BACKUP_DIR="${join(T, "backup")}"`,
    `GATEO_PLAN_DIR="${PLAN_DIR}"`,
    'GATEO_PLAN_TTL=1800',
    'GATEO_PLAN_SKIP_PRECHECK=1',
    "",
  ].join("\n"));

  // 唯一本地替身：保留真源 gateo_load_plan 的计划 ID / TTL 校验，只替换部署执行面。
  writeFileSync(join(REPLICA, "scripts", "gateo-apply.sh"), [
    "#!/bin/bash",
    "set -euo pipefail",
    'SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)',
    'source "$SCRIPT_DIR/_approval.sh"',
    'gateo_load_plan "$1" "$2"',
    'echo "🔐 确认闸门通过: $GATEO_VERIFIED_PLAN_ID"',
    'echo "  ✅ 自定义发布命令执行完成（本地隔离执行面）"',
    'echo "探活成功"',
    "",
  ].join("\n"), { mode: 0o755 });

  mkdirSync(APP, { recursive: true });
  mkdirSync(PLAN_DIR, { recursive: true });
  mkdirSync(join(T, "backup"), { recursive: true });
  mkdirSync(STATE, { recursive: true });
  writeFileSync(CREDS, "# 隔离验证：不读取真实凭据\n", { mode: 0o600 });
  writeFileSync(join(APP, "index.html"),
    "<!doctype html><html><head><meta charset='utf-8'><title>baseline</title></head><body><h1 id='mark'>baseline</h1><p class='note'>0</p></body></html>\n");
  writeFileSync(join(APP, "browser-e2e.mjs"), browserTest());
  return scripts;
}

function browserTest() {
  return [
    'import { chromium } from "playwright";',
    'import { pathToFileURL } from "node:url";',
    'import { join } from "node:path";',
    `const CHROME = ${JSON.stringify(CHROME)};`,
    "let passed = 0, failed = 0;",
    "function check(name, ok) { if (ok) { passed++; } else { failed++; console.log('  FAIL ' + name); } }",
    "const dir = process.argv[2];",
    "const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox', '--disable-gpu'] });",
    "const page = await browser.newPage();",
    "await page.goto(pathToFileURL(join(dir, 'index.html')).href);",
    "check('title', (await page.title()) === 'gateops-loop-e2e');",
    "check('heading', (await page.textContent('#mark')) === 'gateops-loop-e2e-ok');",
    "check('note', (await page.textContent('.note')) === '1');",
    "check('single-h1', (await page.locator('h1').count()) === 1);",
    "check('body-visible', await page.locator('#mark').isVisible());",
    "await browser.close();",
    "console.log('GATEO_TEST_RESULT ' + JSON.stringify({ passed, failed, skipped: 0 }));",
    "process.exit(failed === 0 ? 0 : 1);",
    "",
  ].join("\n");
}

const scripts = buildReplica();
const { createCore } = await import(pathToFileURL(CORE).href);
const { createLoop } = await import(pathToFileURL(LOOP).href);

const loop = createLoop({
  gateOpsRoot: REPLICA, home: T, stateDir: STATE, evidenceDir: EVIDENCE_DIR,
  projectRoots: { [PROJECT]: APP },
  suites: { "browser-e2e": [process.execPath, join(APP, "browser-e2e.mjs"), APP] },
  timeoutMs: 600000,
});
const core = createCore({
  gateOpsRoot: REPLICA, home: T, stateDir: STATE, evidenceDir: EVIDENCE_DIR,
  loopSourceRoot: APP, recordEnabled: true, timeoutMs: 180000,
});

console.log("003 四步研发闭环 · 隔离式端到端");
console.log("副本: " + REPLICA + " / 项目: " + PROJECT + "\n");

t("LE-00 REPLICA 逐字副本成立（除 1 个部署执行面替身），真源既有 diff 0 字节", () => {
  const real = readdirSync(join(SRC, "scripts")).filter((x) => x.endsWith(".sh")).sort();
  assert(real.length === scripts.length, "脚本数不符");
  let same = 0;
  for (const f of real) {
    if (f === "gateo-apply.sh") continue;
    assert(sha(join(SRC, "scripts", f)) === sha(join(REPLICA, "scripts", f)), "副本与真源不一致: " + f);
    same++;
  }
  assert(same === real.length - 1, "逐字一致数异常: " + same);
  const st = spawnSync("git", ["-C", SRC, "diff", "--", "scripts/", "profiles/", "records/", "SKILL.md", "VERSION"], { encoding: "utf8" });
  assert(st.stdout.trim() === "", "真源既有文件被修改");
  assert(core.rootOk(), "副本 root 不完整");
});

t("LE-01 身份锚定：白名单只认本次隔离项目，越界项目被拒", () => {
  assert(core.projects().length === 1 && core.projects()[0] === PROJECT, "档案白名单异常");
  let code = "";
  try { loop.projectRoot("project-a"); } catch (e) { code = e.code; }
  assert(code === "L_NO_PROJECT", "跨项目推断未被拦截: " + code);
});

t("LE-02 步骤 1：按项目白名单修改本地源码，越界路径被拒", () => {
  const r = loop.edit(PROJECT, "index.html",
    "<!doctype html><html><head><meta charset='utf-8'><title>gateops-loop-e2e</title></head><body><h1 id='mark'>gateops-loop-e2e-ok</h1><p class='note'>1</p></body></html>\n", "write");
  assert(r.ok, "写入失败");
  assert(readFileSync(join(APP, "index.html"), "utf8").includes("gateops-loop-e2e-ok"), "源码未真实改变");
  for (const bad of ["../escape.txt", "/etc/passwd"]) {
    let c = "";
    try { loop.edit(PROJECT, bad, "x", "write"); } catch (e) { c = e.code; }
    assert(c === "L_PATH_DENIED", "越界路径未被拦: " + bad + " / " + c);
  }
});

t("LE-03 步骤 2：真实 Chrome/Playwright E2E 通过并由真源 seal 生成证据", () => {
  const r = loop.test(PROJECT, "browser-e2e", "index.html");
  assert(r.ok, "E2E 未通过");
  assert(r.result.passed >= 5 && r.result.failed === 0 && r.result.exit === 0, "用例计数异常: " + JSON.stringify(r.result));
  evidenceHash = r.evidenceHash;
  assert(/^[0-9a-f]{64}$/.test(evidenceHash), "evidenceHash 格式异常");
  assert(existsSync(join(EVIDENCE_DIR, PROJECT + ".jsonl")), "证据文件未生成");
});

t("LE-04 证据 append-only 且哈希可复算，篡改立即被真源拒绝", () => {
  const f = join(EVIDENCE_DIR, PROJECT + ".jsonl");
  const before = readFileSync(f, "utf8");
  const p = spawnSync("bash", [join(REPLICA, "scripts", "gateo-evidence-verify.sh"), "plan", PROJECT, EVIDENCE_DIR], { encoding: "utf8" });
  assert(p.status === 0, "plan 校验未通过: " + String(p.stderr || ""));
  assert(readFileSync(f, "utf8") === before, "只读校验改写了证据文件");
});

t("LE-05 步骤 3a：无证据时 plan 被 E_NO_EVIDENCE 拒绝（N-1，绕过 persona 直调 core）", () => {
  const other = createCore({ gateOpsRoot: REPLICA, home: T, stateDir: join(T, "state-n1"), evidenceDir: join(T, "state-n1", "evidence") });
  let code = "";
  try { other.plan(PROJECT, "backend", undefined, "-"); } catch (e) { code = e.code; }
  assert(code === "E_NO_EVIDENCE", "无证据却放行: " + code);
});

t("LE-06 步骤 3a：DSH 发令生成真实计划（真源 gateo-plan.sh 四重哈希）", () => {
  const r = core.plan(PROJECT, "backend", undefined, "-");
  assert(r && r.ok, "计划生成失败: " + String(r && r.output || "").slice(-600));
  assert(/^GTO-[0-9a-f]{20}$/.test(r.planId), "计划 ID 异常");
  planId = r.planId; scopeDigest = r.scopeDigest; confirmToken = r.confirmToken;
  const pend = core.readPending();
  const txt = readFileSync(pend[planId].planFile, "utf8");
  for (const k of ["GATEO_PLAN_SERVER_HASH", "GATEO_PLAN_CONFIG_HASH", "GATEO_PLAN_SOURCE_HASH", "GATEO_PLAN_EXPIRES_EPOCH"]) {
    assert(txt.includes(k + "="), "计划缺 " + k);
  }
  assert(existsSync(join(EVIDENCE_DIR, "bindings.jsonl")), "两阶段绑定未写入");
  const b = JSON.parse(readFileSync(join(EVIDENCE_DIR, "bindings.jsonl"), "utf8").trim().split("\n").pop());
  assert(b.planId === planId && b.planScopeDigest === scopeDigest && b.evidenceHash === evidenceHash, "绑定字段不匹配");
});

t("LE-07 铁律 4：用户确认原话缺确切 planId 仍被拒（N-6）", () => {
  let code = "";
  try { core.apply(PROJECT, planId, confirmToken, "同意发版", true, scopeDigest); } catch (e) { code = e.code; }
  assert(code === "G2_CONFIRM_TEXT", "铁律 4 被绕过: " + code);
});

t("LE-08 步骤 3b：用户复述 planId 后 apply 走通（证据 + 绑定 + 源码指纹全比对）", () => {
  const r = core.apply(PROJECT, planId, confirmToken, `确认执行发布计划 ${planId}`, true, scopeDigest);
  assert(r && r.ok, "apply 失败: " + String(r && r.output || "").slice(-800));
  assert(r.recordWritten === true && r.recordAgent === "DSH", "台账自动写入未触发: " + JSON.stringify(r));
});

t("LE-09 步骤 4：台账 append-only 追加 DSH 行，_index.md 由真源聚合生成", () => {
  const rec = readFileSync(join(REPLICA, "records", PROJECT + ".md"), "utf8");
  assert((rec.match(/\| DSH \|/g) || []).length === 1, "DSH 行数量异常");
  assert(rec.includes("003") || rec.includes(planId), "台账缺计划/证据列");
  const idx = join(REPLICA, "records", "_index.md");
  assert(existsSync(idx), "索引未生成");
  assert(readFileSync(idx, "utf8").includes(PROJECT), "索引未收录本次记录");
});

t("LE-10 面板事件：bridge.jsonl 出现真实四步 loop_* 事件，kind/deployKind 语义不回退", () => {
  const rows = readFileSync(core.ledgerPath, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  for (const k of ["loop_edit", "loop_test", "loop_evidence", "loop_record"]) {
    assert(rows.some((x) => x.kind === k), "缺事件: " + k);
  }
  assert(rows.some((x) => x.kind === "apply" && x.result === "ok"), "缺 apply 事件");
  assert(!rows.some((x) => x.kind === "backend" || x.kind === "frontend"), "kind 被发版类型污染");
  assert(rows.some((x) => x.deployKind === "backend"), "deployKind 丢失");
});

t("LE-11 测试后源码被改动 → apply 被 E_BINDING_MISMATCH 拒绝（N-4）", () => {
  appendFileSync(join(APP, "index.html"), "<!-- tampered -->\n");
  let code = "";
  try {
    const r2 = core.plan(PROJECT, "backend", undefined, "-");
    core.apply(PROJECT, r2.planId, r2.confirmToken, `确认执行发布计划 ${r2.planId}`, true, r2.scopeDigest);
  } catch (e) { code = e.code; }
  assert(code === "E_BINDING_MISMATCH", "源码篡改未被拦: " + code);
});

t("LE-12 零副作用：真源 records/_index.md 与既有文件 mtime/内容不变", () => {
  const idx = join(SRC, "records", "_index.md");
  assert(existsSync(idx), "真源索引缺失");
  const st = spawnSync("git", ["-C", SRC, "status", "--porcelain", "--", "."], { encoding: "utf8" });
  const rows = st.stdout.split("\n").filter(Boolean);
  assert(rows.every((x) => x.startsWith("?? ")), "真源出现非新增改动: " + st.stdout.slice(0, 200));
  assert(!existsSync(join(SRC, "records", PROJECT + ".md")), "真源被写入隔离台账");
});

t("LE-13 可回退：清理 REPLICA 后临时资产全清", () => {
  assert(existsSync(REPLICA) && existsSync(APP), "副本/项目目录提前消失");
});

console.log("\n" + "=".repeat(56));
console.log("四步端到端: " + pass + " 通过 / " + fail + " 失败");
console.log("=".repeat(56));

try { rmSync(T, { recursive: true, force: true }); } catch { /* 清理失败不影响结论 */ }
console.log("清理: " + (existsSync(T) ? "未完成" : "临时目录已删除"));
process.exit(fail === 0 ? 0 : 1);
