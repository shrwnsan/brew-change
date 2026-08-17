#!/usr/bin/env bash
# Pure assessment engine for brew-change (T2.2.1 / T2.2.2).
#
# Consumes and produces approved-contract JSONL records
# (docs/research-005-assessment-record-contract.md). One record in, one
# record out per package; every emitted line carries the full 16-key schema
# (strict-write). Malformed input lines are force-classified `unknown`
# with reason "malformed record" (tolerant-read).
#
# Classification precedence (PRD §7.2):
#   1. attention  - any version heuristic or adequate evidence matched a
#                   configured signal
#   2. no-signal  - retrieval_status is fresh|cached-fresh AND a valid
#                   retrieved_at timestamp AND no signal (a freshness status
#                   without a timestamp is contradictory freshness)
#   3. unknown    - otherwise (stale/malformed/unsupported/rate-limited/
#                   contradictory/unavailable/failed/...)
#
# This module is PURE: no terminal formatting, no side effects, no writes.
# Output goes to stdout only.

_ASSESSMENT_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse the existing breaking-change pattern matcher so evidence-signal
# behavior stays compatible with the pre-assessment-module flow.
# shellcheck disable=SC1091 # dynamic path; sources sibling module
if [[ -f "$_ASSESSMENT_MODULE_DIR/brew-change-breaking.sh" ]]; then
    source "$_ASSESSMENT_MODULE_DIR/brew-change-breaking.sh"
fi

# ---------------------------------------------------------------------------
# _assessment_version_core <version>
# Strips a trailing Homebrew revision suffix (_N) from a version string.
_assessment_version_core() {
    printf '%s' "$1" | sed '/_[0-9][0-9]*$/s///'
}

# _assessment_is_dotted_numeric <version>
# True (0) when the version is confidently parsed as dotted numeric with at
# least two segments, e.g. "1.2", "22.6.0", "3.14_1". Anything else
# ("v2.3-beta", "abc", "22") is not parsed and never produces a semantic
# claim.
_assessment_is_dotted_numeric() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)+$ ]]
}

# _assessment_is_calendar_version <version-core>
# True (0) when the leading segment is a four-digit year (calendar scheme,
# e.g. 2026.8.17). Calendar schemes make no major/minor semantic claims.
_assessment_is_calendar_version() {
    [[ "$1" =~ ^[0-9]{4}\. ]]
}

# _assessment_major <version-core> -> prints leading numeric segment
_assessment_major() {
    printf '%s' "$1" | cut -d. -f1
}

