#!/usr/bin/env bash
# Unit tests for cask JSON field handling and production extraction paths
# Verifies that all inventory consumers use canonical tokens, never display-name arrays

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"

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

assert_not_contains() {
    local desc="$1" unexpected="$2" actual="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (should not contain '$unexpected', got='$actual')"
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

# ---------------------------------------------------------------------------
# Raw jq field-type verification (no eval, no command harness needed)
# ---------------------------------------------------------------------------
echo "======================================"
echo "Cask JSON Field Handling Unit Tests"
echo "======================================"
echo ""

# Sample JSON structure matching Homebrew's API v2
SAMPLE_CASK_JSON='{
  "formulae": [
    {"name": "example-formula", "current_version": "1.0.0"}
  ],
  "casks": [
    {
      "token": "rectangle",
      "name": ["Rectangle", "Rectangle Pro"],
      "installed_versions": ["0.88"],
      "current_version": "0.92"
    },
    {
      "token": "visual-studio-code",
      "name": ["Visual Studio Code"],
      "installed_versions": ["1.80.0"],
      "current_version": "1.85.0"
    }
  ]
}'

# Real-world sample from brew outdated --json=v2 where .token is null
# See: https://github.com/shrwnsan/brew-change/issues/28
SAMPLE_CASK_JSON_NULL_TOKEN='{
  "formulae": [],
  "casks": [
    {
      "token": null,
      "name": ["claude-code"],
      "installed_versions": ["2.1.1"],
      "current_version": "2.1.2"
    },
    {
      "token": null,
      "name": ["codex"],
      "installed_versions": ["0.77.0"],
      "current_version": "0.79.0"
    },
    {
      "token": null,
      "name": ["emdash"],
      "installed_versions": ["0.3.44"],
      "current_version": "0.3.46"
    }
  ]
}'

echo "Test Suite: Cask Token Extraction"
echo "-----------------------------------"

# Test 1: Extract cask tokens from JSON
result=$(printf '%s' "$SAMPLE_CASK_JSON" | jq -r '.casks[].token')
expected="rectangle
visual-studio-code"
assert_eq "Extract cask tokens from JSON" "$expected" "$result"

# Test 2: Select cask by token
result=$(printf '%s' "$SAMPLE_CASK_JSON" | jq -r '.casks[] | select(.token == "rectangle") | .current_version')
assert_eq "Select cask by token field" "0.92" "$result"

# Test 3: Select cask by token with multiple matches
result=$(printf '%s' "$SAMPLE_CASK_JSON" | jq -r '.casks[] | select(.token == "visual-studio-code") | .current_version')
assert_eq "Select specific cask by token" "1.85.0" "$result"

# Test 4: Display formatting with name array
result=$(printf '%s' "$SAMPLE_CASK_JSON" | jq -r '.casks[] | select(.token == "rectangle") | "\(.name | join(" / ")) (\(.installed_versions | join(", ")) → \(.current_version))"')
assert_eq "Display cask with formatted name array" "Rectangle / Rectangle Pro (0.88 → 0.92)" "$result"

# Test 5: Verify .name is an array
result=$(printf '%s' "$SAMPLE_CASK_JSON" | jq -r '.casks[] | select(.token == "rectangle") | .name | type')
assert_eq "Verify cask .name field is an array" "array" "$result"

# Test 6: Verify .token is a string
result=$(printf '%s' "$SAMPLE_CASK_JSON" | jq -r '.casks[] | select(.token == "rectangle") | .token | type')
assert_eq "Verify cask .token field is a string" "string" "$result"

# Test 7: Formula .name is a string (contrast with casks)
result=$(printf '%s' "$SAMPLE_CASK_JSON" | jq -r '.formulae[] | .name | type')
assert_eq "Verify formula .name field is a string" "string" "$result"

echo ""
echo "Test Suite: Null Token Handling (real-world brew outdated)"
echo "----------------------------------------------------------"

# Test 8: Extract cask names when token is null
result=$(printf '%s' "$SAMPLE_CASK_JSON_NULL_TOKEN" | jq -r '.casks[].name[]')
expected="claude-code
codex
emdash"
assert_eq "Extract cask names when token is null (FIX: use .name)" "$expected" "$result"

