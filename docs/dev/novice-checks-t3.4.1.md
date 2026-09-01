# T3.4.1 — Novice Workflow Check Materials

**Status:** Prepared for maintainer; not yet run. This is a review-gate kit, not a
self-approval: the maintainer selects the participant, runs the session, records
results, and decides whether blocking failures exist before release.

**Task (tasks-003 §7):** Use scenario prompts rather than teaching the interface.
Verify a participant can explain: the difference between no-signal and unknown;
whether anything has been upgraded yet; how to review an attention result; how
to quit without changes; which packages will be upgraded after selection.
Confusions are recorded and prioritized; blocking comprehension failures are
corrected before release; feedback must not broaden Phase 3 into a GUI project.

## Session setup

Two supported environments; pick one per session (do not mix mid-session).

### A. Live inventory (simplest)

The participant runs on a real machine with outdated packages. Requires:
`brew-change` ≥ the Phase 3 build (Wave 1 + Wave 2 merged), a terminal ≥ 80
columns, and nothing else. The session is read-only unless a scenario reaches a
confirmed upgrade — Scenario 5 uses `--dry-run` or a declined confirmation, so
nothing installs.

### B. Deterministic demo (reproducible classifications)

Guarantees all three classifications appear regardless of the inventory:

```bash
# In the brew-change checkout (maintainer sets this up beforehand):
PATH="$(pwd)/tests/bin-demo:$PATH" brew-change -u
```

Maintainer preparation (once): create `tests/bin-demo/brew` dispatching
`outdated --json=v2` to a fixture with one attention (major-version gap, e.g.
node 22 → 25), one no-signal, and one unknown (rate-limited evidence) package,
and `info --json=v2` accordingly, mirroring the fake-brew pattern in
`tests/lib/test-utils.sh`. (If a fixture-based demo dir is preferred as a
permanent artifact, add it as a follow-up task — not required to run T3.4.1.)

## Scenario prompts (read verbatim to the participant)

Hand the participant the terminal fresh (no demo beforehand). After each
scenario, ask the follow-up question and write down their answer verbatim. Do
not teach, hint, or correct during the session; note everything for the record.

1. **Orientation.** "Run `brew-change -u` and tell me what you're looking at."
   Then: "Without pressing anything — if you closed this right now, would
   anything on your machine have changed?"

2. **no-signal vs unknown.** "Two groups here say 'No risk signal found' and
   'Unknown'. In your own words: what's the difference, and would you treat the
   packages in them the same way?"

3. **Attention review.** "One package is marked 'Needs attention'. Show me what
   changed for it and tell me why it's flagged." (Expect: `r` review → package
   detail → reads the reason + evidence.)

4. **Quit without changes.** "Quit the tool now. Did anything upgrade? How do
   you know?" (If a selection was staged in an earlier exploration, the re-entry
   hint should appear; ask what they think it means.)

5. **Which packages will upgrade.** "If you pressed Enter right now (or ran the
   upgrade action), exactly which packages would be upgraded — and where does
   the tool show you that list before anything runs?" (Run to the exact-plan
   preview with `--dry-run` or decline the confirmation; nothing installs.)

## Recording template (one row per observation)

| # | Scenario | Observation (verbatim) | Classification | Priority | Follow-up |
|---|----------|------------------------|----------------|----------|-----------|
|   |          |                        | comprehension / wording / flow / scope-creep | P0 blocking / P1 should-fix / P2 nice | task or PR |

## Prioritization rubric

- **P0 (blocking, must fix before release):** the participant cannot answer a
  minimum-check question after genuinely trying — e.g. cannot tell whether
  anything upgraded, or believes unknown packages are safe to bulk-upgrade.
- **P1 (should fix in this release):** wrong answer eventually self-corrected,
  or wording caused a visible stumble (record exact wording for T3.1.x polish).
- **P2 (backlog):** cosmetic or power-user wishes. GUI/menu-bar/daemon requests
  are recorded as Phase 4–5 input, per the task's non-broadening rule — they
  are not Phase 3 defects.

## Exit

Record results in tasks-003 under T3.4.1 (participant count, P0/P1/P2 counts,
verbatims or pointer to them). P0 items become tasks with fixes verified by the
same scenario before the release gate (T3.7.1) is marked passed.
