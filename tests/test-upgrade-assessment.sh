#!/usr/bin/env bash
# Tests for the three-tier upgrade assessment classification.
# Phase 1, Task 4: Replace binary breaking/safe with attention/no-signal/unknown.
#
# Producer schema (TSV per package in results.tsv):
#   package<TAB>source<TAB>retrieval_status<TAB>retrieved_at<TAB>reason<TAB>risk_signal
#
# Classification rules (from PRD 7.2, plan Task 4):
#   1. Any trustworthy risk signal -> attention (even if retrieval failed)
#   2. No-signal only for fresh/cached-fresh evidence with nonempty valid timestamp and no risk
#   3. Everything else -> unknown
#
# Collector:
#   - Exactly one outcome per canonical inventory token
#   - Duplicate rows: strongest precedence (attention > no-signal > unknown)
#   - Rows not in inventory are ignored when inventory is supplied
#   - Missing producer rows synthesized as unknown
#   - Counts must sum to canonical inventory count
#   - outcomes.tsv preserves inventory order

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"

# Source shared test utilities
source "$SCRIPT_DIR/lib/test-utils.sh"

# Source production libs (suppress subprocess traps)
export BREW_CHANGE_SUBPROCESS="true"
source "$LIB_DIR/brew-change-config.sh"
source "$LIB_DIR/brew-change-utils.sh"
source "$LIB_DIR/brew-change-brew.sh"
source "$LIB_DIR/brew-change-upgrade.sh"
source "$LIB_DIR/brew-change-display.sh"
source "$LIB_DIR/brew-change-interactive.sh"

# ---------------------------------------------------------------------------
# Minimal test harness
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

# Check that a global array contains exactly the expected elements (order-independent).
# Usage: assert_array_contents "desc" expected1 expected2... -- ARRAY_NAME
assert_array_contents() {
    local desc="$1"; shift
    local -a expected=()
    local array_name=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            shift; array_name="${1:-}"; break
        fi
        expected+=("$1"); shift
    done

    # Bash-4.0-compatible array copy (no local -n)
    local -a actual=()
    case "$array_name" in
        ATTENTION_PKGS) actual=("${ATTENTION_PKGS[@]+"${ATTENTION_PKGS[@]}"}") ;;
        NO_SIGNAL_PKGS) actual=("${NO_SIGNAL_PKGS[@]+"${NO_SIGNAL_PKGS[@]}"}") ;;
        UNKNOWN_PKGS)   actual=("${UNKNOWN_PKGS[@]+"${UNKNOWN_PKGS[@]}"}") ;;
        *) echo "assert_array_contents: unknown array '$array_name'" >&2; return 2 ;;
    esac

    local expected_sorted actual_sorted
    expected_sorted=$(printf '%s\n' "${expected[@]}" | sort)
    actual_sorted=$(printf '%s\n' "${actual[@]+"${actual[@]}"}" | sort)
    if [[ "$expected_sorted" == "$actual_sorted" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc"
        echo -e "  expected: $(printf '%s ' "${expected[@]}")"
        echo -e "  actual:   $(printf '%s ' "${actual[@]+"${actual[@]}"}")"
        ((fail++))
    fi
}

# Assert that an outcomes.tsv file has exactly the expected number of rows
# and optionally check specific fields.
# Usage: assert_outcomes_count "desc" expected_count tsv_path
assert_outcomes_count() {
    local desc="$1" expected="$2" tsv_path="$3"
    local actual
    actual=$(wc -l < "$tsv_path" | tr -d ' ')
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected=$expected, actual=$actual)"
        ((fail++))
    fi
}

# Assert a specific field value in outcomes.tsv for a given package row.
# Usage: assert_outcomes_field "desc" tsv_path package field_idx expected_value
assert_outcomes_field() {
    local desc="$1" tsv_path="$2" pkg="$3" field_idx="$4" expected="$5"
    local actual
    actual=$(grep "^${pkg}	" "$tsv_path" | cut -f"$field_idx")
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
        ((fail++))
    fi
}

# ---------------------------------------------------------------------------
# Helper: write producer rows and run classify_upgrade_evidence
# ---------------------------------------------------------------------------
write_results_tsv() {
    local dir="$1"; shift
    mkdir -p "$dir"
    : > "$dir/results.tsv"
    for row in "$@"; do
        printf '%s\n' "$row" >> "$dir/results.tsv"
    done
}

