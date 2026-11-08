/**
 * @wisediag/dsh-tool-gate-ops-loop · 原子能力层（003）
 *
 * 边界（constitution 铁律 1 / 4）：
 *   - 本文件**不判定能不能发版**。只做「改源码 / 跑真实 E2E / 生成证据 / 转发台账写入」。
 *   - 测试证据是否准入，由真源 gateo-evidence-verify.sh 判定；
 *     发版是否放行，由 _approval.sh::gateo_load_plan / gateo_require_plan 判定。
 *   - 项目白名单与测试套件只来自 config，绝不接受工具入参指定任意路径或任意命令。
 */
import { spawnSync } from "node:child_process";
import {
  readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync,
  realpathSync, statSync,
} from "node:fs";
import { join, resolve, dirname, sep } from "node:path";
import { createHash } from "node:crypto";

const PROJECT_RE = /^[A-Za-z0-9_-]{1,64}$/;
const PLAN_ID_RE = /^[A-Za-z0-9._-]{8,128}$/;
const MAX_OUT = 8000;

export class LoopError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "LoopError";
    this.code = code;
  }
}

function trunc(s) {
  const v = String(s ?? "");
  return v.length > MAX_OUT ? v.slice(0, MAX_OUT) + "\n...[truncated]" : v;
}

