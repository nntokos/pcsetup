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

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/ansible-playbook" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    if [[ "${MACHSTRAP_TEST_OLD_ANSIBLE:-}" == 1 ]]; then
        echo 'ansible-playbook [core 2.15.0]'
    else
        echo 'ansible-playbook [core 2.16.0]'
    fi
    exit 0
fi
printf '%s\n' "$@" > "${MACHSTRAP_TEST_CAPTURE:?}"
if [[ -n "${MACHSTRAP_TEST_PROFILE_CAPTURE:-}" ]]; then
    printf '%s\n' "${MACHSTRAP_PROFILE_FILE:-}" >"$MACHSTRAP_TEST_PROFILE_CAPTURE"
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
