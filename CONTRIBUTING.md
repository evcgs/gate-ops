# Contributing to gate-ops

## The best PR is a lesson

Every gate in this skill came from a real incident. If you hit one:

1. **Write the test first** — add a case to `tests/` that fails without your fix (see `tests/run.sh`, 11 suites currently).
2. **Add the gate** — minimal change to the relevant script or playbook (`processes/`).
3. **Tell the story** — add a row to the "Lessons" table in `README.md` (incident → gate).
4. **Log it** — one entry in `CHANGELOG.md` under a new `[Unreleased]` heading.

## Ground rules

- **Bash 3.2 compatible** — macOS system bash; no bash-4+ features (see `references/mac-traps.md` for the trap list, e.g. BSD grep needs `grep -E` for alternation).
- **Read-only tools stay read-only** — `gateo-plan`, `precheck`, `gateo-doctor` must never mutate cloud state.
- **Redaction is non-negotiable** — no server addresses, key paths or domains in any committed file; use `<server>` style placeholders.
- **Tests must pass 11/11** before any PR touching `scripts/`.

## Adding an integration

Copy the thinnest existing adapter (`integrations/`), add a `case` branch in `scripts/gateo-init.sh` (install path + optional post-install hint), and a row in the integrations table. One self-check item is mandatory.
