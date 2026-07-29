#!/usr/bin/env bash
# Fast wrapper and bundle tests. No target machine is changed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/machstrap-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; pass=$((pass + 1)); }
mode_of() {
    case "$(uname -s)" in
        Darwin|FreeBSD|OpenBSD|NetBSD) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

sh -n "$REPO_ROOT/install.sh"
bash -n "$REPO_ROOT/machstrap" "$REPO_ROOT/quickstart.sh"
ok "shell syntax"

command -v ansible-playbook >/dev/null 2>&1 ||
    fail "ansible-playbook is required; install ansible-core 2.16 or newer"
command -v expect >/dev/null 2>&1 ||
    fail "Expect is required for portable interactive tests"
if ! ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
    "$REPO_ROOT/machstrap" doctor >"$TEST_TMP/doctor-runtime" 2>&1; then
    sed -n '1,120p' "$TEST_TMP/doctor-runtime" >&2
    fail "test runtime dependencies are missing or unsupported"
fi
ok "test runtime dependencies"

"$REPO_ROOT/tests/coverage/run.sh"
ok "configuration and behavior coverage is complete"

for test_script in \
    tests/coverage/run.sh \
    tests/lib/lifecycle.sh \
    tests/run-pre-push-tests.sh \
    tests/run-unit-tests.sh \
    tests/run-docker-tests.sh \
    tests/run-linux-vm-tests.sh \
    tests/run-macos-vm-tests.sh \
    tests/run-canary-tests.sh \
    tests/docker/run.sh \
    tests/docker/entrypoint.sh \
    tests/docker/verify-user.sh \
    tests/e2e/prepare-images.sh \
    tests/e2e/run-linux.sh \
    tests/e2e/run-macos.sh \
    tests/e2e/linux/verify.sh \
    tests/e2e/macos/verify.sh; do
    [[ -x "$REPO_ROOT/$test_script" ]] ||
        fail "pipeline script is not executable: $test_script"
    bash -n "$REPO_ROOT/$test_script"
done
[[ -x "$REPO_ROOT/tests/lib/pty-run.exp" ]] ||
    fail "pipeline script is not executable: tests/lib/pty-run.exp"
[[ -x "$REPO_ROOT/tests/lib/github-canary-run.exp" ]] ||
    fail "pipeline script is not executable: tests/lib/github-canary-run.exp"
[[ -x "$REPO_ROOT/.githooks/pre-push" ]] ||
    fail "versioned pre-push hook is not executable"
grep -q 'exec ./tests/run-pre-push-tests.sh' "$REPO_ROOT/.githooks/pre-push" ||
    fail "versioned pre-push hook does not run the local CI gate"
printf 'pty-test-secret\n' >"$TEST_TMP/pty-secret"
chmod 0600 "$TEST_TMP/pty-secret"
set +e
expect "$REPO_ROOT/tests/lib/pty-run.exp" \
    'BECOME password:' \
    "$TEST_TMP/pty-secret" \
    bash -c \
    'stty -echo; printf "BECOME password:"; IFS= read -r value; stty echo; printf "\nreceived=[REDACTED]\n"; exit 7' \
    >"$TEST_TMP/pty-output"
pty_status=$?
set -e
[[ "$pty_status" -eq 7 ]] || fail "PTY helper did not preserve child status"
grep -q 'received=\[REDACTED\]' "$TEST_TMP/pty-output" ||
    fail "PTY helper did not relay and redact the secret"
if grep -q 'pty-test-secret' "$TEST_TMP/pty-output"; then
    fail "PTY helper exposed the supplied secret"
fi
ok "portable PTY prompt forwarding"
set +e
expect "$REPO_ROOT/tests/lib/github-canary-run.exp" \
    bash -c \
    'printf "Trust this GitHub SSH host key on machstrap-e2e [yes/no]"; IFS= read -r first; printf "\nGitHub action [upload/manual/abort]"; IFS= read -r second; printf "\nanswers=%s,%s\n" "$first" "$second"; [[ "$first" == yes && "$second" == upload ]]; exit 7' \
    >"$TEST_TMP/canary-pty-output"
canary_pty_status=$?
set -e
[[ "$canary_pty_status" -eq 7 ]] ||
    fail "GitHub canary PTY helper did not preserve child status"
grep -q 'answers=yes,upload' "$TEST_TMP/canary-pty-output" ||
    fail "GitHub canary PTY helper did not answer both prompts"
ok "GitHub canary PTY forwarding"
for profile_file in \
    tests/docker/profile/profile.yml \
    tests/docker/system/profile.yml \
    tests/docker/dotfiles/symlink/profile.yml \
    tests/docker/dotfiles/stow/profile.yml \
    tests/docker/dotfiles/script/profile.yml \
    tests/docker/dotfiles/none/profile.yml \
    tests/docker/vault/profile.yml \
    tests/e2e/linux/profile/profile.yml \
    tests/e2e/linux/canary/profile.yml \
    tests/e2e/macos/profile/profile.yml; do
    [[ -f "$REPO_ROOT/$profile_file" ]] ||
        fail "pipeline profile is missing or incorrectly named: $profile_file"
done
[[ ! -e "$REPO_ROOT/.github/workflows/vm-e2e.yml" ]] ||
    fail "VM tests must remain local-only"
[[ ! -e "$REPO_ROOT/.github/workflows/external-canary.yml" ]] ||
    fail "external canary tests must remain local-only"
if grep -R -Eq 'self-hosted|upload-artifact' \
    "$REPO_ROOT/.github/workflows"; then
    fail "CI must use only standard hosted compute without artifact storage"
fi
if grep -R -h '^[[:space:]]*runs-on:' "$REPO_ROOT/.github/workflows" |
    grep -Ev 'runs-on: (ubuntu-latest|\$\{\{ matrix\.os \}\})$'; then
    fail "CI contains a runner outside the reviewed free-tier allowlist"
fi
grep -Fq 'os: [ubuntu-latest, macos-latest]' \
    "$REPO_ROOT/.github/workflows/tests.yml" ||
    fail "fast CI runner matrix changed outside the free-tier allowlist"
grep -q 'ansible-core expect' "$REPO_ROOT/.github/workflows/tests.yml" ||
    fail "Linux fast CI does not install its controller dependencies"
grep -q 'brew install ansible' "$REPO_ROOT/.github/workflows/tests.yml" ||
    fail "macOS fast CI does not install Ansible"
grep -q 'ansible-core expect' "$REPO_ROOT/.github/workflows/docker-e2e.yml" ||
    fail "Docker CI does not install its controller dependencies"
if grep -q -- '--privileged' "$REPO_ROOT/tests/docker/run.sh"; then
    fail "Docker integration suite requests a privileged container"
fi
if grep -q 'machstrap-test-password' "$REPO_ROOT/tests/docker/Dockerfile"; then
    fail "disposable password is embedded in Docker image history"
fi
grep -q 'docker rm -f "$CONTAINER"' "$REPO_ROOT/tests/docker/run.sh" ||
    fail "Docker integration suite does not remove its exact container"
grep -q 'docker image rm -f "$IMAGE"' "$REPO_ROOT/tests/docker/run.sh" ||
    fail "Docker integration suite does not remove its exact image"
grep -q 'virsh undefine "$domain_name"' \
    "$REPO_ROOT/tests/e2e/run-linux.sh" ||
    fail "Linux VM integration suite does not undefine its VMs"
grep -q 'tart delete "$VM_NAME"' "$REPO_ROOT/tests/e2e/run-macos.sh" ||
    fail "macOS VM integration suite does not delete its Tart VM"
[[ -f "$REPO_ROOT/tests/logs/.gitignore" ]] ||
    fail "sanitized test log directory is not configured"
ok "integration pipeline security boundaries"

grep -q 'Keep the Debian local hostname mapping synchronized' \
    "$REPO_ROOT/roles/machstrap/tasks/hostname.yml" ||
    fail "Debian hostname mapping protection missing"
if grep -Eq 'machstrap-linux-(server|workstation)' \
    "$REPO_ROOT/profiles/linux-server/profile.yml" \
    "$REPO_ROOT/profiles/linux-workstation/profile.yml"; then
    fail "reusable Linux profiles still force a shared hostname"
fi
ok "Linux hostname defaults and local resolution are safe"

