# machstrap

machstrap is a small Bash wrapper around a conventional Ansible project. It
selects one reviewed profile, validates its local assets, and applies it to the
current machine, an inventory selection, or one SSH host.

It is meant to be used to quickly bootstrap any machine.

There are two suggested ways to use it:
1. Clone the repo and run `./machstrap` for either a remote bootstrapping or a local one
2. Install machstrap on your system (see Install) and use it with `machstrap`

The installation options provides some additional flexibility with a configuration
directory to store all your preferred/custom profiles 

## Install

From a checkout or extracted source archive, install for the current user:

```bash
./install.sh
```

This copies the self-contained runtime to `~/.local/share/machstrap` and makes
`machstrap` available through `~/.local/bin/machstrap`. The checkout can then
be moved or deleted. If `~/.local/bin` is not already on `PATH`, the installer
prints the exact line to add to your shell startup file; it never edits shell
configuration automatically.

Choose another user or system prefix explicitly:

```bash
./install.sh --prefix /opt/machstrap
```

The caller must already have permission to write the prefix. The installer
never invokes `sudo` and never installs operating-system packages. Re-run the
same command to upgrade the owned runtime. It refuses to replace unrelated
files or an installation without Machstrap's ownership marker.

To fetch and install new changes from `main`:

```bash
./install.sh --update
```

Update uses the checkout's configured `origin`, fetches only `main` without
tags, requires the checkout itself to be on a clean `main` branch, and accepts
only a fast-forward. It then re-executes the newly fetched installer and
upgrades the selected prefix. Source archives have no remote metadata, so they
can reinstall their current contents but cannot use `--update`.

Remove the Machstrap selected by the current `PATH`:

```bash
./install.sh --uninstall
```

If it is not on `PATH`, select it explicitly:

```bash
./install.sh --uninstall --prefix /opt/machstrap
```

Uninstall verifies both the ownership marker and PATH launcher before removing
files. Unrelated files under the prefix are preserved.

Machstrap controllers support Linux, macOS, and Unix-like systems on which
Bash and Ansible's controller prerequisites are available. On Windows, run it
inside WSL; Ansible does not support native Windows control nodes. This does
not expand managed-node behavior, which remains the documented Linux and
macOS feature set.

Installation is optional. `quickstart.sh` continues to clone or update its
working checkout, verify prerequisites, and run Machstrap directly from that
directory without creating a PATH installation.

Show the running version:

```bash
machstrap --version
```

## Start safely

Install `ansible-core` with a trusted system package manager. The installer
runs the same non-mutating prerequisite check automatically, and it can be
repeated at any time:

```bash
machstrap doctor
```

Doctor displays successful checks and `Ready.` in green, and missing or
unsupported prerequisites in red when writing to a terminal. Set `NO_COLOR=1`
to disable color output.

Preview a supplied profile on the current machine:

```bash
machstrap check full-example --local
machstrap apply linux-workstation --local --dry-run --diff
```

Apply only after reviewing the check-mode output:

```bash
machstrap apply linux-workstation --local
```

`--local` and `--here` are aliases. Local execution is always explicit; an
omitted target never silently means the controller.

## Dry runs

Add `--dry-run` to any `apply` command to run Ansible in check mode. It gathers
facts and evaluates the selected profile, inventory, Vault values, hooks, and
tasks, but supported modules do not apply their predicted changes:

```bash
machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --dry-run --diff
```

`--check` is retained as an equivalent Ansible-style alias. Some external
commands cannot predict changes perfectly; review the output before a real
apply, especially for SSH, firewall, and static-network configuration.

## Final report

Every `check` and `apply` ends with a compact report, including failed runs and
dry runs. It records the mode, selected profile, resolved target, duration, and
every emitted Ansible task result grouped as changed, failed, unreachable, OK,
included, skipped, rescued, or ignored.

## Inventory and ad-hoc SSH

Copy `inventories/example/` and fill in non-secret connection information.
Inventory runs require an explicit limit unless `--all` is supplied:

```bash
machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --check --diff
```

For a one-off host, the wrapper builds an ephemeral inventory:

```bash
machstrap apply linux-server \
  --host server.example \
  --user admin \
  --port 22 \
  --identity ~/.ssh/id_ed25519 \
  --check --diff
```

OpenSSH configuration is honored normally. `--ssh-config PATH` selects a
non-default OpenSSH configuration file. Host-key checking stays enabled.

Ansible runs on the controller and transfers only the modules, templates,
files, and scripts required by the selected profile. Machstrap is not uploaded
or installed on the managed host.

