# The Trusted Update Workflow

How `brew-change -u` and `brew-change -b` decide what is safe to touch —
and why they never claim an update is "safe".

## Upgrade behavior

`brew-change -u` defaults only to packages whose fresh release evidence
produced no risk signal. Packages marked **attention** or **unknown** are
never bulk-selected. Before any upgrade, brew-change previews the exact
named package list with Homebrew, then asks for immediate confirmation.
Homebrew can still act on dependencies or dependents shown in that preview.

In a pipe or other non-interactive environment, brew-change prints guidance
and never starts an upgrade.

## The `-b` verdict

`brew-change -b` processes every outdated package and ends with a verdict
that answers the only question a `-b` run has: are there any breaking
packages or none? The verdict uses the same honest three-state assessment
as the `-u` dashboard, computed from the evidence the run already fetched:

```
Verdict: 4 attention · 2 no-signal · 19 unknown

Breaking changes (2)
  abseil 20260526.0 → 20260817.0
    absl::void_t is now deprecated; users should use C++17 std::void_t…
  nnn 5.2 → 5.3
    removed support for the legacy plugin interface
Major version transitions (1)
  vercel 58.9.0 → 59.1.4
No risk signal found (2)
Unknown (19) — no usable release notes; review individually
```

When nothing matches, the run says so explicitly ("No breaking-change
patterns or major version transitions detected across N packages.") while
still disclosing the unknown count — packages without release notes are
never reported as clean. Piped output is identical to the terminal base
render (`NO_COLOR` changes nothing).

## First run

On an interactive `brew-change -u` run you will see a one-line hint on
stderr: brew-change checks your outdated packages, shows what changed for
each (`r` review), and only upgrades what you explicitly confirm — nothing
runs until you approve the exact plan. No account or configuration is
needed, and quitting (`q`) changes nothing. The hint is never printed in
pipes or scripts, and it is not stored anywhere.

## Dashboard by default (changed in v1.14.0)

`brew-change -u` on a terminal runs the interactive dashboard by default
instead of the plain prompt flow: review each package's evidence
provenance read-only (`r`), stage an explicit per-package selection (`s`),
upgrade the no-signal set (`u`/Enter), or quit (`q`).

```bash
brew-change -u          # dashboard is now the default on a terminal
brew-change -u --plain  # previous prompt flow (or BREW_CHANGE_PLAIN=1)
```

Escape hatches, in precedence order (`--plain` flag >
`BREW_CHANGE_PLAIN=1` environment variable > default dashboard):

- `--plain` (or `BREW_CHANGE_PLAIN=1`, e.g. in an rc file) restores the
  previous prompt flow.
- `--dashboard` and `BREW_CHANGE_DASHBOARD=1`, the pre-v1.14.0 opt-ins,
  are accepted as documented no-ops.

Piped or redirected runs are unchanged: plain deterministic output, no
prompts, no upgrades, and the view flags do not switch views.

## Evidence caching and re-entry

Every evidence fetch (GitHub API, npm registry, scraped release pages) goes
through one HTTP response cache under `~/.cache/brew-change/http/`, so a
re-run after quitting the dashboard reuses earlier responses instead of
re-probing. The dashboard's review shows where each package's evidence came
from and how fresh it is; rows served from cache say so, and quitting with
a staged selection prints a one-line hint on the terminal about re-running.

```bash
brew-change -u --fresh   # re-probe all evidence this run (clears only the HTTP cache)
```

`--fresh` removes and recreates only the HTTP response cache; the GitHub
breaking-change patterns, the brew-info cache, and everything else are
preserved. The HTTP cache is bounded (at most 512 entries / 100 MiB, oldest
entries pruned first), never stores authentication tokens (cache keys use a
SHA-256-derived token fingerprint instead), and authenticated responses are
partitioned away from anonymous ones. Failed probes are never cached (a
"no notes" result must not freeze); instead, a package whose release-notes
probe chain concluded nothing is remembered for 10 minutes so immediate
re-runs skip that chain — a successful chain clears the memo instantly.

After an upgrade inside the dashboard, the refresh is *subtractive*:
packages whose version transition is unchanged keep their session-fresh
records verbatim, and only changed transitions, newly outdated packages,
and retryable rows are re-derived — so the pause after "Upgrade completed"
is short instead of a full second evidence pass.

## Accessibility

Output meaning never depends on color or emoji: text labels (like
`[breaking]` and the dashboard group headers) always carry the full
classification, and any emoji is strictly additive decoration on a
terminal. The base render — piped output, `NO_COLOR=1`, screen readers,
copy-paste — is identical by construction.

```bash
export NO_COLOR=1                      # no-color convention: also suppresses decorative emoji
export BREW_CHANGE_NO_EMOJI=1          # explicit no-emoji opt-out (labels unchanged)
export BREW_CHANGE_STATIC_PROGRESS=1   # plain "stage n/N" progress line, no spinner animation
```

`BREW_CHANGE_STATIC_PROGRESS=1` keeps the progress lifecycle (TTY-only
drawing, cleared line before the dashboard, restored terminal state) but
replaces the animated spinner with a static line that updates only when the
count changes. The full environment-variable reference lives in
[configuration.md](configuration.md).
