#!/usr/bin/env bash
# Tests for CLI argument validation (Task 5).
# Validates:
#   --help and --version bypass brew-prefix/dependency/auth/cache side effects
#   --dry-run without -u fails before any fake brew/curl call
#   Invalid combinations fail early
#   Bare brew-change (no args, no flags) reaches Homebrew inventory, not early rejection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"
PROJECT_DIR="$SCRIPT_DIR/.."
BREW_CHANGE="$PROJECT_DIR/brew-change"

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

# ---------------------------------------------------------------------------
# Helper: run brew-change in harness and capture exit code + stdout + stderr
# ---------------------------------------------------------------------------
run_brew_change_harness() {
    setup_command_harness
    local stderr_file="$COMMAND_HARNESS_ROOT/bc-stderr"
    local stdout_file="$COMMAND_HARNESS_ROOT/bc-stdout"
    local exit_code=0

    "$BREW_CHANGE" "$@" >"$stdout_file" 2>"$stderr_file" || exit_code=$?

    RUN_BC_EXIT="$exit_code"
    RUN_BC_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_BC_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_BC_LOG="$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)"
    teardown_command_harness
}

# ---------------------------------------------------------------------------
# Suite 1: --help and --version bypass all side effects
# ---------------------------------------------------------------------------
echo "======================================"
echo "CLI Validation Tests"
echo "======================================"
echo ""

echo "=== Suite 1: --help / --version bypass ==="
echo ""

echo "Test 1: --help exits 0 without invoking brew or curl"
run_brew_change_harness --help
assert_eq "--help exit code" "0" "$RUN_BC_EXIT"
assert_eq "--help no fake commands invoked" "" "$RUN_BC_LOG"
assert_contains "--help mentions Usage" "Usage:" "$RUN_BC_STDOUT"

echo ""
echo "Test 2: -h exits 0 without invoking brew or curl"
run_brew_change_harness -h
assert_eq "-h exit code" "0" "$RUN_BC_EXIT"
assert_eq "-h no fake commands invoked" "" "$RUN_BC_LOG"
assert_contains "-h mentions Usage" "Usage:" "$RUN_BC_STDOUT"

echo ""
echo "Test 3: --version exits 0 without invoking brew or curl"
run_brew_change_harness --version
assert_eq "--version exit code" "0" "$RUN_BC_EXIT"
assert_eq "--version no fake commands invoked" "" "$RUN_BC_LOG"
assert_contains "--version shows version" "brew-change version" "$RUN_BC_STDOUT"

echo ""
echo "Test 4: --help output goes to stdout, not stderr"
run_brew_change_harness --help
assert_contains "--help stdout has Usage" "Usage:" "$RUN_BC_STDOUT"
assert_not_contains "--help stderr empty of Usage" "Usage:" "$RUN_BC_STDERR"

# ---------------------------------------------------------------------------
# Suite 2: --dry-run without -u fails before any fake brew/curl call
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: --dry-run without -u ==="
echo ""

echo "Test 5: --dry-run without -u exits non-zero"
run_brew_change_harness --dry-run
assert_eq "--dry-run exit code" "1" "$RUN_BC_EXIT"
assert_eq "--dry-run no fake commands invoked" "" "$RUN_BC_LOG"
assert_contains "--dry-run error message" "Error:" "$RUN_BC_STDERR"

echo ""
echo "Test 6: -n without -u exits non-zero"
run_brew_change_harness -n
assert_eq "-n exit code" "1" "$RUN_BC_EXIT"
assert_eq "-n no fake commands invoked" "" "$RUN_BC_LOG"
assert_contains "-n error message" "Error:" "$RUN_BC_STDERR"

# ---------------------------------------------------------------------------
# Suite 3: Unknown options fail early
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: Unknown options ==="
echo ""

echo "Test 7: Unknown option fails early"
run_brew_change_harness --bogus
assert_eq "--bogus exit code" "1" "$RUN_BC_EXIT"
assert_eq "--bogus no fake commands invoked" "" "$RUN_BC_LOG"
assert_contains "--bogus error message" "Error: Unknown option" "$RUN_BC_STDERR"

echo ""
echo "Test 8: Single dash invalid fails early"
run_brew_change_harness -z
assert_eq "-z exit code" "1" "$RUN_BC_EXIT"
assert_eq "-z no fake commands invoked" "" "$RUN_BC_LOG"

# ---------------------------------------------------------------------------
# Suite 4: Bare invocation reaches Homebrew inventory (not early rejection)
# "No argument-free execution" applies only to `brew upgrade`, not the CLI.
# Bare brew-change should call `brew outdated --json=v2` to fetch inventory.
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 4: Bare invocation reaches inventory ==="
echo ""

echo "Test 9: bare brew-change (no args) calls brew outdated, no early rejection"
setup_command_harness
# Provide fixture data for brew outdated --json=v2
configure_fake_command brew "$FIXTURE_DIR/outdated-mixed.json" "" 0
# Also need curl to succeed (for auth init)
configure_fake_command curl "" "" 0

local_stderr="$COMMAND_HARNESS_ROOT/bc-stderr"
local_stdout="$COMMAND_HARNESS_ROOT/bc-stdout"
local_exit=0

"$BREW_CHANGE" >"$local_stdout" 2>"$local_stderr" || local_exit=$?

local_log="$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)"
local_stderr_content="$(cat "$local_stderr" 2>/dev/null || true)"

# Should NOT have the "Error: No packages specified" early rejection
assert_not_contains "no early rejection error" "Error: No packages specified" "$local_stderr_content"

# Should have invoked brew outdated --json=v2 (reaching Homebrew inventory)
assert_contains "brew outdated invoked" $'brew\toutdated\t--json=v2' "$local_log"

teardown_command_harness

# ---------------------------------------------------------------------------
# Suite: launcher prefers the checkout's own lib over an installed prefix
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite: launcher lib resolution ==="
echo ""

setup_command_harness
# A "stale install" prefix whose lib/ lacks the checkout's modules. The
# fake brew answers every invocation (including --prefix brew-change)
# with this path, so LIB_DIR resolution must reject it and fall back to
# the checkout's own lib/. A bare invocation is used because --version
# exits in pre-parse BEFORE library resolution runs.
STALE_PREFIX="$COMMAND_HARNESS_ROOT/stale-prefix"
mkdir -p "$STALE_PREFIX/lib"
printf '%s\n' "$STALE_PREFIX" >"$COMMAND_HARNESS_ROOT/prefix-fixture"
configure_fake_command brew "$COMMAND_HARNESS_ROOT/prefix-fixture" "" 0

"$BREW_CHANGE" >"$COMMAND_HARNESS_ROOT/out" 2>"$COMMAND_HARNESS_ROOT/err"
RESOLUTION_EXIT=$?
assert_eq "stale installed prefix does not break repo run" "0" "$RESOLUTION_EXIT"
# The checkout's libs were used (sourcing succeeded) and the run reached
# the Homebrew inventory stage.
assert_contains "repo run reached inventory" "brew" "$(cat "$COMMAND_HARNESS_LOG")"

teardown_command_harness

# ---------------------------------------------------------------------------
# Cleanup
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
