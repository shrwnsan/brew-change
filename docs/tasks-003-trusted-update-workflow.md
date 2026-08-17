# Tasks: Trusted Homebrew Update Workflow

**Parent PRD:** [prd-003-trusted-update-workflow.md](./prd-003-trusted-update-workflow.md)  
**Status:** Planning  
**Created:** 2026-07-28  
**Scope:** Phases 1–3 ready for execution planning; phases 4–5 blocked  

## 1. How to Use This Document

Tasks use `T<phase>.<workstream>.<task>` identifiers. A task is ready only when all dependencies and phase-entry gates are complete.

### 1.1 States

- **Ready:** May be assigned now.
- **Blocked:** Waiting on named dependencies or a decision gate.
- **Integration:** Must be owned by the phase integrator because it crosses shared files or contracts.
- **Review gate:** Read-only decision work; implementation cannot begin until accepted.
- **Done:** Acceptance criteria and verification evidence are recorded.

### 1.2 Complexity

- **S:** Localized change with narrow tests.
- **M:** Multiple functions or one shared contract.
- **L:** Cross-module behavior requiring integration ownership.

Complexity is relative. This document avoids hour estimates because network behavior, Homebrew fixtures, and supported-platform checks make them unreliable.

### 1.3 Subagent assignment rules

1. Assign only tasks marked Ready whose write targets do not overlap another active task.
2. Give each subagent the PRD section, exact task, dependencies, non-goals, and verification command.
3. Junior subagents may implement fixture-backed local behavior but do not own phase gates, release tagging, shared-schema changes, or final integration.
4. Shared-file tasks run sequentially or use isolated worktrees with an integration owner.
5. Every implementation task returns changed files, tests run, results, and unresolved concerns.

## 2. Dependency Overview

```text
Baseline and tag readiness
        |
        v
Phase 1 fixtures ───────┬──── inventory fixes
        |               ├──── classification fixes
        |               ├──── prompt/plan fixes
        |               └──── signal/security fixes
        |                         |
        └──────────────> Phase 1 integration + CI + docs
                                  |
                                  v
                         Assessment record decision
                                  |
                    ┌─────────────┼─────────────┐
                    v             v             v
               assessment     renderer      progress
                    └─────────────┼─────────────┘
                                  v
                         dashboard integration
                                  |
                                  v
                    onboarding/accessibility/provenance
                                  |
                                  v
                         Phase 3 release gate
                                  |
                     adversarial reviews required
                                  |
                         phases 4–5 remain blocked
```

## 3. Global Definition of Done

An implementation task is done only when:

- Acceptance criteria are satisfied.
- Relevant deterministic tests pass.
- `bash -n` passes for changed shell files.
- Static analysis passes when the CI/static-analysis task is available.
- User-facing behavior has documentation where applicable.
- No unrelated changes are included.
- Existing failures are distinguished from regressions.
- Terminal/network tests do not leave background jobs or modified terminal state.

## 4. Pre-Implementation Baseline

### T0.1.1 — Record baseline state

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** S  
**Owner:** Integrator  
**Write target:** Implementation log or PR description; no production files required

Steps:

1. Record `git status --short --branch`.
2. Record `git rev-parse HEAD` and current version/tag.
3. Record Homebrew, Bash, macOS/Linux, and dependency versions used for verification.
4. Confirm whether `v1.11.5` points at the baseline commit.

Acceptance:

- Exact baseline commit and environment are recorded.
- Unexpected worktree changes are identified but not modified.

Verification:

```bash
git status --short --branch
git rev-parse HEAD
git describe --tags --exact-match HEAD
bash --version | head -1
brew --version | head -1
```

### T0.1.2 — Run and classify baseline verification

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Owner:** Integrator

Steps:

1. Run syntax checks for production and test scripts.
2. Run all deterministic test files individually.
3. Run the repository's CI-mode aggregate test only after confirming it cannot perform upgrades.
4. Record pass, fail, skipped, host-dependent, and network-dependent results separately.
5. Record missing development tools such as ShellCheck.

Acceptance:

- Pre-existing failures are explicitly named.
- Host-dependent tests are not presented as product regressions.
- No upgrade or destructive Homebrew command runs.

### T0.1.3 — Prepare verified pre-upgrade tag

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** S  
**Owner:** Maintainer/integrator  
**Suggested tag:** `pre-dashboard-v1.11.5`

Steps:

