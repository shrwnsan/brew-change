#!/usr/bin/env bash
# Tests for signal cleanup and EXIT handler integrity (Task 6).
#
# Validates:
#   _bc_on_TERM exits 143; temp files/dirs removed; children killed + reaped
#   _bc_on_INT exits 130; temp files/dirs removed; children killed + reaped
#   _bc_on_EXIT preserves existing exit status (0, 1, 42, 130)
#   cleanup is idempotent
#   Signal-specific handlers call cleanup, clear trap, and exit conventional code
#   cleanup kills children before removing files (correct ordering)
#   _bc_on_HUP exits 129; _bc_on_QUIT exits 131
#
# Strategy: Directly invoke signal handler functions in subshells. This avoids
# platform-specific issues with signal delivery to backgrounded bash processes.
# Prompt handler chaining and terminal restoration are covered by
# test-terminal-restoration.py using a PTY.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
PROJECT_DIR="$SCRIPT_DIR/.."

# Source shared test utilities
source "$SCRIPT_DIR/lib/test-utils.sh"

# ---------------------------------------------------------------------------
# Minimal assertion harness
# ---------------------------------------------------------------------------
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

assert_file_gone() {
    local desc="$1" path="$2"
    if [[ -z "$path" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc (no path)"
        ((pass++))
        return
    fi
    if [[ ! -e "$path" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (still exists: $path)"
        ((fail++))
        rm -f "$path" 2>/dev/null
        rm -rf "$path" 2>/dev/null
    fi
}

assert_dir_gone() {
    local desc="$1" path="$2"
    if [[ -z "$path" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc (no path)"
        ((pass++))
        return
    fi
    if [[ ! -d "$path" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (still exists: $path)"
        ((fail++))
        rm -rf "$path" 2>/dev/null
    fi
}

assert_pid_gone() {
    local desc="$1" pid="$2"
    if [[ -z "$pid" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc (no PID)"
        ((pass++))
        return
    fi
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${RED}FAIL${NC}: $desc (PID $pid still running)"
        ((fail++))
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    else
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    fi
}

# ---------------------------------------------------------------------------
# Suite 1: Signal handler exit codes
# ---------------------------------------------------------------------------
echo "======================================"
echo "Signal Cleanup Tests"
echo "======================================"
echo ""

echo "=== Suite 1: Signal handler exit codes ==="
echo ""

echo "Test 1: _bc_on_INT exits with 130"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    _bc_on_INT
) 2>/dev/null
assert_eq "_bc_on_INT exit code" "130" "$?"

echo ""
echo "Test 2: _bc_on_TERM exits with 143"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    _bc_on_TERM
) 2>/dev/null
assert_eq "_bc_on_TERM exit code" "143" "$?"

echo ""
echo "Test 3: _bc_on_HUP exits with 129"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    _bc_on_HUP
) 2>/dev/null
assert_eq "_bc_on_HUP exit code" "129" "$?"

echo ""
echo "Test 4: _bc_on_QUIT exits with 131"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    _bc_on_QUIT
) 2>/dev/null
assert_eq "_bc_on_QUIT exit code" "131" "$?"

# ---------------------------------------------------------------------------
# Suite 2: Handler cleanup of temp files, dirs, and children
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: Signal handler cleanup ==="
echo ""

echo "Test 5: _bc_on_TERM removes temp files and dirs, kills children"
RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-test-result-$$.XXXXXX")
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"

    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-term-tmp-$$.XXXXXX")
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/brew-change-term-dir-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"
    register_temp_dir "$TEMP_DIR"

    sleep 300 &
    CHILD_PID=$!
    register_pid "$CHILD_PID"

    # Write artifact paths to result file before handler fires
    echo "$TEMP_FILE" > "$RESULT_FILE"
    echo "$TEMP_DIR" >> "$RESULT_FILE"
    echo "$CHILD_PID" >> "$RESULT_FILE"

    # _bc_on_TERM calls cleanup, then exits 143
    # EXIT trap also fires (_bc_on_exit calls cleanup again, idempotent)
    _bc_on_TERM
) 2>/dev/null

TEMP_FILE_PATH=$(sed -n '1p' "$RESULT_FILE")
TEMP_DIR_PATH=$(sed -n '2p' "$RESULT_FILE")
CHILD_PID_VAL=$(sed -n '3p' "$RESULT_FILE")

assert_file_gone "TERM: temp file removed" "$TEMP_FILE_PATH"
assert_dir_gone "TERM: temp dir removed" "$TEMP_DIR_PATH"
assert_pid_gone "TERM: child killed" "$CHILD_PID_VAL"

rm -f "$RESULT_FILE"

echo ""
echo "Test 6: _bc_on_INT removes temp files and dirs, kills children"
RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-test-result-$$.XXXXXX")
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"

    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-int-tmp-$$.XXXXXX")
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/brew-change-int-dir-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"
    register_temp_dir "$TEMP_DIR"

    sleep 300 &
    CHILD_PID=$!
    register_pid "$CHILD_PID"

    echo "$TEMP_FILE" > "$RESULT_FILE"
    echo "$TEMP_DIR" >> "$RESULT_FILE"
    echo "$CHILD_PID" >> "$RESULT_FILE"

    _bc_on_INT
) 2>/dev/null

TEMP_FILE_PATH=$(sed -n '1p' "$RESULT_FILE")
TEMP_DIR_PATH=$(sed -n '2p' "$RESULT_FILE")
CHILD_PID_VAL=$(sed -n '3p' "$RESULT_FILE")

assert_file_gone "INT: temp file removed" "$TEMP_FILE_PATH"
assert_dir_gone "INT: temp dir removed" "$TEMP_DIR_PATH"
assert_pid_gone "INT: child killed" "$CHILD_PID_VAL"

rm -f "$RESULT_FILE"

# ---------------------------------------------------------------------------
# Suite 3: EXIT trap preserves existing exit status
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: EXIT trap preserves exit status ==="
echo ""

echo "Test 7: EXIT trap preserves exit code 0"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-exit0-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"
    exit 0
)
assert_eq "EXIT preserves exit 0" "0" "$?"

echo ""
echo "Test 8: EXIT trap preserves exit code 1"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-exit1-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"
    exit 1
)
assert_eq "EXIT preserves exit 1" "1" "$?"

echo ""
echo "Test 9: EXIT trap preserves exit code 42"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-exit42-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"
    exit 42
)
assert_eq "EXIT preserves exit 42" "42" "$?"

echo ""
echo "Test 10: EXIT trap preserves exit code 130 (from signal handler)"
RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-test-result-$$.XXXXXX")
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-exit130-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"
    echo "$TEMP_FILE" > "$RESULT_FILE"
    _bc_on_INT  # exits 130; EXIT trap fires
) 2>/dev/null
assert_eq "EXIT preserves exit 130" "130" "$?"
# Verify cleanup happened (EXIT handler + signal handler both called cleanup)
TEMP_FILE_PATH=$(sed -n '1p' "$RESULT_FILE")
assert_file_gone "EXIT+signal: temp file removed" "$TEMP_FILE_PATH"
rm -f "$RESULT_FILE"

