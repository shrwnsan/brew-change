#!/usr/bin/env bash
# tasks-004 Task 1 — -b end-of-run verdict summary.
#
# Deterministic assertions:
#   1. Renderer goldens: mixed and all-clear classified record sets render
#      byte-exact verdict blocks (honest three-state vocabulary, breaking
#      rows with evidence excerpts, counts-only no-signal/unknown groups).
#   2. Renderer properties: breaking wins over major when both signals
#      match; rows sort alphabetically within groups; excerpts truncate at
#      a 72-char word boundary; base render is text-only (no emoji bytes)
#      and byte-identical under NO_COLOR=1; malformed lines are skipped,
#      not fatal; a missing/empty record file renders nothing.
#   3. Pipeline: inventory init + evidence appends + classify_upgrade_evidence
#      feed the renderer (same stage boundary -u uses).
#   4. Launcher: a piped -b run under the fake brew/curl harness prints the
#      verdict after "Completed processing" and before the "Run 'brew
#      upgrade'" line; -a alone prints no verdict; -u keeps its plain
#      non-interactive contract (regression: the -b status-dir reuse must
#      not leak into upgrade mode); NO_COLOR=1 output is byte-identical.
#
# Usage: bash tests/test-b-verdict-summary.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/verdict"
HOMEBREW_FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"
BREW_CHANGE="$PROJECT_DIR/brew-change"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test-utils.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
        ((fail++))
    fi
}

assert_contains() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected to contain '$expected')"
        ((fail++))
    fi
}

assert_not_contains() {
    local desc="$1" unexpected="$2" actual="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (should not contain '$unexpected')"
        ((fail++))
    fi
}

assert_file_eq() {
    local desc="$1" expected_file="$2" actual_file="$3"
    if diff -u "$expected_file" "$actual_file" >/tmp/verdict-diff.$$ 2>&1; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc"
        cat /tmp/verdict-diff.$$ >&2
        ((fail++))
    fi
    rm -f /tmp/verdict-diff.$$
}

WARNING_BYTES=$'⚠️'

# Source only what the pure renderer needs.
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-utils.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-breaking.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-verdict.sh"

echo "======================================"
echo "-b Verdict Summary Tests (tasks-004 Task 1)"
echo "======================================"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 1: renderer goldens ==="
echo ""

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/brew-change-verdict.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

render_verdict_summary "$FIXTURE_DIR/mixed/input.jsonl" > "$tmpdir/mixed.out" 2>"$tmpdir/mixed.err"
assert_eq "mixed renderer exit status" "0" "$?"
assert_file_eq "mixed golden byte-exact" "$FIXTURE_DIR/mixed/expected.txt" "$tmpdir/mixed.out"

render_verdict_summary "$FIXTURE_DIR/all-clear/input.jsonl" > "$tmpdir/all-clear.out" 2>"$tmpdir/all-clear.err"
assert_eq "all-clear renderer exit status" "0" "$?"
assert_file_eq "all-clear golden byte-exact" "$FIXTURE_DIR/all-clear/expected.txt" "$tmpdir/all-clear.out"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: renderer properties ==="
echo ""

mixed_out="$(cat "$tmpdir/mixed.out")"

# Breaking wins over major: ripgrep carries both signals and must appear only
# under Breaking changes; the major group count stays at vercel alone.
ripgrep_hits="$(grep -c "ripgrep" <<< "$mixed_out")"
assert_eq "both-signals row appears once (Breaking wins)" "1" "$ripgrep_hits"
assert_contains "both-signals row is in the breaking group" $'Breaking changes (3)\n  abseil' "$mixed_out"
assert_contains "major group holds only the major-only row" $'Major version transitions (1)\n  vercel 58.9.0 → 59.1.4' "$mixed_out"

# Rows alphabetical within groups (excerpt lines interleave the row lines,
# so compare the package-row lines on their own).
breaking_row_order="$(grep -E '^  [^ ]+ [^ ]+ → ' <<< "$mixed_out" | head -3 | awk '{print $1}' | tr '\n' ' ')"
assert_eq "breaking rows alphabetical" "abseil nnn ripgrep " "$breaking_row_order"

# Excerpt truncation: 72-char word boundary with ellipsis.
assert_contains "long excerpt truncated at word boundary" "std::void_t…" "$mixed_out"

