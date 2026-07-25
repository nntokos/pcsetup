#!/usr/bin/env bash
# Example profile-local post-hook script. It deliberately makes no changes;
# replace it with reviewed, idempotent work or remove the post-hook entirely.
set -euo pipefail

printf 'Machstrap post-hook example ran on %s\n' "$(hostname)"
