# Testing quick start

## Before a pull request

```bash
# Deterministic CI-equivalent tests
./tests/run-deterministic.sh

# Syntax and blocking static-analysis findings
bash -n brew-change lib/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh
shellcheck --severity=error brew-change lib/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh

# Full ShellCheck for files you changed
shellcheck path/to/changed-script.sh
```

The deterministic runner is safe to use during development: its Homebrew and HTTP behavior is faked, and it performs no real upgrade.

## Debug a focused area

```bash
bash tests/test-upgrade-flow.sh
bash tests/test-signal-cleanup.sh
python3 tests/test-terminal-restoration.py
bash tests/test-url-policy.sh
bash tests/test-release-preflight.sh
```

For optional host/network troubleshooting, run `./tests/test-brew-change-local.sh` and choose a menu item. That menu is not used by CI because it can depend on the local Homebrew installation.

Docker test scripts and images were removed; no Docker setup is required.
