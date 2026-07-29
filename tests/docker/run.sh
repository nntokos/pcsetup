#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/tests/lib/lifecycle.sh"
machstrap_test_log_init docker-ubuntu
UBUNTU_VERSION="${1:-24.04}"
case "$UBUNTU_VERSION" in
    22.04|24.04) ;;
    *) printf 'unsupported Docker test version: %s\n' "$UBUNTU_VERSION" >&2; exit 2 ;;
esac

for command_name in ansible-vault docker expect ssh ssh-keygen ssh-keyscan; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required test command is missing: %s\n' "$command_name" >&2
        exit 2
    }
done

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/machstrap-docker.XXXXXX")"
CONTAINER="machstrap-e2e-${UBUNTU_VERSION//./-}-$$"
IMAGE="machstrap-e2e:ubuntu-${UBUNTU_VERSION//./-}-$$"
CURRENT_STAGE=initialization
FAILURE_DIAGNOSTIC=
begin_stage() {
    CURRENT_STAGE=$1
    machstrap_test_log "$CURRENT_STAGE"
}
cleanup() {
    status=$?
    cleanup_failed=0
    trap - EXIT INT TERM
    set +e
    machstrap_test_log "teardown starting: container=$CONTAINER image=$IMAGE"
    if (( status != 0 )); then
        machstrap_test_log "FAILED: status=$status stage=$CURRENT_STAGE"
        if [[ -n "$FAILURE_DIAGNOSTIC" && -f "$FAILURE_DIAGNOSTIC" ]]; then
            printf '\n--- failing stage output: %s ---\n' \
                "$(basename "$FAILURE_DIAGNOSTIC")" >&2
            sed \
                -e 's/machstrap-test-password/[REDACTED]/g' \
                -e 's/machstrap-disposable-vault-password/[REDACTED]/g' \
                "$FAILURE_DIAGNOSTIC" | tail -160 >&2 || true
        fi
        printf '\n--- target SSH log tail ---\n' >&2
        docker logs --tail 40 "$CONTAINER" >&2 || true
    fi
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        machstrap_test_log "removing Docker container $CONTAINER"
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || cleanup_failed=1
    fi
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        machstrap_test_log "ERROR: Docker container remains: $CONTAINER"
        cleanup_failed=1
    fi
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        machstrap_test_log "removing Docker image $IMAGE"
        docker image rm -f "$IMAGE" >/dev/null 2>&1 || cleanup_failed=1
    fi
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        machstrap_test_log "ERROR: Docker image remains: $IMAGE"
        cleanup_failed=1
    fi
    rm -rf -- "$TEST_TMP"
    machstrap_test_log "teardown complete: container and image absent"
    if (( status == 0 && cleanup_failed != 0 )); then
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

begin_stage "starting Ubuntu $UBUNTU_VERSION Docker SSH suite"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_TMP/controller"
printf '%s:%s\n' machstrap-password machstrap-test-password \
    >"$TEST_TMP/password-container"
chmod 0600 "$TEST_TMP/password-container"
begin_stage "building disposable image $IMAGE"
docker build \
    --build-arg "UBUNTU_VERSION=$UBUNTU_VERSION" \
    --tag "$IMAGE" \
    "$REPO_ROOT/tests/docker"
begin_stage "starting disposable container $CONTAINER"
docker run -d --name "$CONTAINER" \
    --hostname machstrap-docker \
    --mount "type=bind,src=$TEST_TMP/controller.pub,dst=/run/machstrap/controller.pub,readonly" \
    --mount "type=bind,src=$TEST_TMP/password-container,dst=/run/machstrap/password,readonly" \
    --publish 127.0.0.1::22 \
    "$IMAGE" >/dev/null
if [[ "${MACHSTRAP_TEST_FAIL_AFTER_DOCKER_START:-}" == 1 ]]; then
    machstrap_test_log "injecting requested post-start failure to verify teardown"
    exit 97
fi

port="$(docker port "$CONTAINER" 22/tcp | sed -n 's/.*://p')"
[[ "$port" =~ ^[0-9]+$ ]] || {
    printf 'could not resolve Docker SSH port\n' >&2
    exit 1
}

begin_stage "waiting for SSH on 127.0.0.1:$port"
for attempt in $(seq 1 30); do
    if ssh-keyscan -p "$port" 127.0.0.1 >"$TEST_TMP/known_hosts" 2>/dev/null; then
        break
    fi
    sleep 1
done
[[ -s "$TEST_TMP/known_hosts" ]] || {
    docker logs "$CONTAINER" >&2
    exit 1
}

cat >"$TEST_TMP/ssh_config" <<EOF
Host machstrap-*
    HostName 127.0.0.1
    Port $port
    IdentityFile $TEST_TMP/controller
    IdentitiesOnly yes
    UserKnownHostsFile $TEST_TMP/known_hosts
    StrictHostKeyChecking yes
EOF

run_apply() {
    local inventory_name=$1
    local profile=$2
    shift 2
    "$REPO_ROOT/machstrap" apply "$profile" \
        --host "$inventory_name" \
        --user "$inventory_name" \
        --ssh-config "$TEST_TMP/ssh_config" \
        "$@"
}

begin_stage "testing dry-run, user ownership, hooks, Git, and idempotency"
docker exec "$CONTAINER" find /root -xdev -printf '%P %y %m %u %g\n' |
    sort >"$TEST_TMP/root-before"
FAILURE_DIAGNOSTIC="$TEST_TMP/user-dry-run"
run_apply machstrap-nosudo "$REPO_ROOT/tests/docker/profile" --dry-run \
    >"$TEST_TMP/user-dry-run"
docker exec "$CONTAINER" \
    test ! -e /home/machstrap-nosudo/.machstrap-replace

FAILURE_DIAGNOSTIC="$TEST_TMP/user-first"
run_apply machstrap-nosudo "$REPO_ROOT/tests/docker/profile" \
    >"$TEST_TMP/user-first"
docker exec -i "$CONTAINER" /bin/bash -s -- machstrap-nosudo \
    <"$REPO_ROOT/tests/docker/verify-user.sh"
docker exec "$CONTAINER" find /root -xdev -printf '%P %y %m %u %g\n' |
    sort >"$TEST_TMP/root-after"
cmp "$TEST_TMP/root-before" "$TEST_TMP/root-after" || {
    printf 'user-only run changed /root\n' >&2
    exit 1
}

FAILURE_DIAGNOSTIC="$TEST_TMP/user-second"
run_apply machstrap-nosudo "$REPO_ROOT/tests/docker/profile" \
    >"$TEST_TMP/user-second"
grep -q 'TOTAL: 0 changed' "$TEST_TMP/user-second" || {
    printf 'user-only profile was not idempotent\n' >&2
    exit 1
}

FAILURE_DIAGNOSTIC="$TEST_TMP/nopass"
run_apply machstrap-nopass "$REPO_ROOT/tests/docker/system" \
    >"$TEST_TMP/nopass"
docker exec "$CONTAINER" dpkg-query -W -f='${Status}\n' tree |
    grep -qx 'install ok installed'

set +e
FAILURE_DIAGNOSTIC="$TEST_TMP/denied"
run_apply machstrap-nosudo "$REPO_ROOT/tests/docker/system" \
    >"$TEST_TMP/denied" 2>&1
denied_status=$?
set -e
[[ "$denied_status" -ne 0 ]] || {
    printf 'system profile unexpectedly succeeded without sudo\n' >&2
    exit 1
}
grep -Eq 'sudo|become|privilege' "$TEST_TMP/denied"

begin_stage "testing password-required sudo through an interactive terminal"
cat >"$TEST_TMP/password-apply.sh" <<EOF
#!/usr/bin/env bash
exec "$REPO_ROOT/machstrap" apply "$REPO_ROOT/tests/docker/system" \
    --host machstrap-password \
    --user machstrap-password \
    --ssh-config "$TEST_TMP/ssh_config" \
    --ask-sudo-pass
EOF
chmod 0700 "$TEST_TMP/password-apply.sh"
printf 'machstrap-test-password\n' >"$TEST_TMP/password-input"
chmod 0600 "$TEST_TMP/password-input"
FAILURE_DIAGNOSTIC="$TEST_TMP/password"
expect "$REPO_ROOT/tests/lib/pty-run.exp" \
    'BECOME password:' \
    "$TEST_TMP/password-input" \
    "$TEST_TMP/password-apply.sh" \
    >"$TEST_TMP/password"
grep -q 'MACHSTRAP REPORT — SUCCESS' "$TEST_TMP/password"

begin_stage "testing symlink, Stow, script, and clone-only dotfile repositories"
FAILURE_DIAGNOSTIC="$TEST_TMP/dotfiles-symlink"
run_apply machstrap-symlink "$REPO_ROOT/tests/docker/dotfiles/symlink" \
    >"$TEST_TMP/dotfiles-symlink"
docker exec "$CONTAINER" test -L /home/machstrap-symlink/shell
docker exec "$CONTAINER" test -L /home/machstrap-symlink/install.sh

FAILURE_DIAGNOSTIC="$TEST_TMP/dotfiles-stow"
run_apply machstrap-stow "$REPO_ROOT/tests/docker/dotfiles/stow" \
    >"$TEST_TMP/dotfiles-stow"
docker exec "$CONTAINER" test -L /home/machstrap-stow/.stow-test

FAILURE_DIAGNOSTIC="$TEST_TMP/dotfiles-script"
run_apply machstrap-script "$REPO_ROOT/tests/docker/dotfiles/script" \
    >"$TEST_TMP/dotfiles-script"
docker exec "$CONTAINER" grep -qx script-installed \
    /home/machstrap-script/.script-installed

FAILURE_DIAGNOSTIC="$TEST_TMP/dotfiles-none"
run_apply machstrap-none "$REPO_ROOT/tests/docker/dotfiles/none" \
    >"$TEST_TMP/dotfiles-none"
docker exec "$CONTAINER" test -d /home/machstrap-none/.dotfiles/.git
docker exec "$CONTAINER" test ! -e /home/machstrap-none/.stow-test
docker exec "$CONTAINER" test ! -e /home/machstrap-none/.script-installed

begin_stage "testing encrypted Vault overrides"
cat >"$TEST_TMP/vault-password" <<'EOF'
machstrap-disposable-vault-password
EOF
chmod 0600 "$TEST_TMP/vault-password"
mkdir -p "$TEST_TMP/vault-inventory/group_vars/all"
cat >"$TEST_TMP/vault-inventory/hosts.yml" <<EOF
all:
  hosts:
    machstrap-vault:
      ansible_host: 127.0.0.1
      ansible_port: $port
      ansible_user: machstrap-vault
EOF
cat >"$TEST_TMP/vault-ssh-config" <<EOF
Host machstrap-vault 127.0.0.1
    HostName 127.0.0.1
    Port $port
    User machstrap-vault
    IdentityFile $TEST_TMP/controller
    IdentitiesOnly yes
    UserKnownHostsFile $TEST_TMP/known_hosts
    StrictHostKeyChecking yes
EOF
cat >"$TEST_TMP/vault-inventory/group_vars/all/vault.yml" <<'EOF'
machstrap_vault_overrides:
  commands:
    - command: "printf 'vault-applied\\n' > .machstrap-vault"
      chdir: "~"
      creates: "~/.machstrap-vault"
EOF
ansible-vault encrypt \
    --vault-password-file "$TEST_TMP/vault-password" \
    "$TEST_TMP/vault-inventory/group_vars/all/vault.yml"
FAILURE_DIAGNOSTIC="$TEST_TMP/zz-vault"
"$REPO_ROOT/machstrap" apply "$REPO_ROOT/tests/docker/vault" \
    --inventory "$TEST_TMP/vault-inventory/hosts.yml" \
    --limit machstrap-vault \
    --ssh-config "$TEST_TMP/vault-ssh-config" \
    --vault-password-file "$TEST_TMP/vault-password" \
    >"$TEST_TMP/zz-vault" 2>&1
docker exec "$CONTAINER" grep -qx vault-applied \
    /home/machstrap-vault/.machstrap-vault

begin_stage "testing include-tags and skip-tags isolation"
FAILURE_DIAGNOSTIC="$TEST_TMP/tags"
run_apply machstrap-tags "$REPO_ROOT/tests/docker/profile" \
    --tags dotfiles >"$TEST_TMP/tags"
docker exec "$CONTAINER" test -f /home/machstrap-tags/.machstrap-replace
docker exec "$CONTAINER" test ! -e /home/machstrap-tags/src/fixture
docker exec "$CONTAINER" test ! -e /home/machstrap-tags/.machstrap-command
docker exec "$CONTAINER" test ! -e /home/machstrap-tags/.machstrap-pre-hook
FAILURE_DIAGNOSTIC="$TEST_TMP/skip-tags"
run_apply machstrap-tags "$REPO_ROOT/tests/docker/profile" \
    --skip-tags dotfiles >"$TEST_TMP/skip-tags"
docker exec "$CONTAINER" test -d /home/machstrap-tags/src/fixture/.git
docker exec "$CONTAINER" grep -qx command \
    /home/machstrap-tags/.machstrap-command

[[ -s "$TEST_TMP/known_hosts" ]]
docker exec "$CONTAINER" test -s /var/log/machstrap-sudo.log
FAILURE_DIAGNOSTIC=
machstrap_test_log "Ubuntu $UBUNTU_VERSION Docker assertions passed"
printf 'docker-e2e: Ubuntu %s passed\n' "$UBUNTU_VERSION"
