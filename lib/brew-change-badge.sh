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
# Duplicate suppression: when a verdict identical to the last printed one is
# about to repeat (same export, within this window), the after-* badge prints
# only its honest tail or nothing. before-upgrade is always printed.
BADGE_STATE_FILE="${HOME}/.brew-change/.badge-last"
BADGE_DUPE_WINDOW=600

# ---------------------------------------------------------------------------
# _badge_now — epoch seconds; BREW_CHANGE_TEST_NOW overrides (test seam,
# same convention as _http_cache_now in brew-change-utils.sh).
# ---------------------------------------------------------------------------
_badge_now() { printf '%s\n' "${BREW_CHANGE_TEST_NOW:-$(date +%s)}"; }

# ---------------------------------------------------------------------------
# badge_paint <ansi-code> <text>
#
# Wraps text in the given SGR code unless NO_COLOR is set or the caller has
# not enabled color via BADGE_USE_COLOR=1 (badge_main sets it for real TTYs
# only — BREW_CHANGE_BADGE_FORCE runs stay plain so tests stay deterministic).
# ---------------------------------------------------------------------------
badge_paint() {
    local code="$1" text="$2"
    if [[ "${BADGE_USE_COLOR:-0}" == "1" && -z "${NO_COLOR:-}" ]]; then
        printf '\033[%sm%s\033[0m' "$code" "$text"
    else
        printf '%s' "$text"
    fi
}

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
    # Color is presentation only: the words carry the full classification
    # (accessibility doctrine, docs/configuration.md). Off unless the caller
    # set BADGE_USE_COLOR (badge_main sets it for real TTYs) and NO_COLOR unset.
    local dim="" red="" grn="" ylw="" rst=""
    if [[ "${BADGE_USE_COLOR:-0}" == "1" && -z "${NO_COLOR:-}" ]]; then
        dim=$'\033[2m'; red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; rst=$'\033[0m'
    fi
    local line="${dim}brew-change:${rst} ${updates} updates"
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
        line+=" · ${red}${breaking} breaking (${label})${rst}"
    fi
    if (( nosignal > 0 )); then line+=" · ${grn}${nosignal} no-signal${rst}"; fi
    if (( unknown > 0 )); then line+=" · ${ylw}${unknown} unknown${rst}"; fi
    if [[ -n "$age" ]]; then line+=" · ${dim}${age} ago${rst}"; fi
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
# Atomically claims the refresh lock. Returns 0 when acquired (fresh, taken
# over from an abandoned lock, or adopted), 1 when a live FOREIGN refresh
# holds it.
#
# Adoption: the badge pre-acquires the lock and writes the spawned child's
# pid into it (badge_spawn_refresh), so the child's own pid is already in the
# file when it calls this — refusing there made every spawned refresh exit
# instantly (found live, 2026-10-06). A lock whose pid equals $$ is adopted.
#
# Takeover cases: readable PID that is dead, or a lock older than
# REFRESH_LOCK_MAX_AGE. A missing/unreadable pid file does NOT take over —
# the creator may be between mkdir and its pid write (conservative skip).
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
    if [[ "$lpid" == "$$" ]] && kill -0 "$lpid" 2>/dev/null; then
        # Own lock: the badge wrote our pid before we exec'd. Adopt it.
        _badge_now > "${REFRESH_LOCK_DIR}/started"
        return 0
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
# badge_export_stamp — cheap change fingerprint of the export (mtime:size).
# "none" when unreadable; dedupe then only matches identical "none" stamps.
# ---------------------------------------------------------------------------
badge_export_stamp() {
    local file="${ASSESSMENT_EXPORT_FILE:-}"
    [[ -n "$file" && -e "$file" ]] || { printf 'none'; return 0; }
    local stamp
    stamp="$(stat -f '%m:%z' "$file" 2>/dev/null || stat -c '%Y:%s' "$file" 2>/dev/null)" || stamp="none"
    printf '%s' "$stamp"
}

