#!/bin/bash

set -u

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP_BASE=${TEST_TMP_BASE:-$(mktemp -d "${TMPDIR:-/tmp}/gateo-tests.XXXXXX")}
TESTS_RUN=0
TESTS_FAILED=0

cleanup_tests() {
    rm -rf "$TEST_TMP_BASE"
}
trap cleanup_tests EXIT

fail() {
    echo "    FAIL: $*" >&2
    return 1
}

assert_eq() {
    local expected="$1" actual="$2" message="${3:-values differ}"
    [[ "$expected" == "$actual" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_ne() {
    local unexpected="$1" actual="$2" message="${3:-values unexpectedly equal}"
    [[ "$unexpected" != "$actual" ]] || fail "$message (unexpected=$unexpected)"
}

assert_contains() {
    local haystack="$1" needle="$2" message="${3:-missing expected text}"
    case "$haystack" in
        *"$needle"*) return 0 ;;
        *) fail "$message: $needle" ;;
    esac
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="${3:-found forbidden text}"
    case "$haystack" in
        *"$needle"*) fail "$message: $needle" ;;
        *) return 0 ;;
    esac
}

assert_file_exists() {
    [[ -f "$1" ]] || fail "expected file does not exist: $1"
}

new_case_dir() {
    mktemp -d "$TEST_TMP_BASE/case.XXXXXX"
}

make_mock() {
    local dir="$1" name="$2"
    mkdir -p "$dir"
    shift 2
    {
        echo '#!/bin/bash'
        printf '%s\n' "$@"
    } > "$dir/$name"
    chmod +x "$dir/$name"
}

run_case() {
    local name="$1" status
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  %-72s' "$name"
    set +e
    ( set -e; "$@" )
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        echo 'PASS'
    else
        echo 'FAIL'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

finish_tests() {
    echo
    echo "tests: $TESTS_RUN, failed: $TESTS_FAILED"
    [[ "$TESTS_FAILED" -eq 0 ]]
}

