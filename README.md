# machstrap

machstrap is a small Bash wrapper around a conventional Ansible project. It
selects one reviewed profile, validates its local assets, and applies it to the
current machine, an inventory selection, or one SSH host.

It is meant to be used to quickly bootstrap any machine.

There are two suggested ways to use it:
1. Install machstrap on your system (see Install) and use it with `machstrap`
2. Clone the repo and run `./machstrap`. This can be particularly useful when on a new system and want to bootstrap it locally (see --local/--here)

The installation option provides some additional flexibility with a configuration
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

From a source checkout, fetch and install new changes from `main`:

```bash
./machstrap update
```

`machstrap upgrade` is an alias. The command fetches `origin/main`,
fast-forwards the checkout when Git can do so safely, then runs the local
installer. It is available only from a checkout; installed runtimes are
self-contained and do not retain a Git source to fetch from.

To install the contents of the current local checkout without contacting a
remote, run:

```bash
./install.sh --update
```

`machstrap update` uses the checkout's configured `origin`, fetches only
`main` without tags, and accepts only a fast-forward. Non-conflicting local
changes are preserved; Git refuses an update that would overwrite them.
`install.sh --update` does not contact a remote and works for source archives
as well.

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

Use `machstrap COMMAND --help` to see options for an individual command, such
as `machstrap config --help`.

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
non-default OpenSSH configuration file for either an inventory or ad-hoc host
run. Host-key checking stays enabled:

```bash
machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --ssh-config ~/.ssh/site_config
```

Ansible runs non-interactively, so it cannot answer OpenSSH's first-connection
host-key prompt itself. For a single-host `apply` launched from a real terminal,
Machstrap checks the resolved OpenSSH connection first and forwards the native
fingerprint question when the key is not yet trusted. The automatic handshake
is skipped when stdin, stdout, or stderr is not a usable terminal, so CI and
redirected runs never block waiting for input. Verify every new fingerprint
through a trusted channel before accepting it. If a machine was rebuilt,
replace only that host's stale entry after verifying the replacement.
Machstrap does not disable host-key checking or accept keys automatically.

Inspect the combined inventory and OpenSSH result without connecting:

```bash
machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit server-01 \
  --ssh-config ~/.ssh/site_config \
  --ssh-plan
```

`--ssh-preflight` performs the interactive handshake and exits without running
the playbook. `--ask-pass` forwards Ansible's SSH connection-password prompt.
Machstrap keeps the SSH login user for dotfiles, repositories, SSH keys, and
other user state, and applies `sudo` only to individual system tasks such as
package installation and hostname changes. Do not set `ansible_become` in
inventory: Ansible gives that connection variable higher precedence than task
keywords, which would also redirect user-scoped work to the privileged account.
Use `--ask-sudo-pass` (the clearer alias for Ansible's
`--ask-become-pass`/`-K`) when sudo requires a password. Passwordless sudo needs
no option. A real apply verifies sudo access before making selected system
changes and reports the login-user boundary separately.
`--interactive` (also available as `--forward-all`) requires a usable terminal,
checks the handshake, and enables SSH, become, and Vault password prompts.
Interactive SSH planning and preflight require a selection that resolves to
exactly one inventory host.

## Git repository access preflight

Before hostname, package, or other role changes, `apply` checks every configured
`git_repos` and `dotfiles_repo` URL from the target with `git ls-remote`. Git
credential prompts are disabled during this probe, so an inaccessible private
repository fails early instead of hanging during cloning.

For an SSH URL on `github.com` with `github_ssh.enabled: true`, Machstrap
first displays GitHub's pinned, published Ed25519 fingerprint and requires
confirmation before adding that key to the target's `known_hosts`; it never
trusts a key learned from the current network connection. Machstrap then
generates the configured target client key before the probe. A real single-host
apply from a usable terminal can either upload the public key—after explicit
confirmation—to the GitHub account already authenticated through `gh` on the
controller, or pause while the user registers it manually. Redirected, CI,
dry-run, and multi-host executions remain non-prompting and fail with
fingerprint instructions on first use.

### Where the key upload runs

The upload cannot run on the target: the key being registered is precisely the
key that has no GitHub access yet. Machstrap therefore delegates the upload to
`localhost`—the controller running `machstrap`—where `gh ssh-key add` reaches
`api.github.com` over HTTPS using the GitHub CLI credentials already stored
there. Two separate credentials are involved: the target's SSH key is the
subject of the change, and the controller's `gh` token is the authority making
it.

This means the controller must be prepared for the `upload` choice:

```bash
gh auth login          # on the machine running machstrap, not the target
gh api user --jq .login # confirm the account that will receive the key
```

Machstrap runs that same `gh api user` check before prompting. When the GitHub
CLI is missing or unauthenticated on the controller, `upload` is not offered at
all; the prompt says so, names the controller, and leaves `manual` and `abort`.
When it is authenticated, the prompt names the exact account the key will be
added to, so a controller logged into the wrong GitHub account is visible
before anything changes. Only the public key is copied to the controller, into
a temporary file that is removed in an `always` block; the private key never
leaves the target. Ansible's own output marks the delegation as
`[target -> localhost]`.

