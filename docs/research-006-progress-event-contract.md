# T2.4.1 — Progress Event Contract (Decision Record)

**Status:** Approved by integrator (2026-08-18), pending maintainer visibility
**Decides:** How pipeline workers report progress without ever drawing terminal frames.

## Contract

Workers append single-line JSON events to `progress.jsonl` in the per-run status dir (same atomic-append guarantee as `assessment.jsonl`; compact line < PIPE_BUF):

```json
{"stage":"evidence","completed":7,"total":23,"package":"node"}
```

- **`stage`**: one of `inventory` | `evidence` | `classify`. Fixed vocabulary; renderer ignores unknown stages (forward compatibility).
- **`completed`**: the worker's local completion ordinal for the stage. NOT a global count — the renderer derives the global monotonic count as the number of events for the stage (dedup by package where present).
- **`total`**: fixed stage total, identical on every event of a stage.
- **`package`**: optional label; present for `evidence`/`classify` stages.

## Rules

1. **Workers never write to the terminal.** All drawing, rate-limiting, cursor and mode management belongs to the single T2.4.2 renderer, which tails `progress.jsonl`.
2. **Redraw rate is renderer-owned** (bounded), not worker-owned.
3. **No animation when stdout is not a TTY** or `BREW_CHANGE_PARALLEL_MODE=true` (test mode): events are still written (cheap, keeps behavior uniform); the renderer simply does not animate. This matches the ratified T2.6.1 stdout-TTY gating.
4. **Monotonicity** is a renderer invariant: displayed completed counts never decrease; final frame must equal `total` before clearing.
5. Progress events are ephemeral (run status dir), never part of `assessment.jsonl`, never a user API.
