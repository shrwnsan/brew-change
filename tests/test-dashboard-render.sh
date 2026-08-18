#!/usr/bin/env bash
# T2.3.2 — static grouped dashboard renderer conformance.
#
# Runs render_dashboard_records (lib/brew-change-dashboard.sh) against every
# golden fixture input and diffs the output byte-exactly against the approved
# expected.txt, plus invariance checks (piped stdout, NO_COLOR) and pure-output
# assertions (no side effects, exit 0).
#
# Usage: bash tests/test-dashboard-render.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/dashboard"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-dashboard.sh"

passed=0
failed=0

pass() { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# TTY-view scenarios: fixture dir -> terminal width budget.
SCENARIOS="mixed:80 all-no-signal:80 all-unknown:80 long-names:80 narrow-60:60 no-color:80 no-outdated:80"

# --- Byte-exact conformance against every golden fixture --------------------

for s in $SCENARIOS; do
    name="${s%%:*}"
    width="${s##*:}"
    dir="$FIXTURE_DIR/$name"

    if render_dashboard_records "$dir/input.jsonl" "$width" \
        | diff -u "$dir/expected.txt" - >/dev/null; then
        pass
    else
        fail "$name: render differs from expected.txt"
        render_dashboard_records "$dir/input.jsonl" "$width" \
            | diff -u "$dir/expected.txt" - | head -20 >&2
    fi
done

# no-color invariance: NO_COLOR=1 must not change a single byte (the base
# render carries no color by construction; overlays are future work).
if NO_COLOR=1 render_dashboard_records "$FIXTURE_DIR/mixed/input.jsonl" 80 \
    | cmp -s - "$FIXTURE_DIR/no-color/expected.txt"; then
    pass
else
    fail "NO_COLOR=1 render differs from no-color/expected.txt"
fi

# Piped invariance: rendering through a pipe (non-TTY stdout) is identical
# to capturing to a file — the static renderer must not detect or branch on
# the output target.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

render_dashboard_records "$FIXTURE_DIR/mixed/input.jsonl" 80 > "$tmpdir/to-file.txt"
render_dashboard_records "$FIXTURE_DIR/mixed/input.jsonl" 80 | cat > "$tmpdir/through-pipe.txt"
if cmp -s "$tmpdir/to-file.txt" "$tmpdir/through-pipe.txt" \
    && cmp -s "$tmpdir/to-file.txt" "$FIXTURE_DIR/mixed/expected.txt"; then
    pass
else
    fail "piped stdout render differs from file-captured render"
fi

# --- Purity: no side effects, clean exit -------------------------------------

purity_dir="$tmpdir/purity"
mkdir -p "$purity_dir"
before="$(ls -A "$purity_dir")"

if render_dashboard_records "$FIXTURE_DIR/mixed/input.jsonl" 80 \
    > "$purity_dir/stdout.txt" 2> "$purity_dir/stderr.txt"; then
    pass
else
    fail "renderer returned nonzero exit"
fi
if [[ -s "$purity_dir/stderr.txt" ]]; then
    fail "renderer wrote to stderr"
else
    pass
fi
after="$(ls -A "$purity_dir")"
if [[ -z $before && $after == $'stderr.txt\nstdout.txt' ]]; then
    pass
else
    fail "renderer wrote unexpected files: $after"
fi

# No ANSI escapes anywhere in any scenario render.
# shellcheck disable=SC2086
if ! printf '%s\n' $SCENARIOS | while IFS=: read -r n w; do
        render_dashboard_records "$FIXTURE_DIR/$n/input.jsonl" "$w"
    done | grep -q $'\x1b'; then
    pass
else
    fail "render contains ANSI escape sequences"
fi

# Default width is 80 (same render as the explicit-width call).
if render_dashboard_records "$FIXTURE_DIR/mixed/input.jsonl" \
    | cmp -s - "$FIXTURE_DIR/mixed/expected.txt"; then
    pass
else
    fail "default width render differs from 80-column expected.txt"
fi

# Missing input file is a clean error, not a crash.
if ! render_dashboard_records "$tmpdir/does-not-exist.jsonl" >/dev/null 2>&1; then
    pass
else
    fail "missing record file must fail"
fi

# The piped (non-TTY) CLI contract is names-only; the same records rendered
# as a dashboard must still match the approved 80-column view.
if render_dashboard_records "$FIXTURE_DIR/piped/input.jsonl" 80 \
    | cmp -s - "$FIXTURE_DIR/mixed/expected.txt"; then
    pass
else
    fail "piped-scenario records must dashboard-render identically to mixed"
fi

# --- Differential reasons: edge cases on generated records -------------------
#
# Group headers state the classification, so row reasons carry only what
# differs within a group: attention -> matched signal tokens (comma-joined,
# first-reason tail-preserving fallback when matched_signals is empty),
# no-signal -> nothing, unknown -> the bare retrieval_status token.

diffdir="$tmpdir/diff-reasons"
mkdir -p "$diffdir"

# Multiple signals, empty-signals fallback, no-signal row, unknown status row.
cat > "$diffdir/edge.jsonl" <<'EOF'
{"package":"fallback","display_name":"fallback","kind":"formula","installed_version":"1.0.0","available_version":"2.0.0","evidence_source":"github","evidence_url":null,"retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":null,"classification":"attention","reasons":["A fairly long fallback reason sentence"],"matched_signals":[],"assessment_recommendation":false,"operational_eligibility":true,"default_selected":false}
{"package":"multi","display_name":"multi","kind":"formula","installed_version":"1.0.0","available_version":"2.0.0","evidence_source":"github","evidence_url":null,"retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":null,"classification":"attention","reasons":["Reason one","Reason two"],"matched_signals":["breaking-change","major-version"],"assessment_recommendation":false,"operational_eligibility":true,"default_selected":false}
{"package":"nosig","display_name":"nosig","kind":"formula","installed_version":"1.0.0","available_version":"2.0.0","evidence_source":"github","evidence_url":null,"retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":null,"classification":"no-signal","reasons":["Release notes checked"],"matched_signals":[],"assessment_recommendation":true,"operational_eligibility":true,"default_selected":true}
{"package":"weird","display_name":"weird","kind":"cask","installed_version":"1.0","available_version":"1.1","evidence_source":"vendor","evidence_url":null,"retrieved_at":null,"retrieval_status":"stale","evidence_snapshot":null,"classification":"unknown","reasons":["Evidence is stale"],"matched_signals":[],"assessment_recommendation":false,"operational_eligibility":true,"default_selected":false}
{"package":"gone","display_name":"gone","kind":"formula","installed_version":"1.0.0","available_version":"2.0.0","evidence_source":"none","evidence_url":null,"retrieved_at":null,"retrieval_status":"unavailable","evidence_snapshot":null,"classification":"unknown","reasons":["Evidence unavailable"],"matched_signals":[],"assessment_recommendation":false,"operational_eligibility":true,"default_selected":false}
EOF

edge_out="$diffdir/edge.txt"
render_dashboard_records "$diffdir/edge.jsonl" 80 > "$edge_out"

# attention with multiple signals: comma-joined tokens, verbatim.
line=$(grep '  multi ' "$edge_out")
if [[ $line == *'  breaking-change, major-version' ]]; then
    pass
else
    fail "multiple signals not comma-joined in: '$line'"
fi

# attention with empty matched_signals: first reason rendered (label-free
# layout widens the reason budget, so the sentence now fits untruncated).
line=$(grep '  fallback ' "$edge_out")
if [[ $line == *'A fairly long fallback reason sentence' ]]; then
    pass
else
    fail "empty-signals fallback reason not rendered: '$line'"
fi

# no-signal row: no reason content; row ends at the versions column.
line=$(grep '  nosig ' "$edge_out")
if [[ $line =~ ^\ \ nosig\ +1\.0\.0\ →\ 2\.0\.0$ ]]; then
    pass
else
    fail "no-signal row carries reason content: '$line'"
fi

# unknown row with a non-unavailable status: bare retrieval_status token
# (^([a-z-]+)$ vocabulary).
line=$(grep '  weird ' "$edge_out")
if [[ $line =~ ^\ \ weird\ +1\.0\ →\ 1\.1\ +stale$ ]]; then
    pass
else
    fail "unknown row reason is not the bare status token: '$line'"
fi

# unknown row with status exactly "unavailable": token suppressed, row ends
# at the versions column (ratified label-free redesign).
line=$(grep '  gone ' "$edge_out")
if [[ $line =~ ^\ \ gone\ +1\.0\.0\ →\ 2\.0\.0$ ]]; then
    pass
else
    fail "unknown unavailable row must show no token: '$line'"
fi

# Label-free rows: the classification strings appear only in group headers,
# never inside a package row (any group, any fixture render).
bad_label=""
# shellcheck disable=SC2086
while IFS=: read -r n w; do
    bad_label+="$(render_dashboard_records "$FIXTURE_DIR/$n/input.jsonl" "$w" \
        | awk '/^  [^ ]/ && /Needs attention|No risk signal|Unknown/')"
done < <(printf '%s\n' $SCENARIOS)
if [[ -z $bad_label ]]; then
    pass
else
    fail "package row carries a classification label: '$bad_label'"
fi

# Joined token list overflowing the budget: single "…", cut at a token
# boundary (never mid-token when avoidable).
cat > "$diffdir/long.jsonl" <<'EOF'
{"package":"aa","display_name":"aa","kind":"formula","installed_version":"1.0.0","available_version":"2.0.0","evidence_source":"github","evidence_url":null,"retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":null,"classification":"attention","reasons":["Reason"],"matched_signals":["alpha-signal-token","beta-signal-token","gamma-signal-token"],"assessment_recommendation":false,"operational_eligibility":true,"default_selected":false}
EOF
long_out="$diffdir/long.txt"
render_dashboard_records "$diffdir/long.jsonl" 80 > "$long_out"
line=$(grep '  aa ' "$long_out")
n_ell=$(printf '%s' "$line" | grep -o '…' | wc -l)
if [[ $line == *'alpha-signal-token, beta-signal-token…' && $line != *gamma* && $n_ell -eq 1 ]]; then
    pass
else
    fail "overflowing token list not truncated at a token boundary: '$line'"
fi

printf 'dashboard renderer: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
