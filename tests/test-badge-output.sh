#!/usr/bin/env bash
# Tests for the badge surface (prd-004 / tasks-006).
#
# Exercises lib/brew-change-badge.sh:
# - badge_counts extracts verdict counts from the export
# - badge_render_line renders the dense one-line contract
# - badge_age_human formats relative age
# - badge_generated_epoch parses ISO-8601 UTC
# - badge_main output contract (Task 3 adds those tests to this file)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/brew-change-badge.sh
source "$REPO_ROOT/lib/brew-change-badge.sh"

FIXTURES="$SCRIPT_DIR/fixtures/badge"
mkdir -p "$FIXTURES"
FIXTURE_EXPORT="$FIXTURES/last-assessment.json"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf 'ok %d - %s\n' "$pass" "$1"
}

no() {
    fail=$((fail + 1))
    printf 'not ok %d - %s\n' "$((pass + fail))" "$1"
    shift
    printf '    %s\n' "$*" >&2
}

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        ok "$desc"
    else
        no "$desc" "got: '$got'  want: '$want'"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$desc"
    else
        no "$desc" "expected '$needle' in '$haystack'"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$desc"
    else
        no "$desc" "did not expect '$needle' in '$haystack'"
    fi
}

# make_export <path> <generated_at_iso> <packages_json_array>
make_export() {
    jq -n --arg ts "$2" --argjson pkgs "$3" \
        '{schema_version: 1, generated_at: $ts, packages: $pkgs}' > "$1"
}

# --- badge_counts -----------------------------------------------------------
make_export "$FIXTURE_EXPORT" "2026-10-05T12:00:00Z" '[
  {"name":"node","classification":"attention","matched_signals":["breaking-change-pattern"]},
  {"name":"python","classification":"attention","matched_signals":["major-version-transition"]},
  {"name":"wget","classification":"no-signal","matched_signals":[]},
  {"name":"gh","classification":"unknown","matched_signals":[]}
]'
assert_eq "badge_counts: counts + breaking names + classifications" \
    "$(badge_counts "$FIXTURE_EXPORT")" \
    "4|1|node|1|1"

printf '{"schema_version":1,"generated_at":"x","packages":[{"name":"a","classification":"attention","matched_signals":["breaking-change-pattern"]}],"extra":true}' > "$FIXTURE_EXPORT"
assert_eq "badge_counts: single breaking" \
    "$(badge_counts "$FIXTURE_EXPORT")" \
    "1|1|a|0|0"

printf 'not json' > "$FIXTURE_EXPORT"
if badge_counts "$FIXTURE_EXPORT" >/dev/null 2>&1; then
    no "badge_counts: malformed JSON fails" "returned success"
else
    ok "badge_counts: malformed JSON fails"
fi

if badge_counts "$FIXTURES/missing.json" >/dev/null 2>&1; then
    no "badge_counts: missing file fails" "returned success"
else
    ok "badge_counts: missing file fails"
fi

# --- badge_render_line ------------------------------------------------------
assert_eq "render: all segments" \
    "$(badge_render_line 4 2 "node,python" 1 1 "2h")" \
    "brew-change: 4 updates · 2 breaking (node, python) · 1 no-signal · 1 unknown · 2h ago"

assert_eq "render: name cap at 3 then +K" \
    "$(badge_render_line 5 4 "a,b,c,d" 0 0 "3d")" \
    "brew-change: 5 updates · 4 breaking (a, b, c +1) · 3d ago"

assert_eq "render: updates + age only" \
    "$(badge_render_line 3 0 "" 0 0 "1m")" \
    "brew-change: 3 updates · 1m ago"

assert_eq "render: updates only, empty age" \
    "$(badge_render_line 3 0 "" 0 0 "")" \
    "brew-change: 3 updates"

# --- badge_age_human --------------------------------------------------------
assert_eq "age: minutes" "$(badge_age_human 1000 1900)" "15m"
assert_eq "age: zero delta is 1m" "$(badge_age_human 500 500)" "1m"
assert_eq "age: hours" "$(badge_age_human 0 7200)" "2h"
assert_eq "age: days" "$(badge_age_human 0 259200)" "3d"
assert_eq "age: clock skew clamps to 1m" "$(badge_age_human 5000 4000)" "1m"

# --- badge_generated_epoch --------------------------------------------------
WANT_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T00:00:00Z" +"%s" 2>/dev/null \
    || date -u -d "2026-01-01T00:00:00Z" +"%s")"
assert_eq "epoch: ISO-8601 Z" "$(badge_generated_epoch "2026-01-01T00:00:00Z")" "$WANT_EPOCH"

if badge_generated_epoch "not-a-date" >/dev/null 2>&1; then
    no "epoch: garbage rejected" "returned success"
