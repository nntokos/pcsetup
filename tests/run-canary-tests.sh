#!/usr/bin/env bash
set -euo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_ROOT/lib/lifecycle.sh"
machstrap_test_log_init external-canary

machstrap_test_log "preparing checksum-pinned Ubuntu VM image"
machstrap_test_run "$TESTS_ROOT/e2e/prepare-images.sh"
machstrap_test_log "running disposable external GitHub, Snap, and Plex canary"
machstrap_test_run "$TESTS_ROOT/e2e/run-linux.sh" \
    --os 24.04 --sudo passwordless --scenario external-services
machstrap_test_log "external canary passed; log=$MACHSTRAP_TEST_LOG"
