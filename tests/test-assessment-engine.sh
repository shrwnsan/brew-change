#!/usr/bin/env bash
# Fixture-backed tests for the pure assessment engine (T2.2.1 / T2.2.2).
#
# Exercises classify_assessment_records from lib/brew-change-assessment.sh:
# PRD 7.2 precedence, version-transition heuristics, tolerant-read/strict-write.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/brew-change-assessment.sh
source "$REPO_ROOT/lib/brew-change-assessment.sh"

FIXTURES="$SCRIPT_DIR/fixtures/assessment"

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

# get <file> <jq-filter> [line]
get() {
    local file="$1" filter="$2" line="${3:-1}"
    sed -n "${line}p" "$file" | jq -r "$filter"
}

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# --- File-arg mode over the full status x signal matrix ---------------------
classify_assessment_records "$FIXTURES/cases.jsonl" > "$OUT"

LINES=$(wc -l < "$OUT" | tr -d ' ')
assert_eq "one record out per record in (19 cases)" "$LINES" "19"

# strict-write: every emitted line is valid JSON with all 15 contract keys
KEYCHECK=$(jq -s 'all(.[]; (keys | sort) == (["assessment_recommendation","available_version","classification","default_selected","display_name","evidence_snapshot","evidence_source","evidence_url","installed_version","kind","matched_signals","operational_eligibility","package","reasons","retrieval_status","retrieved_at"] | sort))' "$OUT")
assert_eq "strict-write: all 15+retrieved_at keys present on every line" "$KEYCHECK" "true"

line_of() { grep -n "\"package\":\"$1\"" "$OUT" | head -1 | cut -d: -f1; }

cls() { get "$OUT" '.classification' "$(line_of "$1")"; }
rec()  { get "$OUT" '.assessment_recommendation' "$(line_of "$1")"; }
sel()  { get "$OUT" '.default_selected' "$(line_of "$1")"; }
sig()  { get "$OUT" '.matched_signals | join(",")' "$(line_of "$1")"; }
rsn()  { get "$OUT" '.reasons | join(";")' "$(line_of "$1")"; }

# --- PRD 7.2 precedence -------------------------------------------------------
assert_eq "fresh + breaking evidence -> attention" "$(cls f-attention-breaking)" "attention"
assert_eq "breaking signal token recorded" "$(sig f-attention-breaking)" "breaking-change-pattern"
assert_eq "breaking reason mentions evidence" "$(rsn f-attention-breaking)" "evidence matched configured breaking-change pattern"

assert_eq "fresh + no signal -> no-signal" "$(cls f-nosignal-eligible)" "no-signal"
assert_eq "no-signal + eligible -> recommendation true" "$(rec f-nosignal-eligible)" "true"
assert_eq "no-signal keeps default_selected false" "$(sel f-nosignal-eligible)" "false"

assert_eq "fresh + no signal + ineligible -> recommendation false" "$(rec f-nosignal-ineligible)" "false"

assert_eq "cached-fresh + no signal -> no-signal" "$(cls f-nosignal-cached)" "no-signal"
assert_eq "cached-fresh + eligible -> recommendation true" "$(rec f-nosignal-cached)" "true"

# --- T2.2.2 version-transition heuristics ------------------------------------
assert_eq "major transition (21.7.3 -> 22.1.0) -> attention" "$(cls f-major-fresh)" "attention"
assert_eq "major signal token recorded" "$(sig f-major-fresh)" "major-version-transition"
R=$(rsn f-major-fresh)
if [[ "$R" == *heuristic* ]]; then ok "major reason labeled heuristic"; else no "major reason labeled heuristic" "got: '$R'"; fi
assert_eq "major attention: recommendation false" "$(rec f-major-fresh)" "false"
assert_eq "major attention: default_selected false" "$(sel f-major-fresh)" "false"

assert_eq "version heuristic independent of evidence availability" "$(cls f-major-unavailable)" "attention"
assert_eq "major + unavailable still records signal" "$(sig f-major-unavailable)" "major-version-transition"
assert_eq "major + unavailable keeps retrieval_status" "$(get "$OUT" '.retrieval_status' "$(line_of f-major-unavailable)")" "unavailable"

assert_eq "two-segment major (1.2 -> 2.0) -> attention" "$(cls f-major-two-seg)" "attention"

