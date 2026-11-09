#!/bin/bash

write_passthrough_ssh() {
    local mocks="$1"
    make_mock "$mocks" ssh \
        'while [[ $# -gt 0 ]]; do' \
        '  case "$1" in' \
        '    -i|-o) shift 2 ;;' \
        '    -*) shift ;;' \
        '    *) shift; break ;;' \
        '  esac' \
        'done' \
        'cmd=${1:-true}' \
        'bash -c "$cmd"'
}

test_http_500_is_unhealthy() {
    local d mocks profile backup output status
    d=$(new_case_dir)
    mocks="$d/bin"
    mkdir -p "$d/src/app" "$d/live/app" "$d/backups" "$d/home"
    echo old > "$d/src/app/old.txt"
    backup="$d/backups/gateo_backend_src_bak_20000101_000000.tar.gz"
    tar czf "$backup" -C "$d/src" app
    sha256sum "$backup" > "$backup.sha256"
    write_passthrough_ssh "$mocks"
    make_mock "$mocks" sleep 'exit 0'
    make_mock "$mocks" curl \
        'for arg in "$@"; do' \
        '  case "$arg" in -f|--fail|--fail-with-body) exit 22 ;; esac' \
        'done' \
        'echo "HTTP/1.1 500 Internal Server Error"' \
        'exit 0'
    profile="$d/profile.sh"
    cat > "$profile" <<EOF
GATEO_ENV="test"
SERVER="local-test"
SSH_KEY="$d/key"
BACKUP_DIR="$d/backups"
DEPLOY_MODE="process"
RSYNC_DEST="$d/live/app"
DEPLOY_RELOAD_CMD="true"
HEALTH_URL="http://127.0.0.1/health"
EOF
    set +e
    output=$(PATH="$mocks:$PATH" HOME="$d/home" DEPLOY_CONF="$profile" \
        bash "$TEST_ROOT/scripts/rollback.sh" backend "$backup" 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "HTTP 500 was accepted as healthy"
    assert_contains "$output" "健康检查未通过" "health failure was not reported"
}

test_rollback_restores_exact_tree() {
    local d mocks profile backup output
    d=$(new_case_dir)
    mocks="$d/bin"
    mkdir -p "$d/snapshot/app" "$d/live/app" "$d/backups" "$d/home"
    echo old > "$d/snapshot/app/kept.txt"
    echo changed > "$d/live/app/kept.txt"
    echo should-disappear > "$d/live/app/added-by-bad-release.txt"
    backup="$d/backups/gateo_backend_src_bak_20000101_000000.tar.gz"
    tar czf "$backup" -C "$d/snapshot" app
    sha256sum "$backup" > "$backup.sha256"
    write_passthrough_ssh "$mocks"
    make_mock "$mocks" sleep 'exit 0'
    make_mock "$mocks" curl 'echo "{\"ok\":true}"' 'exit 0'
    profile="$d/profile.sh"
    cat > "$profile" <<EOF
GATEO_ENV="test"
SERVER="local-test"
SSH_KEY="$d/key"
BACKUP_DIR="$d/backups"
DEPLOY_MODE="process"
RSYNC_DEST="$d/live/app"
DEPLOY_RELOAD_CMD="true"
HEALTH_URL="http://127.0.0.1/health"
EOF
    output=$(PATH="$mocks:$PATH" HOME="$d/home" DEPLOY_CONF="$profile" \
        bash "$TEST_ROOT/scripts/rollback.sh" backend "$backup" 2>&1)
    assert_contains "$output" "健康检查通过" "rollback did not complete"
    assert_eq old "$(cat "$d/live/app/kept.txt")" "snapshot content was not restored"
    [[ ! -e "$d/live/app/added-by-bad-release.txt" ]] || fail "rollback left a file introduced by the failed release"
}

run_case 'health: HTTP 500 is rejected instead of treated as success' test_http_500_is_unhealthy
run_case 'rollback: restore produces the exact backed-up source tree' test_rollback_restores_exact_tree

