#!/usr/bin/env bash
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_ROOT/lib/lifecycle.sh"
machstrap_test_log_init macos-vm

for version in 15 26; do
    machstrap_test_log "running disposable Tart VM for macOS $version"
    machstrap_test_run "$TESTS_ROOT/e2e/run-macos.sh" --os "$version"
done
machstrap_test_log "macOS VM category passed; log=$MACHSTRAP_TEST_LOG"