# ---------------------------------------------------------------------------
# _assessment_version_signal <installed> <available>
# Echoes "major-version-transition" plus reason text when the installed ->
# available transition is a confidently parsed major bump; echoes nothing
# otherwise. Output format (two lines when matched):
#   major-version-transition
#   major version transition detected (heuristic): <inst> -> <avail>
_assessment_version_signal() {
    local installed_core available_core inst_major avail_major
    installed_core="$(_assessment_version_core "$1")"
    available_core="$(_assessment_version_core "$2")"

    _assessment_is_dotted_numeric "$installed_core" || return 1
    _assessment_is_dotted_numeric "$available_core" || return 1

    # Calendar schemes and non-SemVer strings make no semantic claims.
    _assessment_is_calendar_version "$installed_core" && return 1
    _assessment_is_calendar_version "$available_core" && return 1

    inst_major="$(_assessment_major "$installed_core")"
    avail_major="$(_assessment_major "$available_core")"

    if (( avail_major > inst_major )); then
        printf 'major-version-transition\n'
        printf 'major version transition detected (heuristic): %s -> %s\n' \
            "$1" "$2"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _assessment_evidence_signal <evidence_snapshot>
# Echoes "breaking-change-pattern" plus reason text when the evidence
# snapshot matches a configured breaking-change indicator (same pattern set
# as detect_breaking_changes); echoes nothing otherwise.
_assessment_evidence_signal() {
    local snapshot="$1"

    if [[ -z "$snapshot" || "$snapshot" == "null" ]]; then
        return 1
    fi

    local detected=0
    if declare -F detect_breaking_changes >/dev/null 2>&1; then
        detect_breaking_changes "$snapshot" && detected=1
    fi

    if (( detected )); then
        printf 'breaking-change-pattern\n'
        printf 'evidence matched configured breaking-change pattern\n'
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _assessment_emit <line> <classification> <reasons-json> <signals-json>
# Emits one strict-write record: full schema, classification and derived
# fields filled in, all other fields passed through from the input line.
_assessment_emit() {
    local line="$1" classification="$2" reasons="$3" signals="$4"

    printf '%s' "$line" | jq -c \
        --arg classification "$classification" \
        --argjson reasons "$reasons" \
        --argjson matched_signals "$signals" '
        .classification = $classification
        | .reasons = $reasons
        | .matched_signals = $matched_signals
        | .assessment_recommendation =
            (.classification == "no-signal" and .operational_eligibility == true)
        | .default_selected = false
        '
}

# ---------------------------------------------------------------------------
# _assessment_malformed_record <raw-line>
# Emits an unknown record for an unparseable input line. Best-effort package
# recovery: try to salvage the package token; otherwise fall back to the
# raw line's first field-ish token so the record is still traceable.
_assessment_malformed_record() {
    local raw="$1"
    local pkg
    pkg="$(printf '%s' "$raw" | jq -r '.package? // empty' 2>/dev/null || true)"

    jq -cn \
        --arg package "${pkg:-unknown}" \
        --arg raw "$raw" '
        {
            package: $package,
            display_name: $package,
            kind: "formula",
            installed_version: "",
            available_version: "",
            evidence_source: "unsupported",
            evidence_url: "",
            retrieved_at: null,
            retrieval_status: "malformed",
            evidence_snapshot: "",
            classification: "unknown",
            reasons: ["malformed record"],
            matched_signals: [],
            assessment_recommendation: false,
            operational_eligibility: false,
            default_selected: false
        }'
}

# ---------------------------------------------------------------------------
# _assessment_classify_one <line>
_assessment_classify_one() {
    local line="$1"

    if ! printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _assessment_malformed_record "$line"
        return 0
    fi

    local installed available status retrieved_at snapshot
    installed="$(printf '%s' "$line" | jq -r '.installed_version // ""')"
    available="$(printf '%s' "$line" | jq -r '.available_version // ""')"
    status="$(printf '%s' "$line" | jq -r '.retrieval_status // ""')"
    retrieved_at="$(printf '%s' "$line" | jq -r '.retrieved_at // ""')"
    snapshot="$(printf '%s' "$line" | jq -r '
        if (.evidence_snapshot | type) == "object" then
            (.evidence_snapshot | tostring)
        else
            (.evidence_snapshot // "" | tostring)
        end')"

    local reasons=() signals=()

    local version_out
    if version_out="$(_assessment_version_signal "$installed" "$available")"; then
        signals+=("$(printf '%s\n' "$version_out" | sed -n 1p)")
        reasons+=("$(printf '%s\n' "$version_out" | sed -n 2p)")
    fi

    local evidence_out
    if evidence_out="$(_assessment_evidence_signal "$snapshot")"; then
        signals+=("$(printf '%s\n' "$evidence_out" | sed -n 1p)")
        reasons+=("$(printf '%s\n' "$evidence_out" | sed -n 2p)")
    fi

    local classification
    if (( ${#signals[@]} > 0 )); then
        # Precedence 1: any matched signal (heuristic or evidence) wins,
        # regardless of retrieval status.
        classification="attention"
    elif [[ "$status" =~ ^(fresh|cached-fresh)$ ]] && [[ "$retrieved_at" =~ ^[1-9][0-9]*$ ]]; then
        # Precedence 2: fresh evidence with a timestamp and no matched signal.
        classification="no-signal"
        reasons+=("no configured risk signal matched fresh evidence")
    elif [[ "$status" =~ ^(fresh|cached-fresh)$ ]]; then
        # Freshness status without a usable timestamp is contradictory.
        classification="unknown"
        reasons+=("contradictory freshness: retrieval status '$status' without retrieved_at timestamp")
    else
        # Precedence 3: everything else.
        classification="unknown"
        reasons+=("evidence retrieval status: ${status:-missing}")
    fi

    local reasons_json signals_json
    reasons_json="$(printf '%s\n' "${reasons[@]:-}" | jq -R . | jq -s .)"
    signals_json="$(printf '%s\n' "${signals[@]:-}" | jq -R . | jq -s .)"

    _assessment_emit "$line" "$classification" "$reasons_json" "$signals_json"
}

# ---------------------------------------------------------------------------
# classify_assessment_records [file]
# Pure classifier: reads approved-contract JSONL records from the given file
# (or stdin when omitted / "-") and writes classified records, same schema,
# to stdout. One line in, one line out; malformed lines become unknown.
classify_assessment_records() {
    local input="${1:--}"
    local line

    if [[ "$input" != "-" ]]; then
        [[ -r "$input" ]] || return 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            _assessment_classify_one "$line"
        done < "$input"
    else
        while IFS= read -r line || [[ -n "$line" ]]; do
            _assessment_classify_one "$line"
        done
    fi
}