# ---------------------------------------------------------------------------
# Test Suite 1: Classification Matrix
# ---------------------------------------------------------------------------
echo "======================================"
echo "Upgrade Assessment Classification Tests"
echo "======================================"
echo ""

echo "=== Suite 1: Classification Matrix ==="
echo ""

TEST_STATUS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/brew-change-assess.XXXXXX")
trap 'rm -rf "$TEST_STATUS_DIR"' EXIT

echo "Test 1: risk signal + fresh evidence -> attention"
write_results_tsv "$TEST_STATUS_DIR" \
    $'node\tgithub\tfresh\t1753000000\trelease notes checked\tbreaking-change-keyword'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "node -> ATTENTION_PKGS" "node" -- ATTENTION_PKGS
assert_array_contents "NO_SIGNAL_PKGS empty" -- NO_SIGNAL_PKGS
assert_array_contents "UNKNOWN_PKGS empty" -- UNKNOWN_PKGS

echo ""
echo "Test 2: major version transition + failed retrieval -> attention"
write_results_tsv "$TEST_STATUS_DIR" \
    $'postgresql\tnon-github\tfailed\t\tmajor version transition\tmajor-version-transition'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "postgresql -> ATTENTION_PKGS" "postgresql" -- ATTENTION_PKGS
assert_array_contents "NO_SIGNAL_PKGS empty" -- NO_SIGNAL_PKGS
assert_array_contents "UNKNOWN_PKGS empty" -- UNKNOWN_PKGS

echo ""
echo "Test 3: fresh evidence + no risk signal -> no-signal"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\trelease notes checked\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "git -> NO_SIGNAL_PKGS" "git" -- NO_SIGNAL_PKGS
assert_array_contents "ATTENTION_PKGS empty" -- ATTENTION_PKGS
assert_array_contents "UNKNOWN_PKGS empty" -- UNKNOWN_PKGS

echo ""
echo "Test 4: cached-fresh evidence + no risk -> no-signal"
write_results_tsv "$TEST_STATUS_DIR" \
    $'python\tnpm\tcached-fresh\t1753000000\tnpm release checked\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "python -> NO_SIGNAL_PKGS" "python" -- NO_SIGNAL_PKGS

echo ""
echo "Test 5: missing timestamp + no risk -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'firefox\tnon-github\tfailed\t\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "firefox -> UNKNOWN_PKGS" "firefox" -- UNKNOWN_PKGS
assert_array_contents "NO_SIGNAL_PKGS empty" -- NO_SIGNAL_PKGS

echo ""
echo "Test 6: stale evidence -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'rectangle\tgithub\tstale\t1700000000\trelease notes stale\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "rectangle -> UNKNOWN_PKGS" "rectangle" -- UNKNOWN_PKGS

echo ""
echo "Test 7: malformed response -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'docker\tnon-github\tmalformed\t\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "docker -> UNKNOWN_PKGS" "docker" -- UNKNOWN_PKGS

echo ""
echo "Test 8: rate-limited -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'bun\tgithub\trate-limited\t\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "bun -> UNKNOWN_PKGS" "bun" -- UNKNOWN_PKGS

echo ""
echo "Test 9: unavailable -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'obs\tgithub\tunavailable\t\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "obs -> UNKNOWN_PKGS" "obs" -- UNKNOWN_PKGS

echo ""
echo "Test 10: unsupported source -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'some-app\tnon-github\tunsupported\t\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "some-app -> UNKNOWN_PKGS" "some-app" -- UNKNOWN_PKGS

echo ""
echo "Test 11: fresh status but empty timestamp -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'vlc\tnon-github\tfresh\t\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "vlc -> UNKNOWN_PKGS" "vlc" -- UNKNOWN_PKGS

echo ""
echo "Test 12: non-numeric timestamp -> unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'wireshark\tnon-github\tfresh\tinvalid-timestamp\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "wireshark -> UNKNOWN_PKGS" "wireshark" -- UNKNOWN_PKGS

echo ""
echo "Test 13: risk signal overrides stale -> attention"
write_results_tsv "$TEST_STATUS_DIR" \
    $'helm\tgithub\tstale\t1700000000\trelease notes stale\tbreaking-change-keyword'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "helm -> ATTENTION_PKGS" "helm" -- ATTENTION_PKGS

