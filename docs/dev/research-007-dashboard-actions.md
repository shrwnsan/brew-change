# T2.5.1 + T2.5.3 — Dashboard Action-State Machine and Noninteractive Behavior (Decision Record)

**Status:** Approved by integrator (2026-08-18), pending maintainer visibility
**Decides:** Behavior of every dashboard action, input, and noninteractive invocation; defines T2.5.2's implementation contract.

## 1. Action-state machine (T2.5.1)

Base rules inherited from Phase 1: all prompt I/O via `/dev/tty`; single-key actions; invalid input reprompts with a hint; EOF and inactivity timeout (with the 10s countdown) cancel; `q` quits. One outcome per state×input.

### State: DASHBOARD (rendered dashboard, awaiting action)
| Input | Outcome |
|---|---|
| `r` | → REVIEW |
| `s` | → SELECT |
| `u` | → UPGRADE (no-signal set) |
| `Enter` | `u` when no-signal set is non-empty, else `q` (Phase 1 default semantics) |
| `q` | exit 0, no mutation |
| EOF / timeout / invalid | cancel-and-exit / cancel-and-exit / reprompt with hint |

### State: REVIEW
Renders evidence provenance per package: source type, URL (when safe), retrieval status, human-readable freshness, one-line reason, and the sanitized evidence snapshot (the same snapshot assessment used — never a refetch). Navigation: package index/name → that package's detail; `b` → back to DASHBOARD; `q` → exit 0; EOF/timeout → exit 0. Review is read-only; it never mutates records or any plan.

### State: SELECT
Per-package explicit selection over all packages. Defaults mirror Phase 1's tiering: no-signal preselected; attention (⚠) and unknown (?) never preselected — selecting them requires an explicit per-package affirmative (acceptance rule). Inputs: package index/name toggles; `b` → back to DASHBOARD **discarding the staged selection** (nothing persists); `Enter` → confirm staged set → UPGRADE with the named set; `q` → exit 0; EOF/timeout → exit 0.

### State: UPGRADE
Always and only `run_upgrade_with_preview <named set>` — the Phase 1 exact-plan boundary: `brew upgrade --dry-run` preview + dependency warning + y/N confirmation + `execute_upgrade`. No new execution path exists. On decline: return to DASHBOARD with the plan discarded (records unchanged). On completion: records re-derived from the post-upgrade inventory, return to DASHBOARD (an empty dashboard then shows "No outdated packages.").

**Invariant (acceptance):** no state or input reaches mutation except UPGRADE's `execute_upgrade`, which is reachable only after the exact-plan confirmation; attention/unknown reach it only via SELECT's explicit per-package selection.

## 2. Noninteractive behavior (T2.5.3)

- **Piped zero-argument invocation never prompts or upgrades** — output is exactly today's plain name list (research-004 §3.1; byte-identical, including the no-outdated message).
- **Dashboard renders only when stdout is a TTY**; `--dashboard` when piped is ignored in favor of plain output (ratified T2.6.1 ruling).
- **`-u` piped** keeps today's behavior: guidance + suggested command, never an upgrade.
- **Exit statuses stay conventional only:** 0 success/cancelled/declined; 1 misuse/operational failure; 130/143 signals. Attention/unknown classifications are data in output, never machine-significant exit statuses.
- **Output stability:** log-stable, not a promised machine API (a future schema is a Phase 5 adversarial-review question).
