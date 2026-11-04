#!/bin/bash

test_plan_round_trip_and_direct_deploy_blocked() {
    local d home plan id output status profile
    d=$(new_case_dir)
    home="$d/home"
    mkdir -p "$home" "$d/app"
    profile="$d/profile.sh"
    cat > "$profile" <<EOF
DEPLOY_MODE="process"
GATEO_ENV="test"
SERVER="root@203.0.113.77"
SSH_KEY="$d/key"
BACKUP_DIR="/srv/backups"
RSYNC_DEST="/srv/app"
DEPLOY_RELOAD_CMD="true"
HEALTH_URL="http://127.0.0.1/health"
LOCAL_APP_DIR="$d/app"
EOF

    HOME="$home" DEPLOY_CONF="$profile" GATEO_PLAN_TTL=300 \
        bash "$TEST_ROOT/scripts/gateo-plan.sh" backend > "$d/plan.out"
    plan=$(find "$home/.gateo/plans" -name '*.plan' -type f | head -1)
    assert_file_exists "$plan"
    id=$(basename "$plan" .plan)
    assert_contains "$(cat "$d/plan.out")" "$id" "plan output did not expose confirmation ID"

    bash -c 'source "$1"; gateo_load_plan "$2" "$3"' _ \
        "$TEST_ROOT/scripts/_approval.sh" "$plan" "$id"

    set +e
    output=$(HOME="$home" DEPLOY_CONF="$profile" \
        bash "$TEST_ROOT/scripts/deploy-backend.sh" 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "direct deployment bypassed approval"
    assert_contains "$output" "计划" "direct deployment did not explain approval requirement"
}

test_plan_tamper_and_expiry_are_blocked() {
    local d home plan id tampered expired_id status output
    d=$(new_case_dir)
    home="$d/home"
    mkdir -p "$home"
    HOME="$home" GATEO_PLAN_TTL=300 bash "$TEST_ROOT/scripts/gateo-plan.sh" frontend admin >/dev/null
    plan=$(find "$home/.gateo/plans" -name '*.plan' -type f | head -1)
    id=$(basename "$plan" .plan)

    printf '\nGATEO_PLAN_DIFF_SUMMARY=tampered\n' >> "$plan"
    set +e
    output=$(bash -c 'source "$1"; gateo_load_plan "$2" "$3"' _ \
        "$TEST_ROOT/scripts/_approval.sh" "$plan" "$id" 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "tampered plan was accepted"
    assert_contains "$output" "ID" "tamper rejection did not identify the plan ID mismatch"

    HOME="$home" GATEO_PLAN_TTL=300 bash "$TEST_ROOT/scripts/gateo-plan.sh" frontend h5 >/dev/null
    plan=$(find "$home/.gateo/plans" -name '*.plan' -type f | sort | tail -1)
    LC_ALL=C awk 'BEGIN{done=0} /^GATEO_PLAN_EXPIRES_EPOCH=/{print "GATEO_PLAN_EXPIRES_EPOCH=1"; done=1; next} {print} END{if(!done) exit 1}' \
        "$plan" > "$d/expired.plan"
    expired_id=$(bash -c 'source "$1"; gateo_plan_id "$2"' _ \
        "$TEST_ROOT/scripts/_approval.sh" "$d/expired.plan")
    set +e
    output=$(bash -c 'source "$1"; gateo_load_plan "$2" "$3"' _ \
        "$TEST_ROOT/scripts/_approval.sh" "$d/expired.plan" "$expired_id" 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "expired plan was accepted"
    assert_contains "$output" "过期" "expired plan rejection was unclear"
}

test_plan_binds_source_and_target_configuration() {
    local d home profile plan id output status
    d=$(new_case_dir)
    home="$d/home"
    mkdir -p "$home" "$d/app"
    echo initial > "$d/app/app.py"
    profile="$d/profile.sh"
    cat > "$profile" <<EOF
DEPLOY_MODE="process"
GATEO_ENV="test"
SERVER="root@203.0.113.77"
SSH_KEY="$d/key"
BACKUP_DIR="/srv/backups"
RSYNC_DEST="/srv/app"
DEPLOY_RELOAD_CMD="true"
HEALTH_URL="http://127.0.0.1/health"
LOCAL_APP_DIR="$d/app"
EOF
    HOME="$home" DEPLOY_CONF="$profile" GATEO_PLAN_TTL=300 \
        bash "$TEST_ROOT/scripts/gateo-plan.sh" backend >/dev/null
    plan=$(find "$home/.gateo/plans" -name '*.plan' -type f | head -1)
    id=$(basename "$plan" .plan)

    GATEO_APPROVED_PLAN_FILE="$plan" GATEO_APPROVED_PLAN_ID="$id" \
        bash -c 'source "$1"; source "$2"; gateo_require_plan backend backend "$DEPLOY_MODE" "$LOCAL_APP_DIR"' _ \
        "$TEST_ROOT/scripts/_approval.sh" "$profile" >/dev/null

    echo changed-after-confirmation > "$d/app/app.py"
    set +e
    output=$(GATEO_APPROVED_PLAN_FILE="$plan" GATEO_APPROVED_PLAN_ID="$id" \
        bash -c 'source "$1"; source "$2"; gateo_require_plan backend backend "$DEPLOY_MODE" "$LOCAL_APP_DIR"' _ \
        "$TEST_ROOT/scripts/_approval.sh" "$profile" 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "source drift after confirmation was accepted"
    assert_contains "$output" "源码" "source drift rejection was unclear"

    echo initial > "$d/app/app.py"
    set +e
    output=$(GATEO_APPROVED_PLAN_FILE="$plan" GATEO_APPROVED_PLAN_ID="$id" \
        bash -c 'source "$1"; source "$2"; SERVER=root@203.0.113.88; gateo_require_plan backend backend "$DEPLOY_MODE" "$LOCAL_APP_DIR"' _ \
        "$TEST_ROOT/scripts/_approval.sh" "$profile" 2>&1)
    status=$?
    set -e
    assert_ne 0 "$status" "target server drift after confirmation was accepted"
    assert_contains "$output" "服务器" "target drift rejection was unclear"
}

run_case 'approval: plan round-trip works; direct deploy is blocked' test_plan_round_trip_and_direct_deploy_blocked
run_case 'approval: tampered and expired plans are blocked' test_plan_tamper_and_expiry_are_blocked
run_case 'approval: confirmed plan binds source and target configuration' test_plan_binds_source_and_target_configuration