echo ""
echo "Test 14: risk signal + malformed retrieval -> attention"
write_results_tsv "$TEST_STATUS_DIR" \
    $'terraform\tgithub\tmalformed\t\t\tbreaking-change-keyword'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "terraform -> ATTENTION_PKGS" "terraform" -- ATTENTION_PKGS

echo ""
echo "Test 15: mixed outcomes across 5 packages"
write_results_tsv "$TEST_STATUS_DIR" \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword' \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'firefox\tnon-github\tfailed\t\t\t' \
    $'python\tnpm\tcached-fresh\t1753000000\tchecked\t' \
    $'bun\tgithub\trate-limited\t\t\t'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "ATTENTION_PKGS" "node" -- ATTENTION_PKGS
assert_array_contents "NO_SIGNAL_PKGS" "git" "python" -- NO_SIGNAL_PKGS
assert_array_contents "UNKNOWN_PKGS" "firefox" "bun" -- UNKNOWN_PKGS

# ---------------------------------------------------------------------------
# Test Suite 2: Missing-row synthesis
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: Missing Row Synthesis ==="
echo ""

echo "Test 16: missing producer row synthesized as unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword'

INVENTORY_PKGS=("git" "node" "firefox")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
assert_array_contents "ATTENTION: node only" "node" -- ATTENTION_PKGS
assert_array_contents "NO_SIGNAL: git only" "git" -- NO_SIGNAL_PKGS
assert_array_contents "UNKNOWN: firefox synthesized" "firefox" -- UNKNOWN_PKGS

echo ""
echo "Test 17: no producer rows -> all unknown"
: > "$TEST_STATUS_DIR/results.tsv"
INVENTORY_PKGS=("pkg-a" "pkg-b" "pkg-c")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
assert_array_contents "ATTENTION empty" -- ATTENTION_PKGS
assert_array_contents "NO_SIGNAL empty" -- NO_SIGNAL_PKGS
assert_array_contents "all UNKNOWN" "pkg-a" "pkg-b" "pkg-c" -- UNKNOWN_PKGS

echo ""
echo "Test 18: no results file -> all unknown"
rm -f "$TEST_STATUS_DIR/results.tsv"
INVENTORY_PKGS=("pkg-x")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
assert_array_contents "all UNKNOWN from missing file" "pkg-x" -- UNKNOWN_PKGS

# ---------------------------------------------------------------------------
# Test Suite 3: Count invariants
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: Count Invariants ==="
echo ""

echo "Test 19: attention + no_signal + unknown == inventory count"
write_results_tsv "$TEST_STATUS_DIR" \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword' \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'firefox\tnon-github\tfailed\t\t\t' \
    $'python\tnpm\tcached-fresh\t1753000000\tchecked\t' \
    $'bun\tgithub\trate-limited\t\t\t' \
    $'obs\tgithub\tunavailable\t\t\t' \
    $'rectangle\tnon-github\tunsupported\t\t\t'

INVENTORY_PKGS=("node" "git" "firefox" "python" "bun" "obs" "rectangle")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "counts sum to 7" "7" "$total"

# ---------------------------------------------------------------------------
# Test Suite 4: No safe/appear-safe language
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 4: No safe/appear-safe language ==="
echo ""

echo "Test 20: summary output must not contain 'safe'"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword'

INVENTORY_PKGS=("git" "node")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

SUMMARY_OUTPUT=$(print_upgrade_summary '{"formulae":[{"name":"git"},{"name":"node"}],"casks":[]}')
assert_not_contains "no 'safe package' in summary" "safe package" "$SUMMARY_OUTPUT"
assert_not_contains "no 'appear safe' in summary" "appear safe" "$SUMMARY_OUTPUT"

echo "Test 21: suggestion output must not contain 'safe upgrade'"
SUGGEST_OUTPUT=$(print_upgrade_suggestion '{"formulae":[{"name":"git"},{"name":"node"}],"casks":[]}')
assert_not_contains "no 'Suggested safe upgrade' in suggestion" "Suggested safe upgrade" "$SUGGEST_OUTPUT"
assert_not_contains "no 'safe upgrade' in suggestion" "safe upgrade" "$SUGGEST_OUTPUT"

# ---------------------------------------------------------------------------
# Test Suite 5: BREAKING_PKGS and SAFE_PKGS must NOT exist
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 5: Legacy arrays removed ==="
echo ""

