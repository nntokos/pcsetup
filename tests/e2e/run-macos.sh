#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/tests/lib/lifecycle.sh"
machstrap_test_log_init macos-vm
OS_VERSION=
SCENARIO=macos-full
while (( $# )); do
    case "$1" in
        --os) [[ $# -ge 2 ]] || exit 2; OS_VERSION=$2; shift 2 ;;
        --scenario) [[ $# -ge 2 ]] || exit 2; SCENARIO=$2; shift 2 ;;
        *) printf 'unknown macOS E2E option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
case "$OS_VERSION" in 15|26) ;; *) printf -- '--os must be 15 or 26\n' >&2; exit 2 ;; esac
[[ "$SCENARIO" == macos-full ]] || {
    printf 'unsupported macOS E2E scenario: %s\n' "$SCENARIO" >&2
    exit 2
}

for command_name in tart expect ssh sshpass ssh-keygen ssh-keyscan; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required macOS E2E command is missing: %s\n' "$command_name" >&2
        exit 2
    }
done

case "$OS_VERSION" in
    15) BASE_IMAGE="${MACHSTRAP_TART_IMAGE_MACOS_15:-}" ;;
    26) BASE_IMAGE="${MACHSTRAP_TART_IMAGE_MACOS_26:-}" ;;
esac
[[ -n "$BASE_IMAGE" ]] || {
    printf 'set the pinned Tart base image for macOS %s\n' "$OS_VERSION" >&2
    exit 2
}
VM_USER="${MACHSTRAP_TART_USER:-admin}"
VM_PASSWORD="${MACHSTRAP_TART_PASSWORD:-}"
[[ -n "$VM_PASSWORD" ]] || {
    printf 'MACHSTRAP_TART_PASSWORD is required for the disposable test account\n' >&2
    exit 2
}

