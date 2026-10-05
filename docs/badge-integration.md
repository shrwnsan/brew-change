# Badge Integration

One-line verdict highlights after `brew update` / `brew upgrade`, via an
opt-in shell wrapper. Homebrew has no hook or plugin mechanism for augmenting
core commands (verified against Homebrew source, 2026-10 — see
[dev/prd-004](dev/prd-004-badge-integration.md)), so brew-change ships the
wrapper pattern instead: a `brew()` shell function that runs the real brew,
prints the badge from cached assessment data, and returns brew's exact exit
status.

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

    brew-change: 5 updates · 2 breaking (node, python) · 1 no-signal · 2h ago

- Counts come from the last assessment export (`~/.brew-change/last-assessment.json`)
  — the badge is instant and never touches the network.
- After `brew update` with a stale assessment (> 24h): `· refreshing…` — a
  headless `brew-change refresh` runs in the background (lock-protected, so
  parallel brew sessions never stack refreshes).
- After `brew upgrade`: `· assessment updating…` — always refreshed, because
  the outdated set provably changed.
- No assessment yet: `brew-change: no assessment yet — run brew-change -b`.
- The badge never prints in pipes or scripts (its own stdout-TTY check), and
  never changes brew's exit status.

## Wrapper semantics

    brew() {
        local __bc_ec=0
        command brew "$@" || __bc_ec=$?      # real brew runs unchanged
        case "${1:-}" in
            update)  { command brew-change badge after-update  >/dev/tty; } 2>/dev/null || true ;;
            upgrade) { command brew-change badge after-upgrade >/dev/tty; } 2>/dev/null || true ;;
        esac
        return $__bc_ec                       # brew's status passes through
    }

The `{ …; } 2>/dev/null` brace group matters: when no controlling terminal
exists (detached tmux pane, some IDE shells), the failed `>/dev/tty` open
would otherwise print shell noise after every `brew update`. The group's own
`2>/dev/null` is set up first and swallows exactly that message.

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
