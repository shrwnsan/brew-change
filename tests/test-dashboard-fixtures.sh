#!/usr/bin/env bash
# T2.3.1 — golden dashboard fixture validation.
#
# Validates that every input file is contract-conformant JSONL (research-005
# schema: exact key set, vocabulary checks, selection invariants) and that
# every expected-render file agrees with its input (summary counts, group
# header counts, row totals, group order, footer no-signal count). This
# catches fixture drift between input records and golden renders.
#
# Usage: bash tests/test-dashboard-fixtures.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/dashboard"

passed=0
failed=0

pass() { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# Exact key set from the approved record contract (research-005).
read -r -d '' CONTRACT_KEYS <<'EOF' || true
["assessment_recommendation","available_version","classification","default_selected","display_name","evidence_snapshot","evidence_source","evidence_url","installed_version","kind","matched_signals","operational_eligibility","package","reasons","retrieval_status","retrieved_at"]
EOF

SCENARIOS="mixed all-no-signal all-unknown no-outdated long-names narrow-60 no-color piped"

validate_input() { # scenario-dir
    local dir="$1" line_no=0 line ok
    local input="$dir/input.jsonl"
    while IFS= read -r line || [[ -n $line ]]; do
        line_no=$((line_no + 1))
        [[ -z $line ]] && continue

        echo "$line" | jq -e . >/dev/null 2>&1 || {
            fail "$dir: line $line_no is not valid JSON"; return 1; }

        ok=$(echo "$line" | jq -r --argjson keys "$CONTRACT_KEYS" '
            [ (keys == $keys),
              (.package | type == "string" and length > 0),
              (.kind | IN("formula", "cask")),
              (.installed_version | type == "string"),
              (.available_version | type == "string"),
              (.classification | IN("attention", "no-signal", "unknown")),
              (.retrieval_status | IN("fresh", "cached-fresh", "stale", "unavailable",
                                      "failed", "malformed", "contradictory",
                                      "rate-limited", "unsupported")),
              (.reasons | type == "array"),
              (.matched_signals | type == "array"),
              ((.classification == "no-signal") or (.default_selected == false)),
              ((.classification == "no-signal") or (.assessment_recommendation == false))
            ] | all' 2>/dev/null)
        if [[ $ok != true ]]; then
            fail "$dir: line $line_no violates the record contract (keys/vocab/types/selection invariants)"
            return 1
        fi
    done < "$input"
    pass
}

group_header_regex() { # class -> header prefix
    case $1 in
        attention) echo 'Needs attention' ;;
        no-signal) echo 'No risk signal found' ;;
        unknown)   echo 'Unknown' ;;
    esac
}

validate_render() { # scenario-dir
    local dir="$1"
    local input="$dir/input.jsonl" render="$dir/expected.txt"
    local total att ns unk
    total=$(jq -s 'length' "$input")
    att=$(jq -sr '[.[] | select(.classification == "attention")] | length' "$input")
    ns=$(jq -sr '[.[] | select(.classification == "no-signal")] | length' "$input")
    unk=$(jq -sr '[.[] | select(.classification == "unknown")] | length' "$input")

    if (( total == 0 )); then
        if [[ $(<"$render") == "No outdated packages." ]]; then
            pass
        else
            fail "$dir: empty input must render exactly 'No outdated packages.'"
        fi
        return
    fi

    # Summary line: "N outdated · A attention · B no-signal · C unknown"
    local summary
    summary=$(sed -n '1p' "$render")
    if [[ $summary =~ ^([0-9]+)\ outdated\ ·\ ([0-9]+)\ attention\ ·\ ([0-9]+)\ no-signal\ ·\ ([0-9]+)\ unknown$ ]]; then
        if [[ ${BASH_REMATCH[1]} == "$total" && ${BASH_REMATCH[2]} == "$att" \
           && ${BASH_REMATCH[3]} == "$ns" && ${BASH_REMATCH[4]} == "$unk" ]]; then
            pass
        else
            fail "$dir: summary counts ('$summary') disagree with input ($total/$att/$ns/$unk)"
        fi
    else
        fail "$dir: summary line malformed: '$summary'"
    fi

    # Group headers: exactly one per non-empty class, count matching, order fixed.
    local expected_order=() cls want_n header_n
    for cls in attention no-signal unknown; do
        case $cls in
            attention) want_n=$att ;;
            no-signal) want_n=$ns ;;
            *)         want_n=$unk ;;
        esac
        header_n=$(grep -c "^$(group_header_regex "$cls") ([0-9]*)\$" "$render" || true)
        if (( want_n == 0 )); then
            [[ $header_n == 0 ]] || fail "$dir: unexpected '$cls' group header with 0 records"
        else
            [[ $header_n == 1 ]] || fail "$dir: expected exactly one '$cls' group header"
            local n
            n=$(grep "^$(group_header_regex "$cls") ([0-9]*)\$" "$render" | grep -o '[0-9]*')
            [[ $n == "$want_n" ]] || fail "$dir: '$cls' group header count $n != $want_n"
            expected_order+=("$(group_header_regex "$cls")")
        fi
    done

    local order
    order=$(grep -E '^(Needs attention|No risk signal found|Unknown) \([0-9]+\)$' "$render" \
            | sed -E 's/ \([0-9]+\)$//' | paste -sd, -)
    local expectedJoined
    expectedJoined=$(printf '%s\n' "${expected_order[@]}" | paste -sd, -)
    if [[ $order == "$expectedJoined" ]]; then pass; else fail "$dir: group order '$order' != '$expectedJoined'"; fi

    # Row totals: every package row is a two-space-indented line.
    local rows
    rows=$(grep -c '^  [^ ]' "$render" || true)
    if [[ $rows == "$total" ]]; then pass; else fail "$dir: row count $rows != total $total"; fi

    # Footer: [u] count matches when present; must be absent when ns == 0.
    if (( ns > 0 )); then
        local footer_ns
        footer_ns=$(grep -o '\[u\] Upgrade no-signal ([0-9]*)' "$render" | grep -o '[0-9]*')
        if [[ $footer_ns == "$ns" ]]; then pass; else fail "$dir: footer no-signal count '$footer_ns' != $ns"; fi
    else
        if grep -q '\[u\] Upgrade no-signal' "$render"; then
            fail "$dir: footer offers upgrade-no-signal with 0 no-signal records"
        else
            pass
        fi
    fi
}

