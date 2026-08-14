# PRD: Trusted Homebrew Update Workflow

**Status:** Approved for planning  
**Created:** 2026-07-28  
**Owner:** Project maintainer  
**Target:** Incremental v1.x releases  
**Parent product:** `brew-change`  
**Task breakdown:** [tasks-003-trusted-update-workflow.md](./tasks-003-trusted-update-workflow.md)

## 1. Executive Summary

`brew-change` will evolve from a changelog viewer into a trusted Homebrew update assistant. Its primary job is to help users understand what may break, what could not be assessed, and exactly which packages they are asking Homebrew to upgrade before Homebrew changes anything.

The default terminal experience will become a compact inline dashboard. It will assess outdated formulae and casks, display honest evidence-based classifications, and let the user review or select updates without entering a full-screen interface. Animated progress will communicate that work is ongoing on interactive terminals. Pipes, logs, accessibility settings, and automation will receive deterministic output without animation.

Delivery is incremental. Phase 1 fixes current trust, reliability, testing, and documentation gaps. Phase 2 introduces the normalized assessment model and default dashboard. Phase 3 improves onboarding, accessibility, provenance, and adoption. Native macOS reach and power-user extensions remain blocked until adversarial reviews establish that they are valuable enough to justify their maintenance cost.

## 2. Problem Statement

Homebrew can report and install updates, but it does not provide a decision-oriented summary of upstream release evidence before an upgrade. Users must choose between upgrading without review and manually searching many release pages.

The current `brew-change` release provides useful changelog retrieval, breaking-change heuristics, parallel processing, and selective upgrades, but its core value is hidden behind flags. Running `brew-change` without arguments mostly duplicates `brew outdated`. The upgrade path also has trust problems:

- Missing or failed release-note retrieval can be counted as safe.
- The UI uses language such as “appear safe” despite heuristic evidence.
- The final confirmation helper is not part of the active execution path.
- Cask identity extraction differs across code paths.
- Some interactive input and signal paths are inconsistent.
- Tests rely partly on the developer's installed packages.
- No CI workflow protects releases.
- User and contributor documentation has drifted behind v1.11.5.

These issues matter to both intended audiences:

1. **Technical Homebrew users** need concise evidence, predictable automation behavior, and confidence that package selection maps exactly to the executed command.
2. **Everyday macOS users** need plain language, visible progress, safe defaults, actionable errors, and a guided path that does not assume package-manager expertise.

## 3. Product Positioning

### 3.1 Core promise

> Know what may break, what could not be assessed, and exactly which packages you are asking Homebrew to upgrade before Homebrew changes anything.

### 3.2 Product priorities

1. **Trust:** become the routine pre-upgrade safety check.
2. **Adoption:** make the workflow understandable and habit-forming.
3. **Power-user depth:** add automation only where it reinforces trust or adoption.

### 3.3 Language principles

- Never claim that a package or update is safe.
- Distinguish “no risk signal found” from “could not assess.”
- State which evidence was checked and why a classification was assigned.
- Prefer “app” and “command-line tool” in novice-facing explanations; introduce “cask” and “formula” only where useful.
- Make destructive boundaries explicit and place confirmation next to execution.

## 4. Goals and Non-Goals

### 4.1 Goals

1. Provide a compact default dashboard for all outdated Homebrew packages.
2. Use three honest result classes: `attention`, `no-signal`, and `unknown`.
3. Keep evidence acquisition, assessment, presentation, planning, and execution separate.
4. Show responsive TTY progress without corrupting output or terminal state.
5. Require explicit selection and final confirmation before upgrades.
6. Preserve detailed package review and practical CLI compatibility.
7. Make deterministic tests and CI mandatory release gates.
8. Improve first-run comprehension and error recovery without requiring a GUI.
9. Keep runtime data local and avoid accounts, hosted services, or telemetry.

### 4.2 Non-goals for phases 1–3

