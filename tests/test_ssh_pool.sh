#!/bin/bash
# SSH 连接复用测试：验证开关、显式配置尊重、无凭据降级、cleanup 幂等。
# 不依赖真实服务器（建连失败时的降级路径也必须正确）。

test_pool_disabled_by_env() {
    local out
    out=$(GATEO_SSH_POOL=0 PROJECT=t1 bash -c '
        source "$1"
        SSH_OPTS="-o BatchMode=yes"; ssh_pool_init
        echo "ACTIVE=$SSH_POOL_ACTIVE"; echo "OPTS=$SSH_OPTS"
    ' _ "$TEST_ROOT/scripts/_ssh_pool.sh")
    assert_contains "$out" "ACTIVE=0" "GATEO_SSH_POOL=0 must disable pool"
    assert_not_contains "$out" "ControlPath" "no ControlPath when disabled"
}

test_pool_respects_explicit_controlpath() {
    local out
    out=$(GATEO_SSH_POOL=1 PROJECT=t2 bash -c '
        source "$1"
        SSH_OPTS="-o ControlPath=/tmp/user-explicit.sock"; ssh_pool_init
        echo "ACTIVE=$SSH_POOL_ACTIVE"; echo "OPTS=$SSH_OPTS"
    ' _ "$TEST_ROOT/scripts/_ssh_pool.sh")
    assert_contains "$out" "ACTIVE=0" "must skip when user set ControlPath"
    assert_contains "$out" "/tmp/user-explicit.sock" "must preserve user ControlPath"
    assert_not_contains "$out" "gateo-sshpool" "must not inject extra socket"
}

test_pool_graceful_without_credentials() {
    local out
    out=$(GATEO_SSH_POOL=1 PROJECT=t3 bash -c '
        unset SERVER SSH_KEY DEPLOY_SERVER DEPLOY_SSH_KEY
        source "$1"
        SSH_OPTS="-o BatchMode=yes"; ssh_pool_init
        echo "ACTIVE=$SSH_POOL_ACTIVE"
    ' _ "$TEST_ROOT/scripts/_ssh_pool.sh")
    assert_contains "$out" "ACTIVE=0" "no credentials must degrade gracefully"
}

test_pool_cleanup_is_noop_when_inactive() {
    local out
    out=$(bash -c '
        source "$1"
        SSH_POOL_ACTIVE=0; SSH_POOL_SOCKET=""; ssh_pool_cleanup; echo CLEAN_OK
    ' _ "$TEST_ROOT/scripts/_ssh_pool.sh")
    assert_contains "$out" "CLEAN_OK" "cleanup must no-op when inactive"
}

run_case 'ssh pool: disabled by GATEO_SSH_POOL=0' test_pool_disabled_by_env
run_case 'ssh pool: respects explicit ControlPath' test_pool_respects_explicit_controlpath
run_case 'ssh pool: graceful without credentials' test_pool_graceful_without_credentials
run_case 'ssh pool: cleanup no-op when inactive' test_pool_cleanup_is_noop_when_inactive
