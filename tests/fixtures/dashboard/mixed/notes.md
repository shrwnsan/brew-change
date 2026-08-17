# mixed — design notes (T2.3.1 golden fixture)

23 packages (the PRD's scannability bar): 3 attention, 18 no-signal, 2 unknown.

## Layout (nominal 80 columns, 2-space indent)

```
N outdated · A attention · B no-signal · C unknown      <- line 1, no "Summary:" prefix

Needs attention (A)                                     <- groups in fixed order
  <name> <inst> → <avail> <label> <reason>
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
  2 + versions (width = longest "inst → avail", capped at 26) + 2 + label
  (fixed 15) + 2 + reason (remainder).
- Reason truncates with a single trailing "…" when it exceeds the remainder
  (see `node` / `ffmpeg` rows). One-line reason only; no release-note dumps —
  full evidence is reachable via `[r] Review details`.

## Labels (color-independent by construction)

- attention → `Needs attention`
- no-signal → group header `No risk signal found`, row label `No risk signal`
- unknown → group header `Unknown`, row label `Unknown`; the one-line reason
  always states *why* evidence was insufficient (e.g. "Release notes
  unavailable", "Rate limited; no usable cache").

Unknown vs no-signal can never be confused: different group, different label
word, and every unknown row carries an explicit evidence-failure reason while
every no-signal row carries an evidence-checked reason.

## Footer

Static action bar, last line, blank-line separated. `[u] Upgrade no-signal (B)`
appears only when B > 0 and its count must equal the no-signal group count and
the summary-line B.
