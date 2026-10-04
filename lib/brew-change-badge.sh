#!/usr/bin/env bash
# Badge + shell-integration surface (prd-004 / tasks-006).
#
# The badge is a first-party consumer of the assessment export
# (~/.brew-change/last-assessment.json). It renders one terminal line from
# cached data and never runs the assessment pipeline itself; refreshes are
# spawned as detached one-shot runs guarded by a lock (prd-004 Approach A).
# Contract: the badge may never fail the caller's shell — every path exits
# 0 and error paths are silent.

# Default staleness threshold for the badge (seconds), used when
# BREW_CHANGE_BADGE_MAX_AGE is unset.
BADGE_DEFAULT_MAX_AGE=86400
# Breaking names shown before collapsing to "+K" (prd-004 output contract).
BADGE_NAME_CAP=3
# Lock directory for the detached one-shot refresh.
REFRESH_LOCK_DIR="${HOME}/.brew-change/.refresh.lock"
# A lock older than this (seconds) is abandoned even if its PID looks alive
# (recycled-PID guard).
REFRESH_LOCK_MAX_AGE=1800

# ---------------------------------------------------------------------------
# _badge_now — epoch seconds; BREW_CHANGE_TEST_NOW overrides (test seam,
# same convention as _http_cache_now in brew-change-utils.sh).
# ---------------------------------------------------------------------------
_badge_now() { printf '%s\n' "${BREW_CHANGE_TEST_NOW:-$(date +%s)}"; }

# ---------------------------------------------------------------------------
# badge_counts <export_file>
#
# Prints verdict counts as one TAB-separated line:
#   updates <TAB> breaking <TAB> breaking_names_csv <TAB> nosignal <TAB> unknown
#
# updates = all packages (every export row was outdated at assessment time).
# breaking = rows whose matched_signals include "breaking-change-pattern"
# (signal names: lib/brew-change-assessment.sh; the other current signal is
# "major-version-transition").
#
# Prints nothing and returns 1 when the file is unreadable or not valid JSON.
# ---------------------------------------------------------------------------
badge_counts() {
    local file="$1"
    [[ -r "$file" ]] || return 1
    jq -r '
        (.packages // []) as $pkgs
        | ([ $pkgs[] | select((.matched_signals // []) | index("breaking-change-pattern")) ]) as $brk
        | [ ($pkgs | length),
            ($brk | length),
            ([ $brk[].name ] | join(",")),
            ([ $pkgs[] | select(.classification == "no-signal") ] | length),
            ([ $pkgs[] | select(.classification == "unknown") ] | length)
          ]
        | @tsv' "$file" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# badge_render_line <updates> <breaking> <names_csv> <nosignal> <unknown> <age>
#
# Renders the badge line without any state suffix. Segments beyond "N
# updates" print only when non-empty (prd-004 output contract).
# ---------------------------------------------------------------------------
badge_render_line() {
    local updates="$1" breaking="$2" names_csv="$3" nosignal="$4" unknown="$5" age="$6"
    local line="brew-change: ${updates} updates"
    if (( breaking > 0 )); then
        local -a names=() shown=()
        IFS=',' read -r -a names <<< "$names_csv"
        local i
        for (( i = 0; i < ${#names[@]} && i < BADGE_NAME_CAP; i++ )); do
            shown+=("${names[$i]}")
        done
        local label
        label="$(printf '%s, ' "${shown[@]}")"
        label="${label%, }"
        if (( ${#names[@]} > BADGE_NAME_CAP )); then
            label="${label} +$(( ${#names[@]} - BADGE_NAME_CAP ))"
        fi
        line+=" · ${breaking} breaking (${label})"
    fi
    if (( nosignal > 0 )); then line+=" · ${nosignal} no-signal"; fi
    if (( unknown > 0 )); then line+=" · ${unknown} unknown"; fi
    if [[ -n "$age" ]]; then line+=" · ${age} ago"; fi
    printf '%s' "$line"
}

# ---------------------------------------------------------------------------
# badge_age_human <generated_epoch> <now_epoch>
#
# Prints "16m" / "3h" / "2d". Sub-hour deltas round up to 1m; negative deltas
# (clock skew) clamp to 1m. Non-numeric input prints an empty string.
# ---------------------------------------------------------------------------
badge_age_human() {
    local gen="$1" now="$2"
    [[ "$gen" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
    local delta=$(( now - gen ))
    if (( delta < 60 )); then delta=60; fi
    if (( delta < 3600 )); then
        printf '%dm' $(( delta / 60 ))
    elif (( delta < 172800 )); then
        printf '%dh' $(( delta / 3600 ))
    else
        printf '%dd' $(( delta / 86400 ))
    fi
}

# ---------------------------------------------------------------------------
# badge_generated_epoch <iso8601_utc_timestamp>
#
# Parses "2026-10-05T12:34:56Z" to epoch seconds. BSD date first, then GNU.
# Returns 1 when unparseable (badge_main treats that as a non-event).
# ---------------------------------------------------------------------------
badge_generated_epoch() {
    local ts="$1" epoch=""
    epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +"%s" 2>/dev/null)" \
        || epoch="$(date -u -d "$ts" +"%s" 2>/dev/null)" \
        || epoch=""
    [[ -n "$epoch" ]] || return 1
    printf '%s' "$epoch"
}
