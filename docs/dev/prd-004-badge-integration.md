# PRD-004: Badge Integration — brew-change highlights after `brew update`/`brew upgrade`

**Status:** Implemented via tasks-006, 2026-10-05
**Complements:** research-010 (native app due diligence) — this is the CLI-native form of the same thesis: brew-change as the trust/assessment layer, consumed through the export surface. The badge is brew-change's own first-party consumer of `last-assessment.json`.
**Grounding fact:** Homebrew has no hook/plugin mechanism for augmenting core commands. Verified 2026-10-05 against installed source (`/opt/homebrew/Library/Homebrew/brew.rb`, `commands.rb`): external commands (`brew-<cmd>` on `PATH` or tap `cmd/`) are strictly additive — internal commands resolve first (`commands.rb` `Commands.path`) — and no hook or callback exists in `cmd/update.rb`/`upgrade.rb`. Inline highlights are therefore only achievable via a user-shell wrapper.

## Problem

The user runs `brew update` / `brew upgrade` and sees nothing from brew-change. The verdicts (attention / no-signal / unknown, breaking-change evidence) that are brew-change's differentiator only surface when the user remembers to run `brew-change`. Ambient awareness of "3 updates · 1 breaking" at the moment brew finishes is the cheapest way to put the trust layer in front of users.

## Decisions (maintainer, 2026-10-05)

| Question | Decision |
|---|---|
| Target UX | Inline one-line badge after `brew update`/`brew upgrade` |
| Stale/missing cache | Print marker and refresh in background (detached one-shot, locked) |
| Architecture | Approach A: badge + detached one-shot refresh; no daemons. `refresh` designed so a future LaunchAgent (Approach B) can call the same entry point unchanged |
| Badge format | One dense line (counts + breaking names + age) |
| After `brew upgrade` | Always treat assessment as stale: print `updating…` marker, spawn locked refresh |
| No export at all | Show setup hint (`run brew-change -b`) |

## Architecture

Three new subcommands dispatched in the main script (same pattern as `export)`, post-library-sourcing handling):

### `brew-change badge`

- Reads `~/.brew-change/last-assessment.json` (schema v1: `generated_at`, `packages[].classification`, `matched_signals`). **No schema changes.**
- Prints exactly one line; always exits 0; never prompts; never touches the network.
- Silent no-op when stdout is not a TTY (safe in scripts/pipes).
- Sources only the libs it needs (`utils`, export reader) — target <100 ms runtime; no heavy pipeline sourcing.
- Output contract:
  - Fresh (age ≤ `BREW_CHANGE_BADGE_MAX_AGE`): `brew-change: N updates · M breaking (names) · S no-signal · U unknown · <age> ago`
    - Segments beyond `N updates` print only when their count is > 0.
    - Breaking = packages whose `matched_signals` include `breaking-change-pattern` (signal names confirmed in `lib/brew-change-assessment.sh:82,108`; the other current signal is `major-version-transition`). Names capped at 3, then `+K`: `(node, python@3.13, +2)`.
    - Age: `Xm` / `Xh` / `Xd`.
  - Stale (age > max) after `update`: same line, then `· refreshing…`, and spawn refresh (§ Refresh scheduling).
  - After `upgrade` (wrapper passes the trigger via argv, below): line ends `· assessment updating…`, always spawn refresh.
  - Missing export file: `brew-change: no assessment yet — run brew-change -b`.
  - Unparsable JSON or unsupported `schema_version`: silent no-op (consumer contract: non-event, never an error; a future schema written by a newer brew-change must not nag).
- `BREW_CHANGE_BADGE_DISABLE=1` → immediate silent no-op (escape hatch without editing rc files).
- Trigger signaling: the wrapper invokes `brew-change badge after-update` / `badge after-upgrade` so badge knows the context without inspecting brew state.

### `brew-change refresh`

- Headless, non-interactive assessment run: the existing `-b` pipeline with prompts auto-resolved (decision points record `unknown` instead of asking), no dashboard, no interactive upgrade, progress suppressed.
- Quiet by default (no `-q` flag — quiet is inherent; deviation recorded in tasks-006); writes the export and evidence caches on success; leaves the previous export untouched on failure.
- Exit 0 on success, non-zero on hard failure; appends a one-line status to `~/.brew-change/refresh.log` (truncated tail, size-capped).
- Public entry point: a future LaunchAgent/launchd unit (macOS) or cron (Linux) calls the identical command unchanged.

### `brew-change init zsh|bash`

- Emits the wrapper function to stdout; user opts in via `eval "$(brew-change init zsh)"` in their rc (starship/zoxide pattern). **Never writes to rc files itself.**
- Wrapper (zsh form; bash equivalent):

```zsh
brew() {
  command brew "$@"
  local ec=$?
  case "$1" in
    update)  command brew-change badge after-update  >/dev/tty 2>&1 || true ;;
    upgrade) command brew-change badge after-upgrade >/dev/tty 2>&1 || true ;;
  esac
  return $ec
}
```

- `return $ec` — brew's exit status passes through; the badge's is discarded by construction (`|| true`, and `badge` itself always exits 0).
- `>/dev/tty` — badge survives `brew update | tee` and redirects; never pollutes pipes.
- Fires only on explicit first-arg `update`/`upgrade`; brew's internal auto-update before install/upgrade is untouched.
- Functions are not exported, so brew-change subprocesses invoking `brew` internally cannot recurse into the wrapper.
- Unknown shell argument → stderr error, exit 1.