# Test 9: Verify .token returns null
result=$(printf '%s' "$SAMPLE_CASK_JSON_NULL_TOKEN" | jq -r '.casks[0].token')
assert_eq "Verify cask .token field can be null" "null" "$result"

# Test 10: Null tokens are filtered out correctly
result=$(printf '%s' "$SAMPLE_CASK_JSON_NULL_TOKEN" | jq -r '.casks[].token | select(. != null)')
assert_eq "Filter out null tokens from parallel processing array" "" "$result"

# Test 11: Using .name instead of .token works for null token case
result=$(printf '%s' "$SAMPLE_CASK_JSON_NULL_TOKEN" | jq -r '.casks[].name[]' | wc -l | awk '{print $1}')
assert_eq "Use .name field to get casks with null tokens" "3" "$result"

# ---------------------------------------------------------------------------
# Production extraction path tests
# ---------------------------------------------------------------------------
echo ""
echo "Test Suite: Production extract_outdated_package_tokens"
echo "---------------------------------------------------------"

# Test 12: Production extraction with mixed fixture yields canonical tokens
echo ""
echo "Test 12: production extraction yields node, rectangle, claude-code"
result=$(extract_outdated_package_tokens "$(cat "$FIXTURE_DIR/outdated-mixed.json")" 2>/dev/null)
assert_contains "contains node token" $'node\tformula' "$result"
assert_contains "contains rectangle token" $'rectangle\tcask' "$result"
assert_contains "contains claude-code token" $'claude-code\tcask' "$result"
assert_not_contains "no array display names" "Rectangle Pro" "$result"
assert_not_contains "no array brackets" "[" "$result"

# Test 13: Formula-only JSON
echo ""
echo "Test 13: formula-only JSON yields formula rows"
result=$(extract_outdated_package_tokens '{"formulae":[{"name":"git","installed_versions":["2.45.0"],"current_version":"2.47.0"}],"casks":[]}' 2>/dev/null)
assert_eq "formula-only: git row" $'git\tformula' "$result"

# Test 14: Cask-only JSON with string token
echo ""
echo "Test 14: cask-only JSON with string token"
result=$(extract_outdated_package_tokens '{"formulae":[],"casks":[{"token":"docker","name":["Docker Desktop"],"installed_versions":["4.30"],"current_version":"4.32"}]}' 2>/dev/null)
assert_eq "cask-only: docker row" $'docker\tcask' "$result"

# Test 15: Cask-only JSON with null token, string name fallback
echo ""
echo "Test 15: cask-only JSON with null token, string name"
result=$(extract_outdated_package_tokens '{"formulae":[],"casks":[{"token":null,"name":"atom","installed_versions":["1.60"],"current_version":"1.63"}]}' 2>/dev/null)
assert_eq "null-token-string-name: atom row" $'atom\tcask' "$result"

# Test 16: Cask with empty string name is omitted
echo ""
echo "Test 16: cask with empty string name is omitted"
result=$(extract_outdated_package_tokens '{"formulae":[],"casks":[{"token":null,"name":"","installed_versions":["1.0"],"current_version":"2.0"}]}' 2>/dev/null)
assert_eq "empty name: 0 rows" "" "$result"

# Test 17: Formulae with null or empty names are omitted
echo ""
echo "Test 17: formulae with invalid names are omitted"
result=$(extract_outdated_package_tokens '{"formulae":[{"name":null},{"name":""}],"casks":[]}' 2>/dev/null)
assert_eq "invalid formula names: 0 rows" "" "$result"

# Test 18: Multiple formulae and casks
echo ""
echo "Test 18: multiple formulae and casks"
result=$(extract_outdated_package_tokens '{"formulae":[{"name":"node","installed_versions":["22.6.0"],"current_version":"22.8.0"},{"name":"python","installed_versions":["3.12.5"],"current_version":"3.13.0"}],"casks":[{"token":"rectangle","name":["Rectangle"],"installed_versions":["0.88"],"current_version":"0.92"},{"token":null,"name":["claude-code"],"installed_versions":["2.1.1"],"current_version":"2.1.2"}]}' 2>/dev/null)
line_count=$(echo "$result" | wc -l | tr -d ' ')
assert_eq "4 TSV rows for 2 formulae + 2 casks" "4" "$line_count"

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
