# Inventories and Vault

Copy `example/` to a private configuration repository and replace the sample
hosts. Keep connection details in inventory, desired machine state in a
profile, and secrets in files created with `ansible-vault`.

Do not define `ansible_become` in inventory, even as `false`. Machstrap opts
individual system tasks into privilege escalation. An inventory connection
variable overrides those task-level decisions and can redirect gathered user
facts, dotfiles, SSH keys, and repositories to the privileged account.
If the target requires a sudo password, pass `--ask-sudo-pass`; passwordless
sudo needs no inventory setting or command-line option.

An inventory run is deliberately explicit:

```bash
./machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --check --diff
```

Machstrap refuses an unlimited inventory run unless `--all` is supplied.
Pass `--ssh-config PATH` to use a non-default OpenSSH configuration file for
the selected inventory hosts.

Keep reusable profiles hostname-neutral and assign a unique machine name in
inventory. Falling back to `inventory_hostname` works well when inventory names
are valid hostnames:

```yaml
machstrap_overrides:
  hostname:
    hostname: "{{ machine_hostname | default(inventory_hostname) }}"
```

On Debian and Ubuntu, Machstrap synchronizes the `127.0.1.1` entry in
`/etc/hosts` before changing the hostname, preventing later `sudo` operations
from stalling on local hostname resolution.

Inventory SSH arguments may also select a config relative to the inventory:

```yaml
ansible_ssh_common_args: "-F {{ inventory_dir }}/../ssh_config"
```

The SSH planner safely resolves Ansible's built-in `inventory_dir` and
`inventory_file` path tokens before calling `ssh -G`. Other Jinja expressions
remain under Ansible's control; automatic handshake planning is skipped for
those values, while explicit `--ssh-plan` and `--ssh-preflight` explain that
they cannot be resolved safely outside Ansible.

## Disposable hosts with changing endpoints

Use the inventory host name as the stable identity for its `host_vars`, group
membership, and Vault values. For a recreated machine, override its current
SSH endpoint on the command line instead of editing the inventory:

```bash
./machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --host 203.0.113.99 \
  --user deploy \
  --port 2222
```

This run still applies `server-01`'s normal inventory configuration, but uses
the supplied `ansible_host`, `ansible_user`, and `ansible_port`. The limit must
resolve to exactly one host; `--all` cannot be used with an endpoint override.
`--identity PATH` is also supported. `--ssh-config PATH` can be used with any
inventory run, with or without a transient endpoint override. Use
`inventory_hostname` when a task needs the stable name and `ansible_host` when
it needs the current address.

Never commit a Vault password file. Encrypted Vault YAML may be committed if
that matches your repository's security policy.

`host_vars/<inventory-host>.yml` may also define standalone, non-secret
variables such as `media_root`. These are available to the selected profile
and its hooks. Keep them outside `machstrap_overrides`, which accepts only
documented Machstrap profile settings.
