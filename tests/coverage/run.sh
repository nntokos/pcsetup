#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MANIFEST="$REPO_ROOT/tests/coverage/manifest.tsv"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/machstrap-coverage.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
    printf 'coverage: %s\n' "$*" >&2
    exit 1
}

[[ -f "$MANIFEST" ]] || fail "missing manifest: $MANIFEST"

awk '
    /^machstrap_defaults:/ { in_defaults = 1; next }
    in_defaults && /^[^[:space:]#]/ { in_defaults = 0 }
    in_defaults && /^  [a-z_][a-z0-9_]*:/ {
        key = $1
        sub(/:$/, "", key)
        print key
    }
' "$REPO_ROOT/config/defaults.yml" | sort -u >"$TEST_TMP/defaults"

awk '
    /^machstrap_profile:/ { in_profile = 1; next }
    in_profile && /^[^[:space:]#]/ { in_profile = 0 }
    in_profile && /^  [a-z_][a-z0-9_]*:/ {
        key = $1
        sub(/:$/, "", key)
        print key
    }
' "$REPO_ROOT/profiles/full-example/profile.yml" | sort -u >"$TEST_TMP/full-example"

awk '
    /machstrap_supported_keys:/ { in_keys = 1; next }
    in_keys && /^      - [a-z_][a-z0-9_]*$/ { print $2; next }
    in_keys && !/^      - / { in_keys = 0 }
' "$REPO_ROOT/roles/machstrap/tasks/validate.yml" | sort -u >"$TEST_TMP/validation"

cut -f1 "$MANIFEST" | sed -n 's/^profile\.//p' | sort -u >"$TEST_TMP/manifest-profile"

cmp "$TEST_TMP/defaults" "$TEST_TMP/full-example" >/dev/null ||
    fail "canonical full example and defaults expose different top-level fields"
cmp "$TEST_TMP/defaults" "$TEST_TMP/validation" >/dev/null ||
    fail "validation and defaults expose different top-level fields"
cmp "$TEST_TMP/defaults" "$TEST_TMP/manifest-profile" >/dev/null ||
    fail "one or more profile fields lack a coverage-manifest entry"

required_roles='hostname packages ssh dotfiles macos git commands network firewall wireguard plex'
for role_name in $required_roles; do
    grep -q "^role\\.$role_name	" "$MANIFEST" ||
        fail "role coverage missing: $role_name"
done

required_cli='check apply ssh privilege vault tags lifecycle'
for cli_name in $required_cli; do
    grep -q "^cli\\.$cli_name	" "$MANIFEST" ||
        fail "CLI coverage missing: $cli_name"
done

while IFS=$'\t' read -r capability variants tiers scenarios; do
    [[ -z "$capability" || "$capability" == \#* ]] && continue
    [[ -n "$variants" && -n "$tiers" && -n "$scenarios" ]] ||
        fail "incomplete coverage row: $capability"
done <"$MANIFEST"

printf 'coverage: all profile fields, role families, and CLI families are mapped\n'