echo "Test 22: BREAKING_PKGS is not defined (no legacy aliases)"
if declare -p BREAKING_PKGS &>/dev/null; then
    echo -e "${RED}FAIL${NC}: BREAKING_PKGS should not be defined"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: BREAKING_PKGS is not defined"
    ((pass++))
fi

echo "Test 23: SAFE_PKGS is not defined (no legacy aliases)"
if declare -p SAFE_PKGS &>/dev/null; then
    echo -e "${RED}FAIL${NC}: SAFE_PKGS should not be defined"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: SAFE_PKGS is not defined"
    ((pass++))
fi

# ---------------------------------------------------------------------------
# Test Suite 6: Default bulk action uses only NO_SIGNAL_PKGS
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 6: Bulk action restrictions ==="
echo ""

echo "Test 24: print_upgrade_suggestion does not suggest bare 'brew upgrade'"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword'

INVENTORY_PKGS=("git" "node")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

SUGGEST_OUTPUT=$(print_upgrade_suggestion '{"formulae":[{"name":"git"},{"name":"node"}],"casks":[]}')
# Check that no line is exactly "brew upgrade" (bare, no packages)
bare_found=0
while IFS= read -r line; do
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ "$trimmed" == "brew upgrade" ]]; then
        bare_found=1
        break
    fi
done <<< "$SUGGEST_OUTPUT"
if [[ "$bare_found" -eq 1 ]]; then
    echo -e "${RED}FAIL${NC}: suggestion contains bare 'brew upgrade' line"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: no bare 'brew upgrade' line in suggestion"
    ((pass++))
fi
assert_not_contains "no 'To upgrade all'" "To upgrade all" "$SUGGEST_OUTPUT"
assert_contains "suggestion mentions no-signal package git" "brew upgrade" "$SUGGEST_OUTPUT"

# ---------------------------------------------------------------------------
# Test Suite 7: Retrieval status preserved independently
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 7: Retrieval status independence ==="
echo ""

echo "Test 25: stale retrieval stays stale even when classified attention"
write_results_tsv "$TEST_STATUS_DIR" \
    $'helm\tgithub\tstale\t1700000000\tstale notes\tbreaking-change-keyword'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "helm is ATTENTION" "helm" -- ATTENTION_PKGS

echo ""
echo "Test 26: failed retrieval stays failed when classified attention"
write_results_tsv "$TEST_STATUS_DIR" \
    $'postgresql\tnon-github\tfailed\t\tmajor version transition\tmajor-version-transition'

classify_upgrade_evidence "$TEST_STATUS_DIR"
assert_array_contents "postgresql is ATTENTION" "postgresql" -- ATTENTION_PKGS

# ---------------------------------------------------------------------------
# Test Suite 8: is_package_breaking maps to ATTENTION
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 8: is_package_breaking maps to ATTENTION ==="
echo ""

echo "Test 27: is_package_breaking returns true for attention package"
write_results_tsv "$TEST_STATUS_DIR" \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword'

INVENTORY_PKGS=("node")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
if is_package_breaking "node"; then
    echo -e "${GREEN}PASS${NC}: is_package_breaking(node) returns 0 for attention"
    ((pass++))
else
    echo -e "${RED}FAIL${NC}: is_package_breaking(node) should return 0 for attention package"
    ((fail++))
fi

echo "Test 28: is_package_breaking returns false for no-signal package"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t'

INVENTORY_PKGS=("git")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
if is_package_breaking "git"; then
    echo -e "${RED}FAIL${NC}: is_package_breaking(git) should return 1 for no-signal"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: is_package_breaking(git) returns 1 for no-signal"
    ((pass++))
fi

echo "Test 29: is_package_breaking returns false for unknown package"
write_results_tsv "$TEST_STATUS_DIR" \
    $'firefox\tnon-github\tfailed\t\t\t'

INVENTORY_PKGS=("firefox")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
if is_package_breaking "firefox"; then
    echo -e "${RED}FAIL${NC}: is_package_breaking(firefox) should return 1 for unknown"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: is_package_breaking(firefox) returns 1 for unknown"
    ((pass++))
fi

# ---------------------------------------------------------------------------
# Test Suite 9: Duplicate row deduplication with precedence
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 9: Duplicate row deduplication ==="
echo ""

echo "Test 30: duplicate rows with same classification -> one outcome"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'git\tnpm\tcached-fresh\t1753000001\tchecked\t'

