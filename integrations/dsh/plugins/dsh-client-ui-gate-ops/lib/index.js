/**
 * @wisediag/dsh-client-ui-gate-ops · host 侧只读 Remote service
 *
 * 形态：导出 default **类**，由 cordis-plugin-loader 解 default 后实例化（与
 * @wisediag/dsh-client-ui-security-guard 同构）。不要包成 apply() 函数——
 * 类形式才能保证 Typert Remote 在 client fiber 等待 remote.gateops 之前注册完成。
 *
 * 只暴露 4 个只读方法：status / plans / events / pending。
 * 不暴露任何写方法：面板是观测面，写动作只能由 Agent 经 gateops_apply 两段式闸门发起
 * （spec-addendum-C §3.1）。所有出参经 dsh-tool-gate-ops 的脱敏层后才跨进程。
 */
import { Remote, TypertRemoteService } from "@deepseek-ai/dsh-typert-protocol";
import { createCore, DEFAULT_HOME } from "../../dsh-tool-gate-ops/lib/core.js";

var __runInitializers = function (thisArg, initializers, value) {
  var useValue = arguments.length > 2;
  for (var i = 0; i < initializers.length; i++) {
    value = useValue ? initializers[i].call(thisArg, value) : initializers[i].call(thisArg);
  }
  return useValue ? value : void 0;
};

/** 标准 TS 装饰器样板（与 security-guard 生产产物同构）；只用于把 Remote 标记挂到原型。 */
var __esDecorate = function (ctor, descriptorIn, decorators, contextIn, initializers, extraInitializers) {
  function accept(f) {
    if (f !== void 0 && typeof f !== "function") throw new TypeError("Function expected");
    return f;
  }
  var _;
  var done = false;
  var kind = contextIn.kind;
  var key = kind === "getter" ? "get" : kind === "setter" ? "set" : "value";
  var target = !descriptorIn && ctor ? (contextIn["static"] ? ctor : ctor.prototype) : null;
  var descriptor = descriptorIn || (target ? Object.getOwnPropertyDescriptor(target, contextIn.name) : {});
  for (var i = decorators.length - 1; i >= 0; i--) {
    var context = {};
    for (var p in contextIn) context[p] = p === "access" ? {} : contextIn[p];
    for (var q in contextIn.access) context.access[q] = contextIn.access[q];
    context.addInitializer = function (f) {
      if (done) throw new TypeError("Cannot add initializers after decoration has completed");
      extraInitializers.push(accept(f || null));
    };
    var result = (0, decorators[i])(
      kind === "accessor" ? { get: descriptor.get, set: descriptor.set } : descriptor[key],
      context
    );
    if (kind === "accessor") {
      if (result === void 0) continue;
      if (result === null || typeof result !== "object") throw new TypeError("Object expected");
      if ((_ = accept(result.get))) descriptor.get = _;
      if ((_ = accept(result.set))) descriptor.set = _;
      if ((_ = accept(result.init))) initializers.unshift(_);
    } else if ((_ = accept(result))) {
      if (kind === "field") initializers.unshift(_);
      else descriptor[key] = _;
    }
  }
  done = true;
  if (target) Object.defineProperty(target, contextIn.name, descriptor);
};

var _instanceExtraInitializers = [];

/** 只读面板数据源。任何异常都返回结构化错误，绝不把原始真源输出抛过 RPC。 */
function snapshot(core, kind) {
  try {
    if (!core.rootOk()) {
      return { ok: false, code: "GATEOPS_ROOT_UNAVAILABLE", data: null, note: "gate-ops 真源不可用" };
    }
    if (kind === "status") return { ok: true, data: core.status() };
    if (kind === "plans") return { ok: true, data: core.plans() };
    if (kind === "events") return { ok: true, data: core.events(100) };
    if (kind === "pending") return { ok: true, data: core.todos() };
    return { ok: false, code: "UNKNOWN_METHOD", data: null };
  } catch (e) {
    return { ok: false, code: "SNAPSHOT_FAILED", data: null, note: String((e && e.message) || e).slice(0, 200) };
  }
}

var GateopsPanelService = (() => {
  let _classSuper = TypertRemoteService;
  return class GateopsPanelService extends _classSuper {
    static {
      const _metadata = typeof Symbol === "function" && Symbol.metadata
        ? Object.create(_classSuper[Symbol.metadata] ?? null)
        : void 0;
      // 白名单：只注册 4 个只读方法。任何写方法都不出现在这里（Q-14 负例）。
      for (const n of ["status", "plans", "events", "pending"]) {
        __esDecorate(this, null, [Remote(n)], {
          kind: "method", name: n, static: false, private: false,
          access: { has: (obj) => n in obj, get: (obj) => obj[n] },
          metadata: _metadata,
        }, null, _instanceExtraInitializers);
      }
    }
    constructor(ctx) {
      super(ctx, "gateops");
      __runInitializers(this, _instanceExtraInitializers);
    }
    async status() {
      const core = createCore({ home: process.env.DSH_HOME || DEFAULT_HOME });
      return snapshot(core, "status");
    }
    async plans() {
      const core = createCore({ home: process.env.DSH_HOME || DEFAULT_HOME });
      return snapshot(core, "plans");
    }
    async events() {
      const core = createCore({ home: process.env.DSH_HOME || DEFAULT_HOME });
      return snapshot(core, "events");
    }
    async pending() {
      const core = createCore({ home: process.env.DSH_HOME || DEFAULT_HOME });
      return snapshot(core, "pending");
    }
  };
})();

export { GateopsPanelService, GateopsPanelService as default };
