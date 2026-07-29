#!/usr/bin/env bash

# Shared, sanitized lifecycle logging for integration harnesses.
machstrap_test_log_init() {
    MACHSTRAP_TEST_CATEGORY=$1
    local tests_root timestamp
    tests_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
    mkdir -p "$tests_root/logs"
    chmod 0700 "$tests_root/logs"
    if [[ -z "${MACHSTRAP_TEST_LOG:-}" ]]; then
        timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
        MACHSTRAP_TEST_LOG="$tests_root/logs/${MACHSTRAP_TEST_CATEGORY}-${timestamp}-$$.log"
        : >"$MACHSTRAP_TEST_LOG"
    else
        mkdir -p "$(dirname "$MACHSTRAP_TEST_LOG")"
        touch "$MACHSTRAP_TEST_LOG"
    fi
    chmod 0600 "$MACHSTRAP_TEST_LOG"
    export MACHSTRAP_TEST_LOG
}

machstrap_test_log() {
    local line
    printf -v line '[machstrap-test] %s [%s] %s' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$MACHSTRAP_TEST_CATEGORY" "$*"
    printf '%s\n' "$line" >&2
    if [[ "${MACHSTRAP_TEST_EVENTS_CAPTURED:-}" != 1 ]]; then
        printf '%s\n' "$line" >>"$MACHSTRAP_TEST_LOG"
    fi
}

machstrap_test_run() {
    MACHSTRAP_TEST_EVENTS_CAPTURED=1 "$@" 2>&1 |
        tee -a "$MACHSTRAP_TEST_LOG"
}