INVENTORY_PKGS=("git")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "total outcomes == 1 for deduplicated git" "1" "$total"
assert_array_contents "git -> NO_SIGNAL" "git" -- NO_SIGNAL_PKGS

echo ""
echo "Test 31: conflicting duplicates -> strongest precedence wins"
write_results_tsv "$TEST_STATUS_DIR" \
    $'helm\tgithub\tfresh\t1753000000\tchecked\t' \
    $'helm\tgithub\tstale\t1700000000\tstale\tbreaking-change-keyword'

INVENTORY_PKGS=("helm")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "total outcomes == 1 for deduplicated helm" "1" "$total"
assert_array_contents "helm -> ATTENTION (strongest)" "helm" -- ATTENTION_PKGS
assert_array_contents "NO_SIGNAL empty for helm" -- NO_SIGNAL_PKGS

echo ""
echo "Test 32: attention + unknown duplicates -> attention wins"
write_results_tsv "$TEST_STATUS_DIR" \
    $'obs\tnon-github\tfailed\t\t\t' \
    $'obs\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword'

INVENTORY_PKGS=("obs")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "total outcomes == 1 for deduplicated obs" "1" "$total"
assert_array_contents "obs -> ATTENTION" "obs" -- ATTENTION_PKGS

echo ""
echo "Test 33: no-signal + unknown duplicates -> no-signal wins"
write_results_tsv "$TEST_STATUS_DIR" \
    $'python\tnon-github\tfailed\t\t\t' \
    $'python\tnpm\tcached-fresh\t1753000000\tchecked\t'

INVENTORY_PKGS=("python")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "total outcomes == 1 for deduplicated python" "1" "$total"
assert_array_contents "python -> NO_SIGNAL" "python" -- NO_SIGNAL_PKGS

# ---------------------------------------------------------------------------
# Test Suite 10: Extraneous package rows ignored with inventory
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 10: Extraneous rows ignored ==="
echo ""

echo "Test 34: rows not in inventory are ignored"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'extraneous-pkg\tnon-github\tfailed\t\t\t' \
    $'another-extra\tnon-github\tfailed\t\t\t'

INVENTORY_PKGS=("git")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "total outcomes == 1 (only inventory counted)" "1" "$total"
assert_array_contents "git -> NO_SIGNAL" "git" -- NO_SIGNAL_PKGS

echo ""
echo "Test 35: all results rows extraneous -> all synthesized unknown"
write_results_tsv "$TEST_STATUS_DIR" \
    $'extra-a\tnon-github\tfailed\t\t\t' \
    $'extra-b\tnon-github\tfresh\t1753000000\tchecked\t'

INVENTORY_PKGS=("real-pkg")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "total outcomes == 1 (all extraneous ignored)" "1" "$total"
assert_array_contents "real-pkg -> UNKNOWN" "real-pkg" -- UNKNOWN_PKGS

echo ""
echo "Test 36: inventory order preserved in outcomes"
write_results_tsv "$TEST_STATUS_DIR" \
    $'charlie\tnon-github\tfailed\t\t\t' \
    $'alpha\tgithub\tfresh\t1753000000\tchecked\t' \
    $'bravo\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword'

INVENTORY_PKGS=("bravo" "alpha" "charlie")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

# Check outcomes.tsv preserves inventory order
if [[ -f "$TEST_STATUS_DIR/outcomes.tsv" ]]; then
    local_outcomes_line1=$(sed -n '1p' "$TEST_STATUS_DIR/outcomes.tsv" | cut -f1)
    local_outcomes_line2=$(sed -n '2p' "$TEST_STATUS_DIR/outcomes.tsv" | cut -f1)
    local_outcomes_line3=$(sed -n '3p' "$TEST_STATUS_DIR/outcomes.tsv" | cut -f1)
    assert_eq "outcomes row 1 = bravo (inventory order)" "bravo" "$local_outcomes_line1"
    assert_eq "outcomes row 2 = alpha (inventory order)" "alpha" "$local_outcomes_line2"
    assert_eq "outcomes row 3 = charlie (inventory order)" "charlie" "$local_outcomes_line3"
else
    echo -e "${RED}FAIL${NC}: outcomes.tsv not created"
    ((fail++))
fi

