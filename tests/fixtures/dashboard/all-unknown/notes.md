# all-unknown

Four distinct unknown causes (unavailable, rate-limited, unsupported,
malformed). Per the ratified differential-reasons design the label is always
`Unknown` and the one-line reason is the **bare retrieval_status token** —
the distinct causes now render as distinct `^[a-z-]+$` tokens, never the
"Evidence retrieval status: …" sentence. No `[u] Upgrade no-signal` action
appears (B = 0) and the footer drops to
`[r] Review details  [s] Select packages  [q] Quit` — unknown packages are
never bulk-actionable.
