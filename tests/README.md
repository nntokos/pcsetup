# Testing machstrap

Machstrap has three test tiers. GitHub CI uses only standard hosted runners for
this public repository. VM and external-service tests are local-only and none
of the test tiers may use production credentials.

## Category entrypoints

Run each category independently from the repository root:

```bash
# Local gate matching the push-triggered fast and Docker CI jobs
./tests/run-pre-push-tests.sh

# Fast unit, wrapper, validation, and security tests
./tests/run-unit-tests.sh

# Both Ubuntu Docker matrices
./tests/run-docker-tests.sh

# All Ubuntu/libvirt and sudo-mode combinations
./tests/run-linux-vm-tests.sh

# Both prepared macOS/Tart images
./tests/run-macos-vm-tests.sh

# Real external-service canary
./tests/run-canary-tests.sh
```

The Docker category optionally accepts one or more versions:

```bash
./tests/run-docker-tests.sh 24.04
./tests/run-docker-tests.sh 22.04 24.04
```

## Before pushing

Run the same fast checks and both Ubuntu Docker matrices used by the
push-triggered CI workflows:

```bash
./tests/run-pre-push-tests.sh
```

Enable the repository's versioned Git hooks once per checkout to run the fast
suite before commits and the complete local gate before pushes:

```bash
git config core.hooksPath .githooks
```

The pre-push gate requires Docker, Ansible, Bash, OpenSSH, and Expect. It runs
the fast suite on the current host OS and exercises Ubuntu 22.04 and 24.04 in
Docker. GitHub still runs the fast suite independently on both Linux and macOS.
Privileged VM and external-service suites are local-only because they require
dedicated disposable VM capacity and sandbox credentials.

Every category writes its complete console output to a mode-`0600` file under
`tests/logs/` and prints the path while running. Logs are ignored by Git.
Lifecycle messages identify the current image, container, VM, network, test
phase, and teardown phase without printing private keys, passwords, Vault
plaintext, tokens, or private environment files.

## Cleanup guarantee

Docker and VM integration scripts install exit, interrupt, and termination
traps before creating disposable resources. On success, failure, or
interruption:

- Docker containers and their uniquely tagged test images are forcibly
  removed and verified absent.
- Linux SUT/probe VMs are destroyed and undefined; run-specific libvirt
  networks, overlays, seed media, and temporary credentials are removed.
- Tart VMs are stopped and deleted, their launcher process is reaped, and
  temporary credentials are removed.
- External-canary SSH keys are removed from the sandbox GitHub account.

A test that otherwise passed is changed to a failure if its exact disposable
container, image, VM, or network remains. The scripts never run broad Docker,
libvirt, or Tart prune commands and do not remove resources belonging to other
runs.

## Fast tests

Run the wrapper, validation, privilege-surface, installation, and coverage
tests:

```bash
./tests/run-unit-tests.sh
```

The underlying fast suite and coverage contract remain available separately:

```bash
./tests/run-tests.sh
./tests/coverage/run.sh
```

`tests/coverage/manifest.tsv` must map every supported profile field, role
family, and CLI family to concrete test tiers and scenarios.

## Docker SSH integration

Docker tests use real SSH connections to isolated ordinary users covering no
sudo, passwordless sudo, password-required sudo, Vault, tags, and each dotfile
repository method. They do not use `--privileged`.

```bash
# Complete Docker category:
./tests/run-docker-tests.sh

# Individual matrix entries:
./tests/docker/run.sh 22.04
./tests/docker/run.sh 24.04
```

The suite verifies dry-run behavior, ownership, dotfiles, assets, hooks, Git,
commands, idempotency, denied elevation, password forwarding, and that
user-scoped runs do not modify `/root`.

## Linux VM integration

The local Linux test host needs QEMU/KVM, libvirt, `virt-install`,
`cloud-localds`, Expect, SSH clients, and permission for the test account to
use `qemu:///system`. Do not grant that account general host sudo.

Download and verify the pinned Ubuntu images:

```bash
./tests/e2e/prepare-images.sh
```

Run one matrix entry:

```bash
./tests/e2e/run-linux.sh --os 24.04 --sudo passwordless
./tests/e2e/run-linux.sh --os 24.04 --sudo password
```

Run the complete Linux matrix:

```bash
./tests/run-linux-vm-tests.sh
```

Each run creates fresh SUT and probe overlays plus two run-specific libvirt
networks. Cleanup targets only resources containing that run's generated
identifier. The test changes sshd, Netplan, UFW, WireGuard, Docker, Snap,
hostname, and systemd only inside the disposable guest.

When Ubuntu publishes a new release image at a pinned URL, update both its URL
and SHA-256 in `tests/e2e/images.lock` in one reviewed change.

## macOS VM integration

The local Apple Silicon test host needs Tart, `sshpass`, Expect, SSH clients,
Ansible, Homebrew, and two prepared disposable images. Each image must:

- expose an SSH test account with a known disposable password;
- permit that account to use sudo with its password;
- have Homebrew installed for that account;
- have Python 3 available;
- contain no production credentials.

Set local environment variables `MACHSTRAP_TART_IMAGE_MACOS_15`,
`MACHSTRAP_TART_IMAGE_MACOS_26`, and `MACHSTRAP_TART_USER`. Supply the
disposable account password in `MACHSTRAP_TART_PASSWORD`.

```bash
# Complete macOS category:
./tests/run-macos-vm-tests.sh

# Individual matrix entries:
./tests/e2e/run-macos.sh --os 15
./tests/e2e/run-macos.sh --os 26
```

## Local-only VM boundary

VM suites are intentionally absent from `.github/workflows`. Run them only on
hosts you control. Their local mode-`0600` logs may include reports, console
output, cloud-init status, journals, and sudo logs, but must never include
private keys, Vault plaintext, claim tokens, or private environment files.

## External-service canary

The local-only canary uses a dedicated GitHub account and repository with no
production access. Set `GH_TOKEN` to its restricted token and
`MACHSTRAP_E2E_GH_REPO` to `owner/repository` only for the command invocation.

The token needs only repository read access and permission to manage the
sandbox account's SSH keys. The canary uploads the VM's temporary public key,
clones the sandbox repository, tests the real Snap Store and Plex registry,
and removes the uploaded key in normal and failure cleanup paths.

Run it separately after securely supplying `GH_TOKEN` and
`MACHSTRAP_E2E_GH_REPO` through the environment:

```bash
./tests/run-canary-tests.sh
```
