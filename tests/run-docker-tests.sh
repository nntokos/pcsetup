#!/usr/bin/env bash
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_ROOT/lib/lifecycle.sh"
machstrap_test_log_init docker

versions=("$@")
(( ${#versions[@]} )) || versions=(22.04 24.04)
for version in "${versions[@]}"; do
    machstrap_test_log "running Docker SSH integration for Ubuntu $version"
    machstrap_test_run "$TESTS_ROOT/docker/run.sh" "$version"
done
machstrap_test_log "Docker category passed; log=$MACHSTRAP_TEST_LOG"
