# Trusted Update Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing upgrade flow honest, deterministic, and release-gated before the default dashboard is built.

**Architecture:** Preserve the Bash modules and make their ownership explicit: Homebrew inventory emits canonical package tokens, evidence collection emits one structured status per package, upgrade planning consumes those statuses, and execution receives only a named, previewed package array. Tests replace `brew`, `curl`, and time through `PATH` fixtures so safety decisions do not depend on the host or network.

**Tech Stack:** Bash 4+, jq, curl, Homebrew CLI, ShellCheck, GitHub Actions, Python 3 standard-library PTY tests.

**Source of scope:** [Phase 1 task graph](../../tasks-003-trusted-update-workflow.md#5-phase-1--trust-foundation) and [approved PRD](../../prd-003-trusted-update-workflow.md).

---

## File and ownership map

| Area | Files | Responsibility |
|---|---|---|
| Test boundaries | `tests/lib/test-utils.sh`, `tests/fixtures/`, focused `tests/test-*.sh` | Fake Homebrew/curl/time, capture invocations, deterministic assertions |
| Inventory | `lib/brew-change-brew.sh`, `lib/brew-change-parallel.sh` | Canonical formula/cask command tokens |
| Evidence/status | `lib/brew-change-display.sh`, `lib/brew-change-parallel.sh`, `lib/brew-change-upgrade.sh` | Emit and consume `attention`, `no-signal`, `unknown` outcomes |
| Prompt/plan | `brew-change`, `lib/brew-change-interactive.sh`, `lib/brew-change-upgrade.sh` | Validate mode, select named packages, preview, confirm |
| Runtime safety | `lib/brew-change-config.sh`, `lib/brew-change-utils.sh` | Signals, cleanup, URL policy, redirects |
| Delivery | `.github/workflows/ci.yml`, `scripts/release.sh`, user/contributor docs | Static checks, tests, release preflight, accurate guidance |

Shared production files are integration-owned. Workers may add isolated tests and fixtures concurrently, but edits to `brew-change-upgrade.sh`, `brew-change-interactive.sh`, `brew-change-config.sh`, and `brew-change-utils.sh` are merged sequentially.

## Task 1: Verify and tag the baseline

**Files:** No production changes.

- [ ] **Step 1: Record the exact baseline**

```bash
git status --short --branch
git rev-parse HEAD
git rev-parse v1.11.5
git tag --list pre-dashboard-v1.11.5
bash --version | head -1
brew --version | head -1
```

Expected: clean worktree; `v1.11.5` points to the latest code release; the pre-dashboard tag does not already exist.

- [ ] **Step 2: Run non-mutating baseline checks**

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
./tests/test-breaking-changes.sh --ci
./tests/test-refactor-fixes.sh
./tests/test-cask-json-parsing.sh
./tests/test-variant-resolution.sh
```

Expected: syntax and the first three suites pass; record the current host-dependent variant failure rather than hiding it.

- [ ] **Step 3: Create the local annotated milestone tag**

```bash
git tag -a pre-dashboard-v1.11.5 -m "Baseline before trusted update workflow implementation"
git show --no-patch --decorate pre-dashboard-v1.11.5
```

Expected: tag points to the committed PRD/task baseline. Do not push it without separate approval.

## Task 2: Build deterministic command boundaries

**Tasks covered:** T1.1.1–T1.1.4, T1.4.4
**Files:** Modify `tests/lib/test-utils.sh`; create `tests/fixtures/homebrew/*.json`, `tests/fixtures/http/*`, `tests/test-command-harness.sh`.

- [ ] **Step 1: Write failing harness tests**

Add tests that call `setup_fake_commands`, run `brew outdated --json=v2`, run a representative `curl`, and assert fixture output plus captured argv. The test must also set a sentinel real command that fails if reached.

```bash
setup_fake_commands
set_fake_brew_response "outdated --json=v2" "$FIXTURE_DIR/homebrew/outdated-mixed.json" 0
output=$(brew outdated --json=v2)
assert_eq "fake brew output" "$(cat "$FIXTURE_DIR/homebrew/outdated-mixed.json")" "$output"
assert_file_contains "$FAKE_COMMAND_LOG" $'brew\toutdated\t--json=v2'
teardown_fake_commands
```

- [ ] **Step 2: Verify the tests fail before helpers exist**

```bash
bash tests/test-command-harness.sh
```

Expected: FAIL because `setup_fake_commands` is undefined.

- [ ] **Step 3: Implement the minimum harness**

Add helpers that create a temporary `bin`, prepend it to `PATH`, write dispatch tables under a temporary fixture-state directory, and restore the original `PATH` in `teardown_fake_commands`. Fake scripts append tab-separated argv to `FAKE_COMMAND_LOG`. Include response body, exit status, stderr, headers, redirect URL, and a fixed `BREW_CHANGE_TEST_NOW` value.

- [ ] **Step 4: Add representative fixtures**

`outdated-mixed.json` must include a formula, a cask with a string token/array display name, and a cask with a null token/name-array fallback. HTTP fixtures must include success, malformed JSON, 404, 429, timeout, fresh cache, stale cache, and allowed/disallowed redirect cases.

- [ ] **Step 5: Verify harness isolation**

```bash
bash tests/test-command-harness.sh
minimal_path=$(mktemp -d)
for utility in dirname mktemp mkdir cat chmod cp rm jq; do
  ln -s "$(command -v "$utility")" "$minimal_path/$utility"
done
PATH="$minimal_path" /bin/bash tests/test-command-harness.sh
rm -rf "$minimal_path"
```

Expected: PASS; no real Homebrew or network request is made.

- [ ] **Step 6: Commit the test boundary**

```bash
git add tests/lib/test-utils.sh tests/fixtures tests/test-command-harness.sh
git commit -m "test: add deterministic command harness"
```

## Task 3: Canonicalize Homebrew package identity

**Tasks covered:** T1.1.2, T1.1.3, T1.2.1
**Files:** Modify `lib/brew-change-brew.sh`, `lib/brew-change-parallel.sh`, `lib/brew-change-upgrade.sh`, `tests/test-variant-resolution.sh`, `tests/test-cask-json-parsing.sh`.

- [ ] **Step 1: Replace host assumptions with failing fixtures**

Make variant tests define fake `brew list --formula` and `brew list --cask` responses. Add production-path assertions proving mixed outdated JSON yields these command tokens:

```text
node
rectangle
claude-code
```

Expected red test: current parallel/upgrade extraction emits an array-form cask name.

- [ ] **Step 2: Introduce one canonical extraction function**

Add an inventory-owned function with this contract:

```bash
extract_outdated_package_tokens() {
    local outdated_json="$1"
    jq -r '
      (.formulae[]? | [.name, "formula"]),
      (.casks[]? |
        [(.token // (if (.name | type) == "array" then .name[0] else .name end)), "cask"])
      | @tsv
    ' <<< "$outdated_json"
}
```

Reject empty/null command tokens after extraction. Parallel and upgrade code consume this function rather than duplicating jq.

- [ ] **Step 3: Run focused tests**

```bash
bash tests/test-variant-resolution.sh
bash tests/test-cask-json-parsing.sh
bash tests/test-command-harness.sh
```

Expected: all pass without requiring particular installed packages.

- [ ] **Step 4: Commit canonical inventory**

```bash
git add lib/brew-change-brew.sh lib/brew-change-parallel.sh lib/brew-change-upgrade.sh tests
git commit -m "fix: canonicalize outdated package tokens"
```

## Task 4: Emit honest evidence outcomes

**Tasks covered:** T1.3.1–T1.3.3
**Files:** Modify status-producing paths in `lib/brew-change-display.sh`, `lib/brew-change-parallel.sh`, `lib/brew-change-upgrade.sh`; create `tests/test-upgrade-assessment.sh`.

- [ ] **Step 1: Write the classification matrix as failing tests**

Use fixture rows with fields `package`, `source`, `retrieval_status`, `retrieved_at`, `reason`, and `risk_signal`. Assert precedence:

```text
risk signal + fresh evidence       -> attention
major transition + failed evidence -> attention, retrieval remains failed
fresh evidence + no signal         -> no-signal
missing timestamp + no signal      -> unknown
stale/malformed/429/failed          -> unknown
```

Also assert that counts sum to inventory count and no output contains “safe package” or “appear safe”.

- [ ] **Step 2: Verify current behavior fails**

```bash
bash tests/test-upgrade-assessment.sh
```

Expected: FAIL because empty and unknown statuses currently enter `SAFE_PKGS`.

- [ ] **Step 3: Replace binary status with three arrays**

Use `ATTENTION_PKGS`, `NO_SIGNAL_PKGS`, and `UNKNOWN_PKGS`. Status producers must write one row per inventory package. A missing row is synthesized as `unknown`, never no-signal. Keep retrieval status distinct from classification.

- [ ] **Step 4: Remove bulk-all semantics**

Bulk upgrade contains only `NO_SIGNAL_PKGS`. Attention and unknown packages remain available for explicit review/selection but are never selected by default.

- [ ] **Step 5: Verify classification and legacy breaking tests**

```bash
bash tests/test-upgrade-assessment.sh
./tests/test-breaking-changes.sh --ci
```

Expected: PASS, with exact three-state counts.

- [ ] **Step 6: Commit honest assessment**

```bash
git add lib/brew-change-display.sh lib/brew-change-parallel.sh lib/brew-change-upgrade.sh tests/test-upgrade-assessment.sh
git commit -m "fix: distinguish unknown upgrade evidence"
```

## Task 5: Enforce preview, plan, and confirmation integrity

**Tasks covered:** T1.4.1–T1.4.5
**Files:** Modify `brew-change`, `lib/brew-change-interactive.sh`, `lib/brew-change-upgrade.sh`; create `tests/test-upgrade-flow.sh`, `tests/test-cli-validation.sh`.

- [ ] **Step 1: Write failing CLI and prompt tests**

Assert help/version bypass dependency and auth initialization; `--dry-run` without `-u` fails before network; invalid prompt input reprompts; EOF/timeout/quit cancel; Enter selects no-signal only; no path returns bulk-all.

- [ ] **Step 2: Write failing execution-capture tests**

For selected `node` and `rectangle`, assert the fake log receives:

```text
brew upgrade --dry-run node rectangle
brew upgrade --yes node rectangle
```

Both calls must receive `HOMEBREW_NO_AUTO_UPDATE=1`; the mutating call also receives `HOMEBREW_NO_INSTALL_CLEANUP=1`. Preview failure, timeout, interruption, and declined confirmation must omit the second call.

- [ ] **Step 3: Move side-effect-free option handling before initialization**

Parse `--help`, `--version`, and invalid combinations before `brew --prefix`, dependency checks, GitHub auth, cache creation, or module side effects. Keep normal execution sourcing behavior unchanged after validation.

- [ ] **Step 4: Normalize prompt actions**

The action vocabulary is `no-signal`, `choose`, and `cancel`. Invalid keys reprompt. EOF, timeout, and `q` return `cancel`. Empty Enter returns `no-signal` only when that set is non-empty; otherwise cancel.

- [ ] **Step 5: Preview and confirm named arrays**

Remove argument-free upgrade execution. Run the named dry-run with auto-update disabled, show its output and dependent-side-effect warning, then call `prompt_upgrade_confirmation` with the same array. Only an affirmative response runs the named mutating command.

- [ ] **Step 6: Run focused tests**

```bash
bash tests/test-cli-validation.sh
bash tests/test-upgrade-flow.sh
bash tests/test-upgrade-assessment.sh
```

Expected: PASS; fake command log proves preview/execution identity.

- [ ] **Step 7: Commit plan integrity**

```bash
git add brew-change lib/brew-change-interactive.sh lib/brew-change-upgrade.sh tests
git commit -m "fix: require previewed upgrade confirmation"
```

## Task 6: Make cleanup and signals terminal-safe

**Tasks covered:** T1.5.1–T1.5.2
**Files:** Modify `lib/brew-change-config.sh`, `lib/brew-change-interactive.sh`; create `tests/test-signal-cleanup.sh`, `tests/test-terminal-restoration.py`.

- [ ] **Step 1: Write failing signal and PTY tests**

Assert `INT=130`, `TERM=143`, temporary files are removed, the spinner child exits, and PTY `stty -g` matches before/after success, quit, EOF, INT, and TERM.

- [ ] **Step 2: Separate EXIT cleanup and signal exits**

Keep cleanup idempotent. Install signal-specific handlers that call cleanup, clear their trap, and exit with the conventional status. The EXIT trap performs cleanup without overriding the existing status.

- [ ] **Step 3: Protect prompt terminal restoration**

Capture `stty -g` before mutation and restore it from a local cleanup trap or an equivalent guaranteed path. Stop and wait for the spinner before returning.

- [ ] **Step 4: Run bounded tests**

```bash
bash tests/test-signal-cleanup.sh
python3 tests/test-terminal-restoration.py
```

Expected: PASS within the test timeout and no remaining child process.

- [ ] **Step 5: Commit runtime cleanup**

```bash
git add lib/brew-change-config.sh lib/brew-change-interactive.sh tests
git commit -m "fix: preserve signal and terminal state"
```

## Task 7: Enforce the evidence URL boundary

**Tasks covered:** T1.6.1–T1.6.2
**Files:** Modify `lib/brew-change-utils.sh` and any direct runtime request sites; create `tests/test-url-policy.sh`.

- [ ] **Step 1: Audit every runtime HTTP call**

```bash
rg -n 'curl|fetch_url_with_retry' brew-change lib
```

Classify each as fixed allowlisted endpoint or policy-bound URL. The test records the expected call-site list so new bypasses require review.

- [ ] **Step 2: Write failing policy tests**

Cover supported HTTPS hosts, unsupported public hosts, localhost, literal private/link-local IPv4/IPv6, file/data schemes, and redirects from an allowed host to a disallowed host. Unsupported sources return unknown plus a review URL.

- [ ] **Step 3: Implement allowlist and manual redirects**

Use one validation function for dynamic destinations. Do not use unrestricted `curl --location`; inspect the next `Location` value, validate it, and follow only a bounded number of allowed hops. Document that portable Bash does not fully prevent DNS rebinding.

- [ ] **Step 4: Run policy and existing URL tests**

```bash
bash tests/test-url-policy.sh
bash tests/test-refactor-fixes.sh
```

Expected: PASS after updating old assertions that intentionally allowed arbitrary HTTPS domains.

- [ ] **Step 5: Commit network policy**

```bash
git add lib tests
git commit -m "fix: restrict release evidence destinations"
```

## Task 8: Add CI, release preflight, and accurate docs

**Tasks covered:** T1.7.1–T1.7.4
**Files:** Create `.github/workflows/ci.yml`, `tests/test-release-preflight.sh`; modify `scripts/release.sh`, `README.md`, `CHANGELOG.md`, `tests/README.md`, `tests/QUICK_START.md`, `CONTRIBUTING.md`.

- [ ] **Step 1: Run ShellCheck and classify baseline findings**

```bash
brew install shellcheck
shellcheck brew-change lib/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh
```

Fix touched-file warnings. Use narrow explained suppressions for intentional dynamic behavior.

- [ ] **Step 2: Add CI**

CI installs Bash 4+, jq, and ShellCheck, runs `bash -n`, then deterministic tests. macOS must invoke Homebrew Bash, not `/bin/bash`. Live network checks are separate and non-blocking if retained.

- [ ] **Step 3: Write release preflight failure tests**

Test dirty tree, invalid SemVer, existing tag, missing tool, failing verification, and HTTP failure. Each must leave commit, tag, and remote state unchanged.

- [ ] **Step 4: Move release validation before mutation**

`scripts/release.sh` performs all preflight checks before editing `brew-change`. Download uses `curl --fail --location`. Do not change push behavior beyond preventing preflight failures; pushing remains a maintainer-invoked action.

- [ ] **Step 5: Repair documentation**

Add v1.6–v1.11 release history, current upgrade behavior, real test commands, and remove obsolete Docker instructions. Do not introduce absolute user-specific paths.

- [ ] **Step 6: Run delivery checks**

```bash
shellcheck brew-change lib/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
./tests/test-breaking-changes.sh --ci
./tests/test-refactor-fixes.sh
./tests/test-cask-json-parsing.sh
./tests/test-variant-resolution.sh
bash tests/test-command-harness.sh
bash tests/test-upgrade-assessment.sh
bash tests/test-cli-validation.sh
bash tests/test-upgrade-flow.sh
bash tests/test-signal-cleanup.sh
python3 tests/test-terminal-restoration.py
bash tests/test-url-policy.sh
```

Expected: all deterministic checks pass.

- [ ] **Step 7: Commit delivery gates**

```bash
git add .github scripts README.md CHANGELOG.md CONTRIBUTING.md tests docs
git commit -m "ci: gate trusted upgrade releases"
```

## Task 9: Phase 1 integration gate

**Task covered:** T1.8.1
**Files:** No new scope; integration fixes only.

- [ ] **Step 1: Review invariants against the diff**

Confirm unknown is never no-signal, attention/unknown are never bulk-selected, all upgrades use named arrays, preview succeeds before confirmation, preview/execution share Homebrew metadata, execution disables cleanup, and no runtime HTTP path bypasses policy.

- [ ] **Step 2: Run the full deterministic command from Task 8**

Expected: all pass with zero skipped safety assertions.

- [ ] **Step 3: Run a real non-mutating smoke test**

```bash
./brew-change --help
./brew-change --version
./brew-change -u --dry-run
```

Expected: help/version are immediate; dry-run names packages, previews through Homebrew, and performs no upgrade.

- [ ] **Step 4: Review final changes**

```bash
git status --short
git log --oneline pre-dashboard-v1.11.5..HEAD
git diff --stat pre-dashboard-v1.11.5..HEAD
```

- [ ] **Step 5: Record Phase 1 exit evidence**

Update the task document states or release notes with exact verification results and any platform checks that could not run. Do not push commits or tags without maintainer approval.