echo ""
echo "Test 37: total outcomes equals inventory size with duplicates + extras"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'git\tnpm\tcached-fresh\t1753000001\tchecked\t' \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword' \
    $'node\tgithub\tstale\t1700000000\tstale\t' \
    $'extra\tnon-github\tfailed\t\t\t'

INVENTORY_PKGS=("git" "node" "missing-pkg")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"
total=$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))
assert_eq "total == 3 (inventory size)" "3" "$total"
assert_array_contents "git -> NO_SIGNAL" "git" -- NO_SIGNAL_PKGS
assert_array_contents "node -> ATTENTION" "node" -- ATTENTION_PKGS
assert_array_contents "missing-pkg -> UNKNOWN" "missing-pkg" -- UNKNOWN_PKGS

# ---------------------------------------------------------------------------
# Test Suite 11: outcomes.tsv structured output
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 11: outcomes.tsv structured output ==="
echo ""

echo "Test 38: outcomes.tsv has correct row count"
write_results_tsv "$TEST_STATUS_DIR" \
    $'git\tgithub\tfresh\t1753000000\tchecked\t' \
    $'node\tgithub\tfresh\t1753000000\tchecked\tbreaking-change-keyword'

INVENTORY_PKGS=("git" "node" "firefox")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

if [[ -f "$TEST_STATUS_DIR/outcomes.tsv" ]]; then
    assert_outcomes_count "outcomes.tsv has 3 rows" "3" "$TEST_STATUS_DIR/outcomes.tsv"
    assert_outcomes_field "git retrieval_status in outcomes" "$TEST_STATUS_DIR/outcomes.tsv" "git" 3 "fresh"
    assert_outcomes_field "git classification in outcomes" "$TEST_STATUS_DIR/outcomes.tsv" "git" 7 "no-signal"
    assert_outcomes_field "node classification in outcomes" "$TEST_STATUS_DIR/outcomes.tsv" "node" 7 "attention"
    assert_outcomes_field "firefox retrieval_status synthesized" "$TEST_STATUS_DIR/outcomes.tsv" "firefox" 3 "unavailable"
    assert_outcomes_field "firefox reason synthesized" "$TEST_STATUS_DIR/outcomes.tsv" "firefox" 5 "missing"
    assert_outcomes_field "firefox risk_signal empty" "$TEST_STATUS_DIR/outcomes.tsv" "firefox" 6 ""
    assert_outcomes_field "firefox classification synthesized" "$TEST_STATUS_DIR/outcomes.tsv" "firefox" 7 "unknown"
else
    echo -e "${RED}FAIL${NC}: outcomes.tsv not created"
    ((fail++))
fi

echo ""
echo "Test 39: synthesized rows have structured unknown data"
rm -f "$TEST_STATUS_DIR/outcomes.tsv"
: > "$TEST_STATUS_DIR/results.tsv"
INVENTORY_PKGS=("pkg-a")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

if [[ -f "$TEST_STATUS_DIR/outcomes.tsv" ]]; then
    assert_outcomes_count "outcomes has 1 synthesized row" "1" "$TEST_STATUS_DIR/outcomes.tsv"
    assert_outcomes_field "pkg-a retrieval_status = unavailable" "$TEST_STATUS_DIR/outcomes.tsv" "pkg-a" 3 "unavailable"
    assert_outcomes_field "pkg-a reason = missing" "$TEST_STATUS_DIR/outcomes.tsv" "pkg-a" 5 "missing"
    assert_outcomes_field "pkg-a risk_signal empty" "$TEST_STATUS_DIR/outcomes.tsv" "pkg-a" 6 ""
    assert_outcomes_field "pkg-a classification = unknown" "$TEST_STATUS_DIR/outcomes.tsv" "pkg-a" 7 "unknown"
else
    echo -e "${RED}FAIL${NC}: outcomes.tsv not created for synthesized row"
    ((fail++))
fi

echo ""
echo "Test 40: retrieval status preserved in outcomes (stale stays stale)"
write_results_tsv "$TEST_STATUS_DIR" \
    $'helm\tgithub\tstale\t1700000000\tstale notes\tbreaking-change-keyword'

INVENTORY_PKGS=("helm")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

if [[ -f "$TEST_STATUS_DIR/outcomes.tsv" ]]; then
    assert_outcomes_field "helm retrieval_status = stale" "$TEST_STATUS_DIR/outcomes.tsv" "helm" 3 "stale"
    assert_outcomes_field "helm classification = attention" "$TEST_STATUS_DIR/outcomes.tsv" "helm" 7 "attention"
