#!/bin/bash
# ============================================
# 003 · gateo-evidence-verify（测试证据 → 发令硬前置；真源纯新增）
# ============================================
# 判定权分层：本脚本只做「测试证据准入」校验与绑定比对；
# 「能不能发版」的最终判定仍在 _approval.sh::gateo_load_plan / gateo_require_plan。
#
# 子命令（argv 数组传入，不接受工具入参决定路径；不新增可注入 env）：
#   seal  <project> <evidenceDir> <evidence-json>     生成并追加一条证据（由真源计算哈希）
#   plan  <project> <evidenceDir>                      plan 前置校验
#   apply <project> <evidenceDir> <planId> <planScopeDigest> [sourceRoot|-]
#                                                      apply 前置校验 + 绑定比对 + 源码指纹复核
#
# 成功：stdout 输出一行 `GATEO_EVIDENCE {"evidenceHash":...,"sourceHash":...}`
# 失败：stderr 首行 `E_<CODE>: <原因>`，退出码非 0（fail-closed）。
# 数据：证据与绑定均 append-only，不覆盖、不删除、不改写历史行。
# ============================================

set -euo pipefail

MODE="${1:-}"
PROJECT="${2:-}"
EVIDENCE_DIR="${3:-}"

fail() { printf '%s: %s\n' "$1" "$2" >&2; exit 1; }

case "$MODE" in
    seal|plan|apply) ;;
    *) fail E_BAD_ARGS "mode 必须是 seal/plan/apply" ;;
esac
if ! printf '%s' "$PROJECT" | grep -Eq '^[A-Za-z0-9_-]{1,64}$'; then
    fail E_BAD_ARGS "project 非法"
