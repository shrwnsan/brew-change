# brew-change test suite

The deterministic test gate is fixture-backed: it does not contact live services or run a real Homebrew upgrade.

## Run the CI-equivalent gate

```bash
./tests/run-deterministic.sh
```

The runner covers:

- command isolation and CLI validation
- breaking-change detection
- cask token and installed-variant handling
- attention / no-signal / unknown classification
- preview-confirm-mutate argument integrity
- signal cleanup and terminal restoration
- URL allowlisting, redirects, and credential confinement
- release preflight failure invariants

Run syntax and static analysis exactly as CI does:

```bash
bash -n brew-change lib/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh
shellcheck --severity=error brew-change lib/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh
shellcheck scripts/release.sh tests/run-deterministic.sh tests/test-release-preflight.sh
```

The repository currently baselines pre-existing ShellCheck warning/style findings outside the release gate, while treating all ShellCheck errors as blocking. New or modified scripts should be checked at the default severity and should not add warnings without a narrow, explained suppression.

## Focused suites

Every deterministic suite can run independently. Common examples:

```bash
bash tests/test-cli-validation.sh
bash tests/test-upgrade-assessment.sh
bash tests/test-upgrade-flow.sh
bash tests/test-url-policy.sh
bash tests/test-release-preflight.sh
python3 tests/test-terminal-restoration.py
```

`tests/lib/test-utils.sh` provides fake `brew`/`curl` commands, argument logging, environment capture, and injected time. Add network behavior through these fixtures rather than using a live endpoint.

## Optional live checks

`./tests/test-brew-change-local.sh` remains an interactive troubleshooting menu. It may inspect the host Homebrew installation or network and is therefore not a deterministic CI gate.

Docker test infrastructure was removed in v1.5.4. References to it in older release notes are historical, not runnable instructions.

## CI platforms

GitHub Actions runs the deterministic gate on current Ubuntu and macOS runners. macOS explicitly invokes Homebrew Bash 4+ rather than the system Bash 3.2. Both jobs install jq and ShellCheck.
