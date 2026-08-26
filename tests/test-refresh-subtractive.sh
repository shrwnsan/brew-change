#!/usr/bin/env bash
# Subtractive refresh (post-upgrade re-derivation skip) — the session's
# same-transition records are kept verbatim; only changed transitions,
# new packages, and retryable rows re-derive. Field feedback 2026-08-25:
# a 24-package refresh re-probed everything for 198-222s.
#
# Two layers:
#   1. _dashboard_subtractive_plan keep/re-derive rules (pure helper)
#   2. dashboard_refresh_records orchestration with the pipeline stubbed
#      (subset filtering, all-kept fast path, ordered merge)
#
# Usage: bash tests/test-refresh-subtractive.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-breaking.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-dashboard.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-dashboard-ui.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
pass=0
fail=0

pass() { pass=$((pass + 1)); printf "${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { fail=$((fail + 1)); printf "${RED}FAIL${NC}: %s\n" "$1" >&2; }
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc (expected='$expected' actual='$actual')"
    fi
}
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (missing '$needle')"
    fi
}

record() { # package inst avail cls status
    jq -cn --arg p "$1" --arg i "$2" --arg a "$3" --arg c "$4" --arg s "$5" \
        '{package:$p, installed_version:$i, available_version:$a,
          classification:$c, retrieval_status:$s}'
}

echo "======================================"
echo "Subtractive Refresh Tests"
echo "======================================"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/refresh-subtractive.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

# --- 1. Plan rules -----------------------------------------------------------

RECORDS="$TMPD/records.jsonl"
{
    record keep-att   1.0.0 2.0.0 attention    fresh
    record keep-ns    1.0.0 1.1.0 no-signal    cached-fresh
    record keep-un    1.0.0 1.0.1 unknown      unavailable
    record retry-rl   1.0.0 1.0.1 unknown      rate-limited
    record retry-st   1.0.0 1.0.1 unknown      stale
    record changed    1.0.0 1.2.0 no-signal    fresh
    record upgraded   1.0.0 2.0.0 no-signal    fresh
} > "$RECORDS"

# Inventory: same transitions for the first six, CHANGED available for
# `changed`, nothing for `upgraded` (it upgraded), plus NEW `newpkg`.
OUTDATED='{"formulae":[
    {"name":"keep-att","installed_versions":["1.0.0"],"current_version":"2.0.0"},
    {"name":"keep-ns","installed_versions":["1.0.0"],"current_version":"1.1.0"},
    {"name":"keep-un","installed_versions":["1.0.0"],"current_version":"1.0.1"},
    {"name":"retry-rl","installed_versions":["1.0.0"],"current_version":"1.0.1"},
    {"name":"retry-st","installed_versions":["1.0.0"],"current_version":"1.0.1"},
    {"name":"changed","installed_versions":["1.0.0"],"current_version":"1.5.0"},
    {"name":"newpkg","installed_versions":["0.1.0"],"current_version":"0.2.0"}
],"casks":[]}'

KEPT="$TMPD/kept.jsonl"
PLAN="$TMPD/plan.txt"
if _dashboard_subtractive_plan "$RECORDS" "$OUTDATED" "$KEPT" > "$PLAN"; then
    pass "plan succeeds on well-formed records"
else
    fail "plan should succeed"
fi

assert_eq "kept count (att + no-signal + unavailable-unknown)" \
    "3" "$(grep -c '' "$KEPT")"
assert_contains "attention kept" keep-att "$(cat "$KEPT")"
assert_contains "no-signal kept" keep-ns "$(cat "$KEPT")"
assert_contains "unavailable-unknown kept" keep-un "$(cat "$KEPT")"

assert_eq "re-derive set (rate-limited + stale + changed + new)" \
    "4" "$(grep -c '' "$PLAN")"
assert_contains "rate-limited retried" retry-rl "$(cat "$PLAN")"
assert_contains "stale retried" retry-st "$(cat "$PLAN")"
assert_contains "changed transition re-derived" changed "$(cat "$PLAN")"
assert_contains "new package re-derived" newpkg "$(cat "$PLAN")"

if ! grep -q "upgraded" "$KEPT" && ! grep -q "upgraded" "$PLAN"; then
    pass "upgraded package drops out entirely"
else
    fail "upgraded package must be in neither set"
fi
if ! grep -q "keep-un" "$PLAN"; then
    pass "unavailable-unknown NOT re-derived (the slow scrapes)"
else
    fail "unavailable-unknown must be kept"
fi

# Empty/missing records -> fallback signal
if _dashboard_subtractive_plan "$TMPD/nope.jsonl" "$OUTDATED" "$KEPT" >/dev/null 2>&1; then
    fail "missing records must signal fallback"
else
    pass "missing records signals fallback (rc 1)"
fi

# --- 2. Orchestration with the pipeline stubbed ------------------------------

export UPGRADE_STATUS_DIR="$TMPD/run"
mkdir -p "$UPGRADE_STATUS_DIR"