fi
case "$EVIDENCE_DIR" in
    /*) ;;
    *) fail E_BAD_ARGS "evidenceDir 必须为绝对路径" ;;
esac
# launchd 生产 profile 的 PATH 可能不含 WorkBuddy 自带 python3，逐一探测可用解释器
PY_BIN=""
for c in python3 /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if command -v "$c" >/dev/null 2>&1; then PY_BIN="$c"; break; fi
done
[[ -n "$PY_BIN" ]] || fail E_BAD_ENV "python3 不可用，fail-closed"

exec "$PY_BIN" - "$@" <<'PY'
import sys, os, json, hashlib
from datetime import datetime, timezone

args = sys.argv[1:]
mode, project, edir = args[0], args[1], args[2]

REQUIRED = ["v", "project", "scopePaths", "suite", "result", "sourceHash", "timestamp", "expiresAt"]

def die(code, msg):
    print("%s: %s" % (code, msg), file=sys.stderr)
    sys.exit(1)

def sha(s):
    return hashlib.sha256(s.encode("utf-8")).digest().hex()

def canon(rec):
    # 规范化：键字典序、无多余空白、数组按路径排序；不依赖调用方字段顺序
    obj = {k: rec[k] for k in REQUIRED}
    obj["scopePaths"] = sorted(list(obj["scopePaths"]))
    obj["result"] = {k: obj["result"][k] for k in sorted(obj["result"])}
    obj["scopeDigest"] = scope_digest(obj["scopePaths"])
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

def scope_digest(paths):
    return sha("\n".join(sorted(set(paths))))

def rec_hash(rec):
    return sha(canon(rec))

def evidence_path():
    return os.path.join(edir, project + ".jsonl")

def bindings_path():
    return os.path.join(edir, "bindings.jsonl")

def last_json(path):
    if not os.path.isfile(path):
        return None
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                die("E_HASH_MISMATCH", "证据/绑定文件存在无法解析的历史行")
    return rows[-1] if rows else None

def source_hash_from_tree(root, paths):
    parts = []
    for rel in sorted(set(paths)):
        if rel.startswith("/") or ".." in rel.split("/"):
            die("E_BAD_ARGS", "scopePaths 含越界路径")
        p = os.path.join(root, rel)
        if not os.path.isfile(p):
            die("E_SOURCE_MISSING", "被测源码文件缺失或已变更")
        with open(p, "rb") as f:
            parts.append("%s:%s" % (rel, hashlib.sha256(f.read()).hexdigest()))
    return sha("\n".join(parts))

def validate(rec, check_source_root=""):
    for k in REQUIRED:
        if k not in rec:
            die("E_BAD_ARGS", "证据缺字段 " + k)
    if rec.get("v") != 1:
        die("E_BAD_ARGS", "证据版本不支持")
    if rec.get("project") != project:
        die("E_BINDING_MISMATCH", "证据 project 与本次计划不一致")
    if not isinstance(rec.get("scopePaths"), list) or not rec["scopePaths"]:
        die("E_BAD_ARGS", "scopePaths 必须是非空数组")
    if rec.get("scopeDigest") and rec["scopeDigest"] != scope_digest(rec["scopePaths"]):
        die("E_HASH_MISMATCH", "scopeDigest 与变更清单不一致")
    # 先验哈希再验结果：字段被篡改应报 E_HASH_MISMATCH，
    # 只有哈希自洽但测试确实失败时才报 E_TEST_FAILED（两类负例必须可区分）
    want = rec.get("evidenceHash")
    if not want or want != rec_hash(rec):
        die("E_HASH_MISMATCH", "evidenceHash 不匹配，证据可能被篡改")
    try:
        exp = datetime.fromisoformat(str(rec["expiresAt"]).replace("Z", "+00:00"))
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=timezone.utc)
        if datetime.now(timezone.utc) > exp:
            die("E_EXPIRED", "测试证据已过期")
    except SystemExit:
        raise
    except Exception:
        die("E_BAD_ARGS", "expiresAt 不是合法 ISO8601")
    r = rec.get("result") or {}
    if r.get("exit") != 0 or r.get("failed") != 0 or not isinstance(r.get("passed"), int) or r["passed"] < 1:
        die("E_TEST_FAILED", "测试结果未通过（exit/failed/passed 不达标）")
    if check_source_root and check_source_root != "-":
        actual = source_hash_from_tree(check_source_root, rec["scopePaths"])
        if actual != rec["sourceHash"]:
            die("E_BINDING_MISMATCH", "源码指纹与被测时不一致（测试后源码被改动）")
    return rec

def emit(rec):
    print("GATEO_EVIDENCE " + json.dumps(
        {"evidenceHash": rec["evidenceHash"], "sourceHash": rec["sourceHash"]},
        separators=(",", ":")))

if mode == "seal":
    if len(args) < 4:
        die("E_BAD_ARGS", "seal 缺证据 JSON")
    try:
        rec = json.loads(args[3])
    except Exception:
        die("E_BAD_ARGS", "证据 JSON 无法解析")
    for k in REQUIRED:
        if k not in rec:
            die("E_BAD_ARGS", "证据缺字段 " + k)
    if rec["project"] != project:
        die("E_BAD_ARGS", "证据 project 与调用参数不一致")
    rec["scopePaths"] = sorted(set(rec["scopePaths"]))
    rec["scopeDigest"] = scope_digest(rec["scopePaths"])
    rec["evidenceHash"] = rec_hash(rec)
    os.makedirs(edir, exist_ok=True)
    with open(evidence_path(), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    emit(rec)

elif mode == "plan":
    rec = last_json(evidence_path())
    if rec is None:
        die("E_NO_EVIDENCE", "无测试证据，拒绝生成发布计划")
    emit(validate(rec))

elif mode == "apply":
    if len(args) < 5:
        die("E_BAD_ARGS", "apply 缺 planId / planScopeDigest")
    plan_id, plan_scope_digest = args[3], args[4]
    source_root = args[5] if len(args) > 5 else "-"
    rec = last_json(evidence_path())
    if rec is None:
        die("E_NO_EVIDENCE", "无测试证据，拒绝发令")
    validate(rec, source_root)
    matches = []
    if os.path.isfile(bindings_path()):
        with open(bindings_path(), "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    b = json.loads(line)
                except Exception:
                    die("E_BINDING_MISMATCH", "绑定文件存在无法解析的历史行")
                if b.get("planId") == plan_id:
                    matches.append(b)
    if not matches:
        die("E_BINDING_MISMATCH", "本次计划没有测试证据绑定（可能绕过 plan 直接发令）")
    b = matches[-1]
    if (b.get("project") != project
            or b.get("evidenceHash") != rec["evidenceHash"]
            or b.get("sourceHash") != rec["sourceHash"]
            or b.get("planScopeDigest") != plan_scope_digest):
        die("E_BINDING_MISMATCH", "计划与证据绑定不一致（项目/证据/源码/范围摘要）")
    emit(rec)
PY