# Base render is text-only: no emoji bytes, and NO_COLOR is byte-identical.
assert_not_contains "base render carries no emoji" "$WARNING_BYTES" "$mixed_out"
NO_COLOR=1 render_verdict_summary "$FIXTURE_DIR/mixed/input.jsonl" > "$tmpdir/mixed-nocolor.out"
assert_file_eq "NO_COLOR output byte-identical" "$tmpdir/mixed.out" "$tmpdir/mixed-nocolor.out"

# All-clear wording never claims safety and always discloses unknowns.
all_clear_out="$(cat "$tmpdir/all-clear.out")"
assert_contains "all-clear names what was not detected" "No breaking-change patterns or major version transitions detected across 3 packages." "$all_clear_out"
assert_contains "all-clear still discloses unknowns" "Unknown (1) — no usable release notes; review individually" "$all_clear_out"
assert_not_contains "no safe-to-upgrade claim" "safe" "$all_clear_out"

# Malformed lines are skipped without failing the render.
{
    cat "$FIXTURE_DIR/mixed/input.jsonl"
    printf '%s\n' 'this is not json'
} > "$tmpdir/malformed.jsonl"
render_verdict_summary "$tmpdir/malformed.jsonl" > "$tmpdir/malformed.out" 2>/dev/null
assert_eq "malformed line skipped, exit status" "0" "$?"
assert_file_eq "malformed line does not alter output" "$tmpdir/mixed.out" "$tmpdir/malformed.out"

# Missing / empty record files render nothing (caller skips the block).
render_verdict_summary "$tmpdir/does-not-exist.jsonl" > "$tmpdir/missing.out" 2>/dev/null
assert_eq "missing file exit status" "0" "$?"
assert_eq "missing file renders nothing" "" "$(cat "$tmpdir/missing.out")"
: > "$tmpdir/empty.jsonl"
render_verdict_summary "$tmpdir/empty.jsonl" > "$tmpdir/empty.out" 2>/dev/null
assert_eq "empty file renders nothing" "" "$(cat "$tmpdir/empty.out")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: pipeline feeds the renderer ==="
echo ""

setup_command_harness || exit 1
export BREW_CHANGE_SUBPROCESS="true"
export BREW_CHANGE_CACHE_DIR="$COMMAND_HARNESS_ROOT/cache"
mkdir -p "$BREW_CHANGE_CACHE_DIR"

# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-config.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-assessment.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-brew.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-upgrade.sh"

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-change-verdict-run.XXXXXX")"
export UPGRADE_STATUS_DIR="$run_dir"

assessment_record_init "$run_dir" "$(cat "$HOMEBREW_FIXTURE_DIR/outdated-mixed.json")"
append_assessment_evidence "node" "github" "https://github.com/nodejs/node/releases/tag/v22.8.0" \
    "1755648000" "fresh" "## Breaking Changes
- Removed support for legacy --trace flags."
append_assessment_evidence "rectangle" "github" "https://github.com/rxhanson/Rectangle/releases/tag/v0.92" \
    "1755648000" "fresh" "Added a hover badge and switcher for stacked windows."
# claude-code gets no evidence row: classify synthesizes it as unknown.

classify_upgrade_evidence "$run_dir" node rectangle claude-code
pipeline_out="$(render_verdict_summary "$run_dir/assessment.jsonl")"
assert_contains "pipeline verdict counts" "Verdict: 1 attention · 1 no-signal · 1 unknown" "$pipeline_out"
assert_contains "pipeline breaking row" "  node 22.6.0 → 22.8.0" "$pipeline_out"
assert_contains "pipeline no-signal row absent by design (counts only)" "No risk signal found (1)" "$pipeline_out"
assert_contains "pipeline synthesized unknown counted" "Unknown (1) — no usable release notes; review individually" "$pipeline_out"

unset UPGRADE_STATUS_DIR
rm -rf "$run_dir"
teardown_command_harness

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 4: launcher integration (piped -b) ==="
echo ""

