# Migration from the Python release

The Ansible-native release intentionally does not execute legacy specs.

| Legacy field or command | New location |
| --- | --- |
| `hostname` | `machstrap_profile.hostname` |
| `packages` | `machstrap_profile.packages` |
| `git_config`, `git_repos` | Same names below `machstrap_profile` |
| `dotfiles` | List entries below `machstrap_profile.dotfiles` |
| `dotfile_sources`, `folder_sources` | Lists with profile-relative sources |
| `dotfiles_repo`, `github_ssh`, `ssh`, `macos`, `commands` | Same names below `machstrap_profile` |
| Static-network job | `machstrap_profile.static_network` |
| Firewall job | `machstrap_profile.firewall` |
| WireGuard job | `machstrap_profile.wireguard` |
| Plex job | `machstrap_profile.plex` |
| Custom Ansible job | `hooks/pre.yml` or `hooks/post.yml` |
| Local script job | Explicit `ansible.builtin.script` task in a hook |
| HTTPS script/playbook job | Removed |
| Includes and layered specs | One profile plus inventory overrides |
| `machstrap remote apply` | `machstrap apply --inventory ...` or `--host ...` |
| `machstrap plan`, `execute` | Removed; use `check` and Ansible check mode |

Mappings that were compiled into lists must now use the normalized list shape
shown by `profiles/full-example/profile.yml`. This keeps playbook input direct
and eliminates a second configuration language.

Portable bundles remain available, but inventory and secrets are deliberately
supplied separately.