else
    ok "epoch: garbage rejected"
fi

# --- badge_main --------------------------------------------------------------
# Re-point the lock + export at fixture paths (the lib derived them from the
# real HOME at source time, exactly like tests/test-assessment-export.sh).
REFRESH_LOCK_DIR="$FIXTURES/badge-main.lock"
export ASSESSMENT_EXPORT_FILE="$FIXTURE_EXPORT"
export BREW_CHANGE_BADGE_FORCE=1       # tests run without a TTY on stdout
export BREW_CHANGE_BADGE_NO_SPAWN=1
ts_now="2026-10-05T12:00:00Z"
export BREW_CHANGE_TEST_NOW="$(badge_generated_epoch "$ts_now")"

# fresh export: line only, no suffix
make_export "$FIXTURE_EXPORT" "$ts_now" \
    '[{"name":"node","classification":"attention","matched_signals":["breaking-change-pattern"]}]'
assert_eq "badge_main: fresh line" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: 1 updates · 1 breaking (node) · 1m ago"

# zero packages: still a valid fresh line
make_export "$FIXTURE_EXPORT" "$ts_now" '[]'
assert_eq "badge_main: zero updates" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: 0 updates · 1m ago"

# stale export (36h old > 24h default): refreshing suffix
make_export "$FIXTURE_EXPORT" "2026-10-04T00:00:00Z" \
    '[{"name":"node","classification":"unknown","matched_signals":[]}]'
out="$(badge_main after-update "$REPO_ROOT/brew-change")"
assert_contains "badge_main: stale suffix" "$out" "· refreshing…"
assert_contains "badge_main: stale age" "$out" "36h ago"

# upgrade trigger: always updating suffix, even when fresh
make_export "$FIXTURE_EXPORT" "$ts_now" '[]'
assert_contains "badge_main: upgrade suffix" \
    "$(badge_main after-upgrade "$REPO_ROOT/brew-change")" "· assessment updating…"

# custom max age: 3600 makes the 36h-old export stale, 172800 (48h) keeps it
# fresh. The assignment sits INSIDE the substitution: a prefix assignment on
# the assert_* call would not apply while $(...) arguments expand.
make_export "$FIXTURE_EXPORT" "2026-10-04T00:00:00Z" '[]'
assert_contains "badge_main: BREW_CHANGE_BADGE_MAX_AGE shortens freshness" \
    "$(BREW_CHANGE_BADGE_MAX_AGE=3600 badge_main after-update "$REPO_ROOT/brew-change")" "· refreshing…"
assert_not_contains "badge_main: BREW_CHANGE_BADGE_MAX_AGE extends freshness" \
    "$(BREW_CHANGE_BADGE_MAX_AGE=172800 badge_main after-update "$REPO_ROOT/brew-change")" "refreshing"

# garbage max age: falls back to default (24h → 36h-old export is stale), never crashes
assert_eq "badge_main: garbage max age falls back to default" \
    "$(BREW_CHANGE_BADGE_MAX_AGE=notanumber badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: 0 updates · 36h ago · refreshing…"

# missing export: setup hint
export ASSESSMENT_EXPORT_FILE="$FIXTURES/does-not-exist.json"
assert_eq "badge_main: missing → hint" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: no assessment yet — run brew-change -b"

# malformed export: silence (non-event contract)
printf 'not json' > "$FIXTURE_EXPORT"
export ASSESSMENT_EXPORT_FILE="$FIXTURE_EXPORT"
assert_eq "badge_main: malformed → silence" "$(badge_main after-update x)" ""

# future schema: silence
jq -n '{schema_version: 99, generated_at: "2026-10-05T12:00:00Z", packages: []}' > "$FIXTURE_EXPORT"
assert_eq "badge_main: future schema → silence" "$(badge_main after-update x)" ""

# unparsable generated_at: silence
jq -n '{schema_version: 1, generated_at: "garbage", packages: []}' > "$FIXTURE_EXPORT"
assert_eq "badge_main: bad generated_at → silence" "$(badge_main after-update x)" ""

# disable beats force
make_export "$FIXTURE_EXPORT" "$ts_now" '[]'
export BREW_CHANGE_BADGE_DISABLE=1
assert_eq "badge_main: disable beats force" "$(badge_main after-update x)" ""
unset BREW_CHANGE_BADGE_DISABLE

# piped stdout (force off): silence
unset BREW_CHANGE_BADGE_FORCE
assert_eq "badge_main: piped stdout is silent" "$(badge_main after-update x)" ""
export BREW_CHANGE_BADGE_FORCE=1
unset BREW_CHANGE_BADGE_NO_SPAWN BREW_CHANGE_TEST_NOW

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
