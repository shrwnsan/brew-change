# long-names — degradation without corrupting columns

Input stresses all three width axes: a 44-char canonical cask token
(`visual-studio-code-insiders@nightly-channel`), a 15-char version, and a
34-char name sibling (`some-other-quite-long-formula-name`).

Rules exercised (in priority order):

1. **Package names win space.** Names are canonical Homebrew tokens used for
   review and for the exact upgrade plan — they are never truncated and never
   wrapped. The name column simply widens to the longest name present.
2. **Reasons pay first.** With a 44-char name the reason budget falls below
   the 12-char floor, so the reason column is dropped table-wide (rows keep
   name + versions only, aligned; there is no per-row label column under the
   ratified label-free redesign).
3. **Versions truncate structurally.** The versions column caps at 26 chars;
   when "inst → avail" exceeds it, each side is truncated independently with
   "…" while the " → " arrow is always preserved (`2026.08.15… → 2026.08.16…`),
   so the
   installed→available direction is never lost. Below a 9-char budget the
   whole column would be dropped instead.
4. Padding is **character-based**, not byte-based: "→" and "…" are multi-byte.
   `printf '%-15s'` pads by bytes and visibly corrupts columns — the
   production renderer (T2.3.2) must pad/truncate by characters (e.g. bash
   `${s:0:n}` + manual padding, never `printf %-Ns` on fields containing
   non-ASCII).