1. Confirm whether `v1.11.5` already identifies the verified code baseline.
2. If a distinct post-planning milestone is still desired, verify the proposed tag does not exist locally or remotely.
3. Present the exact commit, verification summary, and proposed tag to the maintainer.
4. Create an annotated local tag only after confirmation.
5. Do not push the tag without separate explicit approval.

Acceptance:

- Tag points to the verified baseline commit.
- Annotation explains its purpose and known baseline failures.
- Remote state remains unchanged unless separately approved.

## 5. Phase 1 — Trust Foundation

### Phase 1 entry gate

- T0.1.1 and T0.1.2 complete.
- T0.1.3 is either complete or explicitly deferred by the maintainer.
- Integrator assigns non-overlapping workstreams.

### Workstream 1.1 — Deterministic Homebrew fixtures

#### T1.1.1 — Add a mock Homebrew command harness

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Junior-safe:** Yes  
**Likely writes:** `tests/lib/test-utils.sh`, test fixture location chosen by implementer

Purpose: Let tests control `brew info`, `brew outdated`, and `brew list` without relying on the host installation.

Steps:

1. Create a temporary `brew` executable earlier in `PATH`.
2. Dispatch responses by command and arguments.
3. Store representative JSON and line fixtures in a test-owned location.
4. Ensure teardown restores `PATH` and removes temporary files.
5. Add a self-test proving the real Homebrew executable was not called.

Acceptance:

- Tests can define formulae, casks, variants, and errors deterministically.
- Harness supports exit status and stderr fixtures.
- Teardown runs on success, failure, and interruption.

Verification:

- Focused harness tests pass without Homebrew installed in the test `PATH`.

#### T1.1.2 — Convert installed-variant tests to fixtures

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** S  
**Junior-safe:** Yes  
**Writes:** `tests/test-variant-resolution.sh`

Acceptance:

- No assertion depends on `claude-code`, `node`, `git`, or any host package.
- Exact match, `@latest`, another `@version`, and missing package cases pass.
- Existing host-dependent failure is eliminated without weakening assertions.

#### T1.1.3 — Add production-path cask fixtures

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Junior-safe:** Yes  
**Writes:** New or existing cask/parallel tests; avoid production writes

Fixtures must cover:

- Cask with string token and array display name
- Cask with null token and usable name fallback
- Formula name
- Mixed formula/cask outdated output
- Empty arrays

Acceptance:

- Tests invoke production extraction functions or command paths rather than standalone `jq` snippets.
- Expected canonical package argument is asserted exactly.

#### T1.1.4 — Add deterministic HTTP and time harness

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Junior-safe:** Yes  
**Writes:** Test harness and network/cache fixtures

Purpose: Exercise retrieval outcomes without live network, clock, DNS, or rate-limit variability.

Steps:

1. Route test retrieval through a fake `curl` executable or the project's single fetch boundary.
2. Support response body, headers, status, stderr, redirect, timeout, and attempt-count fixtures.
3. Provide a controllable current timestamp and cache modification time.
4. Assert that tests never contact a real network endpoint.

Acceptance:

- Fresh cache, stale cache, malformed body, 404, 429, timeout, redirect, and success outcomes are deterministic.
- Harness teardown restores `PATH` and temporary state.

### Workstream 1.2 — Canonical inventory

#### T1.2.1 — Define canonical outdated-package extraction

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Owner:** Integrator or experienced contributor  
**Likely writes:** `lib/brew-change-brew.sh`, consumers in parallel/upgrade modules

Purpose: Establish one source of truth for formula and cask package tokens.

Steps:

1. Define the canonical extraction contract from Homebrew JSON v2.
2. Prefer package token fields intended for command invocation.
3. Use a documented fallback only when fixtures prove Homebrew can return null.
4. Update parallel and upgrade consumers to use the shared behavior.
5. Avoid a wrapper if changing the existing source-of-truth function is sufficient.

Acceptance:

- `-a`, `-b`, and `-u` pass valid canonical names for representative casks.
- No array-form display name is passed as a package argument.
- Formula behavior is unchanged.

Verification:

- T1.1.3 fixtures and existing cask tests pass.

### Workstream 1.3 — Honest assessment and upgrade selection

#### T1.3.1 — Specify current-flow assessment statuses

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** S  
**Owner:** Integrator  
**Write target:** Test names and implementation notes; may update upgrade tests

