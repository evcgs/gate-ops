/**
 * @wisediag/dsh-tool-gate-ops · dsh 服务端工具插件入口
 *
 * 形态：SOP 阶段 0 的「工具插件」。7 个 defineTool 只是**入口**，
 * 所有闸门判定仍在 gate-ops 真源 shell（见 lib/core.js 顶部信任边界说明）。
 *
 * 契约：
 *   - package.json 的 dsh.bundle.patch → cordis.patch.yml（id 全局唯一）
 *   - inject 只声明 ["tools"]；不访问任何未 inject 的服务（check-ctx-inject）
 *   - 每个 defineTool 显式写 execute: 与 output.render（check-tool-contracts）
 *   - parameters 全为标量，避免嵌套 object 缺 additionalProperties（check-tool-schemas）
 *   - apply 幂等；真源缺失时注册降级工具而非抛错，绝不拖垮 boot
 */
import { defineTool } from "@deepseek-ai/dsh-tools";
import { createCore } from "./core.js";

export const name = "dsh-tool-gate-ops";
export const inject = ["tools"];

const APPLIED = new WeakSet();

function renderText(value) {
  return [{ type: "text", text: String(value ?? "") }];
}

export function apply(ctx, config) {
  if (APPLIED.has(ctx)) return;
  APPLIED.add(ctx);

  let core = null;
  try { core = createCore(config || {}); } catch { core = null; }

  /** 统一包装：闸门错误是给 Agent 的可操作提示（不经脱敏），其余输出一律已脱敏。 */
  function wrap(tool, fn) {
    return async (args) => {
      const a = args || {};
      try {
        if (!core || !core.rootOk()) {
          return JSON.stringify({
            ok: false, tool, code: "GATEOPS_ROOT_UNAVAILABLE",
            output: "[gate-ops] 真源不可用（SKILL.md / scripts 缺失）。插件已降级，不执行任何动作，也不影响 dsh 启动。",
          }, null, 2);
        }
        const r = await fn(a);
        return JSON.stringify({ ok: r.ok !== false, tool, ...r }, null, 2);
      } catch (e) {
        if (e && e.name === "GateError") {
          return JSON.stringify({
            ok: false, tool, code: e.code,
            output: `[闸门拒绝 ${e.code}] ${e.message}`,
          }, null, 2);
        }
        // 内部异常不回传原始输出，避免绕过脱敏层泄出真源 stdout
        return JSON.stringify({
          ok: false, tool, code: "INTERNAL",
          output: `[gate-ops] 内部异常，输出已阻断：${String((e && e.message) || e).slice(0, 300)}`,
        }, null, 2);
      }
    };
  }

  const tools = [
    defineTool({
      name: "gateops_status",
      description: "gate-ops 只读状态：真源可达性、版本、档案数量、凭据在位情况（只报存在/缺失，不报值）、待确认计划数。不执行任何动作。",
      parameters: {},
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_status", () => ({ output: JSON.stringify(core.status(), null, 2), redacted: 0 })),
    }),

    defineTool({
      name: "gateops_doctor",
      description: "只读体检：转发 gateo-doctor.sh。project 必须由用户当前消息明确指定；历史记忆/台账不得推断。回执首行身份声明。deep=true 走 --deep 跨产物一致性。审计回执即终点，不自动转 plan/apply。",
      parameters: {
        project: { type: "string", required: true, description: "目标系统名（必须来自用户当前消息，且存在于 profiles 白名单）" },
        deep: { type: "boolean", description: "是否跑 --deep 跨产物一致性体检（默认 false）" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_doctor", (a) => core.doctor(a.project, a.deep === true || a.deep === "true")),
    }),

    defineTool({
      name: "gateops_precheck",
      description: "只读预检：转发 precheck-deploy.sh，列出本地与云端差异。expect_diffs 必须显式声明（铁律 1），无差异传 '-'。禁用 FORCE，检查工具自身失败一律判不通过。",
      parameters: {
        project: { type: "string", required: true, description: "目标系统名（用户当前消息明确指定）" },
        kind: { type: "string", required: true, description: "backend 或 frontend" },
        expect_diffs: { type: "string", required: true, description: "期望差异清单，逗号分隔；无差异传 '-'。路径以 precheck 输出原样为准" },
        local_dir: { type: "string", description: "可选本地目录（相对或绝对路径，只含安全字符）" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_precheck", (a) => core.precheck(a.project, a.kind, a.expect_diffs, a.local_dir)),
    }),

    defineTool({
      name: "gateops_records",
      description: "只读查询 gate-ops 发版台账索引最近 N 行（脱敏后）。只读，不改变任何状态，不触发任何过程。",
      parameters: {
        limit: { type: "number", description: "返回行数（默认 30，上限 200）" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_records", (a) => ({ output: JSON.stringify(core.records(a.limit), null, 2), redacted: 0 })),
    }),

    defineTool({
      name: "gateops_plan",
      description: "生成发布计划（绝不部署）。转发 gateo-plan.sh，产出 planId / 范围摘要 / 确认令牌 / TTL。返回后必须等用户在对话中给出确切计划 ID，再由 gateops_apply 执行；讨论性调用一律不放行。",
      parameters: {
        project: { type: "string", required: true, description: "目标系统名（用户当前消息明确指定）" },
        kind: { type: "string", required: true, description: "backend 或 frontend" },
        target: { type: "string", description: "frontend 目标：admin / h5 / all（默认 all）" },
        expect_diffs: { type: "string", description: "可选期望差异清单（铁律 1）" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_plan", (a) => core.plan(a.project, a.kind, a.target, a.expect_diffs)),
    }),

    defineTool({
      name: "gateops_apply",
      description: "执行发版（写操作）。两段式闸门：必须先由 gateops_plan 生成声明，再由用户在对话中给出确切计划 ID；调用须同时提供 plan_id、confirm_token、user_confirm_text（原话须含计划 ID）、scope_confirmed=true、scope_digest。缺失任一即拒绝。真源 gateo-apply.sh 会再校验 manifest 指纹与 TTL。",
      parameters: {
        project: { type: "string", required: true, description: "目标系统名（必须与计划声明一致）" },
        plan_id: { type: "string", required: true, description: "gateops_plan 返回的计划 ID" },
        confirm_token: { type: "string", required: true, description: "gateops_plan 声明阶段返回的确认令牌" },
        user_confirm_text: { type: "string", required: true, description: "用户确认原话，必须包含确切计划 ID（铁律 4）" },
        scope_confirmed: { type: "boolean", required: true, description: "用户已明确同意覆盖范围；无低风险豁免" },
        scope_digest: { type: "string", required: true, description: "gateops_plan 返回的范围摘要哈希" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_apply", (a) => core.apply(a.project, a.plan_id, a.confirm_token, a.user_confirm_text, a.scope_confirmed, a.scope_digest)),
    }),

    defineTool({
      name: "gateops_rollback",
      description: "精确快照恢复（写操作）。不走计划闸门（真故障越快越好），但目标备份名须显式、强制留痕。list 只读列出可用备份。探活失败先看进程，勿自动从 apply 转入本工具。",
      parameters: {
        project: { type: "string", required: true, description: "目标系统名（用户当前消息明确指定）" },
        action: { type: "string", required: true, description: "list / frontend / backend" },
        target: { type: "string", description: "frontend 时用 admin 或 h5" },
        backup: { type: "string", description: "显式备份文件名；省略则由真源取最近一次" },
      },
      output: { schema: { type: "string" }, render: (_a, v) => renderText(v) },
      execute: wrap("gateops_rollback", (a) => core.rollback(a.project, a.action, a.target, a.backup)),
    }),
  ];

  for (const t of tools) ctx.tools.register(t);
}
