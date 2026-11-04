#!/bin/bash

test_template_is_sourceable() {
    local d output status
    d=$(new_case_dir)
    mkdir -p "$d/home"
    set +e
    output=$(HOME="$d/home" SCRIPT_DIR="$TEST_ROOT/scripts" \
        bash -c 'source "$1"' _ "$TEST_ROOT/profiles/template.sh" 2>&1)
    status=$?
    set -e
    assert_eq 0 "$status" "profile template cannot be sourced: $output"
}

test_doctor_accepts_safe_minimal_profile() {
    local d profile output status
    d=$(new_case_dir)
    mkdir -p "$d/app"
    : > "$d/key"
    chmod 600 "$d/key"
    profile="$d/profile.sh"
    cat > "$profile" <<EOF
DEPLOY_MODE="process"
GATEO_ENV="dev"
E2E_MODE="auto"
SERVER="local-test"
SSH_KEY="$d/key"
BACKUP_DIR="/srv/backups"
RSYNC_DEST="/srv/app"
DEPLOY_RELOAD_CMD="true"
HEALTH_URL="http://127.0.0.1/health"
LOCAL_APP_DIR="$d/app"
EOF
    [[ -f "$TEST_ROOT/scripts/gateo-doctor.sh" ]] || fail "gateo-doctor.sh is missing"
    set +e
    output=$(DEPLOY_CONF="$profile" GATEO_DOCTOR_OFFLINE=1 \
        bash "$TEST_ROOT/scripts/gateo-doctor.sh" 2>&1)
    status=$?
    set -e
    assert_eq 0 "$status" "doctor rejected a valid offline profile: $output"
}

run_case 'config: shipped profile template is safe to source' test_template_is_sourceable
run_case 'config: doctor accepts a valid minimal offline profile' test_doctor_accepts_safe_minimal_profile