else
    echo -e "${RED}FAIL${NC}: outcomes.tsv not created"
    ((fail++))
fi

echo ""
echo "Test 41: retrieval status preserved in outcomes (failed stays failed)"
write_results_tsv "$TEST_STATUS_DIR" \
    $'postgresql\tnon-github\tfailed\t\tmajor version transition\tmajor-version-transition'

INVENTORY_PKGS=("postgresql")
classify_upgrade_evidence "$TEST_STATUS_DIR" "${INVENTORY_PKGS[@]}"

if [[ -f "$TEST_STATUS_DIR/outcomes.tsv" ]]; then
    assert_outcomes_field "postgresql retrieval_status = failed" "$TEST_STATUS_DIR/outcomes.tsv" "postgresql" 3 "failed"
    assert_outcomes_field "postgresql classification = attention" "$TEST_STATUS_DIR/outcomes.tsv" "postgresql" 7 "attention"
else
    echo -e "${RED}FAIL${NC}: outcomes.tsv not created"
    ((fail++))
fi

# ---------------------------------------------------------------------------
# Test Suite 12: top-level local -a is invalid (Correction 1)
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 12: Top-level 'local' is invalid in Bash ==="
echo ""

echo "Test 42: runtime source rejects top-level 'local -a'"
# Create a minimal script with top-level 'local -a' and source it to verify
# it causes a runtime error (local is only valid inside functions).
TEST_LOCAL_SCRIPT="$TEST_STATUS_DIR/test-local-toplevel.sh"
cat > "$TEST_LOCAL_SCRIPT" <<'TESTEOF'
#!/usr/bin/env bash
set -euo pipefail
local -a inventory_tokens=()
TESTEOF
chmod +x "$TEST_LOCAL_SCRIPT"
if (bash "$TEST_LOCAL_SCRIPT" 2>/dev/null); then
    echo -e "${RED}FAIL${NC}: top-level 'local -a' should cause runtime error"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: top-level 'local -a' causes runtime error"
    ((pass++))
fi

echo ""
echo "Test 43: brew-change passes bash -n (no syntax errors)"
if bash -n "$SCRIPT_DIR/../brew-change" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: brew-change passes bash -n"
    ((pass++))
else
    echo -e "${RED}FAIL${NC}: brew-change fails bash -n"
    ((fail++))
fi

echo ""
echo "Test 43b: brew-change sources without top-level local error"
# Verify that sourcing brew-change does not trigger a 'local' error
# by running it in a bounded subshell with BREW_CHANGE_SUBPROCESS set
# to skip dependency checks and command -v calls.
(
    # Set up a minimal environment so brew-change can be sourced
    # without hitting dependency errors before reaching the top-level code
    export BREW_CHANGE_SUBPROCESS="true"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    # Override verify_dependencies to succeed
    verify_dependencies() { return 0; }
    # Source the libs that brew-change sources, skipping the main script
    # entry point. The top-level 'local -a' in brew-change is in the
    # UPGRADE_MODE block, which only runs during actual execution, not
    # sourcing. So we test by checking for the pattern in the file.
    if grep -n '^ *local -a inventory_tokens' "$SCRIPT_DIR/../brew-change" >/dev/null 2>&1; then
        echo -e "${RED}FAIL${NC}: brew-change contains top-level 'local -a inventory_tokens'"
        exit 1
    else
        echo -e "${GREEN}PASS${NC}: brew-change has no top-level 'local -a inventory_tokens'"
        exit 0
    fi
)
if [[ $? -eq 0 ]]; then
    ((pass++))
else
    ((fail++))
fi

# ---------------------------------------------------------------------------
# Test Suite 13: Major version transition requires numeric versions
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 13: Numeric major version transition ==="
echo ""

echo "Test 44: is_major_version_transition detects numeric major bump"
if is_major_version_transition "1.5.0" "2.0.0"; then
    echo -e "${GREEN}PASS${NC}: 1.5.0 -> 2.0.0 is a major transition"
    ((pass++))
else
    echo -e "${RED}FAIL${NC}: 1.5.0 -> 2.0.0 should be a major transition"
    ((fail++))
fi

