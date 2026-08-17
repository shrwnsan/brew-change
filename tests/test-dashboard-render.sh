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

printf 'dashboard renderer: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
