/**
 * @wisediag/dsh-tool-gate-ops · 核心闸门层
 *
 * ── 信任边界（务必先读，防止后续维护者把判定逻辑搬进 JS）────────────────────
 * "能不能发版"的物理判定权**只在** gate-ops 真源 shell 脚本：
 *   gateo-plan.sh / _approval.sh::gateo_load_plan / gateo-apply.sh
 * 那里有 planId = 文件 SHA-256、TTL、config digest、source digest 四重硬校验，
 * 以及备份→部署→探活→台账的完整链路。本文件一行都不重写这些判定。
 *
 * 本文件只做真源**之外**的约束层：
 *   G1 身份锚定（目标系统只来自本次调用的显式 project）
 *   G2 计划确认唯一授权（两段式：声明 → 复述 planId + token + 用户确认原话）
 *   G3 范围确认（无低风险豁免）
 *   G4 脱敏（fail-closed；防止内部标识进入对外输出）
 *   G5 留痕（append-only JSONL；写失败即拒绝执行）
 *   G6 只读默认 / 命令白名单（argv 数组、shell:false、禁用 FORCE / DEPLOY_CONF）
 *   G7 入口解耦（工具间无隐式串联，doctor 不自动转 plan/apply）
 *   G8 幂等注册
 *
 * 无法物理保证的一点（如实声明，不夸大）：本层无法验证"用户确认原话"确实来自
 * 用户而非模型自行编造。这正是 gate-ops 铁律 4 的边界——最终不可绕过的是
 * gateo-apply.sh 的 manifest 指纹与 TTL，以及计划 ID 只由 plan 声明产生。
 */
import { spawnSync } from "node:child_process";
import {
  readFileSync, writeFileSync, appendFileSync, existsSync,
  mkdirSync, readdirSync, renameSync, statSync,
} from "node:fs";
import { join, basename } from "node:path";
import { randomBytes, createHash } from "node:crypto";

// 发布副本：默认路径为占位符；部署时通过 GATEOPS_ROOT / DSH_HOME 或 cordis config 注入。
export const DEFAULT_ROOT = process.env.GATEOPS_ROOT || "/path/to/gate-ops";
export const DEFAULT_HOME = process.env.DSH_HOME || "/path/to/dsh-home";

/** 允许执行的真源脚本白名单。任何脚本名都不接受调用方传入。 */
export const SCRIPTS = Object.freeze({
  doctor: "gateo-doctor.sh",
  precheck: "precheck-deploy.sh",
  plan: "gateo-plan.sh",
  apply: "gateo-apply.sh",
  rollback: "rollback.sh",
  records: "build-index.sh",
  // 002 T-14 纯追加：窗口凭证签发。判定权仍只在真源 _approval.sh::gateo_load_plan。
  windowOpen: "gateo-window-open.sh",
  windowClose: "gateo-window-close.sh",
  // 003 纯追加：测试证据准入校验 + 台账 append-only 自动写入。
  // 前者只判「能否进入发令链」，最终「能否发版」仍由 _approval.sh 四重校验决定。
  verifyEvidence: "gateo-evidence-verify.sh",
  recordAppend: "gateo-record-append.sh",
});

export const KINDS = Object.freeze(["backend", "frontend"]);
export const TARGETS = Object.freeze(["admin", "h5", "all"]);
export const ROLLBACK_ACTIONS = Object.freeze(["list", "frontend", "backend"]);

/** 显式差异清单允许的字符集——不是自由文本，不能承载命令。 */
const SAFE_LIST = /^[A-Za-z0-9_,./\- ]{0,2048}$/;
/** 备份文件名白名单 */
const SAFE_BASENAME = /^[A-Za-z0-9_.\-]{1,160}$/;
/** 计划 ID：真源输出为十六进制摘要 */
const SAFE_PLAN_ID = /^[A-Za-z0-9._\-]{8,128}$/;

// ── 002 窗口编排专用校验收紧（只在显式开启窗口时生效）───────────────────
/** 窗口凭证 v1 / v1c payload + 64 位 HMAC hex；字符集收紧，杜绝远程 shell 注入 */
const SAFE_WINDOW_TOKEN = /^v1c?\|[A-Za-z0-9_.|\-]{1,480}\.[0-9a-f]{64}$/;
/** 真源计划 ID 固定格式（scripts/_approval.sh::gateo_plan_id = GTO-<sha256 前 20 位>） */
const SAFE_GTO_ID = /^GTO-[0-9a-f]{20}$/;
const SAFE_SSH_TARGET = /^[A-Za-z0-9_.-]{1,64}@[A-Za-z0-9_.:-]{1,128}$/;
const SAFE_SSH_PORT = /^[0-9]{2,5}$/;
const SAFE_HOSTS_FILE = /^(?:\/dev\/null|\/[A-Za-z0-9_./-]{1,200})$/;