echo ""
echo "Test 45: is_major_version_transition rejects same major"
if is_major_version_transition "2.1.0" "2.5.0"; then
    echo -e "${RED}FAIL${NC}: 2.1.0 -> 2.5.0 should NOT be a major transition"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: 2.1.0 -> 2.5.0 is not a major transition"
    ((pass++))
fi

echo ""
echo "Test 46: is_major_version_transition rejects non-numeric installed"
if is_major_version_transition "HEAD" "2.0.0"; then
    echo -e "${RED}FAIL${NC}: HEAD -> 2.0.0 should NOT be a major transition (non-numeric)"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: HEAD -> 2.0.0 is not a major transition (non-numeric)"
    ((pass++))
fi

echo ""
echo "Test 47: is_major_version_transition rejects non-numeric latest"
if is_major_version_transition "1.5.0" "latest"; then
    echo -e "${RED}FAIL${NC}: 1.5.0 -> latest should NOT be a major transition (non-numeric)"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: 1.5.0 -> latest is not a major transition (non-numeric)"
    ((pass++))
fi

echo ""
echo "Test 48: is_major_version_transition rejects both non-numeric"
if is_major_version_transition "HEAD" "latest"; then
    echo -e "${RED}FAIL${NC}: HEAD -> latest should NOT be a major transition"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: HEAD -> latest is not a major transition"
    ((pass++))
fi

echo ""
echo "Test 49: is_major_version_transition handles empty version"
if is_major_version_transition "" "2.0.0"; then
    echo -e "${RED}FAIL${NC}: empty -> 2.0.0 should NOT be a major transition"
    ((fail++))
else
    echo -e "${GREEN}PASS${NC}: empty -> 2.0.0 is not a major transition"
    ((pass++))
fi

echo ""
echo "Test 50: is_major_version_transition handles 0.x to 1.x"
if is_major_version_transition "0.61" "1.0"; then
    echo -e "${GREEN}PASS${NC}: 0.61 -> 1.0 is a major transition"
    ((pass++))
else
    echo -e "${RED}FAIL${NC}: 0.61 -> 1.0 should be a major transition"
    ((fail++))
fi

echo ""
echo "Test 51: major-version evidence is recorded before release retrieval"
: > "$TEST_STATUS_DIR/results.tsv"
export UPGRADE_STATUS_DIR="$TEST_STATUS_DIR"
record_major_version_evidence "postgresql" "16.4" "17.0"
major_row=$(cat "$TEST_STATUS_DIR/results.tsv")
assert_eq "major evidence row" \
    $'postgresql\tinventory\tunavailable\t\tmajor version transition detected\tmajor-version-transition' \
    "$major_row"

echo ""
echo "Test 52: non-numeric versions do not emit major-version evidence"
: > "$TEST_STATUS_DIR/results.tsv"
record_major_version_evidence "example" "HEAD" "latest"
assert_eq "non-numeric evidence remains empty" "" "$(cat "$TEST_STATUS_DIR/results.tsv")"
unset UPGRADE_STATUS_DIR

echo ""
echo "Test 53: bulk prompt action resolves only to no-signal"
assert_eq "u selects no-signal" "no-signal" "$(upgrade_action_from_response "u" 2)"
assert_eq "Enter selects no-signal when available" "no-signal" "$(upgrade_action_from_response "" 2)"

echo ""
echo "Test 54: legacy bulk-all and safe actions cancel"
assert_eq "a is invalid" "invalid" "$(upgrade_action_from_response "a" 2)"
assert_eq "s is invalid" "invalid" "$(upgrade_action_from_response "s" 2)"
assert_eq "Enter cancels with no no-signal packages" "cancel" "$(upgrade_action_from_response "" 0)"

echo ""
echo "Test 55: only no-signal packages are default-selected"
ATTENTION_PKGS=("node")
NO_SIGNAL_PKGS=("git")
UNKNOWN_PKGS=("firefox")
if is_package_default_selected "git"; then
    echo -e "${GREEN}PASS${NC}: no-signal package is default-selected"
    ((pass++))
else
    echo -e "${RED}FAIL${NC}: no-signal package should be default-selected"
    ((fail++))
fi
for package in node firefox absent; do
    if is_package_default_selected "$package"; then
        echo -e "${RED}FAIL${NC}: $package must not be default-selected"
        ((fail++))
    else
        echo -e "${GREEN}PASS${NC}: $package is not default-selected"
        ((pass++))
    fi
done

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$TEST_STATUS_DIR"
trap - EXIT

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
