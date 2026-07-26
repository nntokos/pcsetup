# Inventories and Vault

Copy `example/` to a private configuration repository and replace the sample
hosts. Keep connection details in inventory, desired machine state in a
profile, and secrets in files created with `ansible-vault`.

An inventory run is deliberately explicit:

```bash
./machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --check --diff
```

Machstrap refuses an unlimited inventory run unless `--all` is supplied.

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
`--identity PATH` and `--ssh-config PATH` are also supported. Use
`inventory_hostname` when a task needs the stable name and `ansible_host` when
it needs the current address.

Never commit a Vault password file. Encrypted Vault YAML may be committed if
that matches your repository's security policy.

`host_vars/<inventory-host>.yml` may also define standalone, non-secret
variables such as `media_root`. These are available to the selected profile
and its hooks. Keep them outside `machstrap_overrides`, which accepts only
documented Machstrap profile settings.
