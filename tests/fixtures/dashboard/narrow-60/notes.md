# narrow-60 — 60-column variant (same 23-package input as `mixed`)

Degradation ladder, applied table-wide (never per-row, so columns never
desynchronize):

1. **Reason column dropped** when the remainder for it falls below 12 chars.
   At 60 cols with this input the budget is 2+13+2+15+2+15 = 46, leaving 9 —
   so reasons are dropped and the label alone carries classification.
   Justification: the reason is the widest, least-dense column and is fully
   reachable via `[r] Review details`; the label is the classification
   contract and is never dropped.
2. **Versions column shrunk** toward a floor of 12, preserving the
   `inst → avail` structure (see long-names). Below the floor the versions
   column is dropped (name + label only).
3. **Footer degrades** by dropping `[s] Select packages` (select remains
   reachable from review) before anything else; `[q] Quit` is never dropped.

The summary line and group headers never degrade — they are the widest-legible
minimum of the view.
