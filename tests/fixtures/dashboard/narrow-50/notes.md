# narrow-50 — 50-column word-aware reason truncation (T3.3.1)

Same 23-package input as `mixed` (and `narrow-60`), rendered at 50 columns
to pin the narrow-terminal readability rule added for T3.3.1:

- **Reason budget is 16** (fixed prefix 2+13+2+15+2 = 34): above the 12-char
  floor, so reasons still render — but the two kebab-case signal tokens no
  longer fit whole (`major-version-transition` is 24 chars,
  `breaking-change-note` is 20).
- **Truncation is word-aware for kebab tokens.** The signal vocabulary is
  `^[a-z-]+$`, so "word boundary" includes the hyphen: overflowing tokens cut
  at the last hyphen inside the budget and never mid-word. Before T3.3.1 this
  width produced the unreadable `major-version-tran…` /
  `breaking-chang…`; the approved bytes are now `major-version…` /
  `breaking…`, keeping the classification reason's leading words readable.
  Space-separated token lists keep the pre-existing behavior (drop the whole
  trailing partial token, see the `long` edge case in
  tests/test-dashboard-render.sh).
- The 12-char `rate-limited` unknown-status token fits untruncated.
- **Footer degrades twice**: `[s] Select packages` drops first (select stays
  reachable from review), then `[u] Upgrade no-signal (18)` (still reachable
  via review/selection); `[q] Quit` is never dropped.

Base render stays zero-color/zero-emoji like every scenario
(no-color/notes.md), so this fixture doubles as the narrow no-color view.
