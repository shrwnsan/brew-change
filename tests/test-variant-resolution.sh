#!/usr/bin/env bash
# Test resolve_installed_variant and the @version cask redirect

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source required libs
source "$LIB_DIR/brew-change-config.sh"
source "$LIB_DIR/brew-change-utils.sh"

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
        echo -e "${RED}FAIL${NC}: $desc (expected exit=$expected, got exit=$actual')"
        ((fail++))
    fi
}

echo "=== resolve_installed_variant tests ==="
echo ""

# Test 1: Base name with @latest variant installed
echo "Test 1: claude-code → claude-code@latest (when @latest is installed)"
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
result=$(resolve_installed_variant "git" 2>/dev/null)
exit_code=$?
assert_empty "Returns empty" "$result"
assert_exit_code "Exit code 1" "1" "$exit_code"

echo ""
echo "=== Results ==="
echo "Passed: $pass"
echo "Failed: $fail"

if [[ $fail -gt 0 ]]; then
    exit 1
fi