awk '
    /^- name: / { name = substr($0, 9) }
    /^[[:space:]]+become: true[[:space:]]*$/ {
        print FILENAME " — " name
    }
' \
    "$REPO_ROOT/playbooks/site.yml" \
    "$REPO_ROOT/roles/machstrap/handlers/main.yml" \
    "$REPO_ROOT"/roles/machstrap/tasks/*.yml \
    | sed "s|$REPO_ROOT/||" \
    | LC_ALL=C sort >"$TEST_TMP/privilege-surface"
if ! cmp -s "$REPO_ROOT/tests/privilege-surface.txt" "$TEST_TMP/privilege-surface"; then
    diff -u "$REPO_ROOT/tests/privilege-surface.txt" "$TEST_TMP/privilege-surface" >&2 || true
    fail "task-scoped privilege surface changed without explicit review"
fi
if grep -Eq '^[[:space:]]+become:[[:space:]]+true[[:space:]]*$' \
    "$REPO_ROOT/roles/machstrap/tasks/dotfiles.yml" \
    "$REPO_ROOT/roles/machstrap/tasks/git.yml" \
    "$REPO_ROOT/roles/machstrap/tasks/github-ssh.yml" \
    "$REPO_ROOT/roles/machstrap/tasks/commands.yml" \
    "$REPO_ROOT/roles/machstrap/tasks/macos.yml"; then
    fail "user-scoped task file requested privilege escalation"
fi
ok "privilege escalation surface is explicit and reviewed"

first_role_task="$(sed -n '/ansible.builtin.import_tasks:/ { s/.*import_tasks: //; p; q; }' \
    "$REPO_ROOT/roles/machstrap/tasks/main.yml")"
[[ "$first_role_task" == github-ssh.yml ]] ||
    fail "GitHub identity preparation is not the first role task"
grep -q 'ansible.builtin.import_tasks: git-preflight.yml' \
    "$REPO_ROOT/roles/machstrap/tasks/main.yml" ||
    fail "early Git repository access preflight missing"
ok "Git access is checked before machine changes"

"$REPO_ROOT/machstrap" --help > "$TEST_TMP/help"
grep -q 'Manage configured and bundled profiles' "$TEST_TMP/help" || fail "profiles help text"
grep -q 'machstrap profiles \[COMMAND\]' "$TEST_TMP/help" || fail "profiles help text"
"$REPO_ROOT/machstrap" config --help > "$TEST_TMP/config-help"
grep -q '^Usage: machstrap config' "$TEST_TMP/config-help" || fail "config command help"
"$REPO_ROOT/machstrap" profiles --help > "$TEST_TMP/profiles-help"
grep -q 'edit NAME' "$TEST_TMP/profiles-help" || fail "profiles edit help"
grep -q 'browse \[PROFILE\]' "$TEST_TMP/profiles-help" || fail "profiles browse help"
"$REPO_ROOT/machstrap" profiles > "$TEST_TMP/profiles-command-help"
cmp "$TEST_TMP/profiles-help" "$TEST_TMP/profiles-command-help" || fail "profiles command help"
"$REPO_ROOT/machstrap" profiles new --help > "$TEST_TMP/profiles-new-help"
grep -q -- '--no-edit' "$TEST_TMP/profiles-new-help" || fail "profiles new command help"
"$REPO_ROOT/machstrap" profiles delete --help > "$TEST_TMP/profiles-delete-help"
grep -q -- '--force' "$TEST_TMP/profiles-delete-help" || fail "profiles delete command help"
"$REPO_ROOT/machstrap" inventories --help > "$TEST_TMP/inventories-help"
grep -q '^  browse ' "$TEST_TMP/inventories-help" || fail "inventories browse help"
"$REPO_ROOT/machstrap" identities --help > "$TEST_TMP/identities-help"
grep -q '^  browse ' "$TEST_TMP/identities-help" || fail "identities browse help"
set +e
"$REPO_ROOT/machstrap" init > "$TEST_TMP/retired-init-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "retired init command status"
grep -q 'unknown command: init' "$TEST_TMP/retired-init-output" || fail "retired init diagnostic"
"$REPO_ROOT/machstrap" apply --help > "$TEST_TMP/apply-help"
grep -q '^Usage: machstrap apply PROFILE' "$TEST_TMP/apply-help" || fail "apply command help"
grep -q -- '--ssh-plan' "$TEST_TMP/apply-help" || fail "apply SSH plan help"
grep -q -- '--interactive' "$TEST_TMP/apply-help" || fail "apply interactive help"
grep -q -- '--ask-sudo-pass' "$TEST_TMP/apply-help" ||
    fail "apply sudo password help"
"$REPO_ROOT/machstrap" update --help > "$TEST_TMP/update-help"
grep -q '^Usage: machstrap update|upgrade' "$TEST_TMP/update-help" || fail "update command help"
ok "command help"

grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$REPO_ROOT/VERSION" ||
    fail "VERSION is not a stable semantic version"
expected_version="$(sed -n '1p' "$REPO_ROOT/VERSION")"
"$REPO_ROOT/machstrap" --version >"$TEST_TMP/version"
grep -qx "machstrap $expected_version" "$TEST_TMP/version" ||
    fail "version command does not match VERSION"
ok "version metadata"

config_home="$TEST_TMP/config home"
profile_root="$TEST_TMP/user profiles"
mkdir -p "$profile_root/profiles/alpha" "$profile_root/profiles/linux-server"
chmod 700 "$profile_root"
cp "$REPO_ROOT/profiles/linux-workstation/profile.yml" \
    "$profile_root/profiles/alpha/profile.yml"
cp "$REPO_ROOT/profiles/linux-server/profile.yml" \
    "$profile_root/profiles/linux-server/profile.yml"
mkdir -p "$profile_root/profiles/bravo"
cp "$REPO_ROOT/profiles/linux-workstation/profile.yml" \
    "$profile_root/profiles/bravo/profile.yaml"

XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" profiles default >"$TEST_TMP/default-profiles"
grep -q '^  full-example ' "$TEST_TMP/default-profiles" ||
    fail "default profiles missing full-example"
if grep -q '^  alpha ' "$TEST_TMP/default-profiles"; then
    fail "default profiles included a configured-only profile"
fi
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" profiles list >"$TEST_TMP/unconfigured-profiles"
grep -q 'No profile directory configured' "$TEST_TMP/unconfigured-profiles" ||
    fail "unconfigured profiles guidance"
set +e
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" profiles unknown \
    >"$TEST_TMP/unknown-profiles-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "unknown profiles command status"
grep -q 'usage: machstrap profiles list|default|edit PROFILE' \
    "$TEST_TMP/unknown-profiles-output" || fail "profiles subcommand usage"
ok "profile commands work without config or Ansible"

XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config "$profile_root" >"$TEST_TMP/config-set" 2>"$TEST_TMP/config-set-stderr"
profile_root_real="$(cd "$profile_root" && pwd -P)"
grep -qx "$profile_root_real" "$TEST_TMP/config-set" ||
    fail "config did not print canonical profile directory"
grep -Fq "successfully set the Machstrap profile directory to: $profile_root_real" \
    "$TEST_TMP/config-set-stderr" || fail "config success message"
for default_profile in full-example linux-server linux-workstation macos-workstation; do
    [[ -f "$profile_root/profiles/$default_profile/profile.yml" ]] ||
        fail "config did not copy bundled profile: $default_profile"
done
[[ -f "$profile_root/profiles/full-example/hooks/pre.yml" ]] || fail "config did not copy pre-hook example"
[[ -f "$profile_root/profiles/full-example/hooks/post.yml" ]] || fail "config did not copy post-hook example"
[[ -x "$profile_root/profiles/full-example/scripts/example-post-hook.sh" ]] ||
    fail "config did not copy executable post-hook script"
[[ -f "$profile_root/inventories/example/hosts.yml" ]] || fail "config did not copy inventory template"
[[ -f "$profile_root/inventories/example/group_vars/all.yml" ]] || fail "config inventory group vars missing"
[[ -f "$profile_root/inventories/example/host_vars/example-server.yml" ]] || fail "config inventory host vars missing"
[[ -f "$profile_root/inventories/example/host_vars/example-mac.yml" ]] || fail "config inventory macOS host vars missing"
[[ -d "$profile_root/identities" ]] || fail "config did not create identities directory"
[[ "$(mode_of "$config_home/machstrap")" == 700 ]] ||
    fail "config directory mode"
