# 🚢 gate-ops

**Gate-driven release operations for AI coding agents.** _No gate, no ship._

[![Version](https://img.shields.io/badge/version-3.2.0-0F6E56)](CHANGELOG.md) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Tests](https://img.shields.io/badge/tests-11%2F11-3B6D11)](tests/) [![Language](https://img.shields.io/badge/language-bash--3.2+-444)](#) [![Docs](https://img.shields.io/badge/docs-gh--pages-534AB7)](docs/index.html)

> [!TIP]
> 🇨🇳 中文文档：[README.zh-CN.md](README.zh-CN.md)

AI coding agents are great at writing code — and terrifyingly good at shipping it badly: deleting production databases with `rsync --delete`, overwriting cloud hot-fixes, skipping backups, and declaring victory on a failed health check. **gate-ops** is a skill that turns operations discipline into hard gates your agent *cannot* bypass — every rule in it grew out of a real production incident.

---

## Why gates, not prompts

Prompt-based discipline ("please be careful when deploying") fails exactly when it matters most. gate-ops encodes each lesson as an **executable gate**:

| Lesson (real incident) | Gate it produced |
|---|---|
| `rsync --delete` wiped a production SQLite DB inside the sync target | Bind-mount data-safety checklist + global excludes + pre-run verification |
| Agent claimed "deployed OK" while the old process was still running | Readiness probe (`READINESS_URL/CMD`) with liveness/readiness/acceptance semantics; HTTP 4xx/5xx = failure |
| Health check failed at 30s while the app was still warming up (~60s) | Failure triage: process alive → auto-extend observation 60s before any rollback |
| A plan got edited between approval and execution | Immutable plan manifest: SHA-256 config + source fingerprints, TTL, exact plan-ID confirmation |
| Two sessions deployed concurrently | Nonce-based release lock with heartbeat + host check |
| A session onboarded the wrong system by "remembering" it | Identity-anchoring rule (Iron Rule 0) + mandatory receipt identity line |
| Receipts claimed files were committed but they weren't | Cross-artifact consistency audit (`gateo-doctor --deep`) |

## Core mechanisms

- **Three-step release pipeline (hard gate)** — `gateo-plan` (read-only plan: config fingerprint, source fingerprint, change summary, plan ID, 30-min TTL) → **you confirm the plan ID** → `gateo-apply` (verifies nothing was tampered with, then deploys). Running deploy scripts directly is *refused by design*.
- **Precheck with expected-diffs** — read-only checksum dry-run; the plan embeds the file-level diff list so what you confirm is what gets overwritten. Out-of-list diffs block the release.
- **Exact snapshot rollback** — pre-restore verification with sha256/md5 sidecars; restore into a *cleaned* directory (no tar-overlay leftovers); rollback never needs a plan gate (real failures move fast).
- **Cross-artifact consistency audit** — `gateo-doctor --deep` validates that profiles, feature markers, ledgers, deploy notes and audit receipts agree with each other *and with git reality*.
- **Multi-project profiles** — one repo operates many systems on shared servers with strict isolation (ports, containers, directories).
- **Redacted credentials** — server IPs and keys live only in `~/.gateo/credentials.sh` (chmod 600, never committed). Receipts and logs show `<server>`, never addresses.

## Six processes, independent entry points

Borrowed from spec-kit's process-presets idea — each process has its own entry, gates and *endpoint*; crossing a process boundary always requires an explicit user instruction.

| Process | Purpose | Endpoint |
|---|---|---|
| `release` *(core)* | Ship code via the gated pipeline | Acceptance passed + ledger row + memory write |
| `rollback` | Recover from real failures | Restored + ledger row |
| `onboarding` | Onboard / re-verify a system | Profile + markers + ledger row + audit receipt |
| `data-change` | Database content changes, bulk generation | `gateo_data_*` backup + ledger row |
| `audit` | Read-only audits & reviews | Receipt — *never* auto-advances to release |
| `hotfix` | Live bug: assess cause → scoped fix → record verification | Root cause + fix + regression check |

See [`processes/README.md`](processes/README.md).

## Quick start

```bash
# 1. Install (links the repo into your agent's skills dir)
bash scripts/gateo-init.sh --integration workbuddy   # or claude / codex / generic
bash scripts/gateo-init.sh --list                    # see all integrations

# 2. Onboard your first project (five-stage guided flow)
cp profiles/template.sh profiles/myapp.sh            # fill DEPLOY_MODE, GATEO_ENV, E2E_MODE…
# register credentials once:
mkdir -p ~/.gateo && chmod 700 ~/.gateo
cat > ~/.gateo/credentials.sh <<'EOF'
CRED_MYAPP_SERVER="user@your-server"
CRED_MYAPP_SSH_KEY="$HOME/.ssh/your_key"
EOF
chmod 600 ~/.gateo/credentials.sh

# 3. Release (the only supported path)
PROJECT=myapp bash scripts/gateo-plan.sh backend     # read-only plan + plan ID + diff list
# → confirm the plan ID with the user →
PROJECT=myapp bash scripts/gateo-apply.sh <plan-file> <plan-id>

# 4. Verify everything offline
bash scripts/gateo-doctor.sh --deep                  # cross-artifact consistency audit
bash tests/run.sh                                    # 11 behavioral tests
```

## Integrations

Same philosophy as spec-kit's `specify init`: **one source of truth + a thin adapter per host**. Installs are symlinks — upgrade once, every host updates.

| Integration | Host | Status |
|---|---|---|
| `workbuddy` | WorkBuddy | ✅ |
| `claude` | Claude Code | ✅ |
| `codex` | Codex CLI | ✅ (+ auto AGENTS.md hint) |
| `generic` | any agent | ✅ escape hatch |

Adding an integration is intentionally cheap — a path, an optional post-install hint, and a self-check. PRs welcome; our goal is a catalog as wide as spec-kit's 38.

## Misoperation scenarios — the threat model

In the era of *one-sentence agent operations* ("just publish everything", "take a look at this system"), the biggest risk is no longer clumsy hands — it is **semantic overreach, silent data destruction and missing evidence**. gate-ops catalogs every real misoperation pattern as a scenario → root cause → gate entry:

| Class | Typical scenario (all real) | Gate that blocks it |
|---|---|---|
| **A · Semantic overreach** | A discussion gets executed as a release; agent infers the target system "from memory"; audit output auto-advances into a deploy | Plan-ID is the *only* release authorization; Iron Rule 0 identity anchoring; process-boundary decoupling |
| **B · Data destruction** | `rsync --delete` wipes a production DB; server-only secrets deleted; restore runs on a truncated backup | Bind-mount checklist; verified excludes; triple backup validation before overwrite |
| **C · State misjudgment** | "Deployed OK" while the old process runs; 30s health window kills a warming app; local diffs misread as cloud hot-fixes | Three-level readiness semantics; warm-up triage (auto-extend 60s); direction verdict by content evidence, never mtime |
| **D · Missing evidence** | Receipt claims "committed" but files are untracked; shared-script edits undeclared; credentials echoed into logs | Mandatory ledger rows; post-commit `git status` check + `gateo-doctor --deep`; `grep -c` only, never echo |
| **E · Concurrency** | Two sessions deploy at once; parallel source edits with unknown ownership | Nonce release lock; single-writer releases + attribution adjudication before any apply |

Full playbook with self-check commands and the one-sentence-era mantra: **[references/misoperations.md](references/misoperations.md)**

## How it complements spec-kit

spec-kit governs *before* the code (intent → spec → plan → implement → converge). gate-ops governs *after* (precheck → plan → confirm → apply → verify → rollback). They share one philosophy — structured process, artifact chains, user-confirmation gates, evidence trails — and are designed to be chained: converge your spec, then ship through the gates.

## Repository layout

```
gate-ops/
├── SKILL.md               # entry: iron rules, quick start, process decoupling
├── lifecycle/             # eight-stage release handbook (core process)
├── processes/             # six process playbooks + registry
├── references/            # config contract, env traps, browser E2E
├── profiles/              # per-project machine configs (template + examples)
├── records/               # cross-agent shared release ledger
├── scripts/               # gateo-plan / gateo-apply / precheck / rollback / doctor / init / tests
├── integrations/          # per-host adapters (workbuddy / claude / codex / generic)
├── tests/                 # 11 behavioral tests (tamper, TTL, redaction, rollback…)
└── docs/                  # GitHub Pages site
```

## Contributing

The best PRs are **lessons**: if you hit a production incident, add the gate that would have prevented it (test first), plus a row in the lessons table above. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
