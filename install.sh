#!/bin/sh
#
# Install or remove a self-contained machstrap runtime under one prefix.
# This script intentionally installs no operating-system packages.

set -eu

INSTALL_MARKER=machstrap-install-v1
SOURCE_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
MODE=install
PREFIX=${MACHSTRAP_PREFIX:-"${HOME:?HOME is required}/.local"}
PREFIX_EXPLICIT=false
STAGE=
BACKUP=
LINK_TEMP=
RUNTIME_REPLACED=false
HAD_RUNTIME=false
INSTALL_COMPLETE=false

usage() {
    cat <<'EOF'
Usage:
  ./install.sh [--prefix PATH]
  ./install.sh --update [--prefix PATH]
  ./install.sh --uninstall [--prefix PATH]

The default prefix is $HOME/.local. Re-running the installer upgrades an
installation from the current source. --update first fast-forwards a clean
main checkout from its configured origin.
EOF
}

err() {
    printf 'machstrap install: error: %s\n' "$*" >&2
}

info() {
    printf 'machstrap install: %s\n' "$*" >&2
}

is_owned_runtime() {
    runtime=$1
    [ -d "$runtime" ] &&
        [ ! -L "$runtime" ] &&
        [ -f "$runtime/.machstrap-install" ] &&
        [ ! -L "$runtime/.machstrap-install" ] &&
        [ "$(sed -n '1p' "$runtime/.machstrap-install")" = "$INSTALL_MARKER" ]
}

