# Testing

Run the non-mutating checks:

```bash
sh -n install.sh
bash -n machstrap quickstart.sh
tests/run-tests.sh
./machstrap check full-example --local
```

To run the fast suite automatically before each commit, enable the versioned
hook once per checkout:

```bash
git config core.hooksPath .githooks
```

The same hook configuration runs the fast suite plus both Ubuntu Docker
matrices before each push. Run that gate directly with:

```bash
./tests/run-pre-push-tests.sh
```

The pre-push gate covers every push-triggered CI check. Privileged VM and
external-service suites are local-only because they require dedicated VM
capacity and sandbox credentials.

Run a complete check-mode smoke test:

```bash
./machstrap apply full-example --local --check
```

The fast suite is designed to run on Linux and macOS in CI. Windows WSL uses
the Linux userland path; FreeBSD and WSL should also receive an installation
lifecycle smoke test before a release. A complete platform test installs into
a temporary prefix, removes the source checkout, invokes the installed command
through `PATH`, upgrades it, and uninstalls it without disturbing unrelated
prefix files. The suite also builds a local bare Git remote to verify clean
`main` fast-forward updates without contacting an external service.

Profile discovery tests isolate `XDG_CONFIG_HOME`, verify secure atomic config
writes and optional-failure fallback, and exercise configured/default listings
from both source and installed runtimes.