Decision contract:

- `attention`: trustworthy inventory version heuristic or adequate evidence with a matched risk signal
- `no-signal`: adequate evidence within freshness policy with no matched signal
- `unknown`: no attention signal and missing, stale, failed, malformed, contradictory, rate-limited, or unsupported evidence

Minimal Phase 1 evidence outcome:

- Upstream source type
- Retrieval status
- Retrieval timestamp required for `no-signal`; a missing or unverifiable timestamp makes otherwise non-attention evidence unknown
- Assessment reason
- Exactly one classification

Acceptance:

- Every current upgrade status path maps to exactly one state.
- No empty/missing status maps to `no-signal`.
- Classification precedence matches PRD section 7.2.
- A major-version heuristic plus unavailable release notes maps to attention while preserving the unavailable retrieval status.

#### T1.3.2 — Separate unknown from no-signal in summaries

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Junior-safe:** Yes with fixtures  
**Writes:** Status-producing evidence/display paths, `lib/brew-change-upgrade.sh`, focused tests

Acceptance:

- Summary reports attention, no-signal, and unknown counts separately.
- User-facing text contains no “safe package” claim.
- Count totals equal the number of assessed packages.
- Empty, stale, malformed, rate-limited, unsupported, and failed evidence fixtures render unknown when no independent attention signal exists.

#### T1.3.3 — Make default selection classification-driven

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Writes:** `lib/brew-change-upgrade.sh`, focused tests

Acceptance:

- Bulk no-signal action contains only `no-signal` packages.
- Attention and unknown are unselected by default.
- User can still explicitly inspect all packages.
- Displayed selection count equals actual execution input count.

### Workstream 1.4 — Prompt and execution integrity

#### T1.4.1 — Normalize prompt action return values

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** S  
**Junior-safe:** Yes  
**Writes:** `lib/brew-change-interactive.sh`, prompt tests

Acceptance:

- Every prompt branch returns one documented action value.
- Enter returns the bulk `no-signal` action only after three-state classification is available.
- Invalid input reprompts; EOF, timeout, and quit cancel without execution.
- Caller and prompt use the same action vocabulary.
- Quit and EOF are distinguishable where behavior differs.
- There is no bulk action that includes attention or unknown packages.

#### T1.4.2 — Validate CLI flag combinations before work begins

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** S  
**Junior-safe:** Yes  
**Writes:** `brew-change`, argument tests

Cases to define:

- `--dry-run` without upgrade mode
- Upgrade mode with explicit packages
- Conflicting list/detail modes
- Repeated compatible flags

Acceptance:

- Invalid combinations fail before network calls.
- Error includes a valid corrected example.
- Help documents supported combinations.
- `--help`, `--version`, and argument errors are handled before Homebrew probing, dependency verification, GitHub authentication, cache initialization, or other side effects.

#### T1.4.3 — Integrate exact-plan final confirmation

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Owner:** Integrator  
**Writes:** `lib/brew-change-upgrade.sh`, `lib/brew-change-interactive.sh`, execution tests

Acceptance:

- Exact selected package names and the Homebrew dry-run preview are displayed immediately before confirmation.
- Confirmation states that Homebrew may upgrade required dependencies or outdated dependents.
- Decline, EOF, timeout, quit, preview failure, and interrupt execute no mutating upgrade command.
- Approval executes exactly the displayed package array.
- Preview-only mode never invokes a mutating `brew upgrade`.
- Actual execution disables automatic cleanup for the invocation without disabling Homebrew's dependency checks.

#### T1.4.4 — Add fake execution capture

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Junior-safe:** Yes  
**Writes:** Test harness and upgrade tests

Purpose: Capture arguments passed to mocked `brew upgrade` and prove plan integrity.

Acceptance:

- Test fails if execution adds, drops, splits, or reorders package names unexpectedly.
- Names containing valid punctuation remain one argument.
- No real upgrade command can run in the test.

#### T1.4.5 — Add Homebrew-resolved upgrade preview

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Owner:** Integrator  
**Writes:** `lib/brew-change-upgrade.sh`, mocked execution tests

Purpose: Distinguish the exact requested package plan from Homebrew's possible dependency, dependent, and cleanup side effects.

Acceptance:

- Preview invokes named `brew upgrade --dry-run` arguments only.
- Preview and actual execution set `HOMEBREW_NO_AUTO_UPDATE=1` so both use the same Homebrew metadata snapshot.
- Preview output is shown before confirmation and is clearly labeled as Homebrew's resolution.
- Actual invocation sets `HOMEBREW_NO_INSTALL_CLEANUP=1` for this command.
- UI discloses that Homebrew may upgrade required dependencies or outdated dependents.
- A successful preview is mandatory; failure, timeout, or interruption cancels before confirmation.
- No argument-free `brew upgrade` path exists.

### Workstream 1.5 — Signals and terminal safety

#### T1.5.1 — Separate EXIT cleanup from signal termination

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Writes:** `lib/brew-change-config.sh`, signal tests

Acceptance:

- `EXIT` performs cleanup without changing the program's status.
- `INT` and `TERM` terminate with conventional nonzero statuses.
- Handlers do not recurse.
- Registered background processes and temporary files are cleaned.

#### T1.5.2 — Prove prompt terminal restoration

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Writes:** `lib/brew-change-interactive.sh` if needed, pseudo-terminal test

Use Python 3's standard-library pseudo-terminal support as a test-only dependency unless a smaller portable mechanism is proven. CI must invoke Homebrew Bash 4+ on macOS rather than `/bin/bash` 3.2.

Acceptance:

- Echo/canonical mode and cursor state are restored after success, quit, EOF, `INT`, and `TERM`.
- Test has a bounded timeout and cannot hang CI.

### Workstream 1.6 — Network boundary hardening

#### T1.6.1 — Specify generic URL destination policy

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Owner:** Security review/integrator  
**Write target:** Tests first, then implementation notes

Policy must address:

- Explicitly supported HTTPS hosts
- Unsupported arbitrary vendor hosts returning unknown with a reviewable URL
- Literal loopback/localhost and IPv4/IPv6 private or link-local destinations
- Manual redirect-hop revalidation before following
- Portable Bash and DNS-rebinding limitations
- Narrow, documented exceptions for supported vendors

Acceptance:

- Policy is enforceable with available shell/runtime tools.
- It does not promise complete SSRF prevention that the implementation cannot provide.
- The supported-host list is documented and fixture-tested.

#### T1.6.2 — Enforce destination policy with fixtures

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Writes:** `lib/brew-change-utils.sh`, network validation tests

Acceptance:

- Unsupported hosts, literal loopback/private/link-local targets, file/data schemes, and redirect hops to disallowed hosts are rejected before the corresponding request.
- Required supported public sources remain accepted.
- Failure returns unknown evidence, not no-signal.
- Tests document that DNS rebinding cannot be fully prevented by this portable Bash policy.
- An audit identifies every runtime HTTP request and proves it uses this policy boundary or a fixed, documented allowlisted endpoint.

### Workstream 1.7 — CI and release hygiene

#### T1.7.1 — Add static-analysis configuration

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** S  
**Junior-safe:** Yes  
**Writes:** static-analysis config/exclusions only if necessary

Acceptance:

- ShellCheck runs on production scripts and meaningful test scripts.
- Suppressions are narrow, inline where appropriate, and explained.
- Existing warnings are fixed or explicitly baselined; the command does not silently ignore all findings.

#### T1.7.2 — Add deterministic CI workflow

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Writes:** `.github/workflows/` workflow

Required jobs:

- Bash syntax
- ShellCheck
- Deterministic fixture-backed tests
- Supported platform matrix justified by runtime and cost

Acceptance:

- CI performs no real upgrade.
- Network smoke tests, if retained, are isolated from deterministic gates.
- Workflow commands match contributor documentation.

#### T1.7.3 — Add release-script preflight

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Writes:** `scripts/release.sh`, release-script tests or dry-run harness

Preflight must occur before mutation or publication and check:

- Clean worktree
- Expected branch/upstream
- Valid SemVer
- Tag availability
- Required tools
- Required verification command
- Failing HTTP downloads via `curl --fail --location`

Acceptance:

- A failed preflight creates no commit, tag, push, or release.
- Partial-publication risks and recovery steps are documented.

#### T1.7.4 — Repair release and contributor documentation

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** M  
**Junior-safe:** Yes  
**Writes:** `README.md`, `CHANGELOG.md`, `tests/README.md`, `tests/QUICK_START.md`, `CONTRIBUTING.md`, relevant roadmap references

Acceptance:

