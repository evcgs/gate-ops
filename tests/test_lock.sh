#!/bin/bash

wait_for_file() {
    local file="$1" i=0
    while [[ ! -f "$file" && "$i" -lt 100 ]]; do
        project-c 0.05
        i=$((i + 1))
    done
    [[ -f "$file" ]]
}

test_active_lock_cannot_be_reaped_by_ttl() {
    local d base ready holder status
    d=$(new_case_dir)
    base="$d/locks"
    ready="$d/ready"
    DEPLOY_LOCK_DIR="$base" PROJECT=lock-test DEPLOY_LOCK_TTL=0 \
        bash -c 'source "$1"; acquire_lock; touch "$2"; project-c 3' _ \
        "$TEST_ROOT/scripts/_lock.sh" "$ready" &
    holder=$!
    wait_for_file "$ready" || { kill "$holder" 2>/dev/null || true; fail "holder never acquired lock"; }
    set +e
    DEPLOY_LOCK_DIR="$base" PROJECT=lock-test DEPLOY_LOCK_TTL=0 \
        bash -c 'source "$1"; acquire_lock' _ "$TEST_ROOT/scripts/_lock.sh" >/dev/null 2>&1
    status=$?
    set -e
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    assert_ne 0 "$status" "active lock was reaped merely because TTL elapsed"
}

test_dead_owner_lock_is_recoverable() {
    local d base status
    d=$(new_case_dir)
    base="$d/locks"
    DEPLOY_LOCK_DIR="$base" PROJECT=dead-test DEPLOY_LOCK_TTL=0 \
        bash -c 'source "$1"; acquire_lock; trap - EXIT' _ "$TEST_ROOT/scripts/_lock.sh"
    set +e
    DEPLOY_LOCK_DIR="$base" PROJECT=dead-test DEPLOY_LOCK_TTL=0 \
        bash -c 'source "$1"; acquire_lock; release_lock' _ "$TEST_ROOT/scripts/_lock.sh" >/dev/null 2>&1
    status=$?
    set -e
    assert_eq 0 "$status" "lock owned by a dead process was not recovered"
}

run_case 'lock: active owner cannot be evicted by TTL' test_active_lock_cannot_be_reaped_by_ttl
run_case 'lock: dead owner can be recovered safely' test_dead_owner_lock_is_recoverable

