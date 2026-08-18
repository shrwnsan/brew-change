# mixed — design notes (T2.3.1 golden fixture)

23 packages (the PRD's scannability bar): 3 attention, 18 no-signal, 2 unknown.

## Layout (nominal 80 columns, 2-space indent)

```
N outdated · A attention · B no-signal · C unknown      <- line 1, no "Summary:" prefix

Needs attention (A)                                     <- groups in fixed order
  <name> <inst> → <avail> <reason>
No risk signal found (B)
Unknown (C)

[r] Review details  [s] Select packages  [u] Upgrade no-signal (B)  [q] Quit
```

- Group order is always attention → no-signal → unknown (T2.3.2); empty
  groups are omitted entirely.
- Rows within a group are alphabetical by canonical package token.
- Group headers repeat the count so the summary line and body can be
  cross-checked at a glance.
- Column budget at 80 cols: 2 indent + name (width = longest name, min 12) +
  2 + versions (width = longest "inst → avail", capped at 26) + 2 + reason
  (remainder). There is no per-row classification label column — group
  headers already state the classification (ratified label-free redesign),
  and the reclaimed 17 columns widen the reason budget.
- Reason truncates with a single trailing "…" when it exceeds the remainder,
  preferring a token boundary (never mid-word when avoidable). One-line reason
  only; no release-note dumps — full evidence is reachable via
  `[r] Review details`.

## Differential reasons (ratified redesign)

Group headers already state the classification, so the row reason carries only
what differs *within* a group:

- **attention** rows show the matched signal token(s) from
  `matched_signals`, comma-joined (e.g. `major-version-transition`,
  `breaking-change-note`). If an attention record has no matched signals, the
  reason falls back to the first reason sentence, tail-preserving-truncated.
- **no-signal** rows carry no reason content at all — the row ends at the
  versions column (rstripped, no trailing padding).
- **unknown** rows show only the `retrieval_status` token — never a "…; …"
  status sentence — **except** when the token is exactly `unavailable`: that
  is the dominant no-action case and is suppressed (row ends at the
  versions). Rare actionable tokens (`rate-limited`, `stale`, `missing`,
  `malformed`, `unsupported`, `failed`) still render.

Full sentences remain in the `[r]` review view; only compact dashboard rows
changed.

## Labels (headers only, color-independent by construction)

- attention → group header `Needs attention`
- no-signal → group header `No risk signal found`
- unknown → group header `Unknown`

Rows carry no classification label (ratified label-free redesign): the
classification strings `Needs attention` / `No risk signal` / `Unknown` must
appear only in group headers, never inside a package row.

Unknown vs no-signal rows stay distinguishable without labels: separate
groups in fixed order, and unknown rows may carry an explicit non-unavailable
retrieval-status token while no-signal rows never carry reason content.

## Footer

Static action bar, last line, blank-line separated. `[u] Upgrade no-signal (B)`
appears only when B > 0 and its count must equal the no-signal group count and
the summary-line B.
