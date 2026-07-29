#!/usr/bin/env bash
set -euo pipefail

expected_user=${1:?expected user is required}
expected_home="/home/$expected_user"

assert_file() {
    [[ -f "$1" ]] || {
        printf 'missing expected file: %s\n' "$1" >&2
        exit 1
    }
}

assert_file "$expected_home/.machstrap-replace"
assert_file "$expected_home/.machstrap-blocks"
assert_file "$expected_home/.config/machstrap/copied.conf"
assert_file "$expected_home/.config/machstrap-folder/app.conf"
assert_file "$expected_home/.machstrap-command"
assert_file "$expected_home/.machstrap-pre-hook"
assert_file "$expected_home/.machstrap-post-hook"
assert_file "$expected_home/src/fixture/README.md"

grep -qx 'replace-line' "$expected_home/.machstrap-replace"
grep -q 'first-line' "$expected_home/.machstrap-blocks"
grep -q 'last-line' "$expected_home/.machstrap-blocks"
grep -qx 'copied-from-profile=true' "$expected_home/.config/machstrap/copied.conf"
grep -qx 'folder-source=true' "$expected_home/.config/machstrap-folder/app.conf"
grep -qx 'Machstrap Integration' <(
    HOME="$expected_home" git config --global --get user.name
)

expected_uid="$(id -u "$expected_user")"
while IFS= read -r path; do
    actual_uid="$(stat -c %u "$path")"
    [[ "$actual_uid" == "$expected_uid" ]] || {
        printf 'wrong owner for %s: expected %s, got %s\n' \
            "$path" "$expected_uid" "$actual_uid" >&2
        exit 1
    }
done < <(find "$expected_home" -mindepth 1 -xdev -print)
