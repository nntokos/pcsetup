#!/usr/bin/env bash
#
# Clone or update machstrap, verify controller prerequisites, and optionally
# apply a profile. This script never installs Ansible or creates a virtualenv.

set -euo pipefail

REPO_URL="${MACHSTRAP_REPO:-https://github.com/nntokos/machstrap.git}"
INSTALL_DIR="${MACHSTRAP_HOME:-$HOME/.machstrap/tool}"

info() { printf 'machstrap quickstart: %s\n' "$*" >&2; }
err()  { printf 'machstrap quickstart: error: %s\n' "$*" >&2; }

locate_source() {
    local script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    fi
    if [[ -n "$script_dir" && -x "$script_dir/machstrap" ]]; then
        SOURCE_DIR="$script_dir"
    elif [[ -d "$INSTALL_DIR/.git" ]]; then
        info "updating $INSTALL_DIR"
        git -C "$INSTALL_DIR" pull --ff-only
        SOURCE_DIR="$INSTALL_DIR"
    else
        command -v git >/dev/null 2>&1 || { err "git is required"; return 1; }
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone "$REPO_URL" "$INSTALL_DIR"
        SOURCE_DIR="$INSTALL_DIR"
    fi
}

main() {
    locate_source
    "$SOURCE_DIR/machstrap" doctor
    if (( $# == 0 )); then
        info "ready: $SOURCE_DIR/machstrap"
        return
    fi
    "$SOURCE_DIR/machstrap" apply "$@"
}

main "$@"
