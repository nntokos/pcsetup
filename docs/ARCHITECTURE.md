# Architecture

```text
profile path/name + optional profile-directory hint + inventory/Vault
          |
       machstrap                 Bash: paths, target selection, safe archives
          |
   ansible-playbook              Controller-side execution
          |
 profile validation + hooks
          |
      machstrap role             Idempotent desired state
          |
 local machine or SSH targets
```

The wrapper never interprets YAML. Ansible loads `profile.yml` or `profile.yaml`, merges defaults
and inventory overrides, validates the resulting mapping, checks controller
assets, and executes the role.

An installed controller uses a split prefix layout:

```text
PREFIX/bin/machstrap -> PREFIX/share/machstrap/machstrap
PREFIX/share/machstrap/{VERSION,ansible.cfg,config,playbooks,roles,profiles}
```

The same launcher also detects an adjacent runtime when executed from a source
checkout or verified `.machstrap` bundle.

An optional one-line controller config under the XDG config directory points
to a user-selected profile root. It accelerates safe bare-name lookup but is
never required: explicit paths and bundled defaults remain authoritative
fallbacks when the hint is absent or unusable.

## Boundaries

- The installer owns only its marked runtime and PATH link. It does not install
  Ansible, edit shell startup files, or invoke privilege escalation.
- Installer updates require an explicit request, a clean `main` checkout, and
  a fast-forward fetch from that checkout's configured `origin`.
- Bash owns CLI parsing, explicit target selection, dependency diagnostics, and
  portable archive handling. It reads the optional profile path as inert text
  and never evaluates it as shell or YAML.
- Ansible owns facts, variable merging, validation, file transfer, privilege
  escalation, check mode, diff output, and convergence.
- Profiles own desired state and local assets.
- Inventory owns host selection and SSH connection variables.
- Vault owns secrets.
- Hooks provide reviewed local Ansible extensions. A hook may explicitly use
  `ansible.builtin.script`; executable URLs are not supported.

There is no machstrap Python code, generated plan, custom callback, or custom
Ansible module.

## Safety rules

- Local runs require `--local`; inventory runs require `--limit` or `--all`.
- Host-key checking is enabled.
- The wrapper builds commands as Bash arrays and validates typed SSH options.
- System tasks become root individually.
- Profile assets are canonicalized on the controller and confined to the
  profile directory.
- Symlinks are rejected in profiles and bundles.
- Static networking is subnet-guarded and restores invalid Netplan output.
- SSH cannot be enabled with both passwords disabled and no authorized key.
- Bundles exclude inventory and Vault and verify every extracted file.
