#!/usr/bin/env bash
set -euo pipefail

home_dir=/home/cc
test "$(hostname)" = machstrap-e2e
getent hosts machstrap-e2e >/dev/null
dpkg-query -W -f='${Status}\n' tree | grep -qx 'install ok installed'
snap list hello-world >/dev/null
snap list go >/dev/null
python3 -m pip show cowsay >/dev/null
git -C "$home_dir/src/fixture" rev-parse --verify HEAD >/dev/null
test "$(git config --global --get user.name)" = 'Machstrap E2E'

grep -qx replace-line "$home_dir/.machstrap-replace"
grep -q prepend-line "$home_dir/.machstrap-blocks"
grep -q append-line "$home_dir/.machstrap-blocks"
grep -qx linux-vm-asset=true "$home_dir/.config/machstrap/copied.conf"
grep -qx linux-vm-folder=true "$home_dir/.config/machstrap-folder/value.txt"
grep -qx command "$home_dir/.machstrap-command"
test -f "$home_dir/.machstrap-pre-hook"
test -f "$home_dir/.machstrap-post-hook"
test -s "$home_dir/.ssh/id_ed25519"
test -s "$home_dir/.ssh/id_ed25519.pub"

expected_uid="$(id -u cc)"
while IFS= read -r path; do
    test "$(stat -c %u "$path")" = "$expected_uid"
done < <(find "$home_dir" -mindepth 1 -xdev -print)

sudo grep -q '^Port 2222$' /etc/ssh/sshd_config.d/90-machstrap.conf
sudo grep -q '^PasswordAuthentication no$' /etc/ssh/sshd_config.d/90-machstrap.conf
systemctl is-active --quiet ssh
systemctl is-enabled --quiet ssh

sudo test -s /etc/netplan/60-machstrap-static.yaml
ip -4 address show dev enp2s0 | grep -q '192.168.77.10/24'
sudo ufw status | grep -q 'Status: active'
systemctl is-active --quiet wg-quick@wg0
sudo wg show wg0 >/dev/null
test "$(sudo stat -c %a /etc/wireguard/machstrap-e2e.key)" = 600

test "$(sudo stat -c %a /etc/machstrap-plex.env)" = 600
systemctl is-enabled --quiet docker
systemctl is-active --quiet docker
systemctl is-enabled --quiet machstrap-plex
systemctl is-active --quiet machstrap-plex
sudo docker inspect machstrap-plex >/dev/null

sudo test -s /var/log/machstrap-sudo.log
if sudo find /root -mindepth 1 -xdev \
    \( -name '.vimrc' -o -name '.dotfiles' -o -name 'fixture' \) |
    grep -q .; then
    printf 'managed user state appeared beneath /root\n' >&2
    exit 1
fi