export function createLoop(config = {}) {
  // 发布副本：默认路径为占位符；部署时通过 config / DSH_HOME / GATEOPS_ROOT 注入。
  const home = String(config.home || process.env.DSH_HOME || "/path/to/dsh-home");
  const stateDir = String(config.stateDir || join(home, "gateops"));
  const ledgerPath = String(config.ledgerPath || join(stateDir, "bridge.jsonl"));
  const evidenceDir = String(config.evidenceDir || join(stateDir, "evidence"));
  const gateOpsRoot = String(config.gateOpsRoot || process.env.GATEOPS_ROOT || "/path/to/gate-ops");
  const verifyScript = join(gateOpsRoot, "scripts", "gateo-evidence-verify.sh");
  const recordScript = join(gateOpsRoot, "scripts", "gateo-record-append.sh");
  const projectRoots = (config.projectRoots && typeof config.projectRoots === "object") ? config.projectRoots : {};
  const suites = (config.suites && typeof config.suites === "object") ? config.suites : {};
  const timeoutMs = Math.max(1000, Math.min(Number(config.timeoutMs) || 600000, 900000));

  /** 面板「最近动态」事件：与 core.js 的 bridge.jsonl 同形，append-only。 */
  function emit(kind, rec) {
    try {
      mkdirSync(stateDir, { recursive: true });
      appendFileSync(ledgerPath, JSON.stringify({
        ts: new Date().toISOString(),
        source: "dsh-tool-gate-ops-loop",
        ...rec,
        kind,
      }) + "\n", { encoding: "utf8", mode: 0o600 });
    } catch (e) {
      throw new LoopError("L_LEDGER_FAILED", `留痕写入失败，拒绝执行：${e && e.message || e}`);
    }
  }

  function projectRoot(project) {
    if (typeof project !== "string" || !PROJECT_RE.test(project)) {
      throw new LoopError("L_BAD_PROJECT", "项目名必须由用户当前消息明确指定且格式合法");
    }
    if (!Object.prototype.hasOwnProperty.call(projectRoots, project)) {
      throw new LoopError("L_NO_PROJECT", `项目「${project}」未登记白名单；候选：${Object.keys(projectRoots).join(", ") || "无"}。请由用户显式授权后再登记，不得推断。`);
    }
    const root = String(projectRoots[project]);
    if (!root.startsWith("/") || !existsSync(root) || !statSync(root).isDirectory()) {
      throw new LoopError("L_BAD_ROOT", "项目根目录不存在或不是绝对路径");
    }
    return realpathSync(root);
  }

  /** 路径白名单：解析后必须仍在项目根内；同时阻断通过符号链接逃逸。 */
  function safePath(project, rel) {
    const root = projectRoot(project);
    if (typeof rel !== "string" || !rel.trim() || rel.includes("\0")) {
      throw new LoopError("L_PATH_DENIED", "路径为空或含非法字符");
    }
    const abs = resolve(root, rel.trim());
    if (abs !== root && !abs.startsWith(root + sep)) {
      throw new LoopError("L_PATH_DENIED", "路径越出项目根（.. 或绝对路径被拒）");
    }
    if (abs === root) throw new LoopError("L_PATH_DENIED", "不允许以项目根本身为文件");
    let probe = abs;
    while (!existsSync(probe) && probe !== root) probe = dirname(probe);
    const real = realpathSync(probe);
    if (real !== root && !real.startsWith(root + sep)) {
      throw new LoopError("L_PATH_DENIED", "路径经软链解析后越出项目根");
    }
    return { root, abs, rel: rel.trim() };
  }

  function sha(s) { return createHash("sha256").update(s).digest("hex"); }

  function sourceHash(root, paths) {
    const parts = [];
    for (const rel of [...new Set(paths)].sort()) {
      const { abs } = safePathByRoot(root, rel);
      if (!existsSync(abs) || !statSync(abs).isFile()) {
        throw new LoopError("L_SOURCE_MISSING", "被测源码文件不存在：" + rel);
      }
      parts.push(rel + ":" + createHash("sha256").update(readFileSync(abs)).digest("hex"));
    }
    return sha(parts.join("\n"));
  }

  function safePathByRoot(root, rel) {
    const abs = resolve(root, rel);
    if (abs !== root && !abs.startsWith(root + sep)) {
      throw new LoopError("L_PATH_DENIED", "scopePaths 含越界路径：" + rel);
    }
    return { abs, rel };
  }

  /** 步骤 1：按项目白名单读写本地源码。 */
  function edit(project, relPath, content, mode) {
    const { root, abs, rel } = safePath(project, relPath);
    if (mode === "read") {
      if (!existsSync(abs)) throw new LoopError("L_NOT_FOUND", "文件不存在：" + rel);
      emit("loop_edit", { project, path: rel, action: "read", result: "ok" });
      return { ok: true, path: rel, content: trunc(readFileSync(abs, "utf8")) };
    }
    if (mode !== "write") throw new LoopError("L_BAD_MODE", "mode 必须是 read / write");
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, String(content ?? ""), "utf8");
    emit("loop_edit", { project, path: rel, action: "write", result: "ok" });
    return { ok: true, path: rel, root: "[REDACTED]" };
  }

  /** 步骤 2：真实执行 E2E，结果只来自进程退出码与用例计数，不采信 agent 自报。 */
  function test(project, suite, scopePathsCsv) {
    const root = projectRoot(project);
    if (!Object.prototype.hasOwnProperty.call(suites, suite)) {
      throw new LoopError("L_NO_SUITE", `测试套件「${suite}」未登记；候选：${Object.keys(suites).join(", ") || "无"}`);
    }
    const argv = suites[suite];
    if (!Array.isArray(argv) || argv.length === 0 || argv.some((a) => typeof a !== "string")) {
      throw new LoopError("L_BAD_SUITE", "套件必须是预登记的 argv 数组，不接受自由命令文本");
    }
    const paths = String(scopePathsCsv || "").split(",").map((s) => s.trim()).filter(Boolean);
    if (!paths.length) throw new LoopError("L_BAD_SCOPE", "scope_paths 必须是非空变更文件清单");
    for (const rel of paths) safePathByRoot(root, rel);
    const srcHash = sourceHash(root, paths);

    const r = spawnSync(argv[0], argv.slice(1), {
      cwd: root, shell: false, encoding: "utf8", timeout: timeoutMs,
      maxBuffer: 16 * 1024 * 1024,
      env: {
        PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin",
        HOME: process.env.HOME || "/path/to/home",
        LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8",
      },
    });
    const out = String(r.stdout || "") + String(r.stderr || "");
    const line = out.split("\n").map((s) => s.trim()).find((s) => s.startsWith("GATEO_TEST_RESULT "));
    if (!line) {
      throw new LoopError("L_RESULT_UNPARSEABLE", "E2E 未输出 GATEO_TEST_RESULT，拒绝生成证据（不采信自报通过）");
    }
    let counts;
    try { counts = JSON.parse(line.slice("GATEO_TEST_RESULT ".length)); }
    catch { throw new LoopError("L_RESULT_UNPARSEABLE", "GATEO_TEST_RESULT 无法解析"); }
    const exit = r.status === null ? 1 : Number(r.status);
    const result = {
      exit,
      passed: Number(counts.passed) || 0,
      failed: Number(counts.failed) || 0,
      skipped: Number(counts.skipped) || 0,
    };
    const now = new Date();
    const rec = {
      v: 1, project, scopePaths: paths, suite, result,
      sourceHash: srcHash,
      timestamp: now.toISOString(),
      expiresAt: new Date(now.getTime() + 1800000).toISOString(),
    };
    if (!existsSync(verifyScript)) {
      throw new LoopError("L_SCRIPT_MISSING", "真源证据脚本缺失，fail-closed");
    }
    const seal = spawnSync("bash", [verifyScript, "seal", project, evidenceDir, JSON.stringify(rec)], {
      shell: false, encoding: "utf8", timeout: 30000,
      env: { PATH: process.env.PATH || "/usr/bin:/bin", HOME: process.env.HOME || "/path/to/home" },
    });
    const info = String(seal.stdout || "").split("\n").map((s) => s.trim())
      .find((s) => s.startsWith("GATEO_EVIDENCE "));
    if (seal.status !== 0 || !info) {
      throw new LoopError("L_SEAL_FAILED", "证据 seal 失败：" + trunc(String(seal.stderr || seal.stdout || "")).slice(0, 300));
    }
    const ev = JSON.parse(info.slice("GATEO_EVIDENCE ".length));
    emit("loop_test", { project, suite, result: exit === 0 && result.failed === 0 ? "ok" : "failed", passed: result.passed, failed: result.failed, evidenceHash: ev.evidenceHash });
    return { ok: true, project, suite, result, evidenceHash: ev.evidenceHash, sourceHash: srcHash, output: trunc(out) };
  }

  /** 步骤 4 兜底：显式转发真源台账写入（自动写入由 core.apply 的 recordEnabled 承担）。 */
  function record(project, planId, evidenceHash) {
    projectRoot(project);
    if (!PLAN_ID_RE.test(String(planId || ""))) throw new LoopError("L_BAD_PLAN_ID", "planId 格式非法");
    if (!existsSync(recordScript)) throw new LoopError("L_SCRIPT_MISSING", "真源台账脚本缺失，fail-closed");
    const r = spawnSync("bash", [recordScript, project, String(planId), String(evidenceHash || "-")], {
      shell: false, encoding: "utf8", timeout: 60000,
      env: { PATH: process.env.PATH || "/usr/bin:/bin", HOME: process.env.HOME || "/path/to/home" },
    });
    const ok = r.status === 0;
    emit("loop_record", { project, planId, result: ok ? "ok" : "failed", agent: "DSH" });
    return { ok, output: trunc(String(r.stdout || "") + String(r.stderr || "")) };
  }

  return { home, stateDir, ledgerPath, evidenceDir, gateOpsRoot, projectRoots, suites, timeoutMs, emit, projectRoot, safePath, edit, test, record };
}