[[ "$(mode_of "$config_home/machstrap/config")" == 600 ]] ||
    fail "config file mode"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config >"$TEST_TMP/config-show"
grep -qx "$profile_root_real" "$TEST_TMP/config-show" || fail "config show"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" profiles list >"$TEST_TMP/configured-profiles"
grep -q '^  alpha ' "$TEST_TMP/configured-profiles" ||
    fail "configured profiles missing alpha"
grep -q '^  bravo ' "$TEST_TMP/configured-profiles" ||
    fail "configured profiles missing YAML-extension profile"
grep -q 'linux-server.*overrides default' "$TEST_TMP/configured-profiles" ||
    fail "configured profile override marker"
grep -q '^  macos-workstation ' "$TEST_TMP/configured-profiles" ||
    fail "configured profiles missing seeded bundled profile"
ok "optional profile config and configured listing"

mkdir -p "$profile_root/profiles/delete-me"
cp "$REPO_ROOT/profiles/full-example/profile.yml" "$profile_root/profiles/delete-me/profile.yml"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" profiles delete delete-me --force
[[ ! -e "$profile_root/profiles/delete-me" ]] || fail "profiles delete did not remove complete profile"
[[ -d "$REPO_ROOT/profiles/full-example" ]] || fail "profiles delete affected bundled profile"
ok "configured profile deletion"

XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" inventories default >"$TEST_TMP/default-inventories"
grep -q '^  example ' "$TEST_TMP/default-inventories" || fail "default inventories missing example"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" inventories new staging --no-edit
[[ -f "$profile_root/inventories/staging/hosts.yml" ]] || fail "inventories new did not create configured inventory"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" inventories delete staging --force
[[ ! -e "$profile_root/inventories/staging" ]] || fail "inventories delete did not remove configured inventory"
ok "configured inventory collections"

touch "$profile_root/identities/test-id"
chmod 600 "$profile_root/identities/test-id"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" identities list >"$TEST_TMP/configured-identities"
grep -q '^  test-id ' "$TEST_TMP/configured-identities" || fail "identities list did not include secure identity"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" identities delete test-id --force
[[ ! -e "$profile_root/identities/test-id" ]] || fail "identities delete did not remove identity"
ok "configured identity collections"

XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config --unset
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config --unset
set +e
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config >"$TEST_TMP/config-unset-output" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "unset config still showed a path"
touch "$TEST_TMP/foreign-config"
ln -s "$TEST_TMP/foreign-config" "$config_home/machstrap/config"
set +e
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config "$profile_root" \
    >"$TEST_TMP/config-symlink-output" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "config replaced a symlink"
grep -q 'unsafe config file' "$TEST_TMP/config-symlink-output" ||
    fail "unsafe config diagnostic"
rm -f "$config_home/machstrap/config"
unsafe_profile_root="$TEST_TMP/writable profiles"
mkdir -p "$unsafe_profile_root"
chmod 777 "$unsafe_profile_root"
set +e
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config "$unsafe_profile_root" \
    >"$TEST_TMP/writable-root-output" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "config accepted a writable profile root"
grep -q 'not group/world writable' "$TEST_TMP/writable-root-output" ||
    fail "writable profile root diagnostic"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config "$profile_root" >/dev/null
ok "config unset and unsafe-path protection"

if find "$REPO_ROOT" -path "$REPO_ROOT/.venv" -prune -o -path "$REPO_ROOT/.git" -prune -o -name '*.py' -print | grep -q .; then
    fail "repository still contains Python source"
fi
[[ ! -e "$REPO_ROOT/pyproject.toml" ]] || fail "pyproject.toml still exists"
ok "no machstrap Python runtime"

set +e
"$REPO_ROOT/machstrap" apply full-example --check >"$TEST_TMP/no-target" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "missing target did not return status 2"
grep -q 'choose --local' "$TEST_TMP/no-target" || fail "missing-target message"
ok "explicit target required"

set +e
"$REPO_ROOT/machstrap" apply full-example \
    --inventory "$REPO_ROOT/inventories/example/hosts.yml" >"$TEST_TMP/no-limit" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "unlimited inventory did not return status 2"
grep -q 'require --limit' "$TEST_TMP/no-limit" || fail "inventory limit message"
ok "inventory limit required"

mkdir -p "$TEST_TMP/unsafe-become-inventory"
printf '%s\n' \
    'all:' \
    '  hosts:' \
    '    unsafe-become:' \
    '      ansible_connection: local' \
    '      ansible_become: true' \
    >"$TEST_TMP/unsafe-become-inventory/hosts.yml"
set +e
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
"$REPO_ROOT/machstrap" check full-example \
    --inventory "$TEST_TMP/unsafe-become-inventory/hosts.yml" \
    --limit unsafe-become >"$TEST_TMP/unsafe-become-output" 2>&1
status=$?
set -e
if [[ "$status" -ne 2 ]]; then
    sed -n '1,120p' "$TEST_TMP/unsafe-become-output" >&2
    fail "inventory-wide become returned status $status instead of 2"
fi
grep -q 'Do not set ansible_become in inventory' "$TEST_TMP/unsafe-become-output" ||
    fail "inventory-wide become diagnostic"
grep -Eq 'unsafe-become-inventory/hosts\.yml:[0-9]+:[0-9]+:' \
    "$TEST_TMP/unsafe-become-output" ||
    {
        sed -n '1,120p' "$TEST_TMP/unsafe-become-output" >&2
        fail "inventory-wide become diagnostic omitted its source line"
    }

real_ansible_playbook="$(command -v ansible-playbook)"
mkdir -p "$TEST_TMP/wrapped-ansible"
printf '%s\n' \
    '#!/bin/sh' \
    'exec "${MACHSTRAP_TEST_REAL_ANSIBLE:?}" "$@"' \
    >"$TEST_TMP/wrapped-ansible/ansible-playbook"
chmod 0755 "$TEST_TMP/wrapped-ansible/ansible-playbook"
set +e
MACHSTRAP_TEST_REAL_ANSIBLE="$real_ansible_playbook" \
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
PATH="$TEST_TMP/wrapped-ansible:$PATH" \
"$REPO_ROOT/machstrap" check full-example \
    --inventory "$TEST_TMP/unsafe-become-inventory/hosts.yml" \
    --limit unsafe-become >"$TEST_TMP/wrapped-ansible-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] ||
    fail "shell-wrapped Ansible validation returned status $status instead of 2"
grep -Eq 'unsafe-become-inventory/hosts\.yml:[0-9]+:[0-9]+:' \
    "$TEST_TMP/wrapped-ansible-output" ||
    {
        sed -n '1,120p' "$TEST_TMP/wrapped-ansible-output" >&2
        fail "shell-wrapped Ansible diagnostic omitted its source line"
    }
ok "source-aware validation survives a shell-wrapped Ansible launcher"

mkdir -p "$TEST_TMP/unsafe-become-vars/group_vars"
printf '%s\n' \
    'all:' \
    '  hosts:' \
    '    unsafe-vars:' \
    '      ansible_connection: local' \
    >"$TEST_TMP/unsafe-become-vars/hosts.yml"
printf '%s\n' 'ansible_become: false' \
    >"$TEST_TMP/unsafe-become-vars/group_vars/all.yml"
set +e
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
"$REPO_ROOT/machstrap" check full-example \
    --inventory "$TEST_TMP/unsafe-become-vars/hosts.yml" \
    --limit unsafe-vars >"$TEST_TMP/unsafe-become-vars-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] ||
    fail "inventory-wide become in group_vars returned status $status instead of 2"
grep -Eq 'group_vars/all\.yml:[0-9]+:[0-9]+:' \
    "$TEST_TMP/unsafe-become-vars-output" ||
    fail "group_vars become diagnostic omitted its source line"
ok "inventory-wide privilege escalation is rejected"

mkdir -p "$TEST_TMP/snap-profile"
printf '%s\n' \
    'machstrap_profile:' \
    '  packages:' \
    '    snap:' \
    '      - go' \
    '      - name: code' \
    >"$TEST_TMP/snap-profile/profile.yml"
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
"$REPO_ROOT/machstrap" check "$TEST_TMP/snap-profile" --local \
    >"$TEST_TMP/snap-profile-output"
