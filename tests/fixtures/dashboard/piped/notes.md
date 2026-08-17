# piped — noninteractive variant (byte-identical to today's plain output)

## Contract

When stdout is not a TTY, `brew-change` emits **exactly** today's bare-invocation
output: the name-only outdated list, one canonical package token per line, in
Homebrew's reported order. No summary line, no groups, no labels, no footer, no
color, no progress animation, no prompting (research-004 §3.1: "Piped contract
is inviolable").

`expected.txt` here is literally `jq -r '.package' input.jsonl` — the test
suite asserts byte equality against that projection, so any drift (blank lines,
a header, CRLF, sorting change) fails.

## Open questions for the integrator (T2.5.3)

1. **Order.** The fixture defines order as the record-stream order (which today
   equals `brew outdated`'s order). If T2.1.2 re-orders records (e.g. for
   parallel batching), the piped renderer must re-derive Homebrew's original
   order or preserve it in the record. Proposal: preserve `brew outdated` order
   in the record stream.
2. **No outdated packages.** Today's bare run with zero outdated prints nothing
   (empty stdout, exit 0). The TTY fixture (`no-outdated`) says "No outdated
   packages." — the piped path must NOT adopt that message; it stays silent.
   The test only pins the non-empty case; integrator should pin the empty case
   against real `brew outdated` behavior.
3. **`--dashboard` when piped.** Explicit `--dashboard` with a pipe should
   still render plain output (view is TTY-gated, not flag-gated) — confirm in
   T2.5.3/T2.6.2.
