#!/usr/bin/env bash
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_ROOT/lib/lifecycle.sh"
machstrap_test_log_init unit
machstrap_test_log "running fast unit, wrapper, validation, and security tests"
machstrap_test_run "$TESTS_ROOT/run-tests.sh"
machstrap_test_log "unit category passed; log=$MACHSTRAP_TEST_LOG"
