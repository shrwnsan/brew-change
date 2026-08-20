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

- [ ] After parallel processing completes: a summary block —
      `N breaking / M major-review / K clean` with breaking packages
      listed first (name, from→to, one-line evidence); explicit all-clear
      line when zero breaking: "No breaking changes detected across N
      packages — safe to run brew upgrade"
- [ ] Data: aggregate the has_breaking/verdict state the parallel
      workers already compute (mirror of the `-u` assessment records;
      do not re-fetch)
- [ ] Result ordering: breaking first, then major bumps, then the rest
- [ ] Plain-render guarantee (README convention): text labels carry the
      meaning; piped/NO_COLOR output identical by construction
- [ ] During-processing: per-package progress ticker + ETA on the
      existing renderer where the current status line allows (stretch:
      skip if renderer contract makes it invasive)
- [ ] Tests: mixed breaking/clean fixtures assert the summary counts and
      ordering; all-clear fixture asserts the explicit line; piped
      output identical to NO_COLOR

## Task 2: LLM-assisted triage (only if Task 0 says go)

- [ ] PRD from research-009's contracts; opt-in only; labeled provenance
- [ ] Ambiguous-pattern packages only (never re-judge confident pattern
      hits); batched; timeout per call; fallback on any error
- [ ] Tests with a mocked provider: verdict parsing, timeout, no-key
      fallback, provenance labeling

## Dependency graph

Task 1 is independent and shippable first. Task 0 → (go) → Task 2.
