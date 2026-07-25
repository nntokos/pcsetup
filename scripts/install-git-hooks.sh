#!/bin/sh
set -eu

repository=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
git -C "$repository" rev-parse --is-inside-work-tree >/dev/null
git -C "$repository" config core.hooksPath .githooks

printf '%s\n' "machstrap: Git hooks enabled for $repository"
