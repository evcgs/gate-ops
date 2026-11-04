#!/bin/bash

test_unknown_frontend_target_fails_before_side_effects() {
    local d mocks profile output status
    d=$(new_case_dir)
    mocks="$d/bin"
    mkdir -p "$d/project" "$d/home"
    make_mock "$mocks" ssh 'echo called > "${GATEO_MOCK_CALLED:?}"' 'exit 99'
    profile="$d/profile.sh"
    cat > "$profile" <<EOF
GATEO_ENV="test"
SERVER="root@203.0.113.77"
SSH_KEY="$d/key"
BACKUP_DIR="/srv/backups"
PROJECT_ROOT="$d/project"
EOF
    set +e
    output=$(PATH="$mocks:$PATH" HOME="$d/home" DEPLOY_LOCK_DIR="$d/locks" \
        GATEO_MOCK_CALLED="$d/called" DEPLOY_CONF="$profile" \
        bash "$TEST_ROOT/scripts/deploy-frontend.sh" not-a-target 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "unknown frontend target returned success"
    assert_contains "$output" "目标" "unknown target error was unclear"
    [[ ! -e "$d/called" ]] || fail "unknown target reached ssh side effects"
}

test_precheck_redacts_server_from_tool_failure() {
    local d mocks profile output status ip
    d=$(new_case_dir)
    mocks="$d/bin"
    mkdir -p "$d/app" "$d/home"
    ip=203.0.113.77
    make_mock "$mocks" rsync 'echo "ssh: connect to root@203.0.113.77 failed" >&2' 'exit 12'
    profile="$d/profile.sh"
    cat > "$profile" <<EOF
GATEO_ENV="test"
SERVER="root@$ip"
SSH_KEY="$d/key"
CLOUD_APP="/srv/app"
EOF
    set +e
    output=$(PATH="$mocks:$PATH" HOME="$d/home" DEPLOY_CONF="$profile" \
        bash "$TEST_ROOT/scripts/precheck-deploy.sh" backend "$d/app" 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "failed precheck unexpectedly passed"
    assert_not_contains "$output" "$ip" "server address leaked through diagnostic output"
    assert_contains "$output" "<server>" "redacted placeholder was not present"
}

run_case 'frontend: unknown target fails before network or filesystem effects' test_unknown_frontend_target_fails_before_side_effects
run_case 'privacy: precheck errors redact the target server address' test_precheck_redacts_server_from_tool_failure

