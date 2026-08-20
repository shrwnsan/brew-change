# Verdict summary fixtures (tasks-004 Task 1)

Golden outputs for `render_verdict_summary` (lib/brew-change-verdict.sh), the
end-of-run verdict block for plain `brew-change -b` runs.

## Design rationale

- **Honest three-state vocabulary** — same words the `-u` dashboard teaches
  (attention / no-signal / unknown). The all-clear line claims only "no
  breaking-change patterns or major version transitions detected"; it never
  claims the upgrade is safe, and the Unknown count always stays visible
  (no-notes packages are not verified clean). This supersedes the pre-PRD's
  "K clean / safe to run brew upgrade" wording per the T1.3.2 no-safe-claims
  convention.
- **Attention is split by signal kind**: rows whose `matched_signals` contain
  `breaking-change-pattern` render under "Breaking changes" (breaking wins
  when both signals are present — see `ripgrep`); the remaining attention
  rows render under "Major version transitions".
- **Counts-only for no-signal/unknown groups** — the changelog dump above the
  verdict already lists every package; repeating 15 no-signal names would be
  noise. Attention rows carry name, versions, and a one-line evidence
  excerpt because they are the rows the user must act on.
- **Excerpt selection**: the breaking section when the notes have one
  (abseil, ripgrep), else the first line that itself matches
  `detect_breaking_changes` (nnn — pattern-only matches must not surface the
  release title), truncated to 72 chars at a word boundary with `…`.
- **Base render contract** (T3.3.1): these goldens are the non-TTY base —
  text labels carry all meaning, zero emoji. The ⚠️ glyph on the
  "Breaking changes" header is strictly additive on a TTY without NO_COLOR,
  asserted separately in the suite.

## Cases

- `mixed/` — 8 records: 3 breaking (incl. one both-signals row), 1 major,
  2 no-signal (one cached-fresh), 2 unknown (unavailable + rate-limited).
- `all-clear/` — 0 attention: explicit all-clear line with the total, plus
  the unknown disclosure.
