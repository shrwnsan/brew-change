# Badge Integration

One-line verdict highlights after `brew update` / `brew upgrade`, via an
opt-in shell wrapper. Homebrew has no hook or plugin mechanism for augmenting
core commands (verified against Homebrew source, 2026-10 — see
[dev/prd-004](dev/prd-004-badge-integration.md)), so brew-change ships the
wrapper pattern instead: a `brew()` shell function that runs the real brew,
prints the badge from cached assessment data, and returns brew's exact exit
status.

## Requirements

The binary that runs `init` must support the badge subcommands (the release
that first ships them; v1.20.1 and earlier do not — those versions treat
unknown words as package names, so `brew-change init zsh` would start
changelog lookups for packages "init" and "zsh" inside your shell startup).
`init` pins the emitting binary's absolute path into the emitted code, so a
repo checkout works before any release, and a tap install keeps working
across `brew upgrade` (the Cellar symlink path is stable).

## Install (opt-in)

```zsh
# zsh — add to ~/.zshrc
eval "$(brew-change init zsh)"

# bash — add to ~/.bashrc
eval "$(brew-change init bash)"
```

Nothing is written to your rc files by brew-change itself. Place the line
after any other `brew` function or alias you define — the wrapper takes
precedence.

Uninstall: delete the `eval` line from your rc.

## What you see

    ==> brew-change: 5 updates · 2 breaking (node, python) · 1 no-signal · 2h ago

The `==> ` marker mirrors Homebrew's own header style (bold green on a
terminal; plain text under `NO_COLOR`), so the verdict reads as part of
brew's output stream.

- Counts come from the last assessment export (`~/.brew-change/last-assessment.json`)
  — the badge is instant and never touches the network.
- After `brew update` with a stale assessment (> 24h): `· refreshing…` — a
  headless `brew-change refresh` runs in the background (lock-protected, so
  parallel brew sessions never stack refreshes).
- After `brew upgrade`: `· assessment updating…` — always refreshed, because
  the outdated set provably changed.
- The `· refreshing…` / `· assessment updating…` suffix only appears when a
  refresh actually started. After a failed refresh, the badge backs off for
  30 minutes (`BREW_CHANGE_REFRESH_BACKOFF`): no suffix, just the plain line
  with its age marker — the line never promises a refresh that is not
  happening.
- A refresh whose evidence pass came back entirely unhealthy (no `fresh` or
  `cached-fresh` retrievals — the network-dead signature) does not overwrite
  a healthy export with forced-unknown records. The previous export is kept
  and the run logs `rc=2` in `refresh.log`.
- No assessment yet: `brew-change: no assessment yet — run brew-change -u`.

## Color and repetition

On a terminal the line is tinted by risk: **breaking** red, **no-signal**
green, **unknown** yellow, the prefix and age dimmed. Color is presentation
only — the words carry the full classification — and `NO_COLOR` turns it
off, per the accessibility doctrine in `docs/configuration.md`.

A verdict identical to the last one printed (same export, within 10 minutes)
does not repeat: the after-* badge prints only its spawn tail
(`assessment updating…`) or nothing. `before-upgrade` always prints —
decision support is never suppressed.
- The badge never prints in pipes or scripts (its own stdout-TTY check), and
  never changes brew's exit status.

## Wrapper semantics

    __bc_bin=/path/to/brew-change          # pinned by `init`

    brew() {
        case "${1:-}" in
            upgrade) { command "$__bc_bin" badge before-upgrade >/dev/tty; } 2>/dev/null || true ;;
        esac
        local __bc_ec=0
        command brew "$@" || __bc_ec=$?      # real brew runs unchanged
        case "${1:-}" in
            update)  { command "$__bc_bin" badge after-update  >/dev/tty; } 2>/dev/null || true ;;
            upgrade) { command "$__bc_bin" badge after-upgrade >/dev/tty; } 2>/dev/null || true ;;
        esac
        return $__bc_ec                       # brew's status passes through
    }

Details that carry weight:

- **`before-upgrade` is decision support.** A read-only verdict prints above
  brew's plan, where the `y/n` actually happens. It never refreshes — the
  post-upgrade badge owns the settle state.
- **`__bc_bin` pins the emitting binary.** A PATH lookup could resolve an
  older brew-change that predates the subcommands and misfire; the pin
  cannot drift.
- **The `{ …; } 2>/dev/null` brace group**: when no controlling terminal
  exists (detached tmux pane, some IDE shells), the failed `>/dev/tty` open
  would otherwise print shell noise after every `brew update`. The group's
  own `2>/dev/null` is set up first and swallows exactly that message.

Only explicit `brew update` / `brew upgrade` invocations trigger the badge —
Homebrew's internal auto-update before install/upgrade is untouched.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BREW_CHANGE_BADGE_MAX_AGE` | `86400` | Seconds after `generated_at` before the assessment counts as stale and refreshes |
| `BREW_CHANGE_BADGE_DISABLE` | unset | `1` → badge is a silent no-op (escape hatch without editing rc) |

## Refresh internals

`brew-change refresh` is the headless engine: it re-runs the assessment
pipeline with all prompts resolved to `unknown`, no dashboard, no changelog
output, and writes the export. It is a public entry point — a future
LaunchAgent/cron integration calls the same command (prd-004 Approach B door
left open). State: `~/.brew-change/.refresh.lock/` (atomic mkdir; live-PID
skip; dead-PID or 30-min takeover) and `~/.brew-change/refresh.log`
(completion log, capped at the last 100 lines).
