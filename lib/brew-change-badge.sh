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
# After a failed refresh, the badge skips spawning for this many seconds so a
# broken network does not start a doomed refresh on every brew update.
REFRESH_BACKOFF_FILE="${HOME}/.brew-change/.refresh-backoff"

# ---------------------------------------------------------------------------
# _badge_now — epoch seconds; BREW_CHANGE_TEST_NOW overrides (test seam,
# same convention as _http_cache_now in brew-change-utils.sh).
# ---------------------------------------------------------------------------
_badge_now() { printf '%s\n' "${BREW_CHANGE_TEST_NOW:-$(date +%s)}"; }

# ---------------------------------------------------------------------------
# badge_counts <export_file>
#
# Prints verdict counts as one "|"-separated line:
#   updates | breaking | breaking_names_csv | nosignal | unknown
#
# updates = all packages (every export row was outdated at assessment time).
# breaking = rows whose matched_signals include "breaking-change-pattern"
# (signal names: lib/brew-change-assessment.sh; the other current signal is
# "major-version-transition").
#
# The separator is deliberately NOT a TAB: tab is IFS whitespace, and bash
# `read -a` collapses whitespace runs, so empty fields (e.g. no breaking
# names) would be lost. "|" never occurs in Homebrew package names.
#
# Prints nothing and returns 1 when the file is unreadable or not valid JSON.
# ---------------------------------------------------------------------------
badge_counts() {
    local file="$1"
    [[ -r "$file" ]] || return 1
    jq -r '
        (.packages // []) as $pkgs
        | ([ $pkgs[] | select((.matched_signals // []) | index("breaking-change-pattern")) ]) as $brk
        | [ ($pkgs | length | tostring),
            ($brk | length | tostring),
            ([ $brk[].name ] | join(",")),
            ([ $pkgs[] | select(.classification == "no-signal") ] | length | tostring),
            ([ $pkgs[] | select(.classification == "unknown") ] | length | tostring)
          ]
        | join("|")' "$file" 2>/dev/null || return 1
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

# ---------------------------------------------------------------------------
# refresh_lock_acquire
#
# Atomically claims the refresh lock. Returns 0 when acquired (fresh or taken
# over from an abandoned lock), 1 when a live refresh plausibly holds it.
#
# Takeover cases: readable PID that is dead, or a lock older than
# REFRESH_LOCK_MAX_AGE. A missing/unreadable pid file does NOT take over —
# the creator may be between mkdir and its pid write (conservative skip).
#
# The pid file normally records the spawned refresh child (badge writes it
# after spawn, see badge_spawn_refresh); refresh_lock_acquire itself records
# the caller so plain acquire-and-hold tests are meaningful.
# ---------------------------------------------------------------------------
refresh_lock_acquire() {
    # The state dir may not exist yet (fresh install, badge-first workflow).
    mkdir -p "$(dirname "$REFRESH_LOCK_DIR")" 2>/dev/null || true
    if mkdir "$REFRESH_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
        _badge_now > "${REFRESH_LOCK_DIR}/started"
        return 0
    fi
    local lpid lstart age=0
    lpid="$(cat "${REFRESH_LOCK_DIR}/pid" 2>/dev/null || true)"
    lstart="$(cat "${REFRESH_LOCK_DIR}/started" 2>/dev/null || true)"
    [[ "$lstart" =~ ^[0-9]+$ ]] && age=$(( $(_badge_now) - lstart ))
    if [[ -z "$lpid" ]]; then
        return 1
    fi
    if (( age >= REFRESH_LOCK_MAX_AGE )); then
        refresh_lock_release
    elif kill -0 "$lpid" 2>/dev/null; then
        return 1
    else
        refresh_lock_release
    fi
    mkdir "$REFRESH_LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
    _badge_now > "${REFRESH_LOCK_DIR}/started"
    return 0
}

# ---------------------------------------------------------------------------
# refresh_lock_release — idempotent.
# ---------------------------------------------------------------------------
refresh_lock_release() {
    rm -rf "$REFRESH_LOCK_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# badge_self_path <raw_path>
#
# Resolves the main script to an absolute executable path for re-invoking
# refresh. Returns 1 when the path is not a usable executable.
# ---------------------------------------------------------------------------
badge_self_path() {
    local raw="$1"
    [[ -n "$raw" ]] || return 1
    local dir base abs
    dir="$(cd "$(dirname "$raw")" 2>/dev/null && pwd)" || return 1
    base="$(basename "$raw")"
    abs="${dir}/${base}"
    [[ -x "$abs" ]] || return 1
    printf '%s' "$abs"
}

# ---------------------------------------------------------------------------
# refresh_backoff_active / _record / _clear
#
# prd-004: a failed refresh starts a backoff window (default 30 min,
# BREW_CHANGE_REFRESH_BACKOFF) during which the badge does not spawn new
# refreshes — a broken network must not start a doomed run on every trigger.
# The record is an epoch file; expired records self-delete on read.
# ---------------------------------------------------------------------------
refresh_backoff_active() {
    [[ -r "$REFRESH_BACKOFF_FILE" ]] || return 1
    local ts
    ts="$(cat "$REFRESH_BACKOFF_FILE" 2>/dev/null || true)"
    [[ "$ts" =~ ^[0-9]+$ ]] || { refresh_backoff_clear; return 1; }
    if (( $(_badge_now) < ts + ${BREW_CHANGE_REFRESH_BACKOFF:-1800} )); then
        return 0
    fi
    refresh_backoff_clear
    return 1
}

refresh_backoff_record() {
    mkdir -p "$(dirname "$REFRESH_BACKOFF_FILE")" 2>/dev/null || true
    _badge_now > "$REFRESH_BACKOFF_FILE" 2>/dev/null || true
}

refresh_backoff_clear() {
    rm -f "$REFRESH_BACKOFF_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# badge_spawn_refresh <script_path>
#
# Claims the lock, spawns `brew-change refresh` detached, records the child's
# PID in the lock, and leaves the lock in place — the refresh run releases it
# when it exits. Held lock or active backoff → skip silently.
#
# BREW_CHANGE_BADGE_NO_SPAWN=1 exercises the lock decision without executing
# the child (test seam; the lock is released immediately in that case).
# ---------------------------------------------------------------------------
badge_spawn_refresh() {
    if refresh_backoff_active; then
        return 0
    fi
    refresh_lock_acquire || return 0
    if [[ "${BREW_CHANGE_BADGE_NO_SPAWN:-0}" == "1" ]]; then
        refresh_lock_release
        return 0
    fi
    local self
    self="$(badge_self_path "$1")" || { refresh_lock_release; return 0; }
    nohup "$self" refresh >/dev/null 2>&1 </dev/null &
    local child=$!
    printf '%s\n' "$child" > "${REFRESH_LOCK_DIR}/pid"
    disown "$child" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# badge_main <after-update|after-upgrade> <script_path>
#
# Entry from the main script's badge subcommand. Output contract (prd-004):
# - always exits 0; every error path is silent
# - silent when stdout is not a TTY (BREW_CHANGE_BADGE_FORCE=1 overrides —
#   test seam) or when BREW_CHANGE_BADGE_DISABLE=1
# - missing export: one-line setup hint
# - unparsable JSON, unsupported schema_version, or unparsable generated_at:
#   silence (non-event, per the export consumer contract in
#   docs/assessment-export.md)
# - fresh (age < BREW_CHANGE_BADGE_MAX_AGE, default BADGE_DEFAULT_MAX_AGE):
#   the rendered line only
# - stale after-update: line + " · refreshing…" + spawn refresh
# - after-upgrade: line + " · assessment updating…" + always spawn refresh
#   (the outdated set provably changed)
# ---------------------------------------------------------------------------
badge_main() {
    local trigger="$1" script_path="$2"
    if [[ "${BREW_CHANGE_BADGE_DISABLE:-0}" == "1" ]]; then return 0; fi
    if [[ ! -t 1 && "${BREW_CHANGE_BADGE_FORCE:-0}" != "1" ]]; then return 0; fi

    if [[ ! -r "${ASSESSMENT_EXPORT_FILE:-}" ]]; then
        printf '%s\n' "brew-change: no assessment yet — run brew-change -u"
        return 0
    fi
    jq -e 'type == "object" and (.schema_version == 1)' "${ASSESSMENT_EXPORT_FILE}" >/dev/null 2>&1 \
        || return 0

    local counts gen_epoch now age line suffix="" spawn=0
    counts="$(badge_counts "${ASSESSMENT_EXPORT_FILE}")" || return 0
    gen_epoch="$(badge_generated_epoch \
        "$(jq -r '.generated_at // empty' "${ASSESSMENT_EXPORT_FILE}")")" || return 0
    now="$(_badge_now)"
    age="$(badge_age_human "$gen_epoch" "$now")"
    # "|" (non-whitespace) preserves empty fields through read -a; see
    # badge_counts for why TAB cannot be used here.
    local -a counts_fields=()
    IFS='|' read -r -a counts_fields <<< "$counts"
    line="$(badge_render_line "${counts_fields[0]}" "${counts_fields[1]}" \
        "${counts_fields[2]}" "${counts_fields[3]}" "${counts_fields[4]}" "$age")"

    local max_age="${BREW_CHANGE_BADGE_MAX_AGE:-$BADGE_DEFAULT_MAX_AGE}"
    # Non-numeric garbage must fall back to the default, never reach the
    # arithmetic below (set -u turns unset arithmetic names into errors).
    [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=$BADGE_DEFAULT_MAX_AGE
    if [[ "$trigger" == "after-upgrade" ]]; then
        spawn=1
    elif (( now >= gen_epoch + max_age )); then
        spawn=1
    fi
    # A recent refresh failure backs off: no spawn, and no suffix — the
    # suffix promises a refresh that is not happening, while the age marker
    # already tells the staleness story (prd-004 honesty contract).
    if (( spawn == 1 )) && refresh_backoff_active; then
        spawn=0
    fi
    if (( spawn == 1 )); then
        if [[ "$trigger" == "after-upgrade" ]]; then
            suffix=" · assessment updating…"
        else
            suffix=" · refreshing…"
        fi
        badge_spawn_refresh "$script_path"
    fi

    printf '%s%s\n' "$line" "$suffix"
    return 0
}

# ---------------------------------------------------------------------------
# finish_refresh_empty_export
#
# prd-004: a refresh that finds zero outdated packages still writes a fresh,
# empty export (so the badge can say "0 updates" with a new timestamp). The
# EXIT trap installed by the refresh handler owns lock release and the
# refresh.log entry for every exit path, including this one. No-op for every
# non-refresh invocation.
# ---------------------------------------------------------------------------
finish_refresh_empty_export() {
    [[ "${REFRESH_MODE:-}" == "true" ]] || return 0
    local empty_records
    empty_records="$(mktemp -t brew-change-empty.XXXXXX)" || exit 0
    write_assessment_export "$empty_records" || true
    rm -f "$empty_records"
    exit 0
}

# ---------------------------------------------------------------------------
# refresh_export_degraded <assessment_jsonl>
#
# prd-004: true when the file holds at least one record and none has a
# healthy retrieval_status (fresh | cached-fresh) — the signature of a
# network-dead refresh whose records are all unknown-by-force. The
# vocabulary is research-005 §: fresh|cached-fresh|stale|unavailable|failed|
# malformed|contradictory|rate-limited|unsupported; classification requires
# fresh|cached-fresh evidence (lib/brew-change-assessment.sh).
#
# Empty or unreadable input is NOT degraded — the caller proceeds with
# today's behavior (fail-open), and the zero-outdated path never reaches
# this check.
# ---------------------------------------------------------------------------
refresh_export_degraded() {
    local records="$1"
    [[ -s "$records" ]] || return 1
    local healthy total
    healthy="$(jq -sr '[ .[] | select(.retrieval_status == "fresh" or .retrieval_status == "cached-fresh") ] | length' "$records" 2>/dev/null)" || return 1
    total="$(jq -sr 'length' "$records" 2>/dev/null)" || return 1
    (( total > 0 && healthy == 0 ))
}

# ---------------------------------------------------------------------------
# badge_export_has_verdicts <export_file>
#
# True when the export exists and holds at least one non-unknown
# classification — i.e. an assessment worth protecting from a degraded
# overwrite. Missing, empty, or malformed exports are not protected.
# ---------------------------------------------------------------------------
badge_export_has_verdicts() {
    local export_file="$1"
    [[ -s "$export_file" ]] || return 1
    jq -e 'any(.packages[]?; .classification != "unknown")' "$export_file" >/dev/null 2>&1
}
