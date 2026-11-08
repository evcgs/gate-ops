/**
 * @wisediag/dsh-tool-gate-ops-loop · dsh 服务端工具插件入口（003）
 *
 * 形态：SOP 阶段 0 的「工具插件」，与 001 的 @wisediag/dsh-tool-gate-ops 并列。
 * 契约：
 *   - package.json 的 dsh.bundle.patch → cordis.patch.yml（id 全局唯一）
 *   - inject 只声明 ["tools"]；不访问任何未 inject 的服务
 *   - 每个 defineTool 显式写 execute: 与 output.render
 *   - parameters 全为标量，避免嵌套 object 缺 additionalProperties
 *   - apply 幂等；白名单为空时工具按 fail-closed 拒绝，绝不拖垮 boot
 *
 * 本插件不判定「能不能发版」。判定权在 gate-ops 真源 shell。
 */
import { defineTool } from "@deepseek-ai/dsh-tools";
import { createLoop, LoopError } from "./loop.js";

export const name = "dsh-tool-gate-ops-loop";
export const inject = ["tools"];

const APPLIED = new WeakSet();

function renderText(value) {
  return [{ type: "text", text: String(value ?? "") }];
}

export function apply(ctx, config) {
  if (APPLIED.has(ctx)) return;
  APPLIED.add(ctx);

  const loop = createLoop(config || {});

  function wrap(tool, fn) {
    return async (args) => {
      const a = args || {};
      try {
        const r = await fn(a);
        return JSON.stringify({ ok: r.ok !== false, tool, ...r }, null, 2);
      } catch (e) {
        if (e && e.name === "LoopError") {
          return JSON.stringify({ ok: false, tool, code: e.code, output: `[受控拒绝 ${e.code}] ${e.message}` }, null, 2);
        }
        return JSON.stringify({ ok: false, tool, code: "INTERNAL", output: `[gate-ops-loop] 内部异常，输出已阻断：${String((e && e.message) || e).slice(0, 300)}` }, null, 2);
      }
    };
  }

  const tools = [
    defineTool({
      name: "gateops_loop_edit",
      description: "步骤 1：按项目白名单读取/修改本地源码。project 必须由用户当前消息明确指定且已登记；path 必须落在项目根内（防 .. 与软链逃逸）。不执行任何发版动作。",
      parameters: {
        project: { type: "string", required: true, description: "目标项目名（用户当前消息明确指定，且已登记 projectRoots 白名单）" },
        path: { type: "string", required: true, description: "相对项目根的文件路径" },
        content: { type: "string", description: "mode=write 时写入的内容（mode=read 时忽略）" },
        mode: { type: "string", required: true, description: "read 或 write" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_loop_edit", (a) => loop.edit(a.project, a.path, a.content, a.mode)),
    }),

    defineTool({
      name: "gateops_loop_test",
      description: "步骤 2：按预登记套件执行真实端到端测试，输出结构化结果并由真源 seal 生成 append-only 测试证据。结果只来自真实进程退出码与用例计数，不采信自报通过。",
      parameters: {
        project: { type: "string", required: true, description: "目标项目名（用户当前消息明确指定）" },
        suite: { type: "string", required: true, description: "预登记测试套件 id（来自 config.suites）" },
        scope_paths: { type: "string", required: true, description: "本次变更文件清单，逗号分隔，相对项目根" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_loop_test", (a) => loop.test(a.project, a.suite, a.scope_paths)),
    }),

    defineTool({
      name: "gateops_loop_record",
      description: "步骤 4 兜底：把本次发版结果按 append-only 追加到 GateOps 台账并聚合索引。自动写入由 gateops_apply 的 recordEnabled 承担；本工具仅供显式补录。",
      parameters: {
        project: { type: "string", required: true, description: "目标项目名（用户当前消息明确指定）" },
        plan_id: { type: "string", required: true, description: "已完成的计划 ID" },
        evidence_hash: { type: "string", description: "可选：测试证据哈希，写入台账证据列" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_loop_record", (a) => loop.record(a.project, a.plan_id, a.evidence_hash)),
    }),
  ];

  for (const t of tools) ctx.tools.register(t);
}