1. A full-screen terminal UI.
2. A language rewrite or new runtime dependency.
3. A native menu-bar application or background daemon.
4. Automatic upgrades, cleanup, uninstall, rollback, or scheduled execution.
5. Claims that semantic-version changes or keyword matches prove breakage.
6. Supporting package managers other than Homebrew.
7. Sponsorship prompts in the assessment or confirmation flow.
8. A hosted API, user account, or new analytics collection.

## 5. Personas and Jobs to Be Done

### 5.1 Technical Homebrew user

**Job:** “Before I upgrade my development tools, show me which updates deserve attention and let me inspect or automate the result without scraping terminal output.”

Needs:

- Fast batch assessment
- Evidence provenance and freshness
- Stable noninteractive behavior
- Exact package selection
- Useful exit statuses
- Compatibility with SSH, logs, and shell pipelines

### 5.2 Everyday macOS user

**Job:** “Tell me whether my Homebrew-managed apps have routine updates or updates I should read about, then guide me without risking an accidental upgrade.”

Needs:

- Visible progress
- Plain-language grouped results
- Conservative defaults
- Copy-paste remediation
- No unexplained jargon
- A clear quit path that changes nothing

### 5.3 Maintainer and contributor

**Job:** “Make focused changes with deterministic fixtures, clear ownership boundaries, and a release process that catches regressions before publishing.”

Needs:

- Small modules with explicit responsibilities
- Mocked Homebrew and network inputs
- CI and static checks
- Reviewable phase gates
- Accurate release documentation

## 6. Primary User Journey

Running `brew-change` will:

1. Query Homebrew for outdated formulae and casks.
2. Normalize canonical package identities and installed/latest versions.
3. Retrieve relevant upstream evidence concurrently.
4. Display TTY-only progress while work is active.
5. Classify each package from the available evidence.
6. Render a compact grouped dashboard.
7. Offer inline actions to review details, select updates, upgrade eligible updates, or quit.
8. Build an exact requested-package plan from explicit selections.
9. Ask Homebrew for a dry-run preview and disclose that Homebrew may also act on dependencies or dependents.
10. Display the selected packages and command semantics.
11. Require final confirmation immediately before execution.
12. Report actual Homebrew outcomes and actionable recovery guidance.

```text
Checking 14 outdated packages… ⠹ 7/14 · GitHub releases

Attention required (2)
  node        24.1.0 → 25.0.0   Breaking-change signal found
  postgresql  17.4   → 18.0     Major-version update

No risk signal found (9)
  git         2.49.0 → 2.50.1   Release notes checked

Could not assess (3)
  firefox     139.0  → 140.0    Release notes unavailable

[r] Review  [s] Select updates  [u] Upgrade no-signal  [q] Quit
```

The wording above is illustrative. Final labels must pass output and usability review before release.

## 7. Assessment Model

### 7.1 Normalized record

Every interface consumes the same logical assessment record. Bash may represent it using JSON or another testable structured form, but the contract is independent of storage syntax.

| Field | Purpose |
|---|---|
| Package identity | Canonical Homebrew token and display name |
| Package kind | Formula or cask |
| Installed version | Version currently reported by Homebrew |
| Available version | Outdated version reported by Homebrew |
| Evidence source | Upstream source type such as GitHub, npm, vendor page, or unsupported |
| Evidence URL | User-reviewable source when available |
| Retrieved at | Freshness timestamp |
| Retrieval status | Fresh, cached-fresh, stale, unavailable, failed, malformed, contradictory, rate-limited, or unsupported |
| Evidence snapshot | Sanitized evidence body/excerpt or immutable local artifact reference used by assessment and review |
| Classification | `attention`, `no-signal`, or `unknown` |
| Reasons | Concise machine-produced explanations |
| Matched signals | Exact configured indicators that affected classification |
| Assessment recommendation | Whether assessment permits consideration for no-signal bulk selection |
| Operational eligibility | Whether inventory and Homebrew state permit a named upgrade request |
| Default selected | Always false for `attention` and `unknown` |

### 7.2 Classification rules

Classification uses this precedence so every package has exactly one result:

1. `attention` when any trustworthy inventory-derived version heuristic or adequate upstream evidence produces a configured risk signal.
2. `no-signal` only when adequate upstream evidence is within the freshness policy and no risk signal matched.
3. `unknown` otherwise.