Existing SSH keypairs are reused rather than regenerated. If an existing
private key is missing only its public file, Machstrap reconstructs that public
file without replacing the private key; an orphan public key causes a safe
failure. Repository access must succeed on retry before the run continues.
HTTPS repository failures require HTTPS credentials or a deliberate switch to
an SSH URL; adding an SSH key cannot authorize an HTTPS clone.

### Transient endpoint overrides

For disposable machines, keep their durable configuration under a logical
inventory host, then replace only its SSH endpoint for one run. The selected
host still receives its `host_vars`, group variables, and Vault overrides:

```bash
machstrap apply linux-server \
  --inventory inventories/my-site/hosts.yml \
  --limit web-01 \
  --host 203.0.113.99 \
  --user deploy \
  --port 2222 \
  --identity ~/.ssh/disposable_ed25519 \
  --check --diff
```

In this form, `--limit` must resolve to exactly one inventory host and `--all`
is not allowed. `--host`, `--user`, `--port`, and `--identity` temporarily
override `ansible_host`, `ansible_user`, `ansible_port`, and
`ansible_ssh_private_key_file`, respectively. `inventory_hostname` remains
the stable logical name (`web-01` above); tasks and templates that need the
current endpoint should use `ansible_host`. Recreated machines can cause an
SSH host-key mismatch at a reused address—verify the new machine identity
before updating the known-host entry.

Ansible runs on the controller and transfers only the modules, templates,
files, and scripts required by the selected profile. Machstrap is not uploaded
or installed on the managed host.

## Profiles

A profile is a directory:

```text
my-profile/
├── profile.yml              # `profile.yaml` is also accepted
├── assets/
├── hooks/
│   ├── pre.yml
│   └── post.yml
└── scripts/
```

The fully commented starter includes harmless `hooks/pre.yml` and
`hooks/post.yml` examples. They run on every selected target before and after
the Machstrap role, respectively; replace them with reviewed, idempotent tasks
or delete them when they are not needed. Its post-hook invokes the included
`scripts/example-post-hook.sh`, showing how to run a reviewed profile-local
script.

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

Open a profile for editing with the system editor (`$VISUAL`, then `$EDITOR`,
then `vi`):

```bash
machstrap profiles edit my-machine
```

Use the `browse` subcommand to open an entire configured collection in the system
file manager. For example:

```bash
machstrap inventories browse
```

`machstrap profiles browse my-machine` opens that individual profile directory.

The configured directory is organized into separate collections:

```text
~/machine-configs/
├── profiles/my-machine/profile.yml
├── inventories/example/hosts.yml
└── identities/
```

It is only a convenience hint:
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
world-writable. On the first `machstrap config PATH`, Machstrap copies bundled
profiles into `PATH/profiles/`, creates `PATH/inventories/example/`, and creates
the private `PATH/identities/` directory. Existing collection entries are
preserved without modification.

`profiles list` shows only configured profiles. `profiles default` shows only
the presets included with the active Machstrap runtime. A configured profile
with the same name takes precedence for bare-name commands and is marked as an
override in the listing.

Create the fully commented starter:

```bash
machstrap profiles new my-machine
```

When run from a terminal, `profiles new` opens the new profile file in `$VISUAL`,
then `$EDITOR`, or `vi`. Use `--no-edit` for scripts or when you only want to
create the scaffold; non-interactive runs do not start an editor.

Or start from a preset:

```bash
machstrap profiles new server --preset linux-server
```

The supplied presets can always be discovered with
`machstrap profiles default`.

Delete a configured profile and all files in its directory with:

```bash
machstrap profiles delete my-machine
```

This command only deletes an immediate profile directory from the configured
profile root; it cannot delete bundled profiles or arbitrary paths. It asks for
confirmation in a terminal. Use `--force` only in reviewed automation.

Use `--out DIR` with `profiles new` to scaffold outside the configured
directory, for example `machstrap profiles new test --out /tmp/test-profile`.

## Inventories and identities

Configured inventories live in `inventories/`, and identity files live in the
private `identities/` directory. Both collections are managed by name:

```bash
machstrap inventories list
machstrap inventories new production
machstrap inventories delete production
machstrap identities list
machstrap identities delete old-server-key
```

`inventories default` lists the bundled templates, and `inventories edit NAME`
or `identities edit NAME` edits a configured entry in the system editor. Use
`inventories browse` or `identities browse` to open their collection directories.
Inventory creation copies the bundled `example` template by default. Identity
files are never generated or copied automatically; only user-owned, mode `0600`
regular files are listed, opened, or deleted.

Configuration precedence is fixed:

1. Safe role defaults.
2. `machstrap_profile` from the selected `profile.yml` or `profile.yaml`.
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

## Fast tests

Run the fast, non-mutating suite with:

```bash
./tests/run-tests.sh
```

The same suite runs on Linux and macOS for every public push and pull request.

## Existing configurations

This release is a clean break. Legacy single-file specs and the `plan`,
`execute`, `remote`, and script-job commands are not accepted. See
[`docs/MIGRATION.md`](docs/MIGRATION.md) for a direct field mapping.

## License

Machstrap is available under the [MIT License](LICENSE).