assert_eq "revision-only (_1 -> _2) is not a major" "$(cls f-revision-only)" "no-signal"
assert_eq "revision-only records no signals" "$(sig f-revision-only)" ""

assert_eq "calendar version (2026.8.17 -> 2027.1.2) makes no major claim" "$(cls f-calendar)" "no-signal"
assert_eq "calendar version records no signals" "$(sig f-calendar)" ""

assert_eq "junk non-semver strings make no major claim" "$(cls f-junk-version)" "no-signal"
assert_eq "junk version records no signals" "$(sig f-junk-version)" ""

# --- integrator ruling: fresh status without timestamp is contradictory -------
assert_eq "fresh with null retrieved_at -> unknown" "$(cls f-fresh-null-ts)" "unknown"
assert_eq "fresh with null retrieved_at: no signals" "$(sig f-fresh-null-ts)" ""
assert_eq "fresh with null retrieved_at: recommendation false" "$(rec f-fresh-null-ts)" "false"
RT=$(rsn f-fresh-null-ts)
if [[ "$RT" == *"contradictory freshness"* ]]; then ok "fresh null-ts reason names contradictory freshness"; else no "fresh null-ts reason names contradictory freshness" "got: '$RT'"; fi
assert_eq "cached-fresh with null retrieved_at -> unknown" "$(cls f-cached-fresh-null-ts)" "unknown"
CT=$(rsn f-cached-fresh-null-ts)
if [[ "$CT" == *"contradictory freshness"* ]]; then ok "cached-fresh null-ts reason names contradictory freshness"; else no "cached-fresh null-ts reason names contradictory freshness" "got: '$CT'"; fi

# --- every non-fresh status -> unknown ----------------------------------------
for p in f-stale f-failed f-malformed-status f-contradictory f-rate-limited f-unsupported; do
    assert_eq "$p -> unknown" "$(cls "$p")" "unknown"
    assert_eq "$p unknown: recommendation false" "$(rec "$p")" "false"
    assert_eq "$p unknown: default_selected false" "$(sel "$p")" "false"
done

# --- fidelity ------------------------------------------------------------------
assert_eq "unicode package token survives" "$(get "$OUT" '.package' "$(line_of 'f-unicode-🍺')")" "f-unicode-🍺"
assert_eq "unicode display name survives" "$(get "$OUT" '.display_name' "$(line_of 'f-unicode-🍺')")" "pkg-ünïcode-🍺"

# --- no terminal formatting in module output ----------------------------------
if grep -q $'\033\[' "$OUT"; then
    no "module output contains no ANSI escapes"
else
    ok "module output contains no ANSI escapes"
fi

# --- stdin mode matches file-arg mode ------------------------------------------
OUT2="$(mktemp)"
classify_assessment_records < "$FIXTURES/cases.jsonl" > "$OUT2"
if cmp -s "$OUT" "$OUT2"; then ok "stdin mode identical to file-arg mode"; else no "stdin mode identical to file-arg mode"; fi
rm -f "$OUT2"

# --- tolerant read: malformed lines force-classified unknown -------------------
classify_assessment_records "$FIXTURES/malformed.jsonl" > "$OUT"
assert_eq "malformed fixture: 3 lines in, 3 lines out" "$(wc -l < "$OUT" | tr -d ' ')" "3"
assert_eq "record before malformed line classified" "$(get "$OUT" '.classification' 1)" "no-signal"
assert_eq "malformed line -> unknown" "$(get "$OUT" '.classification' 2)" "unknown"
assert_eq "malformed line reason" "$(get "$OUT" '.reasons | join(";")' 2)" "malformed record"
assert_eq "malformed line default_selected false" "$(get "$OUT" '.default_selected' 2)" "false"
assert_eq "record after malformed line classified" "$(get "$OUT" '.classification' 3)" "attention"

# --- determinism ----------------------------------------------------------------
classify_assessment_records "$FIXTURES/cases.jsonl" > "$OUT" 2>/dev/null
OUT3="$(classify_assessment_records "$FIXTURES/cases.jsonl")"
if [[ "$(< "$OUT")" == "$OUT3" ]]; then ok "pure: repeated runs byte-identical"; else no "pure: repeated runs byte-identical"; fi

printf '\nassessment engine: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