Evidence adequacy and classification are separate record fields. For example, a clearly parsed major-version transition with unavailable release notes is `attention` because of the independent version heuristic, while its retrieval status still says that upstream evidence is unavailable.

#### `attention`

Use when retrieved evidence contains a configured risk indicator, or when a version transition triggers a clearly labeled risk heuristic such as a major-version change. The reason must identify the signal. An `attention` result is not proof that an upgrade will break the user's system.

#### `no-signal`

Use only when relevant evidence was retrieved successfully under the freshness policy and no configured risk indicator matched. The user-facing label is “No risk signal found,” not “Safe.”

#### `unknown`

Use when no attention signal exists and evidence is absent, stale beyond policy, unsupported, contradictory, malformed, rate-limited without usable cache, or unavailable after bounded retries. Unknown packages are never included in a default upgrade selection.

### 7.3 Phase 1 evidence outcome

Before the full normalized record exists, every package in the current upgrade flow must still produce a minimal structured outcome containing upstream source type, retrieval status, retrieval timestamp when available, assessment reason, and classification. Phase 1 may not infer `no-signal` from an empty status file or a successful shell exit alone.

### 7.4 Confidence

The initial implementation should communicate evidence status and reasons rather than inventing a numeric confidence score. A future confidence model requires separate validation and is not implied by this PRD.

## 8. Architecture and Ownership Boundaries

The project remains Bash-first for phases 1–3. Existing modules should be changed directly where they own behavior; this PRD does not authorize a rewrite or parallel framework.

### 8.1 Homebrew inventory

Owns:

- Canonical formula/cask tokens
- Display names
- Installed and available versions
- Outdated status
- Installed variant resolution

Must not classify risk or render interactive output.

### 8.2 Evidence acquisition

Owns:

- GitHub, npm, and supported vendor retrieval
- Authentication and bounded retry behavior
- Cache reads/writes
- Provenance and freshness metadata
- URL safety policy

Must not call missing evidence safe.

### 8.3 Assessment

Owns:

- Classification rules
- Matched signals and reasons
- Assessment recommendation derived from classification

Must be testable from fixture evidence without Homebrew or network access.

### 8.4 Presentation

Owns:

- Compact and detailed rendering
- TTY capability detection
- Progress animation
- Static noninteractive output
- Accessible text and color behavior

Must not change classifications or upgrade eligibility.

### 8.5 Upgrade planning

Owns:

- User selections
- Exact requested-package plan
- Operational eligibility from inventory and assessment
- Exclusion reasons
- Dry-run representation

Must not execute Homebrew.

### 8.6 Execution

Owns:

- Final consent boundary
- Exact invocation of Homebrew for the approved plan
- Actual outcome reporting
- Conventional exit status

Must not intentionally broaden the requested package selection. Homebrew can still upgrade required dependencies or outdated dependents; the planner must preview and disclose this behavior rather than promising an exact final mutation set.

## 9. Progress and Terminal Behavior

### 9.1 Interactive terminals

- Show an animated spinner, completed/total count, and current stage.
- Centralize animation so package workers do not write competing frames.
- Rate-limit redraws to avoid CPU use and flicker.
- Preserve copyable final output by clearing the active frame before rendering results.
- Restore cursor visibility, echo, and terminal modes on normal exit and signals.

### 9.2 Noninteractive output

- Disable animation when stdout is not a TTY.
- Honor `NO_COLOR` and provide text labels that do not depend on color or emoji.
- Keep line-oriented output deterministic.
- Avoid prompts when input is unavailable; return an actionable status instead.
- Provide a deterministic test switch for time and animation where needed.

## 10. CLI and Compatibility Contract

### 10.1 Required behavior

- `brew-change` renders the dashboard after phase 2.
- `brew-change PACKAGE...` retains detailed package review.
- `brew-change --help` and `brew-change --version` do not require network access or optional tools.
- `brew-change -u --dry-run` shows the exact requested-package plan and Homebrew's non-mutating resolution preview.
- Invalid flag combinations fail before network work and explain the corrected invocation.
- Signals terminate with conventional statuses after cleanup.

