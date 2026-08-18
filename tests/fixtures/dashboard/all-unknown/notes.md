# all-unknown

Four distinct unknown causes (unavailable, rate-limited, unsupported,
malformed). Per the ratified label-free design rows carry no classification
label; the one-line reason is the **bare retrieval_status token** —
`^[a-z-]+$`, never the "Evidence retrieval status: …" sentence — except that
`unavailable` (the dominant no-action case) is suppressed entirely: the
firefox row ends at its versions column. No `[u] Upgrade no-signal` action
appears (B = 0) and the footer drops to
`[r] Review details  [s] Select packages  [q] Quit` — unknown packages are
never bulk-actionable.
