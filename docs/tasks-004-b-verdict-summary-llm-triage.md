# Tasks: -b verdict summary + LLM-assisted breaking triage (pre-PRD)

**Status:** Pre-PRD — Task 0 (research spike + gate) precedes any PRD;
the summary feature (Task 1) is well-understood and could be PRD'd
almost immediately, the LLM triage (Task 2) is genuinely open design.
**Created:** 2026-08-20
**Evidence:** user run below (2026-08-20)

# Problem (from the evidence)

`brew-change -b` on 36 outdated packages: the outdated list prints, the
changelog prompt answers "y", then —

```
Processing 36 packages in parallel (max 8 jobs)...
Completed processing 36 packages in 318s
Run 'brew upgrade' to upgrade all packages, or 'brew upgrade <package>' for individual packages.
```

Five minutes of processing end in **no verdict**. The per-package
`[breaking]` markers exist somewhere in the scrollback, but the run
never answers the only question the user had: "are there any breaking
packages or none?" — quote: *"I wasn't sure if there are any breaking
packages or none."* The `-u` dashboard already solves this shape of
problem for upgrade runs; plain `-b` runs are the gap.

Secondary UX cost: 318s is a long silent wait; the result ordering does
not put the packages that matter (breaking / major) first.

## Task 0: Research spike — LLM triage feasibility (blocking for Task 2 only)

Spike question: can an LLM pass add signal where the GitHub
breaking-change patterns are inconclusive (pattern says "no evidence"
on a major bump — is that "no breaking" or "unknown"?).

- [ ] research-009 doc: candidate providers (user suggestion on record:
      **glm-4.7**; also evaluate whatever CLI-agent surface exists vs a
      raw API call), input contract (package, from→to versions, fetched
      changelog excerpts — reuse the HTTP evidence cache), output
      contract (breaking|likely-breaking|clean + one-line justification
      + confidence), and the no-key/offline/rate-limit fallback (=
      today's patterns, verbatim)
- [ ] Decide: opt-in flag name (`--ai`?), env var for the key (never
      stored), whether AI verdicts enter the evidence cache (stale-able,
      `--fresh` clears) and are always labeled `ai:` in provenance
- [ ] Cost/latency budget: 36 packages → batched calls, hard ceiling on
      tokens; the 318s baseline must not grow materially
- [ ] Go/no-go recorded in research-009

## Task 1: `-b` end-of-run verdict summary (independent of Task 0)

**State:** Passed — released as v1.16.0 (2026-08-21) via PR #122 (squash 29881ab); maintainer-approved, disclosed lift-merge-restore per the established procedure. Three ratified deviations from the original checkboxes, recorded below.

- [x] After parallel processing completes: a summary block — the counts
      line `Verdict: A attention · D no-signal · E unknown` followed by
      attention rows split by signal kind (breaking first with name,
      from→to, one-line evidence excerpt; then major-only rows) and
      counts-only no-signal/unknown groups; explicit all-clear line when
      attention is zero: "No breaking-change patterns or major version
      transitions detected across N packages."
- [x] Data: plain `-b` runs now create their own `UPGRADE_STATUS_DIR` and
      run `assessment_record_init` → worker evidence rows (the display
      path's `append_assessment_evidence` write was already gated on the
      status dir) → `classify_upgrade_evidence` (same consolidate +
      classify + missing-row-synthesis stage boundary as `-u`; the
      upgrade presentation arrays it builds are inert in `-b`). Nothing
      is re-fetched.
- [x] Result ordering: **deviation** — changelog sections keep streaming
      per batch in inventory order (buffering all output for a
      breaking-first reorder would leave the terminal silent for the full
      ~5-minute run); the summary list itself orders breaking first.
- [x] Plain-render guarantee (README convention): text labels carry the
      meaning; piped/NO_COLOR output identical by construction
      (byte-compared in the suite).
- [x] **Deviation** — honest three-state wording replaces the original
      "N breaking / M major-review / K clean" and the "safe to run brew
      upgrade" all-clear: per the T1.3.2 no-safe-claims convention, the
      all-clear claims only that no patterns/transitions were detected,
      and the unknown count (packages with no usable release notes) is
      always disclosed — in the motivating run 19 of 36 packages were
      unknown, not clean.
- [ ] During-processing: per-package progress ticker + ETA on the
      existing renderer — **deferred** (stretch, as anticipated; the
      renderer contract makes it invasive).
- [x] Tests: `tests/test-b-verdict-summary.sh` (35 assertions; runner
      suite 27 → 28) — mixed and all-clear goldens
      (`tests/fixtures/verdict/`), breaking-wins-over-major, alphabetical
      rows, 72-char word-boundary excerpt truncation, malformed-line and
      empty-file tolerance, pipeline stage-boundary feeding, piped
      launcher integration (placement between the completion line and the
      upgrade hint), `-a` scope guard, `-u` regression, NO_COLOR
      byte-identity.
- Side fix surfaced by making `get_breaking_changes_summary` live code:
      it used `perl -pe`, which prints the captured section *and* the
      whole input (no-match runs returned the full notes verbatim);
      now `perl -0777 -ne`, explicit prints only.

Release evidence (v1.16.0, 2026-08-21):

- Implementation merged via #122 (squash 29881ab); version bump #123
  merged after both CI matrix jobs passed (macOS 7m48s, ubuntu 10m51s)
  and the local preflight deterministic runner passed 28/28 suites from
  a clean invocation on the release HEAD.
- Tag `v1.16.0` → https://github.com/shrwnsan/brew-change/releases/tag/v1.16.0
  (notes = the dated CHANGELOG section); source archive SHA256
  `e819efc5f3f4e75f5321f47fefdfb3c27638feeeb90086d3fe13d483a9a3302f`.
- Tap formula bumped via shrwnsan/homebrew-tap#43 (no lift needed — the
  tap repo has no branch protection).
- End-to-end validation: `brew upgrade` 1.15.0 → 1.16.0 (Homebrew-
  verified sha256), `brew test` and `brew audit` clean, installed CLI
  reports 1.16.0, live `-b` run on the real inventory ends with the
  verdict block.
- Process note (transparency): #122 and #123 were merged via the
  established disclosed lift-merge-restore (branch protection requires
  one approving review; the sole write-access account authored both PRs;
  the maintainer approved in-session and directed both the merge and the
  release; protection restored to its exact prior state immediately
  after each merge, verified by API diff).

## Task 2: LLM-assisted triage (only if Task 0 says go)

- [ ] PRD from research-009's contracts; opt-in only; labeled provenance
- [ ] Ambiguous-pattern packages only (never re-judge confident pattern
      hits); batched; timeout per call; fallback on any error
- [ ] Tests with a mocked provider: verdict parsing, timeout, no-key
      fallback, provenance labeling

## Dependency graph

Task 1 is independent and shippable first. Task 0 → (go) → Task 2.