### 10.2 Compatibility policy

Existing flags remain available during a documented transition. Better long-option names may be added as aliases, but removals require release notes and at least one minor-release deprecation period. Scripts must be able to opt into stable, noninteractive behavior before the zero-argument default changes.

### 10.3 Upgrade safety invariants

1. No upgrade occurs without an explicit upgrade action.
2. No package outside the displayed requested-package plan is passed intentionally by `brew-change` to Homebrew.
3. `attention` and `unknown` are unselected by default.
4. A named `brew upgrade --dry-run` preview runs successfully before final confirmation, with Homebrew auto-update disabled so preview and execution use the same metadata snapshot.
5. The confirmation explains that Homebrew may also upgrade required dependencies or outdated dependents.
6. Preview failure, timeout, or interruption blocks confirmation and executes no upgrade.
7. Actual execution keeps Homebrew auto-update disabled and disables automatic cleanup for this invocation; it does not disable dependency safety checks.
8. Final confirmation occurs immediately before execution.
9. Preview-only and quit paths execute no mutating upgrade command.
10. Interrupting performs no further action after cleanup.

## 11. Security and Privacy

- Fetch automatically only from explicitly supported HTTPS hosts in phases 1–3. Unsupported arbitrary vendor hosts produce `unknown` with a reviewable link rather than being fetched generically.
- Revalidate every redirect destination before following it; do not rely on unrestricted automatic redirects.
- Reject literal loopback, link-local, and private-network destinations, while documenting that portable Bash cannot guarantee complete DNS-rebinding prevention.
- Document any narrowly required HTTP exception.
- Sanitize network-derived terminal text and control sequences.
- Keep cache permissions restrictive and writes atomic.
- Never print authentication tokens.
- Use no account, hosted service, background agent, or new telemetry in phases 1–3.
- Treat package and tap metadata as untrusted input.

## 12. Errors and Recovery

- A single package failure must not erase successful assessments.
- Repeated authentication or rate-limit problems should be summarized once and represented as `unknown` per affected package.
- Dependency errors should include the smallest copy-paste remediation.
- Upgrade failure reporting must distinguish `brew-change` planning errors from Homebrew command failures.
- Do not claim rollback. Provide recovery guidance supported by Homebrew, such as reviewing the command output or running `brew doctor` when relevant.
- Preserve enough source and reason information for the user to inspect unknown or attention results manually.

## 13. Delivery Phases

### 13.1 Phase 1: Trust foundation

Deliver:

- Honest three-state classification in the existing upgrade flow
- Canonical cask extraction across batch paths
- Exact-plan final confirmation
- Homebrew dry-run preview and dependency/dependent disclosure
- Valid prompt return values and flag validation
- Reliable signal and terminal cleanup
- Generic URL safety hardening
- Deterministic mocked tests
- CI and static checks
- Accurate README, changelog, and test documentation

Exit criteria:

- Unknown is never counted or displayed as safe.
- Attention and unknown are never selected by default.
- The displayed selection matches execution inputs in tests.
- Production cask extraction is covered by fixtures.
- Deterministic test jobs pass on supported CI environments.
- Known baseline failures are either fixed or explicitly documented.

### 13.2 Phase 2: Default inline dashboard

Deliver:

- Normalized assessment record
- Compact grouped renderer
- Centralized progress renderer
- Review, select, upgrade, and quit actions
- Deterministic noninteractive mode
- Legacy detailed views and flag compatibility
- Output, narrow-terminal, interruption, and terminal-restoration tests

Exit criteria:

- The primary journey works from check through confirmed upgrade.
- Every dashboard row has a classification and reason.
- No animation appears in piped output.
- Interrupt tests leave terminal state intact.
- Legacy package review remains functional.

### 13.3 Phase 3: Adoption and accessibility

Deliver:

- Concise first-run guidance
- Plain-language terminology and actionable remediation
- Evidence provenance and freshness in review output
- `NO_COLOR`, text indicators, and narrow-terminal behavior

Exit criteria:

- Novice usability checks complete the safe review flow without external instructions.
- Core meaning is available without color or emoji.
- Error paths say what happened and what the user can do next.
- No new telemetry or daemon is introduced.

### 13.4 Phase 4: Optional native reach — blocked

Candidate scope includes local macOS notifications or a thin menu-bar launcher. No implementation is approved by this PRD.

Before tasks become ready, conduct two adversarial review rounds and a third if material disagreement remains. Both initial rounds are required even if round 1 recommends rejection; round 2 independently validates or challenges that recommendation. A skeptical “Gilfoyle-like” reviewer must challenge:

- Whether the feature solves a repeated user problem
- Whether macOS-native distribution and signing are justified
- Security and privacy implications
- Background resource use
- Maintenance and support burden
- Existing tools that already solve the need
- A smaller CLI-only alternative

A round-1 rejection that is confirmed in round 2 closes the proposal. Reconsideration requires new evidence and restarts the two-round gate.

### 13.5 Phase 5: Power-user extensions — blocked

Candidate scope includes JSON output, filters, CI use, and automation contracts. No implementation is approved by this PRD.

The same adversarial review gate applies, with additional focus on schema stability, support commitments, composability with `brew` JSON, and whether the interface reinforces the trusted update workflow.

## 14. Baseline, Versioning, and Rollout

### 14.1 Pre-upgrade baseline

Before behavior-changing implementation:

1. Confirm the exact baseline commit and clean working state.
2. Run the baseline verification suite.
3. Record all pre-existing failures.
4. Confirm whether the existing `v1.11.5` tag already provides the required code baseline.
5. If the maintainer wants a distinct post-planning milestone, propose a tag such as `pre-dashboard-v1.11.5` without assuming availability.
6. Create the verified local tag after maintainer confirmation.
7. Push the tag only with separate explicit approval.

### 14.2 Rollout

- Ship phase 1 independently before changing the default command.
- Announce the phase 2 default behavior clearly in release notes.
- Provide a temporary compatibility path for users who need the old simple list.
- Prefer multiple reviewable minor releases over a single large release.
- Do not combine a language migration with these behavior changes.

## 15. Success Measures

No new telemetry is required. Initial measures use tests, release quality, issue reports, and opt-in/manual feedback.

| Outcome | Initial measure |
|---|---|
| Trust | Zero known paths that label unknown evidence safe or select it by default |
| Plan integrity | Fixture tests prove displayed and requested package sets match; Homebrew-resolved side effects are previewed and disclosed |
| Reliability | CI passes deterministic supported-platform checks before release |
| Comprehension | Usability checks correctly explain all three classifications |
| Adoption | Install/update trends and community feedback improve after dashboard release |
| Compatibility | Existing detailed package review and documented flags pass regression tests |
| Accessibility | Core output is understandable with `NO_COLOR` and without emoji |

Numeric adoption targets should be set only after a baseline data source is identified. This PRD does not invent percentages that the project cannot currently measure.

## 16. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Heuristics create false confidence | Honest labels, reasons, and unknown state |
| Default behavior surprises scripts | Noninteractive contract, compatibility path, release notes |
| Spinner corrupts output or terminal | Central renderer, TTY guard, cleanup and signal tests |
| Bash complexity grows | Preserve ownership boundaries; add structure only where reused |
| Network variability makes tests flaky | Fixtures for behavior; minimal separate live smoke checks |
| Cask JSON shape changes | Canonical token helper and representative fixtures |
| Native scope distracts from CLI | Block phases 4–5 behind adversarial value review |
| Sponsorship harms trust | Defer and keep outside assessment/confirmation flow |

## 17. Open Decisions Deferred to Task Execution

The following decisions must be resolved by focused spikes or output review, not guessed in this PRD:

1. Exact Bash representation of normalized assessment records.
2. Exact compatibility flag for the pre-dashboard simple list.
3. Final action keys and dashboard wording after usability review.
4. Exact supported-host list and narrowly justified exceptions for evidence retrieval.
5. Supported CI matrix after measuring runtime and Homebrew availability.

Each decision has a task and acceptance gate in the companion task document.
