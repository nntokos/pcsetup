#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
IMAGE_DIR="${MACHSTRAP_E2E_IMAGE_DIR:-${HOME:?}/.cache/machstrap-e2e/images}"
LOCK_FILE="$REPO_ROOT/tests/e2e/images.lock"

command -v curl >/dev/null 2>&1 || {
    printf 'curl is required\n' >&2
    exit 2
}

mkdir -p "$IMAGE_DIR"
chmod 0700 "$IMAGE_DIR"

while IFS=$'\t' read -r os_name image_url expected_sha filename; do
    [[ -z "$os_name" || "$os_name" == \#* ]] && continue
    destination="$IMAGE_DIR/$filename"
    temporary="$IMAGE_DIR/.$filename.download"
    if [[ -f "$destination" ]] &&
        printf '%s  %s\n' "$expected_sha" "$destination" | shasum -a 256 -c - >/dev/null 2>&1; then
        printf 'image ready: %s\n' "$destination"
        continue
    fi
    rm -f -- "$temporary"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "$temporary" "$image_url"
    printf '%s  %s\n' "$expected_sha" "$temporary" |
        shasum -a 256 -c -
    chmod 0600 "$temporary"
    mv "$temporary" "$destination"
    printf 'image downloaded: %s\n' "$destination"
done <"$LOCK_FILE"
