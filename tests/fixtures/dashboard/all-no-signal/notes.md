# all-no-signal

Every row is `no-signal`: only that group is rendered; attention and unknown
headers are omitted (not "Attention (0)"). The footer shows
`[u] Upgrade no-signal (4)` and its count must equal the group header and the
summary line. Per the ratified differential-reasons design, no-signal rows
carry **no reason content at all** — nothing differs within the group, so
rows end at the versions column (there is no per-row classification label;
the ratified label-free redesign removed it). The group
header (not each row) states that evidence was checked and no risk signal was
found; full per-package detail stays reachable via `[r] Review details`.
