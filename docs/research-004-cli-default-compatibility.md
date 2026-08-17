# T2.6.1 — Default-Behavior Compatibility Strategy (Decision Record)

**Status:** Ratified by maintainer (2026-08-18) — flip release will be a minor; naming `--dashboard` / `--plain` confirmed
**Date:** 2026-08-18
**Decides:** How the Phase 2 default inline dashboard (T2.6.2) reaches users without breaking existing behavior contracts.
**Inputs:** Current-CLI behavior inventory (this repo, v1.12.1); external conventions research (docker/BuildKit, npm 7, Homebrew 4.0, pip, gh, git).

## 1. The contract being changed

Today's promises (README + help text):

- Bare `brew-change` prints the name-only outdated list, "like `brew outdated`" (README.md:8-9; brew-change:40).
- Piped/redirected runs are deterministic and never prompt or upgrade (README.md:50,60).
- Exit statuses are conventional only (0 incl. cancelled prompts; 1 misuse/operational; 130/143 signals).
- `-u` interactive flow with u/c/q prompt, three-tier assessment, preview-before-mutation, no-signal-only bulk selection.

The dashboard default changes the first bullet **for interactive use only**. The piped contract can remain byte-identical if the view is gated on TTY detection — which leads the decision.

## 2. External conventions (evidence)

- **TTY gating is the industry contract**: `gh`, git, docker BuildKit render rich UI only when stdout is a TTY; piped output stays plain and stable. Tools honoring this plus `NO_COLOR` largely defuse default-flip breakage: scripts never see the rich view.
- **Staged rollout is the gold standard**: pip shipped its new resolver opt-in (`--use-feature`) a full release before flipping; BuildKit did the same via `DOCKER_BUILDKIT=1`. Flip-only precedents (npm 7, Homebrew 4.0) paired the flip with a major bump and an escape hatch (`--legacy-peer-deps`, `HOMEBREW_NO_INSTALL_FROM_API`).
- **Escape-hatch naming**: `--plain` is the established name for "no rich UI" (docker); `BREW_CHANGE_*` uppercase env pins match both Homebrew's own convention and this repo's existing vars (`BREW_CHANGE_JOBS`, `BREW_CHANGE_PROMPT_TIMEOUT`).
- **Messaging**: transition notices go to stderr (never stdout), are actionable, and name the escape hatch. Persistent first-run state is out of scope until Phase 3 (T3.1.1 explicitly adds no state storage), so notices must be transient.
- **Semver practice**: default changes that alter piped/machine output get majors (npm 7, Homebrew 4.0); TTY-only cosmetic flips routinely ship in minors. In-repo precedent: v1.11.0 made `-u` interactive by default in a minor with a changelog entry.

## 3. Decision

1. **Piped contract is inviolable.** The dashboard renders only when stdout is a TTY. Non-TTY runs produce exactly today's output. (Note: `is_interactive_mode` today checks stdin only — interactive.sh:45-47; Phase 2 must gate the *view* on stdout TTY separately, and `NO_COLOR`/narrow terminals are already Phase 3 scope but the gate lands now.)
2. **Staged rollout.** The dashboard ships **opt-in first** behind `--dashboard` (and `BREW_CHANGE_DASHBOARD=1`), current default unchanged, in the release that completes workstreams 2.1–2.5. The default flips only in a subsequent release (T2.6.2), announced prominently.
3. **Escape hatches at flip.** `--plain` restores the name-only list for interactive runs; `BREW_CHANGE_PLAIN=1` pins it for rc files. Precedence: flag > env > default. Names follow Homebrew/GNU conventions (T2.6.1 acceptance).
4. **Transient transition notice.** For one release after the flip, interactive dashboard runs print one stderr line: "Output view changed in vX.Y — use --plain for the old list." Removed the following release; no persistent state (Phase 3 constraint respected).
5. **Exit codes and flag semantics unchanged.** Legacy flags (`-a`, `-v`, `-b`, `-u`, `-n`) keep their meanings; T2.6.2's regression tests pin them.
6. **Version for the flip: minor with a leading "Changed defaults" changelog entry** (recommended), since the piped contract is unchanged and v1.11.0 set in-repo precedent. Alternative considered: major bump (npm/Homebrew precedent) — conservative but heavyweight for a single-user-maintained tap tool whose scripted surface is untouched. **Ratified: minor bump (2026-08-18).**
7. **Deprecation policy (documented before release, per T2.6.1 acceptance):** old-default escape hatches are supported until the Phase 3 usability review; removal, if ever, is announced two releases ahead and tracked in this document.

## 4. Rollout mapping

| Stage | Release | Behavior |
|---|---|---|
| Opt-in | Phase 2 feature release (v1.13.0) | `--dashboard` / `BREW_CHANGE_DASHBOARD=1`; bare default unchanged |
| Flip | Next release (v1.14.0, minor — *pending ratification*) | Dashboard default on TTY; `--plain` / `BREW_CHANGE_PLAIN=1` escape; stderr notice |
| Settle | Following release | Notice removed; escape hatches per §3.7 policy |

## 5. Resolved items (maintainer ratification, 2026-08-18)

1. Flip release: **minor** (§3.6 ratified).
2. Naming: **`--dashboard` / `--plain`** (§3.2, §3.3 ratified).
3. Referred note: the ~133s multi-package runtime is per-package `brew info --json=v2` subprocesses, not evidence fetching (already cached, 1h TTL). Whether inventory may be short-TTL cached is referred to the T2.1.1 spike terms of reference as a freshness-vs-speed design input.