# ---------------------------------------------------------------------------
# Suite 4: cleanup is idempotent
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 4: Idempotent cleanup ==="
echo ""

echo "Test 11: cleanup can be called multiple times"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"

    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-idemp-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"

    cleanup
    cleanup
    cleanup

    exit 0
) 2>/dev/null
assert_eq "idempotent cleanup succeeds" "0" "$?"

echo ""
echo "Test 12: cleanup + EXIT handler (double cleanup) succeeds"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"

    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-double-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"

    # _bc_on_TERM calls cleanup then exits 143
    # EXIT trap calls _bc_on_exit which calls cleanup again (idempotent)
    _bc_on_TERM
) 2>/dev/null
assert_eq "double cleanup (handler + EXIT)" "143" "$?"

# ---------------------------------------------------------------------------
# Suite 5: Cleanup kills children before removing files
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 5: Cleanup ordering ==="
echo ""

echo "Test 13: cleanup kills children first, then removes files"
RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-test-result-$$.XXXXXX")
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"

    TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/brew-change-order-$$.XXXXXX")
    register_temp_file "$TEMP_FILE"

    sleep 300 < "$TEMP_FILE" &
    CHILD_PID=$!
    register_pid "$CHILD_PID"

    echo "$TEMP_FILE" > "$RESULT_FILE"
    echo "$CHILD_PID" >> "$RESULT_FILE"

    cleanup

    if [[ -f "$TEMP_FILE" ]]; then echo "FILE_EXISTS"; else echo "FILE_CLEANED"; fi >> "$RESULT_FILE"
    if kill -0 "$CHILD_PID" 2>/dev/null; then echo "CHILD_ALIVE"; else echo "CHILD_DEAD"; fi >> "$RESULT_FILE"
)

TEMP_FILE_PATH=$(sed -n '1p' "$RESULT_FILE")
CHILD_PID_VAL=$(sed -n '2p' "$RESULT_FILE")
FILE_STATUS=$(sed -n '3p' "$RESULT_FILE")
CHILD_STATUS=$(sed -n '4p' "$RESULT_FILE")

assert_eq "child killed after cleanup" "CHILD_DEAD" "$CHILD_STATUS"
assert_eq "file removed after cleanup" "FILE_CLEANED" "$FILE_STATUS"

rm -f "$RESULT_FILE"

# ---------------------------------------------------------------------------
# Suite 6: Cleanup handles empty state gracefully
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 6: Empty state cleanup ==="
echo ""

echo "Test 14: cleanup with no registered items succeeds"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    cleanup
    exit 0
) 2>/dev/null
assert_eq "empty cleanup succeeds" "0" "$?"

echo ""
echo "Test 15: cleanup with no TEMP_FILES succeeds"
(
    export BREW_CHANGE_SUBPROCESS=""
    source "$LIB_DIR/brew-change-config.sh"
    TEMP_DIRS=()
    TEMP_FILES=()
    BREW_CHANGE_PIDS=()
    cleanup
    exit 0
) 2>/dev/null
assert_eq "explicit empty cleanup succeeds" "0" "$?"

# ---------------------------------------------------------------------------
# Cleanup & Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================"
echo "Test Results Summary"
echo "======================================"
echo "Total tests:  $((pass + fail))"
echo "Passed:       $pass"
echo "Failed:       $fail"
echo ""

if [[ $fail -gt 0 ]]; then
    exit 1
fi
