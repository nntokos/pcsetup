#!/usr/bin/env bash
set -euo pipefail

key_file=/run/machstrap/controller.pub
password_file=/run/machstrap/password
[[ -s "$key_file" ]] || {
    printf 'missing controller public key: %s\n' "$key_file" >&2
    exit 1
}
[[ -s "$password_file" ]] || {
    printf 'missing disposable password input\n' >&2
    exit 1
}
chpasswd <"$password_file"

for account in \
    machstrap-nosudo machstrap-nopass machstrap-password \
    machstrap-symlink machstrap-stow machstrap-script machstrap-none \
    machstrap-vault machstrap-tags; do
    home_dir="/home/$account"
    install -d -m 0700 -o "$account" -g "$account" "$home_dir/.ssh"
    install -m 0600 -o "$account" -g "$account" \
        "$key_file" "$home_dir/.ssh/authorized_keys"
done

exec /usr/sbin/sshd -D -e