RUN_TOKEN="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
RUN_TOKEN="$(printf '%s' "$RUN_TOKEN" | tr -cd 'a-zA-Z0-9-' | cut -c1-28)"
VM_NAME="machstrap-macos-$RUN_TOKEN"
TART_RUN_PID=
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/machstrap-macos-vm.XXXXXX")"
ARTIFACT_DIR="${MACHSTRAP_E2E_ARTIFACT_DIR:-$TEST_TMP/artifacts}"
mkdir -p "$TEST_TMP/logs" "$ARTIFACT_DIR"
printf '%s\n' "$VM_PASSWORD" >"$TEST_TMP/vm-password"
chmod 0600 "$TEST_TMP/vm-password"
tart_vm_exists() {
    tart list 2>/dev/null |
        awk -v vm_name="$VM_NAME" '
            $1 == vm_name || $2 == vm_name { found = 1 }
            END { exit(found ? 0 : 1) }
        '
}
cleanup() {
    status=$?
    cleanup_failed=0
    trap - EXIT INT TERM
    set +e
    machstrap_test_log "teardown starting: Tart VM=$VM_NAME"
    if tart_vm_exists; then
        machstrap_test_log "stopping and deleting Tart VM $VM_NAME"
        tart stop "$VM_NAME" >/dev/null 2>&1 || true
        tart delete "$VM_NAME" >/dev/null 2>&1 || cleanup_failed=1
    fi
    if [[ -n "$TART_RUN_PID" ]] && kill -0 "$TART_RUN_PID" >/dev/null 2>&1; then
        kill "$TART_RUN_PID" >/dev/null 2>&1 || true
        wait "$TART_RUN_PID" >/dev/null 2>&1 || true
    fi
    if tart_vm_exists; then
        machstrap_test_log "ERROR: Tart VM remains: $VM_NAME"
        cleanup_failed=1
    fi
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        cp -R "$TEST_TMP/logs/." "$ARTIFACT_DIR/" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$TEST_TMP"
    machstrap_test_log "teardown complete: Tart VM and temporary credentials removed"
    if (( status == 0 && cleanup_failed != 0 )); then
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

machstrap_test_log "starting disposable Tart VM $VM_NAME from $BASE_IMAGE"
tart clone "$BASE_IMAGE" "$VM_NAME"
tart run --no-graphics "$VM_NAME" >"$TEST_TMP/logs/tart-console.log" 2>&1 &
TART_RUN_PID=$!

vm_ip=
machstrap_test_log "waiting for Tart VM SSH availability"
for attempt in $(seq 1 120); do
    vm_ip="$(tart ip "$VM_NAME" 2>/dev/null || true)"
    if [[ -n "$vm_ip" ]] &&
        SSHPASS="$VM_PASSWORD" sshpass -e ssh \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$VM_USER@$vm_ip" true >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
[[ -n "$vm_ip" ]] || {
    printf 'macOS VM did not become reachable\n' >&2
    exit 1
}

ssh-keygen -q -t ed25519 -N '' -f "$TEST_TMP/controller"
public_key="$(sed -n '1p' "$TEST_TMP/controller.pub")"
bootstrap_ssh=(sshpass -e ssh -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null "$VM_USER@$vm_ip")
SSHPASS="$VM_PASSWORD" "${bootstrap_ssh[@]}" \
    "umask 077; mkdir -p ~/.ssh; printf '%s\n' '$public_key' >> ~/.ssh/authorized_keys"
printf '%s\n' "$VM_PASSWORD" |
    SSHPASS="$VM_PASSWORD" "${bootstrap_ssh[@]}" \
        "set -e; sudo -S -p '' sh -c 'printf \"%s\\n\" \"Defaults logfile=\\\"/var/log/machstrap-sudo.log\\\"\" \"$VM_USER ALL=(root) ALL\" > /etc/sudoers.d/90-machstrap-e2e; chmod 0440 /etc/sudoers.d/90-machstrap-e2e'"
printf '%s\n' "$VM_PASSWORD" |
    SSHPASS="$VM_PASSWORD" "${bootstrap_ssh[@]}" \
        "set -e; sudo -S -p '' -v; sudo mkdir -p /Users/Shared; sudo rm -rf /Users/Shared/machstrap-fixture.git /tmp/machstrap-fixture-work; sudo git init --bare /Users/Shared/machstrap-fixture.git; git init /tmp/machstrap-fixture-work; git -C /tmp/machstrap-fixture-work config user.name 'Machstrap Test'; git -C /tmp/machstrap-fixture-work config user.email test@example.invalid; printf 'fixture\n' >/tmp/machstrap-fixture-work/README.md; git -C /tmp/machstrap-fixture-work add README.md; git -C /tmp/machstrap-fixture-work commit -m fixture; git -C /tmp/machstrap-fixture-work branch -M main; git -C /tmp/machstrap-fixture-work remote add origin /Users/Shared/machstrap-fixture.git; sudo git -C /tmp/machstrap-fixture-work push origin main; sudo chown -R '$VM_USER':staff /Users/Shared/machstrap-fixture.git; sudo chmod -R u+rwX,go+rX /Users/Shared/machstrap-fixture.git; rm -rf /tmp/machstrap-fixture-work"

ssh-keyscan "$vm_ip" >"$TEST_TMP/known_hosts" 2>/dev/null
cat >"$TEST_TMP/ssh_config" <<EOF
Host machstrap-macos
    HostName $vm_ip
    User $VM_USER
    IdentityFile $TEST_TMP/controller
    IdentitiesOnly yes
    UserKnownHostsFile $TEST_TMP/known_hosts
    StrictHostKeyChecking yes
EOF

profile="$REPO_ROOT/tests/e2e/macos/profile"
run_machstrap() {
    local output=$1
    shift
    cat >"$TEST_TMP/invoke.sh" <<EOF
#!/usr/bin/env bash
exec "$REPO_ROOT/machstrap" "$@" "$profile" \
  --host machstrap-macos --ssh-config "$TEST_TMP/ssh_config" --ask-sudo-pass
EOF
    chmod 0700 "$TEST_TMP/invoke.sh"
    expect "$REPO_ROOT/tests/lib/pty-run.exp" \
        'BECOME password:' \
        "$TEST_TMP/vm-password" \
        "$TEST_TMP/invoke.sh" |
        tee "$output"
}

machstrap_test_log "running check, dry-run, and first full apply"
run_machstrap "$TEST_TMP/logs/check.log" check
run_machstrap "$TEST_TMP/logs/dry-run.log" apply --dry-run --diff
ssh -F "$TEST_TMP/ssh_config" machstrap-macos \
    'test ! -e ~/.machstrap-replace'
run_machstrap "$TEST_TMP/logs/first-apply.log" apply

printf '%s\n' "$VM_PASSWORD" |
    ssh -F "$TEST_TMP/ssh_config" machstrap-macos \
        "sudo -S -p '' sh -c 'printf \"%s\\n\" \"$VM_USER ALL=(root) NOPASSWD: ALL\" > /etc/sudoers.d/91-machstrap-e2e-verify; chmod 0440 /etc/sudoers.d/91-machstrap-e2e-verify'"
ssh -F "$TEST_TMP/ssh_config" machstrap-macos \
    /bin/bash -s <"$REPO_ROOT/tests/e2e/macos/verify.sh"

machstrap_test_log "running second apply and asserting zero changes"
run_machstrap "$TEST_TMP/logs/second-apply.log" apply
grep -q 'TOTAL: 0 changed' "$TEST_TMP/logs/second-apply.log" || {
    printf 'macOS full profile was not idempotent\n' >&2
    exit 1
}
ssh -F "$TEST_TMP/ssh_config" machstrap-macos \
    'sudo cat /var/log/machstrap-sudo.log' >"$TEST_TMP/logs/sudo.log"
test -s "$TEST_TMP/logs/sudo.log"
machstrap_test_log "macOS VM assertions passed"
printf 'macos-e2e: macOS %s passed\n' "$OS_VERSION"
