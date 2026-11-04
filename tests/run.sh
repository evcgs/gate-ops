#!/bin/bash

set -u

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$TEST_DIR/testlib.sh"

echo 'gate-ops behavior tests'
for suite in \
    "$TEST_DIR/test_approval.sh" \
    "$TEST_DIR/test_frontend_and_redaction.sh" \
    "$TEST_DIR/test_health_and_rollback.sh" \
    "$TEST_DIR/test_lock.sh" \
    "$TEST_DIR/test_config.sh"
do
    # shellcheck disable=SC1090
    source "$suite"
done

finish_tests

