# Evidence Cache & Re-Entry After Abort (Decision Record)

**Status:** Ratified (2026-08-19)

**Decides:** How a re-run of `brew-change -u` after a dashboard timeout/quit reuses evidence responses, and whether review selections persist across runs.

**Evidence:** Code audit of the fetch/cache layers (2026-08-19) plus two adversarial review rounds on a session-persistence proposal.

## Problem (maintainer field report, v1.14.x soak)

`brew-change -u` gathers per-package evidence before showing the dashboard. A timeout or accidental `(q)uit` discards the per-run review state. A re-run then repeats every evidence request not covered by the existing response cache.

The maintainer also asked whether "selected for upgrade vs still pending" should persist across runs.

## Discovery: two response paths bypass the cache

The current cache coverage is narrower than first assumed:

| Evidence path | Fetch function | Current behavior |
|---|---|---|
| JSON responses, including npm registry responses | `fetch_url_with_retry` | **Cached** by URL with a 1h TTL after JSON validation; validated stale content may be returned after a network failure |
| Homepage and raw changelog text | `fetch_url_with_retry_text` | **Uncached** |
| Authenticated or anonymous GitHub API responses | `fetch_url_policy_aware` | **Uncached** |

GitHub is likely the dominant evidence source for a typical Homebrew inventory, so its bypass is the leading explanation for costly re-runs. That contribution has not been measured against a representative package set and is not treated as the sole proven cause; uncached text probes also contribute.

## Decision 1 — One raw-response cache boundary for every evidence fetch

Keep caching below classification. Introduce one shared HTTP response-cache boundary used by `fetch_url_with_retry`, `fetch_url_with_retry_text`, and `fetch_url_policy_aware` rather than adding a second cache for classified evidence rows.

The boundary must:

- Cache only successful responses accepted by the caller's validator: syntactically valid JSON for JSON/GitHub requests, or a non-empty body for text requests.
- Re-run classification over the raw response on every invocation so current breaking-change patterns take effect immediately.
- Select TTL by request/endpoint class, not host alone:
  - Low-volatility exact GitHub tag, ref, commit, or object endpoints may use 24h. They are not immutable: release bodies can be edited and refs can move.
  - Mutable GitHub collections such as `/releases`, npm responses, scraped pages, and branch-based raw content use at most 1h.
- Partition authenticated cache entries by token identity. Key material is the URL plus either `anon` or a SHA-256-derived token fingerprint; the complete key material is hashed before it becomes a filename. Raw tokens and standalone fingerprints must never be written to disk, logs, or UI.
- Keep response files in a dedicated `$CACHE_DIR/http/` namespace with owner-only permissions and atomic writes.

### Rejected: cross-run evidence-row cache keyed by package and version

An earlier design cached classified evidence rows. It was rejected because:

1. Evidence validity depends on both installed and available versions; caching by installed version can serve evidence for the wrong transition after `brew update`.
2. Cached rows freeze the pattern verdict and need another invalidation scheme when the pattern set changes.
3. It duplicates version-invalidation machinery already used by the brew-info cache.
4. Raw-response caching makes a re-run cheap while preserving the existing classification source of truth.

## Decision 2 — Quit remains an abort

Selections do not persist. A stale selection could pre-arm a later confirmation and override the deliberate rule that attention/unknown packages are not selected by default. `brew outdated` remains the source of truth for packages still pending.

When the user quits with a non-empty staged selection, write this line to the TTY, never captured stdout:

```
Review discarded. Re-run 'brew-change -u' — cached evidence will be reused where available.
```

The wording does not promise that every probe is cached. The per-run status directory and its cleanup remain unchanged.

## Decision 3 — Provenance is part of this cache change

A longer-lived cache cannot continue stamping cached bodies as newly retrieved. T3.2.2 must land after T3.2.1 or deliver its provenance portion in the same change.

Each request records:

- `network-fresh`, `cached-fresh`, or `cached-stale`;
- the original retrieval epoch; and
- age at the time of use.

Shell globals are not valid accounting: fetches run in command substitutions, subshells, and parallel workers. Each producer must pass an explicit request-scoped metadata path (or equivalent output parameter), then consume that result when writing its evidence row. This requires call-site changes in the GitHub, non-GitHub, and npm producers.

For run-level reporting, every cache hit creates a uniquely named event file in an exported run-scoped cache-events directory. Event files survive subshells and avoid concurrent counter updates. The parent process aggregates them into one TTY-only line such as:

```
Reusing 8 cached responses (oldest 17m old). Use --fresh to re-probe.
```

The banner must not enter captured stdout. `cached-stale` is not equivalent to trustworthy no-signal evidence: a detected risk signal may still classify as attention, but otherwise the evidence remains unknown.

## Decision 4 — Validated stale fallback, bounded storage, and `--fresh`

Cache reads follow one lifecycle:

1. A validated, unexpired entry is served as `cached-fresh`.
2. An expired entry triggers a network refresh.
3. A successful validated refresh atomically replaces the entry and is `network-fresh`.
4. If refresh fails, only a previously validated entry may be served as `cached-stale`.
5. A corrupt entry is deleted and fails closed; it is never used as stale fallback.

Expired entries are therefore not deleted unconditionally before refresh. Stale entries may remain for fallback until replaced or pruned.

At run start, prune the oldest HTTP entries until both limits hold: at most 512 entries and at most 100 MiB. The limits apply only to `$CACHE_DIR/http/`; npm payload size makes a count-only cap insufficient. Entry age and size handling must work on both macOS/BSD and Linux/GNU tools, and temporary write artifacts must never be treated as valid entries.

`--fresh` removes and recreates only `$CACHE_DIR/http/` before gathering. It preserves `github-patterns.json`, brew-info caches, and all unrelated state. Because old HTTP entries are gone for that run, `--fresh` cannot fall back to them.

## What a re-run still pays

A quit-and-rerun still performs `brew outdated`, any brew-info work not covered by its separate cache, local classification, and rendering. Evidence network requests are avoided only when a valid cache entry is usable. The user repeats their dashboard selections by design.

## Blast radius

- `lib/brew-change-utils.sh` — shared cache boundary, validators, endpoint TTL selection, auth partitioning, stale lifecycle, per-request metadata, event emission, and pruning.
- `lib/brew-change-github.sh`, `lib/brew-change-non-github.sh`, and `lib/brew-change-npm.sh` — pass and consume request provenance at evidence-producing call sites.
- `lib/brew-change-config.sh` — TTL and HTTP-cache budget constants.
- `brew-change` — `--fresh` parsing/help and run-scoped cache-event setup.
- `lib/brew-change-dashboard-ui.sh` and display/evidence modules — TTY-only summary, quit-time hint, and truthful row provenance.
- Tests — JSON, text, and GitHub cache paths; auth partitions; TTL classes; concurrency; stale/corrupt behavior; namespace isolation and budgets; provenance; TTY output and stdout purity.

## Required verification

Deterministic tests must cover:

- JSON, text, and GitHub response caching.
- Anonymous separation from two distinct authenticated token fingerprints, without exposing tokens.
- Mutable versus low-volatility endpoint TTLs.
- Parallel/subshell hit accounting and per-request provenance in evidence rows.
- Validated stale fallback and rejection of corrupt stale entries.
- `--fresh` preserving unrelated caches.
- HTTP-only pruning enforcing both count and byte budgets.
- The TTY banner and quit line without stdout contamination.

## Sequencing

This decision is ratified. T3.2.2 remains blocked by the Phase 3 entry gate and must follow T3.2.1 or include the required provenance work in the same change. No evidence-cache implementation is authorized by this record alone.