grep -Fq 'MACHSTRAP REPORT — SUCCESS' "$TEST_TMP/snap-profile-output" ||
    fail "Snap shorthand and optional mapping fields were not accepted"

mkdir -p "$TEST_TMP/invalid-snap-profile"
printf '%s\n' \
    'machstrap_profile:' \
    '  packages:' \
    '    snap:' \
    '      - name: code' \
    '        classic: yes-please' \
    >"$TEST_TMP/invalid-snap-profile/profile.yml"
set +e
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
"$REPO_ROOT/machstrap" check "$TEST_TMP/invalid-snap-profile" --local \
    >"$TEST_TMP/invalid-snap-profile-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "invalid Snap controls were accepted"
grep -Eq 'invalid-snap-profile/profile\.yml:[0-9]+:[0-9]+:' \
    "$TEST_TMP/invalid-snap-profile-output" ||
    fail "invalid Snap diagnostic omitted its source line"
grep -q 'optional non-empty channel and boolean classic' \
    "$TEST_TMP/invalid-snap-profile-output" ||
    fail "invalid Snap diagnostic omitted the expected schema"
ok "Snap declarations accept shorthand and report malformed source"

mkdir -p "$TEST_TMP/git-preflight/bin"
cat >"$TEST_TMP/git-preflight/bin/git" <<'STUB'
#!/usr/bin/env sh
printf '%s|%s|%s\n' \
    "${GIT_TERMINAL_PROMPT:-}" "${GIT_SSH_COMMAND:-}" "$*" \
    >>"${MACHSTRAP_TEST_GIT_LOG:?}"
if [ -n "${MACHSTRAP_TEST_GIT_MARKER:-}" ] && [ -f "$MACHSTRAP_TEST_GIT_MARKER" ]; then
    exit 0
fi
printf '%s\n' "${MACHSTRAP_TEST_GIT_STDERR:-}" >&2
exit "${MACHSTRAP_TEST_GIT_RC:-0}"
STUB
chmod +x "$TEST_TMP/git-preflight/bin/git"
cat >"$TEST_TMP/git-preflight/play.yml" <<EOF
---
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    machstrap_home: $TEST_TMP/git-preflight/target-home
    machstrap_interactive: false
    machstrap:
      github_ssh:
        enabled: true
      git_repos:
        - repo: git@github.com:private/project.git
          path: ~/project
          branch: main
    machstrap_github_public_key_stat:
      stat:
        exists: true
    machstrap_github_public_key:
      content: c3NoLWVkMjU1MTkgQUFBQSB0ZXN0
    machstrap_github_public_key_fingerprint:
      stdout: 256 SHA256:test target-key
  tasks:
    - import_tasks: $REPO_ROOT/roles/machstrap/tasks/git-preflight.yml
EOF
set +e
MACHSTRAP_TEST_GIT_LOG="$TEST_TMP/git-preflight/first-use.log" \
PATH="$TEST_TMP/git-preflight/bin:$PATH" \
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
ansible-playbook -i localhost, "$TEST_TMP/git-preflight/play.yml" \
    >"$TEST_TMP/git-preflight/first-use-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "non-interactive GitHub first use trusted a host key"
grep -q 'GitHub SSH host-key confirmation is required' \
    "$TEST_TMP/git-preflight/first-use-output" ||
    fail "GitHub first-use failure omitted fingerprint confirmation guidance"
grep -Fq 'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU' \
    "$TEST_TMP/git-preflight/first-use-output" ||
    fail "GitHub first-use failure omitted the pinned fingerprint"
printf '%s\n' \
    'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
    >"$TEST_TMP/git-preflight/target-home/.ssh/known_hosts"
chmod 644 "$TEST_TMP/git-preflight/target-home/.ssh/known_hosts"
ok "GitHub SSH first use requires explicit host-key confirmation"

MACHSTRAP_TEST_GIT_LOG="$TEST_TMP/git-preflight/success.log" \
PATH="$TEST_TMP/git-preflight/bin:$PATH" \
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
ansible-playbook -i localhost, "$TEST_TMP/git-preflight/play.yml" \
    >"$TEST_TMP/git-preflight/success-output"
grep -Fqx '0|ssh -o BatchMode=yes|ls-remote git@github.com:private/project.git HEAD' \
    "$TEST_TMP/git-preflight/success.log" ||
    fail "Git access preflight did not disable credential prompts"
ssh-keygen -lf "$TEST_TMP/git-preflight/target-home/.ssh/known_hosts" \
    >"$TEST_TMP/git-preflight/known-host-fingerprints"
grep -Fq 'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU' \
    "$TEST_TMP/git-preflight/known-host-fingerprints" ||
    fail "GitHub's pinned Ed25519 host key was not installed"

set +e
MACHSTRAP_TEST_GIT_LOG="$TEST_TMP/git-preflight/failure.log" \
MACHSTRAP_TEST_GIT_RC=128 \
MACHSTRAP_TEST_GIT_STDERR='Permission denied (publickey).' \
PATH="$TEST_TMP/git-preflight/bin:$PATH" \
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
ansible-playbook -i localhost, "$TEST_TMP/git-preflight/play.yml" \
    >"$TEST_TMP/git-preflight/failure-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "inaccessible Git repository passed preflight"
grep -q 'Git access preflight failed for git@github.com:private/project.git' \
    "$TEST_TMP/git-preflight/failure-output" ||
    fail "Git access preflight omitted the inaccessible repository"
grep -q 'Re-run a real apply for one host from a usable terminal' \
    "$TEST_TMP/git-preflight/failure-output" ||
    fail "GitHub SSH failure omitted interactive remediation"
ok "Git preflight is non-prompting and fails with GitHub remediation"

cat >"$TEST_TMP/git-preflight/bin/gh" <<'STUB'
#!/usr/bin/env sh
if [ "${1:-}" = ssh-key ] && [ "${2:-}" = add ]; then
    cp "$3" "${MACHSTRAP_TEST_GITHUB_UPLOADED_KEY:?}"
    touch "${MACHSTRAP_TEST_GIT_MARKER:?}"
    exit 0
fi
exit 1
STUB
chmod +x "$TEST_TMP/git-preflight/bin/gh"
cat >"$TEST_TMP/git-preflight/upload-play.yml" <<EOF
---
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    machstrap_interactive: true
    machstrap_git_github_ssh_repairable: true
    machstrap_git_can_prompt: true
    machstrap_git_repository:
      repo: git@github.com:private/project.git
    machstrap_git_access_initial:
      rc: 128
      stderr: Permission denied (publickey).
    machstrap_github_key_choice:
      user_input: upload
    machstrap_github_cli_account:
      rc: 0
      stdout: test-account
    machstrap_github_public_key:
      content: c3NoLWVkMjU1MTkgQUFBQSB0ZXN0
    machstrap_github_public_key_fingerprint:
      stdout: 256 SHA256:test target-key
  tasks:
    - import_tasks: $REPO_ROOT/roles/machstrap/tasks/git-preflight-repository.yml
EOF
MACHSTRAP_TEST_GIT_LOG="$TEST_TMP/git-preflight/upload.log" \
MACHSTRAP_TEST_GIT_MARKER="$TEST_TMP/git-preflight/uploaded" \
MACHSTRAP_TEST_GITHUB_UPLOADED_KEY="$TEST_TMP/git-preflight/uploaded.pub" \
PATH="$TEST_TMP/git-preflight/bin:$PATH" \
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
ANSIBLE_REMOTE_TMP="$TEST_TMP/ansible-remote" \
ansible-playbook -i localhost, "$TEST_TMP/git-preflight/upload-play.yml" \
    --start-at-task 'Create a temporary public-key file on the controller' \
    >"$TEST_TMP/git-preflight/upload-output"
grep -qx 'ssh-ed25519 AAAA test' "$TEST_TMP/git-preflight/uploaded.pub" ||
    fail "confirmed GitHub upload did not receive the target public key"
grep -q 'failed=0' "$TEST_TMP/git-preflight/upload-output" ||
    fail "Git access was not retried after confirmed GitHub upload"
ok "confirmed GitHub upload stages only the public key and retries access"

mkdir -p "$TEST_TMP/bin"
ANSIBLE_LOCAL_TEMP="$TEST_TMP/ansible-local" \
    "$real_ansible_playbook" --version >"$TEST_TMP/real-ansible-version"
