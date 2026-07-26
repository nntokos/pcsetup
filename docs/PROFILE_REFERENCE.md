# Profile reference

The canonical reference is the fully commented
[`profiles/full-example/profile.yml`](../profiles/full-example/profile.yml).
Machstrap accepts a profile named either `profile.yml` or `profile.yaml`; the
canonical example retains the former.
Use `machstrap profiles default` to list the profiles shipped with the active
runtime. `machstrap config PATH` may optionally point bare-name resolution at a
directory of user profiles; this controller hint does not change the profile
format or configuration precedence.

It covers:

- Linux APT and Snap packages.
- macOS Homebrew formulae, casks, and defaults.
- Optional user pip packages.
- Git configuration and repositories.
- Inline dotfile blocks, copied files, copied directory trees, and a dotfiles
  repository.
- GitHub client-key generation and Linux SSH server configuration.
- Explicit idempotent commands.
- Guarded Netplan static addressing.
- UFW firewall policies and rules.
- WireGuard server configuration.
- Docker-based Plex service configuration.

Only one profile is selected per run. Inventory values under
`machstrap_overrides` recursively replace profile values; lists replace rather
than append. `machstrap_vault_overrides` is applied last for encrypted secrets.

Profile file and directory sources are relative to the profile directory.
Absolute paths, traversal, missing paths, and symbolic links fail validation.

`hooks/pre.yml` runs after validation and before the role. `hooks/post.yml` runs
after the role. Hooks are ordinary Ansible task lists and are included only
when the exact conventional path exists.
