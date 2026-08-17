# T2.1.1 — Assessment Record Contract (Decision Record)

**Status:** Approved by maintainer (2026-08-18)
**Decides:** The structured record passed between pipeline stages (inventory → evidence → classification → presentation → planning) for Phase 2.
**Evidence:** Spike report with measured benchmarks (`spike/record-bench.sh`, macOS arm64 / Bash 5.3.15 / jq 1.8.2, 3 trials).

## Decision 1 — Representation: JSON Lines (Option A)

One `jq -c` object per package per line, append-only `assessment.jsonl` in the per-run status dir (evolution of today's `results.tsv` atomic-append worker pattern).

Measured basis (vs US-delimited and per-package-file alternatives):

- Fidelity: byte-exact round-trips of multiline notes, quotes, tabs, unicode names (`pkg-ünïcode-🍺`); escaping is jq-owned.
- Parallel safety: 16 workers × 25 appends → 400/400 records, 0 malformed (compact line < PIPE_BUF is atomic).
- Corruption containment: tolerant-read (`jq -R 'fromjson? // empty'`) + strict-write; a bad line is logged, its package force-classified `unknown`, never silently dropped; a strict `jq -e` validation pass at each stage boundary fails the stage.
- Performance: 0.098s write @ 23 packages / 0.79s @ 200 — noise against the ~130s inventory runtime (not a deciding criterion).

Rejected: US-delimited (hand-rolled escaping silently splits records on any unescaped LF; demonstrated macOS BSD-awk `\x1f` portability trap), per-package files (2× write cost, filename-encoding hazards, no advantage over line isolation). Per-package files survive only as the subordinate convention for large evidence snapshots (`evidence/<encoded>.txt` referenced from the record).

## Contract schema (all PRD §7.1 fields; `null` = defined not-applicable; writers MUST emit every key)

```json
{"package":"node","display_name":"node","kind":"formula",
 "installed_version":"22.6.0","available_version":"22.8.0",
 "evidence_source":"github",
 "evidence_url":"https://...",
 "retrieved_at":1723900000,
 "retrieval_status":"fresh",
 "evidence_snapshot":"<sanitized excerpt or {\"artifact\":\"<run-dir path>\"}>",
 "classification":"attention",
 "reasons":["major version transition detected"],
 "matched_signals":["major-version-transition"],
 "assessment_recommendation":false,
 "operational_eligibility":true,
 "default_selected":false}
```

- `retrieval_status` vocabulary: `fresh|cached-fresh|stale|unavailable|failed|malformed|contradictory|rate-limited|unsupported` (PRD §7.1 exact).
- `classification`: `attention|no-signal|unknown`; empty string pre-classification.
- Stream direction: workers append only; stage boundaries may rewrite via temp-file + atomic `mv`.

## Decision 2 — `brew info` caching (two layers, approved)

The ~130s runtime is per-package `brew info --json=v2` subprocesses, called 4–5× per package across code paths (`lib/brew-change-brew.sh:73,257,342,392,425`).

1. **Per-run memo:** fetch each package's `brew info` once per run, reuse downstream. Zero freshness impact.
2. **Cross-run cache:** TTL **5 minutes**, keyed by `(package, kind)`, stored under `~/.cache/brew-change/brew-info/` (700 perms, same pattern as existing caches).

Safety argument: classification inputs (installed/available versions) come from the **uncached** `brew outdated --json=v2` that opens every flow; cached `brew info` only routes evidence. Stale info can at worst misroute a URL, which degrades to `unknown` (the safe direction). Extra invalidation rule: if `brew outdated` reports a version newer than the cached info's current version, that entry is refetched. Evidence-fetch caching stays at its existing 1h TTL, unchanged.

## Blast radius for T2.1.2 (integration-owned)

`brew-change-brew.sh` (inventory emits records + memo/cache), `brew-change-display.sh` (two `results.tsv` writers become JSONL appenders; display consumes records), `brew-change-github.sh`/`brew-change-non-github.sh` (fill evidence fields), `brew-change-upgrade.sh` (TSV + three arrays become record-driven; arrays become derived views), `brew-change-parallel.sh` (append target changes; progress events feed T2.4.1), tests/fixtures (fake `brew info` outputs + JSONL goldens).