chmod 0600 "$TEST_TMP/real-ansible-version"
export MACHSTRAP_TEST_REAL_ANSIBLE_VERSION="$TEST_TMP/real-ansible-version"
cat > "$TEST_TMP/bin/ansible-playbook" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    if [[ "${MACHSTRAP_TEST_OLD_ANSIBLE:-}" == 1 ]]; then
        echo 'ansible-playbook [core 2.15.0]'
    else
        cat "${MACHSTRAP_TEST_REAL_ANSIBLE_VERSION:?}"
    fi
    exit 0
fi
printf '%s\n' "$@" > "${MACHSTRAP_TEST_CAPTURE:?}"
if [[ -n "${MACHSTRAP_TEST_PROFILE_CAPTURE:-}" ]]; then
    printf '%s\n' "${MACHSTRAP_PROFILE_FILE:-}" >"$MACHSTRAP_TEST_PROFILE_CAPTURE"
fi
if [[ -n "${MACHSTRAP_TEST_SSH_ARGS_CAPTURE:-}" ]]; then
    printf '%s\n' "${ANSIBLE_SSH_ARGS:-}" >"$MACHSTRAP_TEST_SSH_ARGS_CAPTURE"
fi
if [[ "${MACHSTRAP_TEST_EVENTS:-}" == 1 ]]; then
    cat <<'EVENTS'
TASK [Inspect state] ***********************************************************
ok: [localhost]
TASK [Apply one change] *******************************************************
changed: [localhost]
TASK [Skip irrelevant work] **************************************************
skipping: [localhost]
EVENTS
    if [[ "${ANSIBLE_DISPLAY_SKIPPED_HOSTS:-}" == True ]]; then
        printf '%s\n' "${MACHSTRAP_TEST_EXTRA_SKIPS:-}"
    fi
    cat <<'RECAP'
PLAY RECAP *********************************************************************
localhost                  : ok=2 changed=1 unreachable=0 failed=0 skipped=4 rescued=0 ignored=0
RECAP
fi
if [[ "${MACHSTRAP_TEST_NO_HOSTS:-}" == 1 ]]; then
    cat <<'NO_HOSTS'
[WARNING]: Could not match supplied host pattern, ignoring: missing-host

PLAY [Validate a machstrap profile without changing targets] *******************
skipping: no hosts matched
NO_HOSTS
fi
if [[ "${MACHSTRAP_TEST_FAIL:-}" == 1 ]]; then
    cat <<'FAILURE'
TASK [Fail safely] ************************************************************
fatal: [localhost]: FAILED! => {"changed": false, "msg": "expected test failure"}
FAILURE
    exit 3
fi
if [[ "${MACHSTRAP_TEST_HOST_KEY_FAIL:-}" == 1 ]]; then
    cat <<'HOST_KEY_FAILURE'
TASK [Gather target facts] *****************************************************
fatal: [server.example]: UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh: ssh_askpass: unavailable\r\nHost key verification failed.", "unreachable": true}

PLAY RECAP *********************************************************************
server.example            : ok=0 changed=0 unreachable=1 failed=0 skipped=0 rescued=0 ignored=0
HOST_KEY_FAILURE
    exit 4
fi
STUB
chmod +x "$TEST_TMP/bin/ansible-playbook"

NO_COLOR= MACHSTRAP_COLOR=always PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" doctor > "$TEST_TMP/doctor-color"
grep -Fq $'\033[1;32mok\033[0m' "$TEST_TMP/doctor-color" || fail "green doctor ok"
grep -Fq $'\033[1;32mReady.\033[0m' "$TEST_TMP/doctor-color" || fail "green doctor Ready"
NO_COLOR=1 MACHSTRAP_COLOR=always PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" doctor > "$TEST_TMP/doctor-plain"
if grep -Fq $'\033' "$TEST_TMP/doctor-plain"; then
    fail "NO_COLOR did not disable doctor colors"
fi
set +e
NO_COLOR= MACHSTRAP_COLOR=always MACHSTRAP_TEST_OLD_ANSIBLE=1 \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" doctor > "$TEST_TMP/doctor-failure"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "unsupported Ansible passed doctor"
grep -Fq $'\033[1;31munsupported\033[0m' "$TEST_TMP/doctor-failure" || fail "red doctor failure"
ok "doctor colors and NO_COLOR"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example --local
grep -q '/playbooks/validate.yml' "$TEST_TMP/args" || fail "check playbook selection"
grep -qx 'localhost,' "$TEST_TMP/args" || fail "local inventory"
grep -qx 'machstrap_interactive=false' "$TEST_TMP/args" ||
    fail "wrapper did not explicitly disable Ansible interaction"
grep -qx 'machstrap_prompt_available=false' "$TEST_TMP/args" ||
    fail "redirected validation unexpectedly enabled Ansible prompts"
ok "wrapper invokes validation safely"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/check-events-args" MACHSTRAP_TEST_EVENTS=1 \
MACHSTRAP_TEST_EXTRA_SKIPS=$'skipping: [localhost]\nskipping: [localhost]\nskipping: [localhost]' \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example --local > "$TEST_TMP/check-events-output"
grep -q 'localhost — Skip irrelevant work (4 results)' "$TEST_TMP/check-events-output" ||
    fail "check output did not list every skipped result"
if grep -q 'results suppressed by Ansible compact output' "$TEST_TMP/check-events-output"; then
    fail "check output still suppressed skipped results"
fi
ok "check reports every skipped result"

set +e
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/no-hosts-args" MACHSTRAP_TEST_NO_HOSTS=1 \
PATH="$TEST_TMP/bin:$PATH" \
    "$REPO_ROOT/machstrap" check full-example \
    --inventory "$REPO_ROOT/inventories/example/hosts.yml" --limit missing-host \
    >"$TEST_TMP/no-hosts-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "empty inventory selection did not fail"
grep -q 'target selection matched no hosts' "$TEST_TMP/no-hosts-output" ||
    fail "empty inventory selection diagnostic"
ok "empty inventory selection is rejected"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/configured-profile-args" \
MACHSTRAP_TEST_PROFILE_CAPTURE="$TEST_TMP/configured-profile-path" \
XDG_CONFIG_HOME="$config_home" PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check alpha --local
grep -qx "$profile_root_real/profiles/alpha/profile.yml" \
    "$TEST_TMP/configured-profile-path" ||
    fail "configured bare profile was not resolved"
configured_init="$TEST_TMP/configured-init"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" profiles new configured-init --out "$configured_init" --preset alpha --no-edit
cmp "$profile_root/profiles/alpha/profile.yml" "$configured_init/profile.yml" ||
    fail "configured preset was not copied"
ok "configured profile resolution and preset init"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/yaml-profile-args" \
MACHSTRAP_TEST_PROFILE_CAPTURE="$TEST_TMP/yaml-profile-path" \
XDG_CONFIG_HOME="$config_home" PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check bravo --local
grep -qx "$profile_root_real/profiles/bravo/profile.yaml" \
    "$TEST_TMP/yaml-profile-path" ||
    fail "configured YAML-extension profile was not resolved"
yaml_bundle="$TEST_TMP/bravo.machstrap"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" bundle bravo --out "$yaml_bundle"
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/yaml-bundle-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check "$yaml_bundle" --local
grep -q '/playbooks/validate.yml' "$TEST_TMP/yaml-bundle-args" ||
    fail "YAML-extension bundle was not resolved"
ok "profile.yaml is accepted"

chmod 644 "$config_home/machstrap/config"
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/unsafe-config-args" \
XDG_CONFIG_HOME="$config_home" PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example --local \
    >"$TEST_TMP/unsafe-config-output" 2>&1
grep -q 'ignoring unsafe profile config file' "$TEST_TMP/unsafe-config-output" ||
    fail "unsafe optional config warning"
grep -q "$REPO_ROOT/playbooks/validate.yml" "$TEST_TMP/unsafe-config-args" ||
    fail "unsafe optional config blocked bundled profile"
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/explicit-profile-args" \
MACHSTRAP_TEST_PROFILE_CAPTURE="$TEST_TMP/explicit-profile-path" \
XDG_CONFIG_HOME="$config_home" PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check "$profile_root/profiles/alpha" --local \
    >"$TEST_TMP/explicit-profile-output" 2>&1