export class GateError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "GateError";
    this.code = code;
  }
}

const REDACT_RULES = [
  ["IP", /\b(?:\d{1,3}\.){3}\d{1,3}\b/g],
  ["EMAIL", /\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g],
  ["SECRET", /\b(?:sk-|ghp_|gho_|AKIA|xox[baprs]-)[A-Za-z0-9_\-]{8,}\b/g],
  ["ASSIGN", /\b(api[_-]?key|token|secret|password|passwd|credential|private[_-]?key)\s*[:=]\s*[^\s,;"']+/gi],
  ["HOST", /\b[a-z0-9][a-z0-9-]{1,}\.(?:com|cn|net|org|io|local|internal|lan|test)\b/gi],
  ["KEYPATH", /[\w./~-]*(?:\.pem|id_rsa|id_ed2551[0-9]|\.key)\b/g],
  ["SSHPATH", /\b(?:ssh|scp)\s+[^\s]+@[^\s]+/gi],
  ["ABSPATH", /\/Users\/[^\s"'`,;)]+/g],
  ["ABSPATH", /\/home\/[^\s"'`,;)]+/g],
  ["ABSPATH", /\/var\/[^\s"'`,;)]+/g],
  ["ABSPATH", /\/opt\/[^\s"'`,;)]+/g],
  ["CREDFILE", /~\/\.gateo\/[^\s"'`,;)]+/g],
  ["CREDFILE", /\bcredentials\.sh\b/g],
  ["PORT", /\b\d{1,3}(?:\.\d{1,3}){3}:\d{2,5}\b/g],
  ["UUID", /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi],
  ["MAC", /\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b/gi],
  ["PEM", /-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----/g],
  // 必须在 ENVSECRET 之前：ENVSECRET 只吃键名，会把 "=值" 留在输出里（自测 Q-06b 实测缺陷）
  ["ENVSECRET_ASSIGN", /\b[A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)\s*[:=]\s*[^\s,;"']+/g],
  ["ENVSECRET", /\b(?:WISEDIAG|DEEPSEEK|OPENAI|NVIDIA|CRED)_[A-Z_]*(?:KEY|TOKEN|SECRET)\b/g],
  ["DBURL", /\b(?:mysql|postgres|mongodb|redis):\/\/[^\s"']+/gi],
  ["BEARER", /\bBearer\s+[A-Za-z0-9._\-]{8,}/g],
];

export function createCore(config = {}) {
  const root = config.gateOpsRoot || DEFAULT_ROOT;
  const home = config.home || DEFAULT_HOME;
  const stateDir = config.stateDir || join(home, "gateops");
  const ledgerPath = config.ledgerPath || join(stateDir, "bridge.jsonl");
  const pendingPath = config.pendingPath || join(stateDir, "pending.json");
  // 003：证据目录只由 core 从 stateDir 派生，绝不接受工具入参指定（CF-02 / D-08）。
  const evidenceDir = config.evidenceDir || join(stateDir, "evidence");
  // 003：台账自动写入默认关闭，与 002 windowEnabled 同构；关闭时 apply() 返回逐字不变。
  const recordEnabled = config.recordEnabled === true || process.env.GATEOPS_RECORD_ENABLED === "1";
  // 003：可选的本地源码根；提供时 apply 会重算源码指纹，检测「测试后源码被改动」。
  const loopSourceRoot = String(config.loopSourceRoot || "-");
  const timeout = Math.max(1000, Math.min(Number(config.timeoutMs) || 120000, 600000));
  const maxOut = 8000;

  // ── 002 窗口编排配置（plan D-18 默认关闭 / D-19 ssh 传输留在插件侧）──────
  // 只从插件 config 与进程环境读取，**绝不接收工具入参**，避免调用方指定任意 ssh 目标。
  const windowEnabled = config.windowEnabled === true || process.env.GATEOPS_WINDOW_ENABLED === "1";
  const winTarget = String(config.windowSshTarget || process.env.GATEOPS_WINDOW_SSH_TARGET || "");
  const winKey = String(config.windowSshKey || process.env.GATEOPS_WINDOW_SSH_KEY || "");
  const winPort = String(config.windowSshPort || process.env.GATEOPS_WINDOW_SSH_PORT || "22");
  const winHostsFile = String(config.windowSshKnownHostsFile || process.env.GATEOPS_WINDOW_SSH_KNOWN_HOSTS || "");
  const winSecretFile = String(config.windowSecretFile || process.env.GATEO_GUARD_SECRET_FILE || "");
  // 依赖注入仅用于本地行为自测：生产 config 来自 JSON，无法注入函数，默认走真实 ssh。
  const winSshRunner = typeof config.windowSshRunner === "function" ? config.windowSshRunner : null;

  const scriptsDir = join(root, "scripts");
  const profilesDir = join(root, "profiles");
  const recordsDir = join(root, "records");
  const versionPath = join(root, "VERSION");

  // ── 基础状态 ──────────────────────────────────────────────────────────
  function rootOk() {
    return existsSync(join(root, "SKILL.md")) && existsSync(scriptsDir);
  }

  function ensureState() {
    mkdirSync(stateDir, { recursive: true });
  }

  /** G1：项目白名单只来自真源 profiles/*.sh（template 除外）。零/多候选一律拒绝。 */
  function projects() {
    if (!existsSync(profilesDir)) return [];
    return readdirSync(profilesDir)
      .filter((f) => f.endsWith(".sh") && f !== "template.sh" && !f.startsWith("."))
      .map((f) => basename(f, ".sh"))
      .sort();
  }

  function assertProject(raw) {
    const list = projects();
    if (typeof raw !== "string" || !raw.trim()) {
      throw new GateError("G1_NO_PROJECT", `本次系统未指定。候选（${list.length}）：${list.join(", ") || "无"}。请由用户当前消息明确指定，不得从历史记忆/台账推断。`);
    }
    const p = raw.trim();
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(p)) {
      throw new GateError("G1_BAD_PROJECT", "项目名非法（仅允许字母/数字/下划线/连字符）");
    }
    if (!list.includes(p)) {
      throw new GateError("G1_UNKNOWN_PROJECT", `项目「${p}」不在档案白名单。候选（${list.length}）：${list.join(", ") || "无"}`);
    }
    return p;
  }

  // ── G4 脱敏（fail-closed）────────────────────────────────────────────
  function redact(text) {
    try {
      let s = String(text ?? "");
      let n = 0;
      // 动态项目名词典：历史风险中外泄的正是系统名，静态词表漏掉了它
      for (const p of projects()) {
        const re = new RegExp(`\\b${p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "g");
        s = s.replace(re, (m) => { n++; return "[PROJECT]"; });
      }
      for (const [, re] of REDACT_RULES) {
        re.lastIndex = 0;
        s = s.replace(re, (m) => { n++; return "[REDACTED]"; });
      }
      if (s.length > maxOut) s = s.slice(0, maxOut) + `\n...[truncated ${s.length} chars]`;
      return { text: s, count: n };
    } catch (e) {
      return { text: "[gate-ops] 脱敏层异常，输出已阻断（fail-closed）", count: -1, error: String(e && e.message || e) };
    }
  }

  function redactDeep(value) {
    if (typeof value === "string") return redact(value).text;
    if (Array.isArray(value)) return value.map(redactDeep);
    if (value && typeof value === "object") {
      const out = {};
      for (const [k, v] of Object.entries(value)) out[k] = redactDeep(v);
      return out;
    }
    return value;
  }

  function safeText(label, value) {
    const r = redact(value);
    if (r.count < 0) throw new GateError("G4_FAIL_CLOSED", `${label}: 脱敏层异常，拒绝返回输出`);
    return { text: r.text, redacted: r.count };
  }

  // ── G5 留痕（append-only，写失败即拒绝执行）───────────────────────────
  function ledger(kind, rec) {
    try {
      ensureState();
      // 001-F1 / D-2：rec.kind 是发版类型，不得覆盖作为事件类型的 kind。
      const { kind: deployKind, ...rest } = rec;
      const line = JSON.stringify({
        ts: new Date().toISOString(),
        source: "dsh-tool-gate-ops",
        ...rest,
        ...(deployKind ? { deployKind } : {}),
        kind,
      });
      appendFileSync(ledgerPath, line + "\n", { encoding: "utf8", mode: 0o600 });
    } catch (e) {
      throw new GateError("G5_LEDGER_FAILED", `留痕写入失败，拒绝执行：${e && e.message || e}`);
    }
  }

  function readLedger(limit = 100, project) {
    if (!existsSync(ledgerPath)) return [];
    const lines = readFileSync(ledgerPath, "utf8").split("\n").filter(Boolean);
    const out = [];
    for (const line of lines.slice(-Math.max(1, Math.min(Number(limit) || 100, 500))).reverse()) {
      try {
        const r = JSON.parse(line);
        if (project && r.project && r.project !== project) continue;
        out.push(r);
      } catch { /* 坏行跳过，不静默当成空 */ }
    }
    return out;
  }

  // ── pending 表（plan 声明 → apply 确认）───────────────────────────────
  function readPending() {
    if (!existsSync(pendingPath)) return {};
    try { return JSON.parse(readFileSync(pendingPath, "utf8")); }
    catch { return {}; }
  }

  function writePending(all) {
    ensureState();
    const tmp = pendingPath + ".tmp";
    writeFileSync(tmp, JSON.stringify(all, null, 2), { encoding: "utf8", mode: 0o600 });
    renameSync(tmp, pendingPath);
  }

  function dropExpired(all) {
    const now = Date.now() / 1000;
    let changed = false;
    for (const [id, rec] of Object.entries(all)) {
      if (!rec || !rec.expiresEpoch || now > rec.expiresEpoch) { delete all[id]; changed = true; }
    }
    return changed;
  }

  // ── G6 执行器：argv 白名单、shell:false、env 白名单 ─────────────────────
  function run(scriptKey, argv, envPairs = {}) {
    const file = SCRIPTS[scriptKey];
    if (!file) throw new GateError("G6_SCRIPT", "未知脚本");
    const script = join(scriptsDir, file);
    if (!existsSync(script)) throw new GateError("G6_SCRIPT_MISSING", `真源脚本缺失：${file}`);
    for (const a of argv) {
      if (typeof a !== "string" || /[\n\r\0]/.test(a)) throw new GateError("G6_ARGV", "参数含非法字符");
    }
    // 禁用可绕过闸门的环境变量；只构造白名单 env，绝不整体继承 process.env
    const FORBIDDEN = ["FORCE", "DEPLOY_CONF", "GATEO_FORCE", "GATEO_SKIP", "DEPLOY_MODE"];
    for (const k of Object.keys(envPairs)) {
      if (FORBIDDEN.includes(k)) throw new GateError("G6_FORBIDDEN_ENV", `禁止注入环境变量 ${k}`);
    }
    const env = {
      PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin",
      HOME: process.env.HOME || "/path/to/home",
      LANG: "en_US.UTF-8",
      LC_ALL: "en_US.UTF-8",
      ...envPairs,
    };
    const r = spawnSync("bash", [script, ...argv], {
      cwd: root, env, shell: false, encoding: "utf8",
      timeout, maxBuffer: 8 * 1024 * 1024,
    });
    const out = [r.stdout || "", r.stderr ? `\n[stderr]\n${r.stderr}` : ""].join("");
    const err = r.error ? `\n[spawn error] ${r.error.message}` : "";
    const head = `[gate-ops] script=${file} exit=${r.status ?? "?"}\n`;
    return { status: r.status, raw: head + out + err, timedOut: !!r.error && r.error.code === "ETIMEDOUT" };
  }

  // ── 003 测试证据 → 发令硬前置（FR-04 / CF-02 / R-6）──────────────────
  // 判定逻辑落在真源 gateo-evidence-verify.sh；本层只负责在 plan()/apply()
  // 两个唯一入口处调用，使「绕过 persona 直接调工具」同样无法跳过。
  // 不设关闭开关：开关即旁路，与 AC-02 负例矩阵冲突。
  function evidenceCheck(mode, project, argv = []) {
    const r = run("verifyEvidence", [mode, project, evidenceDir, ...argv], {});
    const info = String(r.raw || "").split("\n").map((s) => s.trim())
      .find((s) => s.startsWith("GATEO_EVIDENCE "));
    if (r.status !== 0 || !info) {
      const m = String(r.raw || "").match(/\bE_[A-Z_]+\b/);
      const code = m ? m[0] : "E_EVIDENCE";
      const why = safeText("evidence", r.raw).text.slice(-400);
      try { ledger("evidence", { project, mode, result: "denied", code }); } catch { /* 拒绝优先 */ }
      throw new GateError(code, `测试证据闸门拒绝（${mode}）：${why}`);
    }
    try {
      return JSON.parse(info.slice("GATEO_EVIDENCE ".length));
    } catch {
      throw new GateError("E_EVIDENCE", "证据校验输出无法解析，拒绝执行");
    }
  }

  /** 两阶段绑定：证据在步骤 2 生成，plan 的 scopeDigest 在步骤 3 才产出，故 plan 成功后补写。 */
  function bindEvidence(planId, project, ev, scopeDigest) {
    try {
      mkdirSync(evidenceDir, { recursive: true });
      appendFileSync(join(evidenceDir, "bindings.jsonl"), JSON.stringify({
        v: 1, planId, project, evidenceHash: ev.evidenceHash, sourceHash: ev.sourceHash,
        planScopeDigest: scopeDigest, boundAt: new Date().toISOString(),
      }) + "\n", { encoding: "utf8", mode: 0o600 });
    } catch (e) {
      throw new GateError("E_BIND_FAILED", `证据绑定写入失败，拒绝进入确认阶段：${e && e.message || e}`);
    }
  }

  // ── 002 窗口编排（plan D-18~D-20；默认关闭时以下函数完全不会被调用）──────
  /** 显式开启时的配置自检：任何一项不合法即 fail-closed，绝不猜测生产目标。 */
  function assertWindowConfig() {
    if (winSshRunner) return; // 传输层已由自测注入，无需真实 ssh 参数
    if (!SAFE_SSH_TARGET.test(winTarget)) {
      throw new GateError("W_CONFIG", "窗口 ssh 目标缺失或格式非法（须 user@host，且只来自插件配置）");
    }
    if (!SAFE_SSH_PORT.test(winPort)) throw new GateError("W_CONFIG", "窗口 ssh 端口非法");
    if (!winKey.startsWith("/") || !existsSync(winKey)) {
      throw new GateError("W_CONFIG", "窗口 ssh 私钥缺失或路径非法");
    }
    if (winHostsFile && !SAFE_HOSTS_FILE.test(winHostsFile)) {
      throw new GateError("W_CONFIG", "known_hosts 路径非法");
    }
  }

  /** 复用 run() 的 argv 数组 / shell:false / env 白名单；窗口脚本只签发、不传输。 */
  function windowToken(scriptKey, argv) {
    const envPairs = winSecretFile ? { GATEO_GUARD_SECRET_FILE: winSecretFile } : {};
    const r = run(scriptKey, argv, envPairs);
    if (r.status !== 0) {
      const why = safeText("window-token", r.raw).text.slice(0, 300);
      throw new GateError("W_TOKEN", `窗口凭证签发失败：${why}`);
    }
    const token = String(r.raw || "").split("\n").map((s) => s.trim()).find((s) => SAFE_WINDOW_TOKEN.test(s));
    if (!token) throw new GateError("W_TOKEN", "窗口凭证格式异常，拒绝发送（fail-closed）");
    return token;
  }

  /** 固定 argv 数组 + 构造式 env 白名单；command 只由内部拼装，token 已过收紧正则。 */
  function windowSsh(command) {
    if (winSshRunner) return winSshRunner(command);
    const argv = [
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=8",
      "-o", "StrictHostKeyChecking=accept-new",
    ];
    if (winHostsFile) argv.push("-o", "UserKnownHostsFile=" + winHostsFile);
    argv.push("-p", winPort, "-i", winKey, winTarget, command);
    const env = {
      PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin",
      HOME: process.env.HOME || "/path/to/home",
      LANG: "en_US.UTF-8",
      LC_ALL: "en_US.UTF-8",
    };
    const r = spawnSync("ssh", argv, {
      cwd: root, env, shell: false, encoding: "utf8",
      timeout: 30000, maxBuffer: 1024 * 1024,
    });
    return {
      status: r.status,
      raw: [r.stdout || "", r.stderr || "", r.error ? `[spawn error] ${r.error.message}` : ""].join(""),
    };
  }

  function windowOpen(planId, rec) {
    assertWindowConfig();
    if (!SAFE_GTO_ID.test(planId)) {
      throw new GateError("W_CONFIG", "计划 ID 非 GTO-<20hex> 格式，窗口凭证无法签发，拒绝执行");
    }
    const token = windowToken("windowOpen", [rec.planFile, planId]);
    // v1|plan|project|kind|target|mode|nonce|expiry —— nonce 即 windowId，用于对账
    const windowId = token.split(".")[0].split("|")[6] || "";
    const r = windowSsh("__GATEOPS_OPEN__ " + token);
    const clean = safeText("window-open", r.raw);
    if (r.status !== 0) {
      ledger("window", { project: rec.project, planId, windowId, action: "open", result: "failed", exit: r.status, redacted: clean.redacted });
      throw new GateError("W_OPEN_FAILED", `开窗失败，拒绝执行发版：${clean.text.slice(0, 300)}`);
    }
    ledger("window", { project: rec.project, planId, windowId, action: "open", result: "ok", redacted: clean.redacted });
    return windowId;
  }

  /** finally 专用：任何异常都不得抛出，以免覆盖 apply 结果；但失败必须留痕。 */
  function windowClose(planId, projectName) {
    try {
      const token = windowToken("windowClose", [planId]);
      const r = windowSsh("__GATEOPS_CLOSE__ " + token);
      const clean = safeText("window-close", r.raw);
      ledger("window", { project: projectName, planId, action: "close", result: r.status === 0 ? "ok" : "failed", exit: r.status, redacted: clean.redacted });
      return r.status === 0;
    } catch {
      try { ledger("window", { project: projectName, planId, action: "close", result: "error", code: "W_CLOSE_FAILED" }); }
      catch { /* 留痕失败也不抛，异常路径优先保住 apply 结果 */ }
      return false;
    }
  }

  // ── 只读状态（供 status / records / RPC）───────────────────────────────
  function status() {
    const ok = rootOk();
    let version = "unavailable";
    try { version = readFileSync(versionPath, "utf8").trim(); } catch { /* 保持不可用 */ }
    let cred = "missing";
    try {
      const c = join(process.env.HOME || "/path/to/home", ".gateo", "credentials.sh");
      cred = existsSync(c) ? "present" : "missing";
    } catch { /* 保持缺失 */ }
    return {
      rootOk: ok, gateOpsVersion: version, root: "[REDACTED]",
      profileCount: projects().length, projects: projects().map(() => "[PROJECT]"),
      credentials: cred, stateDir: "[REDACTED]",
      ledgerPath: "[REDACTED]", pendingCount: Object.keys(readPending()).length,
      checkedAt: new Date().toISOString(),
    };
  }

  function records(limit = 30) {
    const f = join(recordsDir, "_index.md");
    if (!existsSync(f)) return { path: "[REDACTED]", lines: [] };
    const lines = readFileSync(f, "utf8").split("\n").filter(Boolean).slice(-Math.min(Number(limit) || 30, 200));
    return { path: "[REDACTED]", lines: lines.map((l) => redact(l).text) };
  }

  function plans() {
    const all = readPending();
    if (dropExpired(all)) writePending(all);
    return Object.entries(all).map(([planId, p]) => ({
      planId, project: "[PROJECT]", kind: p.kind, target: p.target,
      state: p.state || "awaiting-confirmation",
      createdAt: p.createdAt, expiresAt: p.expiresAt,
      scope: p.scope, ttlRemainingSec: Math.max(0, Math.round((p.expiresEpoch || 0) - Date.now() / 1000)),
    }));
  }

  function events(limit = 100, project) {
    return redactDeep(readLedger(limit, project));
  }

  function todos() {
    const out = [];
    for (const p of plans()) {
      if (p.state === "awaiting-confirmation") {
        out.push({ level: "info", text: `计划 ${p.planId} 等待用户确认（剩余 ${p.ttlRemainingSec}s）；请在对话中给出确切计划 ID 后由 Agent 走 gateops_apply` });
      }
      if (p.ttlRemainingSec < 300) out.push({ level: "warn", text: `计划 ${p.planId} 即将过期` });
    }
    for (const e of readLedger(30)) {
      if (e.result === "denied") out.push({ level: "warn", text: `闸门拦截：${e.kind} / ${e.code || "gate"}` });
      if (e.kind === "apply" && e.result === "ok" && e.verify === "failed") {
        out.push({ level: "warn", text: "探活失败：按铁律 6 先看进程、存活则延长观察 60s，勿直接回滚" });
      }
    }
    return redactDeep(out);
  }

  // ── 计划生成与确认（G2 / G3）──────────────────────────────────────────
  function plan(project, kind, target, expectDiffs) {
    const p = assertProject(project);
    if (!KINDS.includes(kind)) throw new GateError("G6_ARGV", `kind 必须是 ${KINDS.join("/")}`);
    const t = kind === "frontend" ? (target || "all") : "backend";
    // 001-F1 / D-1：target 集合只对 frontend 有意义，backend 不应被 frontend 目标集误杀。
    if (kind === "frontend" && !TARGETS.includes(t)) throw new GateError("G6_ARGV", `target 必须是 ${TARGETS.join("/")}`);
    if (expectDiffs !== undefined && expectDiffs !== null && expectDiffs !== "" && !SAFE_LIST.test(String(expectDiffs))) {
      throw new GateError("G6_ARGV", "expect_diffs 含非法字符（只允许路径清单字符）");
    }
    // 003 FR-04：测试证据硬前置。放在真源 plan 之前，绕过 persona 直接调工具同样被拦。
    const ev = evidenceCheck("plan", p);
    const env = { PROJECT: p };
    if (expectDiffs) env.DEPLOY_EXPECT_DIFFS = String(expectDiffs);
    const argv = kind === "frontend" ? ["frontend", t] : ["backend"];
    const r = run("plan", argv, env);
    const clean = safeText("plan", r.raw);
    if (r.status !== 0) {
      ledger("plan", { project: p, kind, target: t, result: "failed", exit: r.status, redacted: clean.redacted });
      return { ok: false, output: clean.text, redacted: clean.redacted };
    }
    // 真源输出格式固定，解析计划 ID / 文件 / 范围摘要
    const idM = r.raw.match(/计划 ID:\s*([A-Za-z0-9._-]+)/);
    const fileM = r.raw.match(/计划文件:\s*(\S+)/);
    const scopeM = r.raw.match(/覆盖资产:\s*(.+)/);
    const ttlM = r.raw.match(/有效期:\s*(\d+)s/);
    if (!idM || !fileM) {
      ledger("plan", { project: p, kind, result: "failed", code: "PLAN_PARSE" });
      return { ok: false, output: "[gate-ops] 计划已生成但无法解析计划 ID/文件，拒绝进入确认阶段（fail-closed）\n" + clean.text, redacted: clean.redacted };
    }
    const planId = idM[1];
    if (!SAFE_PLAN_ID.test(planId)) throw new GateError("G2_BAD_PLAN_ID", "计划 ID 格式异常");
    const planFile = fileM[1];
    // 计划文件指纹：确认与执行之间被篡改即拒（真源 gateo_load_plan 会再校验一次，双保险）
    let planDigest = "";
    try { planDigest = createHash("sha256").update(readFileSync(planFile)).digest("hex"); }
    catch { throw new GateError("G2_MANIFEST", "计划文件不可读，拒绝进入确认阶段"); }
    const scope = (scopeM ? scopeM[1].trim() : "-");
    const scopeDigest = createHash("sha256").update(scope).digest("hex").slice(0, 16);
    const ttl = Number(ttlM ? ttlM[1] : 1800);
    const confirmToken = randomBytes(12).toString("hex");
    const now = Date.now();
    const all = readPending();
    dropExpired(all);
    all[planId] = {
      planId, planFile, project: p, kind, target: t, scope, scopeDigest, planDigest,
      confirmToken, state: "awaiting-confirmation",
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(now + ttl * 1000).toISOString(),
      expiresEpoch: now / 1000 + ttl,
    };
    // 两阶段绑定：把本次 planId / 范围摘要与步骤 2 的证据钉在一起，apply 时逐项比对。
    bindEvidence(planId, p, ev, scopeDigest);
    writePending(all);
    ledger("loop_evidence", { project: p, planId, mode: "plan", result: "ok", evidenceHash: ev.evidenceHash });
    ledger("plan", { project: p, planId, kind, target: t, result: "ok", state: "awaiting-confirmation", redacted: clean.redacted });
    return {
      ok: true, project: p, planId, scope: redact(scope).text, scopeDigest,
      confirmToken, expiresAt: all[planId].expiresAt,
      output: clean.text, redacted: clean.redacted,
    };
  }

  function apply(project, planId, confirmToken, userConfirmText, scopeConfirmed, scopeDigest) {
    const p = assertProject(project);
    if (!SAFE_PLAN_ID.test(String(planId || ""))) throw new GateError("G2_BAD_PLAN_ID", "计划 ID 缺失或格式异常");
    const all = readPending();
    dropExpired(all);
    const rec = all[planId];
    if (!rec) throw new GateError("G2_NO_DECLARATION", `计划 ${planId} 无有效声明（未生成 / 已过期 / 已执行）。必须先调用 gateops_plan 并由用户确认`);
    if (rec.project !== p) throw new GateError("G1_MISMATCH", "项目与计划声明不一致");
    if (!confirmToken || confirmToken !== rec.confirmToken) throw new GateError("G2_TOKEN", "确认令牌不匹配：讨论性调用未放行");
    if (scopeConfirmed !== true && scopeConfirmed !== "true") throw new GateError("G3_SCOPE", "范围未经用户明确确认（无低风险豁免，纯前端同样要确认）");
    if (!scopeDigest || scopeDigest !== rec.scopeDigest) throw new GateError("G3_SCOPE_DIGEST", "范围摘要不匹配，计划确认与执行之间可能发生变化");
    // 铁律 4：用户确认原话必须复述确切计划 ID
    const ucText = String(userConfirmText || "");
    if (!ucText.includes(planId)) throw new GateError("G2_CONFIRM_TEXT", "用户确认原话未包含确切计划 ID，按铁律 4 不放行");
    // 指纹复核：计划文件在确认与执行之间不得被改动（真源 gateo_load_plan 会再校验一次）
    let digest = "";
    try { digest = createHash("sha256").update(readFileSync(rec.planFile)).digest("hex"); }
    catch { throw new GateError("G2_MANIFEST", "计划文件不可读，拒绝执行"); }
    if (!rec.planDigest || digest !== rec.planDigest) throw new GateError("G2_MANIFEST", "计划文件指纹缺失或已变化，拒绝执行");
    // 003 FR-04：两段式校验通过后再校验证据 + 绑定 + 源码指纹；N-1~N-6 在此被拒。
    const evApplied = evidenceCheck("apply", p, [planId, rec.scopeDigest, loopSourceRoot]);
    ledger("loop_evidence", { project: p, planId, mode: "apply", result: "ok", evidenceHash: evApplied.evidenceHash });
    // G5 必须先留痕，写失败即拒绝执行
    ledger("apply", { project: p, planId, kind: rec.kind, target: rec.target, result: "authorized", scopeDigest });

    // ── 002 T-15 窗口编排（plan D-18）：默认关闭时以下是完整 no-op ────────
    let windowId = null;
    if (windowEnabled) {
      try {
        windowId = windowOpen(planId, rec);
      } catch (e) {
        // 开窗失败不得执行发版；仍尝试关窗，避免半开窗残留
        windowClose(planId, p);
        throw e;
      }
    }

    let r;
    try {
      r = run("apply", [rec.planFile, planId], { PROJECT: p });
    } finally {
      // Q-14：成功、失败、异常三条路径都必须关窗，不留悬挂窗口
      if (windowEnabled) windowClose(planId, p);
    }

    const clean = safeText("apply", r.raw);
    const ok = r.status === 0;
    const winTail = windowEnabled ? { windowId, windowState: "closed" } : {};
    // 003 FR-06：默认关闭；未开启时本函数返回结构与 001-F1 逐字一致。
    let recordTail = {};
    if (recordEnabled && ok) {
      const rr = run("recordAppend", [p, planId, evApplied.evidenceHash], {});
      const recOk = rr.status === 0;
      ledger("loop_record", { project: p, planId, result: recOk ? "ok" : "failed", agent: "DSH" });
      recordTail = { recordWritten: recOk, recordAgent: recOk ? "DSH" : null };
    }
    ledger("apply", {
      project: p, planId, result: ok ? "ok" : "failed", exit: r.status,
      verify: ok ? "passed" : "failed", redacted: clean.redacted, ...winTail,
    });
    delete all[planId];
    writePending(all);
    return {
      ok, output: clean.text + (ok ? "\n[gate-ops] 已执行；台账由真源脚本写入" : "\n[gate-ops] 执行失败：按铁律 6 先看进程，存活则延长观察 60s 再谈回滚"),
      redacted: clean.redacted, planId,
      ...winTail, ...recordTail,
    };
  }

  function rollback(project, action, target, backup) {
    const p = assertProject(project);
    if (!ROLLBACK_ACTIONS.includes(action)) throw new GateError("G6_ARGV", `action 必须是 ${ROLLBACK_ACTIONS.join("/")}`);
    if (backup && !SAFE_BASENAME.test(String(backup))) throw new GateError("G6_ARGV", "备份名非法");
    const argv = [action];
    if (action === "frontend") {
      const t = target || "admin";
      if (!["admin", "h5"].includes(t)) throw new GateError("G6_ARGV", "target 必须是 admin/h5");
      argv.push(t);
    }
    if (backup) argv.push(String(backup));
    // rollback 不走计划闸门（真故障越快越好），但强制留痕 + 目标备份显式
    ledger("rollback", { project: p, action, target: target || "-", backup: backup || "latest", result: "authorized" });
    const r = run("rollback", argv, { PROJECT: p });
    const clean = safeText("rollback", r.raw);
    ledger("rollback", { project: p, action, result: r.status === 0 ? "ok" : "failed", exit: r.status, redacted: clean.redacted });
    return { ok: r.status === 0, output: clean.text, redacted: clean.redacted };
  }

  function doctor(project, deep) {
    const p = assertProject(project);
    const r = run("doctor", deep ? ["--deep"] : [], { PROJECT: p });
    const clean = safeText("doctor", r.raw);
    return { ok: r.status === 0, output: `本次系统=${p}（依据：用户当前消息明确指定）\n${clean.text}`, redacted: clean.redacted };
  }

  function precheck(project, kind, expectDiffs, localDir) {
    const p = assertProject(project);
    if (!KINDS.includes(kind)) throw new GateError("G6_ARGV", `kind 必须是 ${KINDS.join("/")}`);
    if (expectDiffs === undefined || expectDiffs === null || String(expectDiffs).trim() === "") {
      throw new GateError("G6_EXPECT_DIFFS", "期望差异清单必须显式声明（铁律 1）；无差异请传 \"-\"");
    }
    if (!SAFE_LIST.test(String(expectDiffs))) throw new GateError("G6_ARGV", "expect_diffs 含非法字符");
    const argv = [kind];
    if (localDir) {
      if (!SAFE_LIST.test(String(localDir))) throw new GateError("G6_ARGV", "本地目录含非法字符");
      argv.push(String(localDir));
    }
    const r = run("precheck", argv, { PROJECT: p, DEPLOY_EXPECT_DIFFS: String(expectDiffs) });
    const clean = safeText("precheck", r.raw);
    return { ok: r.status === 0, output: `本次系统=${p}（依据：用户当前消息明确指定）\n${clean.text}`, redacted: clean.redacted };
  }

  return {
    root, home, stateDir, ledgerPath, pendingPath, timeout,
    rootOk, projects, assertProject, redact, redactDeep, safeText,
    ledger, readLedger, readPending, writePending, run,
    status, records, plans, events, todos,
    plan, apply, rollback, doctor, precheck,
    // 002 T-14/T-15：供本地行为自测；任何既有工具签名与 RPC 白名单都不变
    windowEnabled, assertWindowConfig, windowToken, windowSsh, windowOpen, windowClose,
  };
}