## Refresh scheduling (Approach A)

- Spawn: `nohup brew-change refresh -q >/dev/null 2>&1 &` then `disown` (zsh/bash; `setsid` not required). Detached one-shot — nothing resident.
- Lock: `~/.brew-change/.refresh.lock/` created with atomic `mkdir`. Contains `pid` and `started` (epoch), written temp-then-`mv`.
- On encountering a live lock: read PID — alive (`kill -0`) → skip silently. Dead PID or lock age > 30 min → take over (remove, recreate).
- Effect: rapid repeated `brew upgrade` invocations coalesce into at most one running refresh; the 30-min takeover bounds zombies even without a runtime cap (existing retry/timeout config governs the run itself).

## Configuration (follows `BREW_CHANGE_*` convention, documented in configuration.md)

| Variable | Default | Meaning |
|---|---|---|
| `BREW_CHANGE_BADGE_MAX_AGE` | `86400` (24 h) | Seconds after `generated_at` before an export counts as stale |
| `BREW_CHANGE_BADGE_DISABLE` | unset | `1` → badge is a silent no-op |

## Error handling

- `badge`: every failure mode is a silent exit 0 by contract — the badge may never disturb the brew UX or a prompt.
- `refresh`: hard failure leaves old export in place; next badge reports stale and retries on the next trigger. `refresh.log` is the debugging surface.
- Lock: stale-PID takeover per above; partial lock writes prevented by temp-then-rename.

## Testing (repo conventions: plain-bash harnesses + fixtures)

- `tests/test-badge-output.sh` — fixture exports (fresh / stale / missing / malformed / future-schema; each classification mix; breaking-name cap) → exact expected lines, exit codes, non-TTY silence, `BREW_CHANGE_BADGE_DISABLE`.
- `tests/test-badge-init.sh` — `init zsh` / `init bash` emit syntax-valid code (`bash -n` / `zsh -n`); simulated wrapper preserves a failing brew's exit code; unsupported shell arg errors.
- `tests/test-refresh-lock.sh` — lock acquire; live-PID skip; dead-PID takeover; >30 min takeover; refresh leaves export untouched on failure.
- Update `tests/test-cli-validation.sh` and `--help` for the three new subcommands.
- All new tests wired into the local suite entry point used by `run-deterministic.sh`.

## Docs

- New `docs/badge-integration.md` — opt-in install, wrapper semantics, badge line legend, staleness/refresh behavior, uninstall (delete rc line).
- `docs/configuration.md` — the two new variables.
- README quick-start — short opt-in block after the main usage examples.
- `CHANGELOG.md` — unreleased entry; version bump per release convention.

## Non-goals

- No LaunchAgent in this scope (door open via `refresh`); no cron shipping either.
- No color/ANSI in badge output v1 (accessibility modes stay untouched).
- No automatic rc-file modification, ever.
- No `brew change` external-command subcommand (separate idea, unchanged).
- No export schema changes; badge is a consumer like any external tool.
- No shadowing or wrapping of brew internals beyond the user's own shell function.

## Success criteria

- Badge line appears after `brew update` completes with no perceptible delay (export read only, <100 ms).
- Brew's exit code survives the wrapper (test-proven).
- Zero badge output when stdout is piped; zero badge output when `BREW_CHANGE_BADGE_DISABLE=1`.
- Concurrent `brew upgrade` sessions produce at most one running refresh.
- Missing export → hint; malformed/future-schema export → silence; nothing ever errors the shell.
- Full local test suite green; docs complete.

## Addendum (2026-10-06): live-testing amendments

Real-usage testing after merge surfaced five amendments, each shipped with
regression coverage (commits 924332b..e94ff16):

1. **Binary pin in `init`** — the emitted wrapper referenced `brew-change`
   via PATH. With tap v1.20.1 still installed, `eval "$(brew-change init
   zsh)"` stalled shell startup: the old pre-parse treats unknown words as
   package names, so `init zsh` ran changelog lookups inside rc evaluation.
   `init` now emits `__bc_bin=<absolute path of the emitting binary>`.
2. **Own-PID lock adoption** — the badge pre-acquires the lock and writes
   the spawned child's pid; the child refused a lock "held by itself" and
   exited, so refresh never ran. `refresh_lock_acquire` adopts its own pid.
3. **Degraded-export guard + backoff** — a network-dead refresh (zero
   `fresh|cached-fresh` retrievals, research-005 vocabulary) kept a healthy
   export instead of overwriting it with forced-unknown records (rc=2);
   failed refreshes start a 30-min badge backoff
   (`BREW_CHANGE_REFRESH_BACKOFF`).
4. **`before-upgrade` trigger** — the post-upgrade badge lands after the
   decision point; a read-only verdict now prints above brew's plan where
   the `y/n` happens.
5. **Presentation pass** — risk coloring (breaking red / no-signal green /
   unknown yellow, `NO_COLOR` respected), Homebrew-style `==>` header
   marker, and duplicate suppression: an after-* verdict identical to the
   last printed one (same export, <10 min) repeats nothing;
   `before-upgrade` always prints.

Known accepted trade-off: a declined `brew upgrade` still triggers the
refresh and suffix — brew exits 0 on decline, and the wrapper deliberately
does not parse brew output.