grep -qx "$profile_root_real/profiles/alpha/profile.yml" \
    "$TEST_TMP/explicit-profile-path" ||
    fail "unsafe optional config blocked explicit profile"
chmod 600 "$config_home/machstrap/config"
printf '%s\n' "$TEST_TMP/missing-profile-root" \
    >"$config_home/machstrap/config"
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/stale-config-args" \
XDG_CONFIG_HOME="$config_home" PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example --local \
    >"$TEST_TMP/stale-config-output" 2>&1
grep -q 'ignoring stale profile config' "$TEST_TMP/stale-config-output" ||
    fail "stale optional config warning"
grep -q "$REPO_ROOT/playbooks/validate.yml" "$TEST_TMP/stale-config-args" ||
    fail "stale optional config blocked bundled profile"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" config "$profile_root" >/dev/null
ok "invalid optional config never blocks existing resolution"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/dry-run-args" MACHSTRAP_TEST_EVENTS=1 \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --local --dry-run --diff > "$TEST_TMP/dry-run-output"
grep -qx -- '--check' "$TEST_TMP/dry-run-args" || fail "dry-run did not enable Ansible check mode"
grep -qx -- '--diff' "$TEST_TMP/dry-run-args" || fail "dry-run did not preserve diff mode"
grep -q 'MACHSTRAP REPORT — SUCCESS' "$TEST_TMP/dry-run-output" || fail "successful final report"
grep -q 'Mode:     DRY RUN' "$TEST_TMP/dry-run-output" || fail "dry-run report mode"
grep -q 'CHANGED (1)' "$TEST_TMP/dry-run-output" || fail "changed report section"
grep -q 'OK (1)' "$TEST_TMP/dry-run-output" || fail "ok report section"
grep -q 'SKIPPED (4)' "$TEST_TMP/dry-run-output" || fail "skipped report section"
grep -q '3 results suppressed' "$TEST_TMP/dry-run-output" || fail "suppressed skip count"
grep -q 'TOTAL: 1 changed · 2 ok' "$TEST_TMP/dry-run-output" || fail "report totals"
ok "dry-run maps to Ansible check mode"

set +e
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/failure-args" MACHSTRAP_TEST_FAIL=1 \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --local > "$TEST_TMP/failure-output"
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "Ansible failure exit status was not preserved"
grep -q 'MACHSTRAP REPORT — FAILED' "$TEST_TMP/failure-output" || fail "failed final report"
grep -q 'FAILED (1)' "$TEST_TMP/failure-output" || fail "failed task report section"
ok "failure report and exit status"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/ask-pass-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --host server.example --ask-pass
grep -qx -- '--ask-pass' "$TEST_TMP/ask-pass-args" ||
    fail "SSH password prompt was not forwarded"
ok "SSH password prompting is forwarded"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/ask-sudo-pass-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --host server.example --ask-sudo-pass
grep -qx -- '--ask-become-pass' "$TEST_TMP/ask-sudo-pass-args" ||
    fail "sudo password prompt was not forwarded"
ok "sudo password prompting has an explicit interface"

set +e
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --host server.example --interactive \
    >"$TEST_TMP/noninteractive-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "interactive mode accepted redirected streams"
grep -q 'requires a usable interactive terminal' \
    "$TEST_TMP/noninteractive-output" ||
    fail "interactive mode missing terminal diagnostic"
ok "interactive mode requires a usable terminal"

set +e
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --host server.example --ssh-preflight \
    >"$TEST_TMP/noninteractive-preflight-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "SSH preflight accepted redirected streams"
grep -q 'requires a usable interactive terminal' \
    "$TEST_TMP/noninteractive-preflight-output" ||
    fail "SSH preflight missing terminal diagnostic"
ok "SSH preflight requires a usable terminal"

cat >"$TEST_TMP/plan-ssh-config" <<EOF
Host server.example
    User cc
    Port 2222
    IdentityFile $TEST_TMP/identity-from-config
EOF
touch "$TEST_TMP/identity-from-config"
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --host server.example \
    --ssh-config "$TEST_TMP/plan-ssh-config" --ssh-plan \
    >"$TEST_TMP/ssh-plan-output"
grep -q '^SSH CONNECTION PLAN' "$TEST_TMP/ssh-plan-output" ||
    fail "SSH plan heading"
grep -q '^  User:           cc$' "$TEST_TMP/ssh-plan-output" ||
    fail "SSH plan did not resolve config user"
grep -q '^  Port:           2222$' "$TEST_TMP/ssh-plan-output" ||
    fail "SSH plan did not resolve config port"
grep -Fq "identityfile $TEST_TMP/identity-from-config" "$TEST_TMP/ssh-plan-output" ||
    fail "SSH plan did not resolve config identity"
ok "SSH plan resolves OpenSSH configuration without connecting"

PATH="$TEST_TMP/bin:$PATH" \
/bin/bash "$REPO_ROOT/machstrap" apply full-example --host server.example \
    --ssh-config "$TEST_TMP/plan-ssh-config" --ssh-plan \
    >"$TEST_TMP/system-bash-ssh-plan-output"
grep -q '^SSH CONNECTION PLAN' "$TEST_TMP/system-bash-ssh-plan-output" ||
    fail "system Bash could not resolve an SSH plan with empty inventory arguments"
ok "SSH plan supports the operating system Bash"

cat >"$TEST_TMP/invalid-ssh-config" <<'EOF'
NotARealOpenSSHDirective yes
EOF
set +e
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --host server.example \
    --ssh-config "$TEST_TMP/invalid-ssh-config" --ssh-plan \
    >"$TEST_TMP/invalid-ssh-plan-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "invalid SSH configuration status"
grep -q 'OpenSSH could not resolve connection settings for: server.example' \
    "$TEST_TMP/invalid-ssh-plan-output" ||
    fail "invalid SSH configuration missing endpoint"
grep -q 'OpenSSH: .*Bad configuration option' "$TEST_TMP/invalid-ssh-plan-output" ||
    fail "invalid SSH configuration suppressed OpenSSH diagnostic"
ok "SSH plan preserves safe OpenSSH parser diagnostics"

set +e
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/host-key-args" MACHSTRAP_TEST_HOST_KEY_FAIL=1 \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" apply full-example --host server.example \
    >"$TEST_TMP/host-key-output"
status=$?
set -e
[[ "$status" -eq 4 ]] || fail "host-key failure exit status was not preserved"
grep -q 'UNREACHABLE (1)' "$TEST_TMP/host-key-output" ||
    fail "host-key failure missing unreachable report"
grep -q 'SSH HOST KEY ACTION REQUIRED' "$TEST_TMP/host-key-output" ||
    fail "host-key failure missing targeted guidance"
grep -q 'ssh_askpass message is secondary' "$TEST_TMP/host-key-output" ||
    fail "host-key failure did not explain askpass"
grep -q 'will not disable' "$TEST_TMP/host-key-output" ||
    fail "host-key guidance weakened verification"
ok "host-key failures receive safe remediation guidance"

touch "$TEST_TMP/identity"
chmod 600 "$TEST_TMP/identity"
identity_real="$(cd "$(dirname "$TEST_TMP/identity")" && pwd -P)/identity"
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/ssh-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example \
    --host server.example --user admin --port 2222 --identity "$TEST_TMP/identity"
grep -qx 'server.example,' "$TEST_TMP/ssh-args" || fail "ad-hoc inventory"
grep -qx 'ansible_port=2222' "$TEST_TMP/ssh-args" || fail "ad-hoc SSH port"
grep -qx "$identity_real" "$TEST_TMP/ssh-args" || fail "ad-hoc identity"
ok "typed ad-hoc SSH options"

mkdir -p "$TEST_TMP/ssh config"
touch "$TEST_TMP/ssh config/config"
ssh_config_real="$(cd "$TEST_TMP/ssh config" && pwd -P)/config"
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/inventory-config-args" \
MACHSTRAP_TEST_SSH_ARGS_CAPTURE="$TEST_TMP/inventory-config-env" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example \
    --inventory "$REPO_ROOT/inventories/example/hosts.yml" --limit example-server \
    --ssh-config "$TEST_TMP/ssh config/config"