# Stubs record their calls in FILES: dashboard_refresh_records runs inside
# a command substitution in these tests, so variable captures in a subshell
# would never propagate back.
rm -f "$TMPD/parallel-args" "$TMPD/classify-args"
process_packages_parallel() { printf '%s' "$1" > "$TMPD/parallel-args"; return 0; }
classify_upgrade_evidence() {
    local dir="$1"; shift
    printf '%s\n' "$@" > "$TMPD/classify-args"
    # Re-derived rows land in assessment.jsonl (init + classify wrote the
    # subset inventory); simulate classify output by rewriting versions.
    local out="$dir/.classified.$$"
    : > "$out"
    local pkg
    for pkg in "$@"; do
        jq -cn --arg p "$pkg" \
            '{package:$p, installed_version:"9.9.9", available_version:"9.9.9",
              classification:"rederived"}' >> "$out"
    done
    mv "$out" "$dir/assessment.jsonl"
    return 0
}
progress_renderer_start() { :; }
progress_renderer_stop() { :; }
_dashboard_flush_pending_summary() { :; }

# Records as the initial pass left them; inventory drops keep-ns (upgraded).
cat > "$UPGRADE_STATUS_DIR/assessment.jsonl" <<J
$(record alpha 1.0.0 2.0.0 attention fresh)
$(record beta 1.0.0 1.1.0 no-signal cached-fresh)
$(record gamma 1.0.0 1.0.1 unknown unavailable)
$(record delta 1.0.0 1.0.1 unknown rate-limited)
J

OUT2='{"formulae":[
    {"name":"alpha","installed_versions":["1.0.0"],"current_version":"2.0.0"},
    {"name":"gamma","installed_versions":["1.0.0"],"current_version":"1.0.1"},
    {"name":"delta","installed_versions":["1.0.0"],"current_version":"1.0.1"},
    {"name":"epsilon","installed_versions":["0.1.0"],"current_version":"0.2.0"}
],"casks":[]}'

_dashboard_fetch_outdated_json() { printf '%s' "$OUT2"; }

RESULT="$(dashboard_refresh_records)"
RC=$?
assert_eq "refresh returns records path rc" "0" "$RC"
assert_eq "returned path is the run records" "$UPGRADE_STATUS_DIR/assessment.jsonl" "$RESULT"

assert_eq "classify ran on the re-derive subset only" \
    "delta epsilon" "$(tr '\n' ' ' < "$TMPD/classify-args" | sed 's/ $//')"
assert_contains "parallel got the filtered inventory" '"name":"delta"' "$(cat "$TMPD/parallel-args")"
if [[ "$(cat "$TMPD/parallel-args")" != *"alpha"* ]]; then
    pass "kept packages never enter the worker pass"
else
    fail "kept package leaked into worker pass"
fi

FINAL="$(cat "$UPGRADE_STATUS_DIR/assessment.jsonl")"
assert_contains "kept attention survives verbatim" \
    '"package":"alpha","installed_version":"1.0.0","available_version":"2.0.0","classification":"attention"' "$FINAL"
assert_contains "kept unavailable-unknown survives verbatim" \
    '"package":"gamma"' "$FINAL"
assert_contains "re-derived delta rewritten" '"package":"delta","installed_version":"9.9.9"' "$FINAL"
assert_contains "new epsilon present" '"package":"epsilon"' "$FINAL"
assert_eq "final record count in inventory order" "4" "$(grep -c '' "$UPGRADE_STATUS_DIR/assessment.jsonl")"
ORDER="$(jq -r '.package' "$UPGRADE_STATUS_DIR/assessment.jsonl" | tr '\n' ' ')"
assert_eq "inventory order preserved" "alpha gamma delta epsilon " "$ORDER"
if ! grep -q '"package":"beta"' "$UPGRADE_STATUS_DIR/assessment.jsonl"; then
    pass "upgraded beta absent from refreshed records"
else
    fail "upgraded package leaked into refreshed records"
fi

# --- 3. All-kept fast path: no pipeline at all -------------------------------

rm -f "$TMPD/parallel-args" "$TMPD/classify-args"
cat > "$UPGRADE_STATUS_DIR/assessment.jsonl" <<J
$(record alpha 1.0.0 2.0.0 attention fresh)
$(record gamma 1.0.0 1.0.1 unknown unavailable)
J
OUT3='{"formulae":[
    {"name":"alpha","installed_versions":["1.0.0"],"current_version":"2.0.0"},
    {"name":"gamma","installed_versions":["1.0.0"],"current_version":"1.0.1"}
],"casks":[]}'
_dashboard_fetch_outdated_json() { printf '%s' "$OUT3"; }

RESULT3="$(dashboard_refresh_records)"
assert_eq "all-kept fast path returns path" "$UPGRADE_STATUS_DIR/assessment.jsonl" "$RESULT3"
if [[ ! -e "$TMPD/parallel-args" && ! -e "$TMPD/classify-args" ]]; then
    pass "all-kept: no worker pass, no classify"
else
    fail "all-kept must skip the pipeline entirely"
fi
assert_eq "all-kept record count" "2" "$(grep -c '' "$UPGRADE_STATUS_DIR/assessment.jsonl")"

echo ""
printf 'Subtractive refresh tests: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