# ---------------------------------------------------------------------------
# badge_is_duplicate <rendered_line>
#
# True when this exact line was already printed recently (BADGE_DUPE_WINDOW)
# against the same export state — the after-* badge then de-duplicates:
# the verdict is already on screen (prd-004 pointer: verdict → decline →
# post-badge repeated the same counts three times).
# TTY-gated via the caller; BREW_CHANGE_BADGE_DUPE_TEST=1 is the test seam.
# ---------------------------------------------------------------------------
badge_is_duplicate() {
    [[ -r "$BADGE_STATE_FILE" ]] || return 1
    local rec ts pline pstamp
    rec="$(cat "$BADGE_STATE_FILE" 2>/dev/null)" || return 1
    IFS='|' read -r ts pline pstamp <<< "$rec"
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    [[ "$pstamp" == "$(badge_export_stamp)" ]] || return 1
    [[ "$pline" == "$1" ]] || return 1
    (( $(_badge_now) < ts + BADGE_DUPE_WINDOW ))
}

badge_remember_print() {
    mkdir -p "$(dirname "$BADGE_STATE_FILE")" 2>/dev/null || true
    printf '%s|%s|%s\n' "$(_badge_now)" "$1" "$(badge_export_stamp)" \
        > "$BADGE_STATE_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# badge_main <after-update|after-upgrade|before-upgrade> <script_path>
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
# - before-upgrade: read-only decision support — never spawns, never suffixes
# - on a real TTY, color by risk (breaking red / no-signal green / unknown
#   yellow, prefix+age dim); NO_COLOR disables; FORCE stays plain
# - duplicate suppression on TTYs: an after-* verdict identical to the last
#   printed one (same export, < BADGE_DUPE_WINDOW) prints only its honest
#   tail when a refresh spawns, or nothing; before-upgrade always prints
# ---------------------------------------------------------------------------
badge_main() {
    local trigger="$1" script_path="$2"
    if [[ "${BREW_CHANGE_BADGE_DISABLE:-0}" == "1" ]]; then return 0; fi
    if [[ ! -t 1 && "${BREW_CHANGE_BADGE_FORCE:-0}" != "1" ]]; then return 0; fi
    local on_tty=0
    if [[ -t 1 ]]; then on_tty=1; fi
    if (( on_tty == 1 )); then
        BADGE_USE_COLOR=1
    else
        BADGE_USE_COLOR=0
    fi

    if [[ ! -r "${ASSESSMENT_EXPORT_FILE:-}" ]]; then
        if (( on_tty == 1 )); then
            printf '%s\n' "$(badge_paint 33 "brew-change: no assessment yet — run brew-change -u")"
        else
            printf '%s\n' "brew-change: no assessment yet — run brew-change -u"
        fi
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
    elif [[ "$trigger" != "before-upgrade" ]] && (( now >= gen_epoch + max_age )); then
        # before-upgrade is read-only decision support: the verdict must sit
        # above brew's plan; spawning here would refresh around the decision
        # and duplicate the post-upgrade trigger's job.
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
    fi

    # Duplicate suppression: a verdict already on screen (same export, recent
    # window) repeats nothing. A spawning suppressed badge still says so —
    # the tail is literally true even when the counts above are unchanged.
    local duplicated=0
    if [[ "$trigger" != "before-upgrade" ]] \
        && { (( on_tty == 1 )) || [[ "${BREW_CHANGE_BADGE_DUPE_TEST:-0}" == "1" ]]; } \
        && badge_is_duplicate "$line"; then
        duplicated=1
    fi

    # The "==> " marker mirrors Homebrew's own header style (bold green when
    # coloring; plain text under NO_COLOR) so the verdict reads as part of
    # brew's output stream.
    local marker
    marker="$(badge_paint "1;32" '==> ')"
    if (( duplicated == 1 )); then
        badge_remember_print "$line"
        if (( spawn == 1 )); then
            printf '%s%s\n' "$marker" "$(badge_paint 36 "brew-change: ${suffix# · }")"
            badge_spawn_refresh "$script_path"
        fi
        return 0
    fi

    badge_remember_print "$line"
    printf '%s%s%s\n' "$marker" "$line" "$(badge_paint 36 "$suffix")"
    if (( spawn == 1 )); then
        badge_spawn_refresh "$script_path"
    fi
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