grep -qx "$REPO_ROOT/inventories/example/hosts.yml" "$TEST_TMP/inventory-config-args" ||
    fail "inventory SSH config lost inventory"
grep -qx "example-server" "$TEST_TMP/inventory-config-args" ||
    fail "inventory SSH config lost limit"
grep -Fqx -- "-F '$ssh_config_real'" "$TEST_TMP/inventory-config-env" ||
    fail "inventory SSH config was not passed to Ansible"
ok "inventory supports a selected SSH config"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/inventory-ssh-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example \
    --inventory "$REPO_ROOT/inventories/example/hosts.yml" --limit example-server \
    --host 203.0.113.99 --user deploy --port 2222 --identity "$TEST_TMP/identity"
grep -qx "$REPO_ROOT/inventories/example/hosts.yml" "$TEST_TMP/inventory-ssh-args" ||
    fail "inventory endpoint override lost inventory"
grep -qx 'example-server' "$TEST_TMP/inventory-ssh-args" || fail "inventory endpoint override lost limit"
grep -qx 'machstrap_transient_endpoint=true' "$TEST_TMP/inventory-ssh-args" ||
    fail "inventory endpoint override did not enable single-host protection"
grep -qx 'ansible_host=203.0.113.99' "$TEST_TMP/inventory-ssh-args" || fail "inventory endpoint host override"
grep -qx 'ansible_user=deploy' "$TEST_TMP/inventory-ssh-args" || fail "inventory endpoint user override"
grep -qx 'ansible_port=2222' "$TEST_TMP/inventory-ssh-args" || fail "inventory endpoint port override"
grep -qx "ansible_ssh_private_key_file=$identity_real" "$TEST_TMP/inventory-ssh-args" ||
    fail "inventory endpoint identity override"
ok "inventory host supports transient SSH endpoint overrides"

set +e
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example \
    --inventory "$REPO_ROOT/inventories/example/hosts.yml" --all --host 203.0.113.99 \
    >"$TEST_TMP/inventory-ssh-all-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "inventory endpoint override accepted --all"
grep -q 'requires one explicit --limit host' "$TEST_TMP/inventory-ssh-all-output" ||
    fail "inventory endpoint override --all diagnostic"
ok "inventory endpoint overrides require one host"

set +e
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check full-example \
    --inventory "$REPO_ROOT/inventories/example/hosts.yml" --limit example-server \
    --host 203.0.113.99 --user 'invalid user' \
    >"$TEST_TMP/inventory-ssh-user-output" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "inventory endpoint override accepted an invalid user"
grep -q 'invalid SSH user' "$TEST_TMP/inventory-ssh-user-output" ||
    fail "inventory endpoint override invalid user diagnostic"
ok "inventory endpoint overrides validate SSH users"

configured_bundle="$TEST_TMP/alpha.machstrap"
XDG_CONFIG_HOME="$config_home" \
    "$REPO_ROOT/machstrap" bundle alpha --out "$configured_bundle"
tar -xOf "$configured_bundle" machstrap/profiles/bundled/profile.yml \
    >"$TEST_TMP/configured-bundle-profile"
cmp "$profile_root/profiles/alpha/profile.yml" "$TEST_TMP/configured-bundle-profile" ||
    fail "bundle did not use configured profile"
ok "configured profile bundle resolution"

bundle="$TEST_TMP/full-example.machstrap"
"$REPO_ROOT/machstrap" bundle full-example --out "$bundle"
tar -tzf "$bundle" >"$TEST_TMP/bundle-list"
grep -q '^machstrap/MANIFEST.sha256$' "$TEST_TMP/bundle-list" ||
    fail "bundle manifest missing"
tar -xOf "$bundle" machstrap/VERSION >"$TEST_TMP/bundle-version"
cmp "$REPO_ROOT/VERSION" "$TEST_TMP/bundle-version" ||
    fail "bundle version does not match source"
if grep -Eq 'inventories|vault' "$TEST_TMP/bundle-list"; then
    fail "bundle contains inventory or Vault material"
fi
ok "bundle excludes inventory and includes manifest"

MACHSTRAP_TEST_CAPTURE="$TEST_TMP/bundle-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check "$bundle" --local
grep -q '/playbooks/validate.yml' "$TEST_TMP/bundle-args" || fail "bundled runtime selection"
ok "bundle verifies and runs"

mkdir "$TEST_TMP/tampered"
tar -xzf "$bundle" -C "$TEST_TMP/tampered"
printf '\n# tampered\n' >> "$TEST_TMP/tampered/machstrap/profiles/bundled/profile.yml"
tar -czf "$TEST_TMP/tampered.machstrap" -C "$TEST_TMP/tampered" machstrap
set +e
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/tampered-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check "$TEST_TMP/tampered.machstrap" --local >"$TEST_TMP/tampered-output" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "tampered bundle was accepted"
grep -q 'hash mismatch' "$TEST_TMP/tampered-output" || fail "tamper diagnostic"
ok "tampered bundle rejected"

mkdir -p "$TEST_TMP/unsafe/machstrap"
touch "$TEST_TMP/unsafe/machstrap/file"
if tar --version 2>&1 | grep -qi bsdtar; then
    tar -czf "$TEST_TMP/unsafe.machstrap" \
        -s ',^machstrap,../escape,' -C "$TEST_TMP/unsafe" machstrap
else
    tar -czf "$TEST_TMP/unsafe.machstrap" \
        --transform='s#^machstrap#../escape#' -C "$TEST_TMP/unsafe" machstrap
fi
set +e
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/unsafe-args" \
PATH="$TEST_TMP/bin:$PATH" \
"$REPO_ROOT/machstrap" check "$TEST_TMP/unsafe.machstrap" --local >"$TEST_TMP/unsafe-output" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "unsafe archive path was accepted"
grep -q 'unsafe bundle member' "$TEST_TMP/unsafe-output" || fail "unsafe archive diagnostic"
ok "archive traversal rejected"

mkdir -p "$TEST_TMP/symlink-profile"
cp "$REPO_ROOT/profiles/linux-server/profile.yml" "$TEST_TMP/symlink-profile/profile.yml"
ln -s /etc/passwd "$TEST_TMP/symlink-profile/passwd"
set +e
"$REPO_ROOT/machstrap" bundle "$TEST_TMP/symlink-profile" \
    --out "$TEST_TMP/symlink.machstrap" >"$TEST_TMP/symlink-output" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "symlink profile was bundled"
grep -q 'symbolic links' "$TEST_TMP/symlink-output" || fail "symlink diagnostic"
ok "symlink profile rejected"

install_source="$TEST_TMP/install source"
install_prefix="$TEST_TMP/prefix with spaces"
mkdir -p "$install_source"
cp "$REPO_ROOT/install.sh" "$REPO_ROOT/machstrap" \
    "$REPO_ROOT/VERSION" "$REPO_ROOT/ansible.cfg" "$install_source/"
cp -R "$REPO_ROOT/config" "$REPO_ROOT/playbooks" "$REPO_ROOT/roles" \
    "$REPO_ROOT/profiles" "$REPO_ROOT/inventories" "$install_source/"
PATH="$TEST_TMP/bin:$PATH" \
    "$install_source/install.sh" --prefix "$install_prefix" \
    >"$TEST_TMP/install-output" 2>&1
install_prefix_real="$(cd "$install_prefix" && pwd -P)"
[[ -L "$install_prefix/bin/machstrap" ]] || fail "PATH launcher was not installed"
[[ -f "$install_prefix/share/machstrap/.machstrap-install" ]] ||
    fail "installation ownership marker missing"
grep -q 'export PATH=' "$TEST_TMP/install-output" || fail "missing PATH guidance"
printf '\n# local installer update marker\n' >>"$install_source/machstrap"
PATH="$TEST_TMP/bin:$PATH" \
    "$install_source/install.sh" --update --prefix "$install_prefix" \
    >"$TEST_TMP/local-update-output" 2>&1
grep -q 'local installer update marker' "$install_prefix/share/machstrap/machstrap" ||
    fail "installer update did not use the current local source"
rm -rf "$install_source"
"$install_prefix/bin/machstrap" --help >"$TEST_TMP/installed-help"
grep -q 'Manage configured and bundled profiles' "$TEST_TMP/installed-help" ||
    fail "installed runtime depends on source checkout"