for s in $SCENARIOS; do
    d="$FIXTURE_DIR/$s"
    if [[ -f $d/input.jsonl && -f $d/expected.txt ]]; then
        validate_input "$d"
        # The piped scenario is the plain name-only variant; its render is
        # checked by the scenario-specific invariant below, not the TTY rules.
        [[ $s == piped ]] || validate_render "$d"
    else
        fail "$s: missing input.jsonl or expected.txt"
    fi
done

# Scenario-specific invariants ----------------------------------------------

# piped: byte-identical to the plain name-only list (today's bare contract).
if diff <(jq -r '.package' "$FIXTURE_DIR/piped/input.jsonl") "$FIXTURE_DIR/piped/expected.txt" >/dev/null; then
    pass
else
    fail "piped: expected render is not the plain name-only list"
fi
if grep -qE 'outdated|attention|Unknown|No risk|\[r\]|\[q\]' "$FIXTURE_DIR/piped/expected.txt"; then
    fail "piped: render contains dashboard chrome (must be names only)"
else
    pass
fi

# Label-free rows + differential reasons (ratified design): group headers
# state the classification, so NO package row may carry the classification
# strings; no-signal rows carry NO reason content (rows end at the versions
# column); unknown rows' reason — when the column survives degradation — is a
# bare retrieval-status token from the ^[a-z-]+$ vocabulary, except that the
# dominant no-action token "unavailable" is suppressed entirely.
for s in mixed all-no-signal all-unknown long-names narrow-60 no-color; do
    r="$FIXTURE_DIR/$s/expected.txt"
    bad_label=$(awk '/^  [^ ]/ && /Needs attention|No risk signal|Unknown/' "$r")
    if [[ -z $bad_label ]]; then
        pass
    else
        fail "$s: package row carries a classification label: '$bad_label'"
    fi
    bad_ns=$(awk '/^No risk signal found \(/{f=1;next} f && /^$/{f=0} f && $0 !~ /^  [^ ]+ +.* → [^ ]+$/' "$r")
    if [[ -z $bad_ns ]]; then
        pass
    else
        fail "$s: no-signal row carries reason text: '$bad_ns'"
    fi
    bad_unk=$(awk '/^Unknown \(/{f=1;next} f && /^$/{f=0} f {
        if ($0 !~ /→/) { print; next }
        if (match($0, /  [a-z][a-z-]*$/)) {
            if (substr($0, RSTART + 2) == "unavailable") print
        }
    }' "$r")
    if [[ -z $bad_unk ]]; then
        pass
    else
        fail "$s: unknown row reason is not a bare non-unavailable status token: '$bad_unk'"
    fi
done

# no-color: byte-identical to the base render (text labels carry all meaning).
if cmp -s "$FIXTURE_DIR/mixed/expected.txt" "$FIXTURE_DIR/no-color/expected.txt"; then
    pass
else
    fail "no-color: expected render differs from mixed (text labels must carry all meaning)"
fi

printf 'dashboard fixtures: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
