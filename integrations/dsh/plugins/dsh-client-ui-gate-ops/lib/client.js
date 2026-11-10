/**
 * @wisediag/dsh-client-ui-gate-ops · 浏览器端面板（观测面）
 *
 * 遵循 PANEL_EXTENSION_STANDARD.md v2：不注册独立 NavMenu、不注册 shell.overlay、
 * 不发自定义事件；只把内容组件通过 registerWisediagPanel("gateops", …) 注入
 * 主 UI 的右侧 460px 抽屉。外壳（返回/关闭/ESC）由主 UI Panel 统一提供。
 *
 * 面板是**只读观测面**：没有任何发版/回滚/确认按钮。写动作只能由 Agent
 * 经 gateops_apply 的两段式闸门发起（spec-addendum-C §3.1）。
 */
window.__ModuleLoader__.load({
  id: "@wisediag/dsh-client-ui-gate-ops",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
    var React = require("react");
    var h = React.createElement;
    var useState = React.useState;
    var useEffect = React.useEffect;

    var PKG = "@wisediag/dsh-client-ui-gate-ops";
    var NS = "gateops";
    var TS = PKG + "/gateops-remote";

    /* ── 跨包面板 API（主 UI 暴露），带就绪重试，规避插件加载顺序 ── */
    function registerWisediagPanel(key, Comp) {
      if (typeof window === "undefined") return;
      var tryReg = function () {
        if (window.__WISEDIAG_PANEL_API__) {
          window.__WISEDIAG_PANEL_API__.registerPanelContent(key, Comp);
          return true;
        }
        return false;
      };
      if (!tryReg()) {
        var t = setInterval(function () { if (tryReg()) clearInterval(t); }, 50);
        setTimeout(function () { clearInterval(t); }, 5000);
      }
    }

    /* ── Typert Remote contribution（out-of-tree 插件须自带，仿 security-guard）── */
    function passthrough(typeSymbol) {
      return { mode: "strict", typeSymbol: typeSymbol, create: function () { return {}; } };
    }
    var gateopsRemote = {
      package: PKG,
      descriptors: ["status", "plans", "events", "pending"].map(function (m) {
        return {
          id: PKG + "#" + NS + "/" + m,
          service: NS,
          namespace: NS,
          method: m,
          invocation: { kind: "direct" },
          parameters: [],
          result: passthrough(TS + "#" + m + "Result"),
        };
      }),
    };

    var remoteFace = null;
    var hostCtx = null;

    function resolveFace() {
      try {
        if (remoteFace && remoteFace.gateops) return remoteFace.gateops;
        if (hostCtx && hostCtx.remote && hostCtx.remote.gateops) return hostCtx.remote.gateops;
      } catch (e) { /* 降级为未就绪 */ }
      return null;
    }

    /* ── 纯展示样式（内联，不依赖主 UI CSS、不新增 CSS 模块）── */
    var S = {
      wrap: { padding: "4px 0 16px", fontSize: "13px", lineHeight: "1.6", color: "var(--dsw-alias-label-primary, #222)" },
      head: { display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "10px" },
      title: { fontSize: "14px", fontWeight: "500", margin: "0" },
      hint: { fontSize: "11.5px", color: "var(--dsw-alias-label-tertiary, #888)" },
      strip: { display: "flex", flexWrap: "wrap", gap: "8px", marginBottom: "14px" },
      pill: { border: "1px solid var(--dsw-alias-border-l2, #ddd)", borderRadius: "999px", padding: "3px 10px", fontSize: "12px" },
      section: { margin: "16px 0 8px", fontSize: "13px", fontWeight: "500" },
      card: { background: "var(--dsw-alias-bg-layer-1, #fafafa)", border: "1px solid var(--dsw-alias-border-l2, #e5e5e5)", borderRadius: "10px", padding: "10px 12px", marginBottom: "8px" },
      row: { display: "flex", gap: "10px", alignItems: "baseline", fontSize: "12px" },
      mono: { fontFamily: "ui-monospace, Menlo, monospace", fontSize: "11.5px", wordBreak: "break-all" },
      muted: { color: "var(--dsw-alias-label-secondary, #777)" },
      warn: { color: "var(--dsw-alias-label-warning, #a05a00)" },
      bad: { color: "var(--dsw-alias-label-danger, #b52323)" },
      empty: { color: "var(--dsw-alias-label-secondary, #777)", fontSize: "12.5px" },
      btn: { background: "transparent", border: "1px solid var(--dsw-alias-border-l2, #ddd)", borderRadius: "6px", padding: "2px 10px", fontSize: "12px", cursor: "pointer" },
      stages: { display: "flex", gap: "4px", flexWrap: "wrap", marginBottom: "8px" },
      stage: { border: "1px solid var(--dsw-alias-border-l2, #ddd)", borderRadius: "6px", padding: "3px 8px", fontSize: "11.5px" },
      stageOn: { border: "1px solid var(--dsw-alias-interactive-bg-active, #4a7fd0)", background: "var(--dsw-alias-bg-info, #eef4ff)", borderRadius: "6px", padding: "3px 8px", fontSize: "11.5px" },
      notice: { marginTop: "18px", padding: "10px 12px", border: "1px dashed var(--dsw-alias-border-l2, #ddd)", borderRadius: "8px", fontSize: "11.5px", color: "var(--dsw-alias-label-secondary, #777)" },
    };

    var STAGES = ["precheck", "plan", "confirm", "apply", "verify", "ledger"];

    /**
     * Typert Remote 会在业务返回值外再包一层 { ok, value } 信封，
     * 而 host service 自身返回 { ok, data }。逐层剥离，避免把整包数据丢掉。
     */
    function unwrap(r) {
      var v = r;
      for (var i = 0; i < 4; i++) {
        if (!v || typeof v !== "object") return v;
        if ("ok" in v && v.ok === false) return null;
        if ("data" in v) return v.data;
        if ("value" in v) { v = v.value; continue; }
        return v;
      }
      return v;
    }

    function Text(props) { return h("span", null, props.children); }

    function GateopsPanel() {
      var state = useState({ status: null, plans: [], events: [], pending: [] });
      var data = state[0], setData = state[1];
      var errState = useState("");
      var error = errState[0], setError = errState[1];
      var timeState = useState("");
      var lastAt = timeState[0], setLastAt = timeState[1];

      var pull = async function () {
        var face = resolveFace();
        if (!face) { setError("gateops remote 未就绪（host 服务尚未挂载）"); return; }
        try {
          var results = await Promise.all([
            face.status(), face.plans(), face.events(), face.pending(),
          ]);
          setData({
            status: unwrap(results[0]),
            plans: unwrap(results[1]) || [],
            events: unwrap(results[2]) || [],
            pending: unwrap(results[3]) || [],
          });
          setError("");
          setLastAt(new Date().toLocaleTimeString());
        } catch (e) {
          setError(String((e && e.message) || e));
        }
      };

      useEffect(function () {
        var alive = true;
        var tick = function () { if (alive) pull(); };
        tick();
        var id = setInterval(tick, 5000);
        return function () { alive = false; clearInterval(id); };
      }, []);

      var st = data.status || {};
      var events = Array.isArray(data.events) ? data.events : [];
      var plans = Array.isArray(data.plans) ? data.plans : [];
      var todos = Array.isArray(data.pending) ? data.pending : [];

      // 进展条：从最近事件推断当前阶段（纯展示，不做任何判定）
      var stageIdx = -1;
      for (var i = 0; i < events.length; i++) {
        var k = String(events[i] && events[i].kind || "");
        var idx = STAGES.indexOf(k);
        if (idx > stageIdx) stageIdx = idx;
      }

      return h("div", { style: S.wrap, className: "gateops-panel" },
        h("div", { style: S.head },
          h("h3", { style: S.title }, "发版闸门 · 观测台"),
          h("div", null,
            h("span", { style: S.hint }, lastAt ? "更新 " + lastAt : "等待数据"),
            h("button", { type: "button", style: S.btn, onClick: pull, title: "只读刷新" }, "刷新")
          )
        ),

        /* F-01 状态条 */
        h("div", { style: S.strip },
          h("span", { style: S.pill }, "真源 " + (st.rootOk ? "可达" : "不可用")),
          h("span", { style: S.pill }, "v" + (st.gateOpsVersion || "-")),
          h("span", { style: S.pill }, "档案 " + (st.profileCount ?? "-")),
          h("span", { style: S.pill }, "凭据 " + (st.credentials || "-")),
          h("span", { style: S.pill }, "待确认 " + (st.pendingCount ?? 0))
        ),
        error ? h("div", { style: Object.assign({}, S.card, S.bad) }, "数据通道：" + error) : null,

        /* F-03 发版进展 */
        h("div", { style: S.section }, "发版进展"),
        h("div", { style: S.stages }, STAGES.map(function (s, i) {
          return h("span", { key: s, style: i <= stageIdx ? S.stageOn : S.stage }, s);
        })),

        /* F-02 进行中计划 */
        h("div", { style: S.section }, "进行中计划（" + plans.length + "）"),
        plans.length === 0
          ? h("div", { style: S.empty }, "暂无待确认计划")
          : plans.map(function (p) {
            return h("div", { key: p.planId, style: S.card },
              h("div", { style: S.row },
                h("span", { style: S.mono }, p.planId),
                h("span", null, p.kind + "/" + p.target),
                h("span", { style: S.muted }, p.state)
              ),
              h("div", { style: Object.assign({}, S.row, S.muted) },
                h("span", null, "剩余 " + p.ttlRemainingSec + "s"),
                h("span", null, "范围 " + (p.scope || "-"))
              )
            );
          }),

        /* F-05 待办与告警 */
        h("div", { style: S.section }, "待办与告警（" + todos.length + "）"),
        todos.length === 0
          ? h("div", { style: S.empty }, "无待办")
          : todos.map(function (t, i) {
            return h("div", { key: i, style: Object.assign({}, S.card, t.level === "warn" ? S.warn : {}) }, String(t.text || ""));
          }),

        /* F-04 最近动态 */
        h("div", { style: S.section }, "最近动态（" + events.length + "）"),
        events.length === 0
          ? h("div", { style: S.empty }, "暂无事件；调用 gateops_status / gateops_plan 后会在这里留痕")
          : events.slice(0, 30).map(function (e, i) {
            return h("div", { key: i, style: S.card },
              h("div", { style: S.row },
                h("span", { style: S.muted }, String(e.ts || "").slice(11, 19)),
                h("span", null, String(e.kind || "-")),
                h("span", { style: e.result === "denied" || e.result === "failed" ? S.bad : S.muted }, String(e.result || "-")),
                h("span", { style: S.mono }, String(e.code || ""))
              )
            );
          }),

        /* 硬约束提示：面板不得成为绕过闸门的捷径 */
        h("div", { style: S.notice },
          "本面板为只读观测面，不提供发版 / 回滚 / 确认按钮。写动作须在对话中由用户给出确切计划 ID，",
          "由 Agent 经 gateops_apply 的两段式闸门发起；每次调用都会留痕到上方动态。"
        )
      );
    }

    var inject = ["remote"];

    async function apply(ctx) {
      hostCtx = ctx;
      try {
        await ctx.remote.$mount(gateopsRemote);
        ctx.inject(["remote." + NS], function (remoteCtx) {
          remoteFace = remoteCtx.remote;
        });
      } catch (err) {
        // 挂载失败只降级面板数据，不抛错、不拖垮 boot
        console.warn("[gateops] failed to mount gateops remote:", err);
      }
      registerWisediagPanel("gateops", GateopsPanel);
    }

    exports.apply = apply;
    exports.inject = inject;
    return module.exports;
  },
});
