#!/usr/bin/env bash
# Deterministic logic tests for the T2.4.2 progress renderer.
#
# Covers the event-contract rules that do not require a PTY:
# monotonic counts, package dedup, malformed-line tolerance, stage reset,
# and silent (no-animation) consumption when stdout is not a TTY.
# Animation/terminal-safety behavior is covered by the PTY suite invoked
# at the end of this script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/../lib" && pwd)"
BASH_BIN="${BASH:-bash}"

pass_count=0
fail_count=0

run_case() {
    local name="$1"
    shift
    if "$@"; then
        printf 'PASS: %s\n' "$name"
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL: %s\n' "$name" >&2
        fail_count=$((fail_count + 1))
    fi
}

# Run render_progress against a synthetic progress.jsonl with stdout piped
# (never a TTY in this harness) and echo the dump variables for assertions.
run_renderer() {
    local run_dir="$1"
    BREW_CHANGE_PROGRESS_DUMP=1 \
        BREW_CHANGE_PROGRESS_IDLE_US=60000 \
        BREW_CHANGE_PROGRESS_STALL_US=60000 \
        "$BASH_BIN" -c "set -u; source '$LIB/brew-change-progress.sh'; render_progress \"\$1\" </dev/null" _ "$run_dir"
}

make_run_dir() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/bc-progress.XXXXXX")"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

test_count_is_monotonic_event_count() {
    local run_dir
    run_dir="$(make_run_dir)"
    {
        # Worker ordinals go backwards; display must still count events.
        echo '{"stage":"evidence","completed":3,"total":3,"package":"node"}'
        echo '{"stage":"evidence","completed":2,"total":3,"package":"git"}'
        echo '{"stage":"evidence","completed":1,"total":3,"package":"jq"}'
    } > "$run_dir/progress.jsonl"
    local out
    out="$(run_renderer "$run_dir")"
    trash "$run_dir" 2>/dev/null || rm -rf "$run_dir"
    [[ "$out" == *"STAGE=evidence COUNT=3 TOTAL=3"* ]]
}

test_dedup_by_package() {
    local run_dir
    run_dir="$(make_run_dir)"
    {
        echo '{"stage":"classify","completed":1,"total":2,"package":"node"}'
        echo '{"stage":"classify","completed":2,"total":2,"package":"node"}'
        echo '{"stage":"classify","completed":2,"total":2,"package":"git"}'
    } > "$run_dir/progress.jsonl"
    local out
    out="$(run_renderer "$run_dir")"
    trash "$run_dir" 2>/dev/null || rm -rf "$run_dir"
    [[ "$out" == *"STAGE=classify COUNT=2 TOTAL=2"* ]]
}

test_malformed_lines_are_skipped() {
    local run_dir
    run_dir="$(make_run_dir)"
    {
        echo 'not json at all'
        echo '{"stage":"evidence"}'
        echo '{"stage":"evidence","completed":"x","total":2}'
        echo '{"stage":"secret-stage","completed":1,"total":1}'
        echo '{"stage":"inventory","completed":1,"total":2}'
        echo '{"stage":"inventory","completed":2,"total":2}'
    } > "$run_dir/progress.jsonl"
    local out
    out="$(run_renderer "$run_dir")"
    trash "$run_dir" 2>/dev/null || rm -rf "$run_dir"
    [[ "$out" == *"STAGE=inventory COUNT=2 TOTAL=2"* ]]
}

test_stage_transition_resets_state() {
    local run_dir
    run_dir="$(make_run_dir)"
    {
        echo '{"stage":"inventory","completed":1,"total":1}'
        echo '{"stage":"evidence","completed":1,"total":2,"package":"node"}'
        echo '{"stage":"evidence","completed":2,"total":2,"package":"node"}'
        # Same package in the new stage must be counted again after reset.
        echo '{"stage":"classify","completed":1,"total":1,"package":"node"}'
    } > "$run_dir/progress.jsonl"
    local out
    out="$(run_renderer "$run_dir")"
    trash "$run_dir" 2>/dev/null || rm -rf "$run_dir"
    [[ "$out" == *"STAGE=classify COUNT=1 TOTAL=1"* ]]
}

test_missing_file_is_noop() {
    local run_dir
    run_dir="$(make_run_dir)"
    local out status
    set +e
    out="$(run_renderer "$run_dir")"
    status=$?
    set -e
    trash "$run_dir" 2>/dev/null || rm -rf "$run_dir"
    [[ $status -eq 0 && -z "$out" ]]
}

test_non_tty_emits_no_frames() {
    local run_dir
    run_dir="$(make_run_dir)"
    {
        echo '{"stage":"evidence","completed":1,"total":5,"package":"node"}'
        echo '{"stage":"evidence","completed":2,"total":5,"package":"git"}'
    } > "$run_dir/progress.jsonl"
    local out
    out="$(run_renderer "$run_dir")"
    trash "$run_dir" 2>/dev/null || rm -rf "$run_dir"
    # Only the test-only dump marker may appear; no spinner or frame text.
    [[ "$out" == *"STAGE=evidence COUNT=2 TOTAL=5"* ]] \
        && [[ "$out" != *$'\r'* ]] \
        && [[ "$out" != *"⠋"* ]]
}

run_case "monotonic count derived from events" test_count_is_monotonic_event_count
run_case "dedup by package" test_dedup_by_package
run_case "malformed lines skipped" test_malformed_lines_are_skipped
run_case "stage transition resets state" test_stage_transition_resets_state
run_case "missing progress file is a no-op" test_missing_file_is_noop
run_case "non-tty run emits no frames" test_non_tty_emits_no_frames

# PTY animation and terminal-safety suite (single deterministic entry point).
printf '\n--- progress renderer PTY ---\n'
if python3 "$SCRIPT_DIR/test-progress-renderer.py"; then
    pass_count=$((pass_count + 1))
else
    printf 'FAIL: progress renderer PTY\n' >&2
    fail_count=$((fail_count + 1))
fi

printf '\nProgress renderer suites: %d passed, %d failed\n' "$pass_count" "$fail_count"
[[ $fail_count -eq 0 ]]
