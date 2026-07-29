#!/usr/bin/env bash
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_ROOT/lib/lifecycle.sh"
machstrap_test_log_init pre-push

command -v docker >/dev/null 2>&1 || {
    printf 'pre-push checks require Docker; run ./tests/run-unit-tests.sh for fast checks only\n' >&2
    exit 1
}
docker info >/dev/null 2>&1 || {
    printf 'pre-push checks require a running, accessible Docker daemon\n' >&2
    exit 1
}

machstrap_test_log "running the local pre-push gate: fast checks and Ubuntu 22.04/24.04 Docker matrices"
machstrap_test_run "$TESTS_ROOT/run-tests.sh"
for version in 22.04 24.04; do
    machstrap_test_log "running Docker SSH integration for Ubuntu $version"
    machstrap_test_run "$TESTS_ROOT/docker/run.sh" "$version"
done
machstrap_test_log "local pre-push gate passed; log=$MACHSTRAP_TEST_LOG"