run_brew_change_piped() {
    setup_command_harness
    configure_fake_command brew "$HOMEBREW_FIXTURE_DIR/outdated-mixed.json" "" 0
    configure_fake_command curl "" "" 0
    mkdir -p "$COMMAND_HARNESS_ROOT/cache"
    local env_prefix="$1"; shift
    local stderr_file="$COMMAND_HARNESS_ROOT/bc-stderr"
    local stdout_file="$COMMAND_HARNESS_ROOT/bc-stdout"
    local exit_code=0
    # Isolate every brew-change cache to this harness run (a warm user
    # cache would hand the launcher real release notes) and drop the
    # worker-mode marker suite 3 exported: the launcher must run as a
    # fresh top-level process or config.sh skips the cleanup/trap block
    # (register_temp_dir et al.) and dies with 127. Job count is pinned so
    # the "max N jobs" line cannot vary with machine load.
    # shellcheck disable=SC2086
    env -u BREW_CHANGE_SUBPROCESS \
        BREW_CHANGE_CACHE_DIR="$COMMAND_HARNESS_ROOT/cache" \
        BREW_CHANGE_JOBS=4 \
        $env_prefix \
        "$BREW_CHANGE" "$@" >"$stdout_file" 2>"$stderr_file" </dev/null || exit_code=$?
    RUN_BC_EXIT="$exit_code"
    RUN_BC_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_BC_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    teardown_command_harness
}

# Normalize wall-clock-dependent bytes so full-output byte comparisons are
# stable across runs: the duration line, and the parallel job count — the
# load-based auto-adjust can halve the pinned jobs on a busy runner
# between the two compared invocations.
normalize_run_output() {
    sed -e 's/^Completed processing \([0-9]\{1,\}\) packages in [0-9]\{1,\}s$/Completed processing \1 packages in Ns/' \
        -e 's/Processing \([0-9]\{1,\}\) packages in parallel (max [0-9]\{1,\} jobs)/Processing \1 packages in parallel (max N jobs)/'
}

echo "Test 1: piped -b ends with the verdict block"
run_brew_change_piped "" -b
assert_eq "piped -b exit code" "0" "$RUN_BC_EXIT"
assert_contains "-b prints the verdict summary" "Verdict: 0 attention · 0 no-signal · 3 unknown" "$RUN_BC_STDOUT"
assert_contains "-b all-clear line names scope" "No breaking-change patterns or major version transitions detected across 3 packages." "$RUN_BC_STDOUT"
assert_contains "-b unknown disclosure" "Unknown (3) — no usable release notes; review individually" "$RUN_BC_STDOUT"

# Placement: after the completion line, before the generic upgrade hint.
completed_line=$(grep -n "^Completed processing" <<< "$RUN_BC_STDOUT" | head -1 | cut -d: -f1)
verdict_line=$(grep -n "^Verdict:" <<< "$RUN_BC_STDOUT" | head -1 | cut -d: -f1)
hint_line=$(grep -n "^Run 'brew upgrade'" <<< "$RUN_BC_STDOUT" | head -1 | cut -d: -f1)
if [[ -n "$completed_line" && -n "$verdict_line" && -n "$hint_line" \
        && "$completed_line" -lt "$verdict_line" && "$verdict_line" -lt "$hint_line" ]]; then
    echo -e "${GREEN}PASS${NC}: verdict sits between completion and upgrade hint"
    ((pass++))
else
    echo -e "${RED}FAIL${NC}: verdict placement (completed=$completed_line verdict=$verdict_line hint=$hint_line)" >&2
    ((fail++))
fi

echo ""
echo "Test 2: NO_COLOR -b is byte-identical to the base render"
run_brew_change_piped "" -b
plain_b_stdout="$(normalize_run_output <<< "$RUN_BC_STDOUT")"
run_brew_change_piped "NO_COLOR=1" -b
assert_eq "NO_COLOR -b byte-identical" "$plain_b_stdout" "$(normalize_run_output <<< "$RUN_BC_STDOUT")"
assert_not_contains "-b base render has no emoji" "$WARNING_BYTES" "$plain_b_stdout"

echo ""
echo "Test 3: -a without -b prints no verdict (scope guard)"
run_brew_change_piped "" -a
assert_eq "piped -a exit code" "0" "$RUN_BC_EXIT"
assert_not_contains "-a alone has no verdict block" "Verdict:" "$RUN_BC_STDOUT"

echo ""
echo "Test 4: -u keeps its non-interactive contract (no verdict leak)"
run_brew_change_piped "" -u
assert_eq "piped -u exit code" "0" "$RUN_BC_EXIT"
assert_contains "-u plain contract unchanged" "Non-interactive mode. Upgrade skipped." "$RUN_BC_STDOUT"
assert_not_contains "-u has no verdict block" "Verdict:" "$RUN_BC_STDOUT"

# ---------------------------------------------------------------------------
echo ""
printf 'Verdict summary tests: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
