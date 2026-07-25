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

Never commit a Vault password file. Encrypted Vault YAML may be committed if
that matches your repository's security policy.

`host_vars/<inventory-host>.yml` may also define standalone, non-secret
variables such as `media_root`. These are available to the selected profile
and its hooks. Keep them outside `machstrap_overrides`, which accepts only
documented Machstrap profile settings.
