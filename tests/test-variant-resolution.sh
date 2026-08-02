#!/usr/bin/env bash
# Test resolve_installed_variant and extract_outdated_package_tokens
# Uses the command harness for deterministic brew list / brew outdated fixtures

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"

# Source shared test utilities (provides setup_command_harness, etc.)
source "$SCRIPT_DIR/lib/test-utils.sh"

# Source required libs
source "$LIB_DIR/brew-change-config.sh"
source "$LIB_DIR/brew-change-utils.sh"
source "$LIB_DIR/brew-change-brew.sh"

# Colors
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

assert_empty() {
    local desc="$1" actual="$2"
    if [[ -z "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected empty, got='$actual')"
        ((fail++))
    fi
}

assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected exit=$expected, got exit=$actual)"
        ((fail++))
    fi
}

assert_contains() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected to contain '$expected', got='$actual')"
        ((fail++))
    fi
}

assert_line_count() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected $expected lines, got $actual)"
        ((fail++))
    fi
}

# ---------------------------------------------------------------------------
# resolve_installed_variant tests (using command harness)
# ---------------------------------------------------------------------------
setup_command_harness
trap teardown_command_harness EXIT

echo "=== resolve_installed_variant tests (harness) ==="
echo ""

# Helper: configure fake brew with inline stdout content
configure_fake_brew_stdout() {
    local content="$1"
    local tmpfile="$COMMAND_HARNESS_ROOT/inline-stdout"
    printf '%s\n' "$content" > "$tmpfile"
    configure_fake_command brew "$tmpfile" "" 0
}

# Fixture: brew list returns claude-code@latest but not claude-code
configure_fake_brew_stdout 'claude-code@latest'

# Test 1: Base name with @latest variant installed
echo "Test 1: claude-code -> claude-code@latest (when @latest is installed)"
result=$(resolve_installed_variant "claude-code" 2>/dev/null)
exit_code=$?
assert_eq "Returns claude-code@latest" "claude-code@latest" "$result"
assert_exit_code "Exit code 0" "0" "$exit_code"

# Test 2: Package name already has @version suffix — no redirect
echo ""
echo "Test 2: claude-code@latest (already has suffix, no redirect)"
result=$(resolve_installed_variant "claude-code@latest" 2>/dev/null)
exit_code=$?
assert_empty "Returns empty" "$result"
assert_exit_code "Exit code 1" "1" "$exit_code"

# Test 3: Package that IS installed exactly (e.g., node) — no redirect
echo ""
echo "Test 3: node (exact match installed, no redirect)"
configure_fake_brew_stdout 'node
claude-code@latest'
result=$(resolve_installed_variant "node" 2>/dev/null)
exit_code=$?
assert_empty "Returns empty" "$result"
assert_exit_code "Exit code 1" "1" "$exit_code"

# Test 4: Completely nonexistent package — no redirect
echo ""
echo "Test 4: nonexistent-pkg-xyz (not installed at all)"
result=$(resolve_installed_variant "nonexistent-pkg-xyz" 2>/dev/null)
exit_code=$?
assert_empty "Returns empty" "$result"
assert_exit_code "Exit code 1" "1" "$exit_code"

# Test 5: Package with no @ variant installed
echo ""
echo "Test 5: git (installed, no @variant)"
configure_fake_brew_stdout 'git
claude-code@latest'
result=$(resolve_installed_variant "git" 2>/dev/null)
exit_code=$?
assert_empty "Returns empty" "$result"
assert_exit_code "Exit code 1" "1" "$exit_code"

# ---------------------------------------------------------------------------
# extract_outdated_package_tokens tests (RED phase)
# ---------------------------------------------------------------------------
echo ""
echo "=== extract_outdated_package_tokens tests ==="
echo ""

# Test 6: Mixed JSON yields exactly 3 TSV rows: node/formula, rectangle/cask, claude-code/cask
echo "Test 6: mixed JSON yields 3 canonical TSV rows"
result=$(extract_outdated_package_tokens "$(cat "$FIXTURE_DIR/outdated-mixed.json")" 2>/dev/null)
exit_code=$?
line_count=$(echo "$result" | sed '/^$/d' | wc -l | tr -d ' ')
assert_line_count "3 TSV rows" "3" "$line_count"
assert_exit_code "Exit code 0" "0" "$exit_code"

# Test 7: First row is node\tformula
echo ""
echo "Test 7: first row is node<tab>formula"
first_line=$(echo "$result" | head -1)
assert_eq "node token" $'node\tformula' "$first_line"

# Test 8: Second row is rectangle\tcask
echo ""
echo "Test 8: second row is rectangle<tab>cask"
second_line=$(echo "$result" | sed -n '2p')
assert_eq "rectangle token" $'rectangle\tcask' "$second_line"

# Test 9: Third row is claude-code\tcask (null token -> name[0] fallback)
echo ""
echo "Test 9: third row is claude-code<tab>cask (null token fallback)"
third_line=$(echo "$result" | sed -n '3p')
assert_eq "claude-code token" $'claude-code\tcask' "$third_line"

# Test 10: No row contains array-form display names
echo ""
echo "Test 10: no row contains array-form display name"
assert_eq "no 'Rectangle Pro'" "" "$(echo "$result" | grep -F 'Rectangle Pro' || true)"

# Test 11: Empty/outdated JSON yields no rows
echo ""
echo "Test 11: empty outdated JSON yields 0 rows"
result=$(extract_outdated_package_tokens '{"formulae":[],"casks":[]}' 2>/dev/null)
line_count=$(echo "$result" | sed '/^$/d' | wc -l | tr -d ' ')
assert_line_count "0 TSV rows for empty" "0" "$line_count"

# Test 12: Cask with empty-string token is omitted
echo ""
echo "Test 12: cask with empty-string token is omitted"
result=$(extract_outdated_package_tokens '{"formulae":[],"casks":[{"token":"","name":["Empty Cask"],"installed_versions":["1.0"],"current_version":"2.0"}]}' 2>/dev/null)
line_count=$(echo "$result" | sed '/^$/d' | wc -l | tr -d ' ')
assert_line_count "0 TSV rows for empty token cask" "0" "$line_count"

teardown_command_harness
trap - EXIT

echo ""
echo "=== Results ==="
echo "Passed: $pass"
echo "Failed: $fail"

if [[ $fail -gt 0 ]]; then
    exit 1
fi