- v1.11.5 features have an accurate release history.
- README recent changes no longer stop at v1.5.8.
- Removed Docker commands are removed or explicitly historical.
- Test commands exist and match CI.
- No absolute user-specific paths are introduced.

### T1.8.1 — Phase 1 integration and regression review

**State:** Complete — shipped in v1.12.0; prompt fixes in v1.12.1
**Complexity:** L  
**Owner:** Integrator

Steps:

1. Reconcile shared-file changes sequentially.
2. Run all deterministic tests and static checks.
3. Review upgrade invariants from PRD section 10.3.
4. Perform a read-only/manual dry-run against representative installed packages.
5. Confirm documentation matches actual behavior.
6. Produce release notes and known limitations.

Exit evidence:

- Unknown is never presented as safe.
- Default selection excludes attention and unknown.
- Displayed and requested package plans match in tests; Homebrew-resolved side effects are previewed.
- Cask identities are canonical in production paths.
- Signal and terminal tests pass.
- CI is green.


### T1.8.1 Exit evidence (recorded 2026-08-18)

- Baseline: `v1.11.5` (last pre-Phase-1 release); local annotated marker `pre-dashboard-v1.11.5` retained unpushed.
- Deterministic verification at release: 14 suites, 0 failed (`tests/run-deterministic.sh`), including the prompt-behavior PTY suite added in v1.12.1; ShellCheck clean; CI green on ubuntu-latest and macos-latest for tags v1.12.0 and v1.12.1.
- Releases: v1.12.0 (2026-08-17, Phase 1 trusted update workflow, PR #77–#79) and v1.12.1 (2026-08-17, prompt fixes: stale-Enter confirmation auto-decline and inactivity-timeout countdown, PR #80–#81).
- Distribution: `shrwnsan/homebrew-tap` formula at 1.12.1 (tap PRs #18, #19), validated end-to-end via `brew upgrade` (Homebrew-verified sha256), `brew test`, and `brew audit` (clean).
- Post-release field verification: two user-observed v1.12.0 prompt defects were root-caused (single-char read leaving Enter in the tty buffer; silent 300s prompt timeout) and fixed in v1.12.1 with PTY regression tests (`tests/test-prompt-behavior.py`, stable on macOS and Linux bash).
- Deviations: `BREW_CHANGE_PROMPT_TIMEOUT` env override added for testability (undocumented knob, default 300s). Phase 1 task states in this document were recorded complete retrospectively.

## 6. Phase 2 — Default Inline Dashboard

### Phase 2 entry gate

- Phase 1 exit evidence accepted.
- Phase 1 released or explicitly approved for stacking.
- Default-behavior compatibility strategy approved.

T2.6.1 is a pre-entry decision task: it becomes Ready after Phase 1 acceptance and must complete before other Phase 2 implementation begins.

### Workstream 2.1 — Assessment record decision

#### T2.1.1 — Spike structured record representation

**State:** Complete — JSONL contract approved (#84)
**Complexity:** M  
**Owner:** Experienced contributor  
**Writes:** Prefer test/spike artifacts; do not commit throwaway production abstraction

Compare two or three minimal options, such as:

- JSON Lines between stages
- Delimited records with strict escaping
- Per-package files containing normalized JSON

Evaluate:

- Correct handling of multiline release notes and punctuation
- `jq` dependency already present
- Parallel worker compatibility
- Test readability
- Performance at representative package counts

Acceptance:

- Recommendation includes evidence and rejected alternatives.
- No new runtime dependency is introduced.
- Integrator approves the record contract before downstream implementation.

#### T2.1.2 — Implement normalized assessment record

**State:** Complete — record pipeline + brew-info caching merged (#89)
**Complexity:** L  
**Owner:** Integrator  
**Likely writes:** inventory, evidence, assessment, and parallel modules

Acceptance:

- Record contains every PRD section 7.1 field or an explicit defined sentinel.
- Presentation and planning consume the record rather than re-deriving classification.
- Fixture round-trip preserves package names, reasons, URLs, status, and multiline evidence snapshot/reference.
- Detailed review consumes the same evidence snapshot used for assessment rather than refetching.

### Workstream 2.2 — Classification engine

#### T2.2.1 — Isolate evidence-to-assessment behavior

**State:** Complete — classification engine merged (#86)
**Complexity:** M  
**Junior-safe:** Yes after contract approval  
**Writes:** assessment/breaking module and tests

Acceptance:

- Pure fixture input produces deterministic classification and reasons.
- Missing, stale, malformed, unsupported, and rate-limited evidence become unknown.
- Matched indicators are captured without embedding terminal formatting.

#### T2.2.2 — Define version-transition reasons

**State:** Complete — merged with T2.2.1 (#86)
**Complexity:** S  
**Owner:** Product/integrator review

Acceptance:

- Formula revisions such as `_1` are not mistaken for major releases.
- Calendar versions and non-SemVer versions do not receive false semantic claims.
- Major-version changes, where confidently parsed, are labeled as heuristic reasons.

### Workstream 2.3 — Compact dashboard renderer

#### T2.3.1 — Approve static output fixtures

**State:** Complete — golden fixtures merged (#90)
**Complexity:** M  
**Owner:** Product/integrator review  
**Writes:** Golden fixtures or test expectations

Fixtures:

- Mixed classifications
- All no-signal
- All unknown
- No outdated packages
- Long names and versions
- Narrow terminal
- No color/no emoji
- Noninteractive output

Acceptance:

- Labels are understandable without color.
- Unknown and no-signal cannot be confused.
- Output remains scannable without dumping full release notes.

#### T2.3.2 — Implement grouped static renderer

**State:** Complete — byte-exact renderer merged (#91)
**Complexity:** M  
**Junior-safe:** Yes with approved fixtures  
**Writes:** `lib/brew-change-display.sh`, renderer tests

Acceptance:

- Group order is attention, no-signal, unknown.
- Count and row totals agree.
- Long content degrades without corrupting columns.
- Minimum `NO_COLOR`, no-emoji, and narrow-terminal behavior passes approved fixtures.
- Renderer has no selection or execution side effects.

### Workstream 2.4 — Central progress renderer

#### T2.4.1 — Specify progress event contract

**State:** Complete — contract approved (#85)
**Complexity:** S  
**Owner:** Integrator

Events must represent stage, completed count, total count, and optional source/package label without allowing workers to draw terminal frames.

#### T2.4.2 — Implement TTY progress renderer

**State:** Complete — merged (#87), Linux portability fix (#88)
**Complexity:** L  
**Writes:** interactive/presentation module and pseudo-terminal tests

Acceptance:

- Spinner and count update while blocking work proceeds.
- Redraw rate is bounded.
- Final frame is cleared before dashboard output.
- Cursor and terminal modes restore on all tested exits.
- No animation occurs when stdout is not a TTY or test mode disables it.

#### T2.4.3 — Integrate worker progress events

**State:** Complete — merged (#92)
**Complexity:** M  
**Writes:** `lib/brew-change-parallel.sh` and progress integration tests

Acceptance:

- Parallel workers never interleave spinner output.
- Completed count is monotonic and ends at total.
- Package failure still advances completion and yields unknown.

### Workstream 2.5 — Inline actions and planning

#### T2.5.1 — Approve action-state machine

**State:** Blocked by T2.3.1  
**Complexity:** M  
**Owner:** Product/integrator review

Define behavior for review, select, upgrade no-signal, back, quit, EOF, invalid input, and noninteractive invocation.

Acceptance:

- Every state and input has one outcome.
- No path bypasses exact-plan confirmation.
- Attention and unknown require explicit per-package selection if selection is supported.

#### T2.5.2 — Implement review and selection actions

**State:** Blocked by T2.1.2, T2.3.2, and T2.5.1  
**Complexity:** L  
**Writes:** interactive, display, and planning modules with tests

Acceptance:

- Review displays source, reason, and detailed notes when available.
- Selection preserves canonical package tokens.
- Back and quit do not mutate the plan unexpectedly.
- Exact-plan confirmation from phase 1 remains the sole execution boundary.

#### T2.5.3 — Define deterministic noninteractive dashboard behavior

**State:** Blocked by T2.1.2 and T2.3.2  
**Complexity:** M  
**Owner:** Integrator

Acceptance:

- Piped zero-argument invocation never prompts or upgrades.
- Exit statuses represent only conventional process outcomes: success, CLI misuse, operational failure, and signal termination.
- Attention and unknown remain data in output, not machine-significant exit statuses.
- Output is stable enough for logs but is not yet promised as a machine API.

### Workstream 2.6 — CLI compatibility and default switch

#### T2.6.1 — Choose compatibility path for old simple list

**State:** Complete — decision ratified 2026-08-18, see [research-004-cli-default-compatibility.md](research-004-cli-default-compatibility.md)  
**Complexity:** S  
**Owner:** Maintainer/product decision

Acceptance:

- Existing users retain an explicit way to request the old name-only list.
- New naming follows Homebrew conventions where practical.
- Deprecation policy is documented before release.

#### T2.6.2 — Switch zero-argument default to dashboard

**State:** Integration; blocked by T2.2.1, T2.2.2, T2.3.2, T2.4.3, T2.5.2, T2.5.3, and T2.6.1  
**Complexity:** L  
**Owner:** Integrator  
**Writes:** `brew-change`, help, README, regression tests

Acceptance:

- `brew-change` runs the dashboard.
- Package arguments retain detailed review.
- Legacy flags pass regression tests or emit documented deprecation guidance.
- Help examples lead with the trusted update workflow.

### T2.7.1 — Phase 2 usability and integration gate

**State:** Integration; blocked by all Phase 2 tasks  
**Complexity:** L  
**Owner:** Maintainer/integrator

Required scenarios:

1. Mixed formula/cask dashboard.
2. Attention, no-signal, and unknown review.
3. No outdated packages.
4. Piped output.
5. Narrow terminal and `NO_COLOR`.
6. Quit, EOF, invalid input, `INT`, and `TERM`.
7. Dry-run and confirmed mocked upgrade.
8. Legacy package detail and documented flags.

Exit evidence:

- Primary journey is complete and unambiguous.
- No terminal corruption or unbounded process remains.
- Exact plan and execution inputs match.
- Release notes clearly announce the default change.

## 7. Phase 3 — Adoption and Accessibility

### Phase 3 entry gate

- Phase 2 integration accepted.
- Dashboard wording has observed user feedback or structured maintainer review.

### T3.1.1 — Add concise first-run guidance

**State:** Blocked by Phase 3 entry gate  
**Complexity:** M  
**Junior-safe:** Yes  
**Writes:** CLI/help/docs and tests

Acceptance:

- Explains check, review, and upgrade boundaries briefly.
- Does not require an account or configuration wizard.
- Uses a concise non-persistent hint; this phase does not add first-run state storage.
- Does not block normal output in noninteractive mode.

### T3.1.2 — Replace jargon-heavy remediation

**State:** Blocked by Phase 3 entry gate  
**Complexity:** M  
**Junior-safe:** Yes  
**Writes:** dependency/error messages and tests

Acceptance:

- Missing required dependencies provide exact supported installation commands.
- Optional GitHub authentication explains the benefit without warning on every invocation.
- Package suggestions do not require users to construct shell pipelines.

### T3.2.1 — Show evidence provenance and freshness in review

**State:** Blocked by Phase 3 entry gate and T2.1.2  
**Complexity:** M  
**Writes:** evidence/display modules and fixtures

Acceptance:

- Review identifies source type, URL when safe, retrieval status, and human-readable freshness.
- Cache use is visible without overwhelming compact output.
- Unknown reasons are actionable where possible.

### T3.3.1 — Polish accessible output modes

**State:** Blocked by Phase 3 entry gate  
**Complexity:** M  
**Writes:** config/display modules and golden fixtures

Acceptance:

- `NO_COLOR` removes color dependence.
- Text labels preserve all classification meaning without emoji.
- Narrow terminals avoid unreadable truncation of the reason.
- Progress has a static alternative.

### T3.4.1 — Conduct novice workflow checks

**State:** Review gate; blocked by T3.1.1, T3.1.2, T3.2.1, and T3.3.1  
**Complexity:** M  
**Owner:** Maintainer/product review

Use scenario prompts rather than teaching the interface. At minimum, verify that a participant can explain:

- The difference between no-signal and unknown
- Whether anything has been upgraded yet
- How to review an attention result
- How to quit without changes
- Which packages will be upgraded after selection

Acceptance:

- Confusions are recorded and prioritized.
- Blocking comprehension failures are corrected before release.
- Feedback does not broaden phase 3 into a GUI project.

### T3.7.1 — Phase 3 integration and release gate

**State:** Integration; blocked by required Phase 3 implementation and review tasks  
**Complexity:** L  
**Owner:** Maintainer/integrator

Exit evidence:

- Novice workflow blocking issues resolved.
- Output meaning survives no-color/no-emoji conditions.
- Provenance and unknown reasons are reviewable.
- No telemetry, account, daemon, or sponsorship interruption was added.
- Documentation covers the primary journey for both audiences.

## 8. Phase 4 — Optional Native Reach

### T4.0.1 — Adversarial value review, round 1

**State:** Blocked until Phase 3 release evidence exists  
**Type:** Review gate  
**Reviewer:** Skeptical “Gilfoyle-like” persona subagent

Challenge user demand, competing tools, maintenance burden, and the smallest CLI-only alternative. Return a recommendation of reject, gather evidence, or proceed to round 2.

Candidate evidence includes one-shot local notifications, menu-bar launchers, existing Homebrew/macOS scheduling, permission behavior, notification fatigue, and no-daemon alternatives. This review does not implement them.

### T4.0.2 — Adversarial architecture review, round 2

**State:** Blocked by completed T4.0.1; always required  
**Type:** Review gate

Challenge signing/notarization, distribution, permissions, security, privacy, background execution, update strategy, and support cost.

If both rounds reject the proposal, close it as no-go. Reconsideration requires new evidence and restarts at T4.0.1.

### T4.0.3 — Adversarial tie-break review, round 3

**State:** Blocked; run only if material disagreement remains  
**Type:** Review gate

Resolve disputed assumptions with explicit evidence requirements. No implementation tasks may become Ready without maintainer approval after the final required review.

## 9. Phase 5 — Power-User Extensions

### T5.0.1 — Adversarial value review, round 1

**State:** Blocked until Phase 3 release evidence exists  
**Type:** Review gate  
**Reviewer:** Skeptical “Gilfoyle-like” persona subagent

Challenge whether JSON, filters, and CI contracts duplicate `brew` output, create permanent schema obligations, or distract from the trusted update workflow.

### T5.0.2 — Adversarial contract review, round 2

**State:** Blocked by completed T5.0.1; always required  
**Type:** Review gate

Challenge schema evolution, exit statuses, backward compatibility, provenance representation, composability, and test burden.

If both rounds reject the proposal, close it as no-go. Reconsideration requires new evidence and restarts at T5.0.1.

### T5.0.3 — Adversarial tie-break review, round 3

**State:** Blocked; run only if material disagreement remains  
**Type:** Review gate

No implementation task may become Ready without maintainer approval after the final required review.

## 10. Recommended Parallel Batches

### Phase 1 batch A

May run in parallel after baseline:

- T1.1.1 mock harness
- T1.3.1 status specification
- T1.4.1 prompt actions
- T1.4.2 flag validation
- T1.5.1 signal cleanup
- T1.6.1 URL policy
- T1.7.1 static analysis
- T1.7.4 documentation repair

Integration warning: T1.4.1 and T1.5.1 may touch interactive/config code used by later tasks; merge before dependent work starts.

### Phase 1 batch B

After batch A contracts land:

- T1.1.2 and T1.1.3 fixture conversions
- T1.1.4 HTTP/time harness
- T1.3.2 summary classification
- T1.4.4 execution capture
- T1.6.2 destination enforcement
- T1.7.3 release preflight

### Phase 1 batch C

Sequential/integration-heavy:

- T1.2.1 canonical inventory
- T1.3.3 classification-driven selection
- T1.4.5 Homebrew-resolved preview
- T1.4.3 final confirmation
- T1.5.2 terminal restoration
- T1.7.2 CI
- T1.8.1 phase integration

### Phase 2 batching rule

Do not parallelize record consumers until T2.1.1 is approved. After approval, classification, static output fixtures, progress contract, action-state design, and compatibility decision can proceed independently. T2.1.2 and final default-switch work remain integration-owned.

### Phase 3 batching rule

First-run guidance, remediation wording, provenance display, and accessibility fixtures may proceed independently once their Phase 2 contracts are stable. Usability checks and release integration remain maintainer-owned gates.

## 11. Phase Execution Checklist

Before starting any phase batch:

- Confirm all tasks are Ready.
- Confirm write targets do not overlap.
- Assign one integration owner.
- State the exact verification command.
- Preserve unexpected user/agent changes.

Before declaring a phase complete:

- Run the phase's deterministic suite from a clean command invocation.
- Run syntax and static analysis.
- Review the PRD invariants, not only test names.
- Record skipped live/network/platform checks.
- Update changelog and user documentation.
- Check the Amp usage allowance only as a resource-planning input; never reduce verification or leave a phase partially integrated to fit an allowance.
