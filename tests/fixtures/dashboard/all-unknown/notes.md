# all-unknown

Four distinct unknown causes (unavailable, rate-limited, unsupported,
malformed) so the label-vs-reason split is visible: the label is always
`Unknown`; the one-line reason states the evidence failure. No `[u] Upgrade
no-signal` action appears (B = 0) and the footer drops to
`[r] Review details  [s] Select packages  [q] Quit` — unknown packages are
never bulk-actionable. Two reasons truncate with "…" at 80 cols, exercising
the reason-ellipsis rule.
