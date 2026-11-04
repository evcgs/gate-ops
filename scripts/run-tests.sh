#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

echo '== bash syntax =='
for file in "$ROOT"/scripts/*.sh "$ROOT"/profiles/*.sh "$ROOT"/tests/*.sh; do
    bash -n "$file"
done

if command -v shellcheck >/dev/null 2>&1; then
    echo '== shellcheck =='
    shellcheck -S warning "$ROOT"/scripts/*.sh "$ROOT"/profiles/*.sh "$ROOT"/tests/*.sh
else
    echo '== shellcheck: skipped (not installed) =='
fi

if command -v shfmt >/dev/null 2>&1; then
    echo '== shfmt =='
    shfmt -d -i 4 -ci "$ROOT"/scripts "$ROOT"/profiles "$ROOT"/tests
else
    echo '== shfmt: skipped (not installed) =='
fi

echo '== behavior =='
bash "$ROOT/tests/run.sh"

