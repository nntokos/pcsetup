#!/usr/bin/env bash
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_ROOT/lib/lifecycle.sh"
machstrap_test_log_init linux-vm

machstrap_test_log "preparing checksum-pinned Ubuntu VM images"
machstrap_test_run "$TESTS_ROOT/e2e/prepare-images.sh"
for version in 22.04 24.04; do
    for sudo_mode in passwordless password; do
        machstrap_test_log "running Linux VM: Ubuntu $version, sudo=$sudo_mode"
        machstrap_test_run \
            "$TESTS_ROOT/e2e/run-linux.sh" --os "$version" --sudo "$sudo_mode"
    done
done
machstrap_test_log "Linux VM category passed; log=$MACHSTRAP_TEST_LOG"