"$install_prefix/bin/machstrap" --version >"$TEST_TMP/installed-version"
grep -qx "machstrap $expected_version" "$TEST_TMP/installed-version" ||
    fail "installed runtime version does not match source"
XDG_CONFIG_HOME="$config_home" \
    "$install_prefix/bin/machstrap" profiles default \
    >"$TEST_TMP/installed-default-profiles"
grep -q '^  full-example ' "$TEST_TMP/installed-default-profiles" ||
    fail "installed runtime cannot list default profiles"
[[ -f "$install_prefix/share/machstrap/inventories/example/hosts.yml" ]] ||
    fail "installed runtime lacks inventory template"
XDG_CONFIG_HOME="$config_home" \
    "$install_prefix/bin/machstrap" profiles list \
    >"$TEST_TMP/installed-configured-profiles"
grep -q '^  alpha ' "$TEST_TMP/installed-configured-profiles" ||
    fail "installed runtime cannot list configured profiles"
MACHSTRAP_TEST_CAPTURE="$TEST_TMP/installed-args" \
PATH="$install_prefix/bin:$TEST_TMP/bin:$PATH" \
    machstrap check full-example --local
grep -q "$install_prefix_real/share/machstrap/playbooks/validate.yml" \
    "$TEST_TMP/installed-args" || fail "installed runtime was not selected"
ok "self-contained user-prefix installation"

touch "$install_prefix/share/machstrap/rollback-sentinel"
chmod 500 "$install_prefix/bin"
if [[ ! -w "$install_prefix/bin" ]]; then
    set +e
    PATH="$TEST_TMP/bin:$PATH" \
        "$REPO_ROOT/install.sh" --prefix "$install_prefix" \
        >"$TEST_TMP/rollback-output" 2>&1
    rollback_status=$?
    set -e
    chmod 755 "$install_prefix/bin"
    [[ "$rollback_status" -ne 0 ]] || fail "forced upgrade failure succeeded"
    [[ -e "$install_prefix/share/machstrap/rollback-sentinel" ]] ||
        fail "failed upgrade did not restore the previous runtime"
    "$install_prefix/bin/machstrap" --help >/dev/null ||
        fail "failed upgrade left the previous launcher unusable"
else
    chmod 755 "$install_prefix/bin"
fi
ok "failed upgrade preserves previous runtime"

touch "$install_prefix/share/machstrap/stale-file"
PATH="$TEST_TMP/bin:$PATH" \
    "$REPO_ROOT/install.sh" --prefix "$install_prefix" \
    >"$TEST_TMP/upgrade-output" 2>&1
[[ ! -e "$install_prefix/share/machstrap/stale-file" ]] ||
    fail "upgrade retained a stale runtime file"
"$install_prefix/bin/machstrap" --help >/dev/null ||
    fail "upgraded launcher is unusable"
ok "repeat installation upgrades runtime"

foreign_prefix="$TEST_TMP/foreign-prefix"
mkdir -p "$foreign_prefix/bin"
printf '#!/bin/sh\nexit 0\n' >"$foreign_prefix/bin/machstrap"
chmod +x "$foreign_prefix/bin/machstrap"
set +e
PATH="$TEST_TMP/bin:$PATH" \
    "$REPO_ROOT/install.sh" --prefix "$foreign_prefix" \
    >"$TEST_TMP/foreign-output" 2>&1
install_status=$?
set -e
[[ "$install_status" -ne 0 ]] || fail "installer replaced a foreign command"
grep -q 'refusing to replace foreign command' "$TEST_TMP/foreign-output" ||
    fail "foreign command diagnostic"
grep -q '^exit 0$' "$foreign_prefix/bin/machstrap" ||
    fail "foreign command contents changed"
ok "foreign installation collision rejected"

touch "$install_prefix/bin/unrelated-command"
PATH="$install_prefix/bin:$PATH" \
    "$REPO_ROOT/install.sh" --uninstall >"$TEST_TMP/uninstall-output" 2>&1
[[ ! -e "$install_prefix/share/machstrap" ]] ||
    fail "auto-discovered runtime was not removed"
[[ ! -e "$install_prefix/bin/machstrap" ]] ||
    fail "auto-discovered launcher was not removed"
[[ -e "$install_prefix/bin/unrelated-command" ]] ||
    fail "uninstall removed an unrelated prefix file"
ok "safe PATH-discovered uninstall"

explicit_prefix="$TEST_TMP/explicit-prefix"
PATH="$TEST_TMP/bin:$PATH" \
    "$REPO_ROOT/install.sh" --prefix "$explicit_prefix" >/dev/null 2>&1
PATH="$TEST_TMP/bin:$PATH" \
    "$REPO_ROOT/install.sh" --uninstall --prefix "$explicit_prefix" \
    >/dev/null 2>&1
[[ ! -e "$explicit_prefix/share/machstrap" ]] ||
    fail "explicit-prefix uninstall left the runtime"
ok "explicit-prefix uninstall"

update_origin="$TEST_TMP/update-origin.git"
update_seed="$TEST_TMP/update-seed"
update_checkout="$TEST_TMP/update-checkout"
update_prefix="$TEST_TMP/update-prefix"
git init --bare "$update_origin" >/dev/null
git init "$update_seed" >/dev/null
git -C "$update_seed" checkout -b main >/dev/null
git -C "$update_seed" config user.name "Machstrap Tests"
git -C "$update_seed" config user.email "tests@machstrap.invalid"
cp "$REPO_ROOT/install.sh" "$REPO_ROOT/machstrap" \
    "$REPO_ROOT/VERSION" "$REPO_ROOT/ansible.cfg" \
    "$REPO_ROOT/README.md" "$update_seed/"
cp -R "$REPO_ROOT/config" "$REPO_ROOT/playbooks" "$REPO_ROOT/roles" \
    "$REPO_ROOT/profiles" "$REPO_ROOT/inventories" "$update_seed/"
git -C "$update_seed" add .
git -C "$update_seed" commit -m initial >/dev/null
git -C "$update_seed" remote add origin "$update_origin"
git -C "$update_seed" push -u origin main >/dev/null
git clone --quiet --branch main "$update_origin" "$update_checkout"
printf '\n# machstrap update test marker\n' >>"$update_seed/machstrap"
git -C "$update_seed" add machstrap
git -C "$update_seed" commit -m update >/dev/null
git -C "$update_seed" push origin main >/dev/null
PATH="$TEST_TMP/bin:$PATH" \
    "$update_checkout/machstrap" upgrade --prefix "$update_prefix" \
    >"$TEST_TMP/update-output" 2>&1
grep -q 'machstrap update test marker' "$update_checkout/machstrap" ||
    fail "update did not fast-forward the source checkout"
grep -q 'machstrap update test marker' \
    "$update_prefix/share/machstrap/machstrap" ||
    fail "update did not install the fetched runtime"
grep -q 'source updated to' "$TEST_TMP/update-output" ||
    fail "update completion diagnostic"
printf '\nlocal change\n' >>"$update_checkout/README.md"
printf '\n# second machstrap update test marker\n' >>"$update_seed/machstrap"
git -C "$update_seed" add machstrap
git -C "$update_seed" commit -m second-update >/dev/null
git -C "$update_seed" push origin main >/dev/null
PATH="$TEST_TMP/bin:$PATH" \
    "$update_checkout/machstrap" upgrade --prefix "$update_prefix" \
    >"$TEST_TMP/dirty-update-output" 2>&1
grep -q 'second machstrap update test marker' "$update_checkout/machstrap" ||
    fail "update did not fast-forward a dirty checkout"
grep -q 'local change' "$update_checkout/README.md" ||
    fail "update did not preserve a non-conflicting local change"
ok "main fast-forward update preserves non-conflicting local changes"

MACHSTRAP_PREFIX="$TEST_TMP/quickstart-prefix" PATH="$TEST_TMP/bin:$PATH" \
    "$REPO_ROOT/quickstart.sh" >"$TEST_TMP/quickstart-output" 2>&1
grep -q "ready: $REPO_ROOT/machstrap" "$TEST_TMP/quickstart-output" ||
    fail "quickstart did not use its source runtime"
[[ ! -e "$TEST_TMP/quickstart-prefix" ]] ||
    fail "quickstart unexpectedly installed a runtime"
ok "quickstart runs directly from source"

printf '%s tests passed\n' "$pass"