## Profiles

A profile is a directory:

```text
my-profile/
├── profile.yml
├── assets/
├── hooks/
│   ├── pre.yml
│   └── post.yml
└── scripts/
```

Show the profiles shipped with Machstrap:

```bash
machstrap profiles default
```

You may optionally configure one directory for faster bare-name lookup:

```bash
machstrap config ~/machine-configs
machstrap profiles list
machstrap check my-machine --local
```

The configured directory contains immediate profile directories such as
`~/machine-configs/my-machine/profile.yml`. It is only a convenience hint:
explicit profile paths and shipped defaults continue to work without it. A
missing, stale, malformed, or unsafe config is warned about and ignored.

The canonical path is stored as one line in
`${XDG_CONFIG_HOME:-$HOME/.config}/machstrap/config`. Show or remove it with:

```bash
machstrap config
machstrap config --unset
```

Machstrap creates its config directory as `0700` and the file as `0600`. The
selected profile directory must already exist and must not be group- or
world-writable; Machstrap never creates or changes that directory.

`profiles list` shows only configured profiles. `profiles default` shows only
the presets included with the active Machstrap runtime. A configured profile
with the same name takes precedence for bare-name commands and is marked as an
override in the listing.

Create the fully commented starter:

```bash
machstrap init ~/machine-configs/my-machine
```

Or start from a preset:

```bash
machstrap init ~/machine-configs/server --preset linux-server
```

The supplied presets can always be discovered with
`machstrap profiles default`.

Configuration precedence is fixed:

1. Safe role defaults.
2. `machstrap_profile` from the selected `profile.yml`.
3. Inventory `machstrap_overrides`.
4. Encrypted `machstrap_vault_overrides`.

Mappings merge recursively and lists replace earlier lists.

Assets must be relative to the profile. Missing files, paths that escape the
profile, and symbolic links are rejected before target mutation. Local scripts
run only when an explicit reviewed hook invokes `ansible.builtin.script`;
machstrap does not download executable URLs.

See the comments in
[`profiles/full-example/profile.yml`](profiles/full-example/profile.yml) and
[`inventories/example/`](inventories/example/) for the complete format.

## Vault

Never store secrets in a profile or plaintext inventory. Copy
`inventories/example/group_vars/vault.example.yml`, then create the real file
with Ansible Vault:

```bash
ansible-vault create inventories/my-site/group_vars/vault.yml
machstrap apply my-profile \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --ask-vault-pass
```

Vault password files belong outside the repository with mode `0600`.

## Portable bundles

Build a self-contained profile and runtime archive:

```bash
machstrap bundle ~/machine-configs/my-machine \
  --out ~/my-machine.machstrap
```

Apply it from a controller that has Ansible:

```bash
machstrap apply ~/my-machine.machstrap \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --check --diff
```

Bundles contain the wrapper, playbooks, role, selected profile, hooks, scripts,
and assets. They intentionally exclude inventory, Vault files, password files,
caches, and local state. Archive paths and types are checked before extraction,
then every file is verified against an internal SHA-256 manifest.

The manifest detects corruption, not malicious replacement. Transfer bundles
through a trusted channel or authenticate them separately.

## Versions and releases

Machstrap uses `MAJOR.MINOR.PATCH` versions:

- `MAJOR` for incompatible command or profile behavior.
- `MINOR` for backward-compatible features.
- `PATCH` for backward-compatible fixes.

The canonical version is the single line in [`VERSION`](VERSION). Release tags
use the same version prefixed with `v`, such as `v0.1.0`, and release changes
are recorded in [`CHANGELOG.md`](CHANGELOG.md). A version change is complete
only when `VERSION` and the changelog agree.

Security issues should be reported privately as described in
[`SECURITY.md`](SECURITY.md).

## Development checks

Run the fast, non-mutating suite with:

```bash
./tests/run-tests.sh
```

Enable the repository's tracked pre-commit and pre-push checks once per clone:

```bash
./scripts/install-git-hooks.sh
```

The same suite runs on Linux and macOS for every public push and pull request.
Local hooks provide early feedback but can be bypassed; protected-branch
settings and required GitHub checks enforce the review path for `main`.

## Existing configurations

This release is a clean break. Legacy single-file specs and the `plan`,
`execute`, `remote`, and script-job commands are not accepted. See
[`docs/MIGRATION.md`](docs/MIGRATION.md) for a direct field mapping.

## License

Machstrap is available under the [MIT License](LICENSE).