normalize_prefix() {
    requested=$1
    [ -n "$requested" ] || {
        err "prefix must not be empty"
        return 1
    }
    case "$requested" in
        /*) ;;
        *) requested="$(pwd -P)/$requested" ;;
    esac
    [ "$requested" != / ] || {
        err "refusing to use the filesystem root as a prefix"
        return 1
    }
    requested=${requested%/}
    if [ -d "$requested" ]; then
        requested=$(CDPATH= cd -P "$requested" && pwd)
    fi
    PREFIX=$requested
}

launcher_matches() {
    launcher=$1
    expected=$2
    [ -L "$launcher" ] && [ "$(readlink "$launcher")" = "$expected" ]
}

cleanup_install() {
    status=$?
    trap - EXIT HUP INT TERM

    [ -z "$LINK_TEMP" ] || rm -f "$LINK_TEMP" || true
    [ -z "$STAGE" ] || rm -rf "$STAGE" || true

    if [ "$INSTALL_COMPLETE" != true ] && [ "$RUNTIME_REPLACED" = true ]; then
        if [ "$HAD_RUNTIME" = true ] && [ -d "$BACKUP" ]; then
            rm -rf "$RUNTIME_DIR" || true
            mv "$BACKUP" "$RUNTIME_DIR" || true
        elif [ "$HAD_RUNTIME" = false ]; then
            rm -rf "$RUNTIME_DIR" || true
        fi
    fi
    if [ "$INSTALL_COMPLETE" = true ] && [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
        rm -rf "$BACKUP" || true
    fi
    exit "$status"
}

validate_source() {
    for entry in machstrap VERSION ansible.cfg config playbooks roles profiles; do
        [ -e "$SOURCE_DIR/$entry" ] || {
            err "installation source is incomplete: missing $entry"
            return 1
        }
        if [ -L "$SOURCE_DIR/$entry" ]; then
            err "installation source contains a symbolic link: $entry"
            return 1
        fi
    done
    linked=$(find "$SOURCE_DIR/config" "$SOURCE_DIR/playbooks" \
        "$SOURCE_DIR/roles" "$SOURCE_DIR/profiles" -type l -print -quit)
    [ -z "$linked" ] || {
        err "installation source contains a symbolic link: $linked"
        return 1
    }
}

update_source() {
    command -v git >/dev/null 2>&1 || {
        err "git is required for --update"
        return 1
    }
    git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        err "--update requires a Git checkout; source archives can only reinstall their current version"
        return 1
    }
    repository=$(git -C "$SOURCE_DIR" rev-parse --show-toplevel)
    repository=$(CDPATH= cd -P "$repository" && pwd)
    [ "$repository" = "$SOURCE_DIR" ] || {
        err "install.sh must be run from the root of its Git checkout"
        return 1
    }
    branch=$(git -C "$SOURCE_DIR" symbolic-ref --quiet --short HEAD || true)
    [ "$branch" = main ] || {
        err "--update requires the checkout's main branch (current: ${branch:-detached HEAD})"
        return 1
    }
    [ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=normal)" ] || {
        err "refusing to update a checkout with local changes"
        return 1
    }
    git -C "$SOURCE_DIR" remote get-url origin >/dev/null 2>&1 || {
        err "--update requires a configured origin remote"
        return 1
    }

    info "fetching main from origin"
    git -C "$SOURCE_DIR" fetch --quiet --no-tags origin main
    git -C "$SOURCE_DIR" merge-base --is-ancestor HEAD FETCH_HEAD || {
        err "origin/main cannot fast-forward the current checkout"
        return 1
    }
    git -C "$SOURCE_DIR" merge --quiet --ff-only FETCH_HEAD
    [ -f "$SOURCE_DIR/install.sh" ] && [ -x "$SOURCE_DIR/install.sh" ] &&
        [ ! -L "$SOURCE_DIR/install.sh" ] || {
        err "the updated checkout does not contain a safe install.sh"
        return 1
    }
    info "source updated to $(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
    exec "$SOURCE_DIR/install.sh" --prefix "$PREFIX"
}

install_runtime() {
    validate_source

    mkdir -p "$PREFIX"
    PREFIX=$(CDPATH= cd -P "$PREFIX" && pwd)
    BIN_DIR=$PREFIX/bin
    SHARE_DIR=$PREFIX/share
    RUNTIME_DIR=$SHARE_DIR/machstrap
    LAUNCHER=$BIN_DIR/machstrap

    if [ -e "$RUNTIME_DIR" ] || [ -L "$RUNTIME_DIR" ]; then
        is_owned_runtime "$RUNTIME_DIR" || {
            err "refusing to replace unowned runtime: $RUNTIME_DIR"
            return 1
        }
        HAD_RUNTIME=true
    fi
    if [ -e "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then
        launcher_matches "$LAUNCHER" "$RUNTIME_DIR/machstrap" || {
            err "refusing to replace foreign command: $LAUNCHER"
            return 1
        }
    fi

    mkdir -p "$BIN_DIR" "$SHARE_DIR"
    STAGE=$SHARE_DIR/.machstrap.install.$$
    BACKUP=$SHARE_DIR/.machstrap.backup.$$
    LINK_TEMP=$BIN_DIR/.machstrap.link.$$
    [ ! -e "$STAGE" ] && [ ! -e "$BACKUP" ] && [ ! -e "$LINK_TEMP" ] || {
        err "temporary installation path already exists"
        return 1
    }

    umask 077
    mkdir "$STAGE"
    chmod 755 "$STAGE"
    umask 022
    cp "$SOURCE_DIR/machstrap" "$SOURCE_DIR/VERSION" \
        "$SOURCE_DIR/ansible.cfg" "$STAGE/"
    cp -R "$SOURCE_DIR/config" "$SOURCE_DIR/playbooks" "$SOURCE_DIR/roles" \
        "$SOURCE_DIR/profiles" "$STAGE/"
    chmod 755 "$STAGE/machstrap"
    printf '%s\n' "$INSTALL_MARKER" > "$STAGE/.machstrap-install"

    trap cleanup_install EXIT HUP INT TERM
    if [ "$HAD_RUNTIME" = true ]; then
        mv "$RUNTIME_DIR" "$BACKUP"
    fi
    mv "$STAGE" "$RUNTIME_DIR"
    STAGE=
    RUNTIME_REPLACED=true

    ln -s "$RUNTIME_DIR/machstrap" "$LINK_TEMP"
    mv -f "$LINK_TEMP" "$LAUNCHER"
    LINK_TEMP=
    INSTALL_COMPLETE=true

    info "installed command: $LAUNCHER"
    info "installed runtime: $RUNTIME_DIR"
    case ":${PATH:-}:" in
        *":$BIN_DIR:"*) ;;
        *)
            escaped_bin=$(printf '%s' "$BIN_DIR" | sed "s/'/'\\\\''/g")
            printf '\nAdd machstrap to PATH in your shell startup file:\n' >&2
            printf '  export PATH='\''%s'\'':"$PATH"\n\n' "$escaped_bin" >&2
            ;;
    esac

    if command -v bash >/dev/null 2>&1; then
        if ! "$LAUNCHER" doctor; then
            info "installation completed, but controller prerequisites are missing"
        fi
    else
        info "installation completed, but Bash must be installed before machstrap can run"
    fi
}

discover_prefix() {
    discovered=$(command -v machstrap 2>/dev/null || true)
    [ -n "$discovered" ] || {
        err "machstrap is not on PATH; pass --prefix PATH to select an installation"
        return 1
    }
    case "$discovered" in
        /*) ;;
        *)
            err "PATH resolved machstrap to a non-file command: $discovered"
            return 1
            ;;
    esac
    discovered_bin=$(CDPATH= cd -P "$(dirname "$discovered")" && pwd)
    PREFIX=$(CDPATH= cd -P "$discovered_bin/.." && pwd)
}

uninstall_runtime() {
    if [ "$PREFIX_EXPLICIT" != true ]; then
        discover_prefix
    fi

    BIN_DIR=$PREFIX/bin
    SHARE_DIR=$PREFIX/share
    RUNTIME_DIR=$SHARE_DIR/machstrap
    LAUNCHER=$BIN_DIR/machstrap

    is_owned_runtime "$RUNTIME_DIR" || {
        err "refusing to remove unowned or missing runtime: $RUNTIME_DIR"
        return 1
    }
    if [ -e "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then
        launcher_matches "$LAUNCHER" "$RUNTIME_DIR/machstrap" || {
            err "refusing to remove foreign command: $LAUNCHER"
            return 1
        }
        rm -f "$LAUNCHER"
    elif [ "$PREFIX_EXPLICIT" != true ]; then
        err "the discovered machstrap command disappeared: $LAUNCHER"
        return 1
    fi

    rm -rf "$RUNTIME_DIR"
    rmdir "$BIN_DIR" 2>/dev/null || true
    rmdir "$SHARE_DIR" 2>/dev/null || true
    info "removed machstrap from $PREFIX"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || {
                err "--prefix requires a path"
                exit 2
            }
            PREFIX=$2
            PREFIX_EXPLICIT=true
            shift 2
            ;;
        --uninstall)
            [ "$MODE" = install ] || {
                err "--uninstall conflicts with another operation"
                exit 2
            }
            MODE=uninstall
            shift
            ;;
        --update)
            [ "$MODE" = install ] || {
                err "--update conflicts with another operation"
                exit 2
            }
            MODE=update
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

normalize_prefix "$PREFIX"
case "$MODE" in
    uninstall) uninstall_runtime ;;
    update) update_source ;;
    install) install_runtime ;;
esac
