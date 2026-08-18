# no-color / no-emoji variant

`expected.txt` is **byte-identical** to `mixed/expected.txt` (the test asserts
`cmp` equality). That is the design decision, not laziness:

- The base render carries **zero** color and **zero** emoji. Color and any
  emoji decoration are strictly additive overlays that the renderer may add on
  a TTY; they never carry meaning, so their absence changes nothing.
- This makes `NO_COLOR=1`, piped-through-`less`, screen readers, and
  copy-paste all produce the approved layout by construction, and it means the
  golden fixtures double as the accessibility fixtures (T3.3.1 will extend, not
  fork, them).
- Implementation note: if the TTY render adds color/emoji, the T2.3.2 renderer
  tests must generate the colored view from these same fixtures by applying the
  overlay, so a meaning change cannot hide behind styling.

Known cost: color users get no extra redundancy (e.g. a red attention glyph).
If the usability review (T3.4.1) wants emoji markers, they go in group headers
only, never in row reasons, and this fixture pair stays identical.
