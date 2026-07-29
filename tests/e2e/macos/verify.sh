#!/usr/bin/env bash
set -euo pipefail

home_dir="${HOME:?}"
test "$(scutil --get ComputerName)" = 'Machstrap E2E Mac'
test "$(scutil --get LocalHostName)" = machstrap-e2e-mac
test "$(scutil --get HostName)" = machstrap-e2e-mac
brew list --formula jq >/dev/null
brew list --formula tree >/dev/null
brew list --cask font-fira-code >/dev/null
python3 -m pip show cowsay >/dev/null
defaults read NSGlobalDomain AppleShowAllExtensions | grep -qx 1

git -C "$home_dir/src/fixture" rev-parse --verify HEAD >/dev/null
test "$(git config --global --get user.name)" = 'Machstrap macOS E2E'
grep -qx replace-line "$home_dir/.machstrap-replace"
grep -q prepend-line "$home_dir/.machstrap-blocks"
grep -q append-line "$home_dir/.machstrap-blocks"
grep -qx macos-vm-asset=true "$home_dir/.config/machstrap/copied.conf"
grep -qx macos-vm-folder=true "$home_dir/.config/machstrap-folder/value.txt"
grep -qx command "$home_dir/.machstrap-command"
test -f "$home_dir/.machstrap-pre-hook"
test -f "$home_dir/.machstrap-post-hook"
test -s "$home_dir/.ssh/id_ed25519"
test -s "$home_dir/.ssh/id_ed25519.pub"

expected_uid="$(id -u)"
while IFS= read -r path; do
    test "$(stat -f %u "$path")" = "$expected_uid"
done < <(find "$home_dir" -mindepth 1 -xdev -print)

sudo test -s /var/log/machstrap-sudo.log
if sudo find /var/root -mindepth 1 -xdev \
    \( -name '.machstrap-replace' -o -name '.dotfiles' -o -name 'fixture' \) |
    grep -q .; then
    printf 'managed user state appeared beneath /var/root\n' >&2
    exit 1
fi
