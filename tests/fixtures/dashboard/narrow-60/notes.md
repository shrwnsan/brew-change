# narrow-60 — 60-column variant (same 23-package input as `mixed`)

Degradation ladder, applied table-wide (never per-row, so columns never
desynchronize):

1. **Reason column survives at 60 cols.** Removing the per-row classification
   label column (ratified label-free redesign: group headers already state
   the classification) reclaimed 17 columns. The fixed prefix is now
   2+13+2+15+2 = 34, leaving a reason budget of 26 — comfortably above the
   12-char floor — so compact signal/status tokens still render at 60 cols
   (the label-era fixture dropped them with only 9). Below 12 the reason
   column is still dropped first; it remains fully reachable via
   `[r] Review details`.
2. **Versions column shrunk** toward a floor of 12, preserving the
   `inst → avail` structure (see long-names). Below the floor the versions
   column is dropped (name only).
3. **Footer degrades** by dropping `[s] Select packages` (select remains
   reachable from review) before anything else; `[q] Quit` is never dropped.

The summary line and group headers never degrade — they are the widest-legible
minimum of the view.
