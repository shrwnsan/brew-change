#!/usr/bin/env bash
# Interactive dashboard action loop (T2.5.2).
#
# Implements the approved action-state machine from
# docs/research-007-dashboard-actions.md on top of the pure renderer in
# brew-change-dashboard.sh:
#
#   DASHBOARD: r -> REVIEW, s -> SELECT, u/Enter -> UPGRADE (no-signal set),
#              q/EOF/inactivity-timeout -> exit 0, invalid -> prompt-only
#              reprompt + hint (no full dashboard re-render).
#   REVIEW:    read-only per-package evidence detail rendered from the
#              assessment record (never refetched); number/name selects a
#              package, b -> DASHBOARD, q/EOF/timeout -> exit 0.
#   SELECT:    explicit per-package toggles (no-signal preselected,
#              attention/unknown never preselected); b -> DASHBOARD discarding
#              the staged set; Enter -> UPGRADE with the staged named set;
#              q/EOF/timeout -> exit 0.
#   UPGRADE:   run_upgrade_with_preview <named set> (lib/brew-change-upgrade.sh)
#              is the SOLE execution boundary. Decline/preview failure returns
#              to DASHBOARD with the plan discarded; completion re-derives the
#              records from the post-upgrade inventory and returns to DASHBOARD.
#
# The loop lives here (not in brew-change-dashboard.sh) so the renderer stays
# a pure, fixture-pinned function, and not in brew-change-interactive.sh so
# the Phase 1 prompt machinery stays untouched. Readers are factored into
# _dashboard_read_key/_dashboard_read_line so deterministic tests can drive
# the states without a terminal; PTY tests cover the real readers
# (stty/signal/timeout/stale-Enter hygiene) in tests/test-dashboard-actions.py.

# Ensure the pure renderer is available when this module is sourced
# standalone (tests). brew-change sources it before this module.
if ! declare -F render_dashboard_records >/dev/null 2>&1; then
    _DASHBOARD_UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091 # dynamic sibling path
    [[ -f "$_DASHBOARD_UI_DIR/brew-change-dashboard.sh" ]] && \
        source "$_DASHBOARD_UI_DIR/brew-change-dashboard.sh"
    unset _DASHBOARD_UI_DIR
fi

# ---------------------------------------------------------------------------
# Terminal hygiene (same pattern as prompt_upgrade_action in
# brew-change-interactive.sh; kept local so that module stays unmodified).
# ---------------------------------------------------------------------------
_dashboard_cleanup() {
    if [[ -n "${dashboard_stty_state:-}" ]]; then
        stty "$dashboard_stty_state" < /dev/tty 2>/dev/null || true
        dashboard_stty_state=""
    fi
    if command -v unregister_terminal_state >/dev/null 2>&1; then
        unregister_terminal_state
    fi
}

_dashboard_run_saved_trap() {
    local definition="$1"
    [[ -z "$definition" ]] && return 0
    definition="${definition#trap -- }"
    eval "set -- $definition"
    eval "$1"
}

_dashboard_handle_signal() {
    local status="$1"
    local previous_trap="$2"
    _dashboard_cleanup
    _dashboard_run_saved_trap "$previous_trap"
    exit "$status"
}

_dashboard_install_traps() {
    dashboard_previous_int_trap="$(trap -p INT)"
    dashboard_previous_term_trap="$(trap -p TERM)"
    trap '_dashboard_handle_signal 130 "$dashboard_previous_int_trap"' INT
    trap '_dashboard_handle_signal 143 "$dashboard_previous_term_trap"' TERM
    dashboard_installed_exit_trap=false
    if [[ -z "$(trap -p EXIT)" ]]; then
        trap '_dashboard_cleanup' EXIT
        dashboard_installed_exit_trap=true
    fi
    dashboard_stty_state="$(stty -g < /dev/tty 2>/dev/null || true)"
    if [[ -n "$dashboard_stty_state" ]] \
        && command -v register_terminal_state >/dev/null 2>&1; then
        register_terminal_state "$dashboard_stty_state"
    fi
}

_dashboard_restore_traps() {
    trap - INT TERM
    [[ -n "${dashboard_previous_int_trap:-}" ]] \
        && eval "$dashboard_previous_int_trap"
    [[ -n "${dashboard_previous_term_trap:-}" ]] \
        && eval "$dashboard_previous_term_trap"
    [[ "${dashboard_installed_exit_trap:-false}" == "true" ]] && trap - EXIT
    _dashboard_cleanup
}

# Cancelled (quit/EOF/timeout): conventional exit 0, terminal restored.
_dashboard_exit_ok() {
    _dashboard_restore_traps
    exit 0
}

# Best-effort write to the controlling terminal. Cosmetic output must never
# abort the flow when /dev/tty is unavailable (e.g. harness environments).
_dashboard_say() { # message
    echo "$1" > /dev/tty 2>/dev/null || true
}

_dashboard_note() { # format [args...]
    # shellcheck disable=SC2059 # format passthrough is the point
    printf "$@" > /dev/tty 2>/dev/null || true
}

# Announce the inactivity timeout the same way prompt_upgrade_action does.
# Width of the last line drawn to /dev/tty (the action prompt); countdown
# redraws must clear at least this width or the prompt tail survives.
dashboard_last_line_width=0

# Redraw the countdown, clearing the wider of the last drawn line and the
# countdown text itself before printing.
_dashboard_countdown_note() { # suffix (e.g. "12  " or "now\n")
    local text
    # shellcheck disable=SC2059 # the suffix may carry a \n escape
    printf -v text 'Still there? Inactivity timeout exiting in... %b' "$1"
    local width=${dashboard_last_line_width:-0}
    (( ${#text} > width )) && width=$(( ${#text} ))
    _dashboard_note "\r%*s\r%s" "$width" "" "$text"
    if (( ${#text} > ${dashboard_last_line_width:-0} )); then
        dashboard_last_line_width=$(( ${#text} ))
    fi
    return 0
}

_dashboard_timeout_notice() {
    local total_timeout="$1"
    local human="$(( total_timeout / 60 ))m"
    (( total_timeout < 60 )) && human="${total_timeout}s"
    _dashboard_countdown_note 'now\n'
    _dashboard_say "Dashboard closed (inactivity timeout after ${human})."
}

# Upper bound (seconds) for a single timed read slice in the readers below.
# Bash's read builtin can swallow a trapped signal that arrives between the
# read starting and its blocking wait: the pending INT/TERM trap is then
# deferred until the read's timeout expires, so a Ctrl-C landing in that
# window freezes the dashboard for the whole slice. Capping the slice bounds
# that deferral to this many seconds instead of (total_timeout -
# countdown_window) — 290s at the default 300s timeout. Inactivity-countdown,
# EOF and key semantics are unchanged: a slice that expires without input
# just re-loops.
DASHBOARD_READ_SLICE_MAX=1

# Read one key from /dev/tty with the Phase-1 input hygiene:
#   - failed read slices with status >128 mean "no key yet" (keep waiting);
#   - status 1 means EOF -> caller cancels;
#   - after a successful single-char read the rest of the typed line (e.g. the
#     Enter that submitted it) is drained so it cannot leak into later
#     line-based reads;
#   - the final countdown window is announced instead of exiting silently.
# Args: $1 = variable name to receive the key
# Returns: 0 key read; 1 EOF; 2 inactivity timeout
_dashboard_read_key() {
    local __var="$1"
    local total_timeout="${BREW_CHANGE_PROMPT_TIMEOUT:-300}"
    local countdown_window=10
    (( countdown_window > total_timeout )) && countdown_window=$total_timeout

    local waited=0 response rc slice remaining
    while true; do
        remaining=$(( total_timeout - waited ))
        if (( remaining <= countdown_window )); then
            slice=1
        else
            slice=$(( remaining - countdown_window ))
            (( slice > DASHBOARD_READ_SLICE_MAX )) && slice=$DASHBOARD_READ_SLICE_MAX
        fi
        response=""
        rc=0
        IFS= read -r -N 1 -t "$slice" response < /dev/tty 2>/dev/null || rc=$?
        if (( rc == 0 )); then
            # Bash's `read -N` delivers a literal ^D byte rather than an
            # EOF condition; treat it as EOF (cancel).
            if [[ "$response" == $'\x04' ]]; then
                return 1
            fi
            # Drain the rest of the typed line (stale-Enter fix, Phase 1).
            local _discard=""
            IFS= read -r -t 0.1 _discard < /dev/tty 2>/dev/null || true
            printf -v "$__var" '%s' "$response"
            return 0
        elif (( rc > 128 )); then
            waited=$(( waited + slice ))
            remaining=$(( total_timeout - waited ))
            if (( remaining <= 0 )); then
                _dashboard_timeout_notice "$total_timeout"
                return 2
            fi
            if (( remaining <= countdown_window )); then
                _dashboard_countdown_note "$remaining  "
            fi
        else
            # EOF (^D on an empty line / closed tty).
            return 1
        fi
    done
}

# Read one line from /dev/tty with the same timeout/countdown contract
# (including the DASHBOARD_READ_SLICE_MAX cap and its signal-deferral
# rationale, documented above _dashboard_read_key).
# Args: $1 = variable name to receive the line (newline stripped)
# Returns: 0 line read; 1 EOF; 2 inactivity timeout
_dashboard_read_line() {
    local __var="$1"
    local total_timeout="${BREW_CHANGE_PROMPT_TIMEOUT:-300}"
    local countdown_window=10
    (( countdown_window > total_timeout )) && countdown_window=$total_timeout

    local waited=0 response rc slice remaining
    while true; do
        remaining=$(( total_timeout - waited ))
        if (( remaining <= countdown_window )); then
            slice=1
        else
            slice=$(( remaining - countdown_window ))
            (( slice > DASHBOARD_READ_SLICE_MAX )) && slice=$DASHBOARD_READ_SLICE_MAX
        fi
        response=""
        rc=0
        IFS= read -r -t "$slice" response < /dev/tty 2>/dev/null || rc=$?
        if (( rc == 0 )); then
            printf -v "$__var" '%s' "$response"
            return 0
        elif (( rc > 128 )); then
            waited=$(( waited + slice ))
            remaining=$(( total_timeout - waited ))
            if (( remaining <= 0 )); then
                _dashboard_timeout_notice "$total_timeout"
                return 2
            fi
            if (( remaining <= countdown_window )); then
                _dashboard_countdown_note "$remaining  "
            fi
        else
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Record views (pure jq reads; REVIEW and SELECT never refetch evidence).
# ---------------------------------------------------------------------------

# Echo all canonical package tokens in record order.
_dashboard_all_pkgs() { # records
    jq -r '.package' "$1" 2>/dev/null
}

# Echo the no-signal canonical tokens (Phase 1 default-selection tier).
_dashboard_default_selected_pkgs() { # records
    jq -r 'select(.classification == "no-signal") | .package' "$1" 2>/dev/null
}

# Human-readable evidence freshness from the record's retrieved_at epoch.
_dashboard_freshness() { # retrieved_at
    local at="$1"
    if [[ -z "$at" || "$at" == "null" ]]; then
        printf 'unknown'
        return 0
    fi
    local now age
    now=$(date +%s)
    age=$(( now - at ))
    (( age < 0 )) && age=0
    if (( age < 60 )); then
        printf '%ds ago' "$age"
    elif (( age < 3600 )); then
        printf '%dm ago' "$(( age / 60 ))"
    elif (( age < 86400 )); then
        printf '%dh ago' "$(( age / 3600 ))"
    else
        printf '%dd ago' "$(( age / 86400 ))"
    fi
}

_dashboard_label() { # classification (reuse renderer vocabulary)
    case "$1" in
        attention) printf 'Needs attention' ;;
        no-signal) printf 'No risk signal' ;;
        *)         printf 'Unknown' ;;
    esac
}

# Review-list group header (same vocabulary as the dashboard groups).
_dashboard_review_group_header() { # classification
    case "$1" in
        attention) printf 'Needs attention' ;;
        no-signal) printf 'No risk signal found' ;;
        *)         printf 'Unknown' ;;
    esac
}

# Compact one-line rendering of a full-sentence reason for the review-list
# fallback token: trimmed, trailing period dropped, leading capital lowered.
_dashboard_compact_reason() { # reason
    local r="$1"
    r="${r#"${r%%[![:space:]]*}"}"
    r="${r%"${r##*[![:space:]]}"}"
    r="${r%.}"
    if [[ -n "$r" ]]; then
        printf '%s%s' \
            "$(printf '%s' "${r:0:1}" | tr '[:upper:]' '[:lower:]')" "${r:1}"
    fi
}

# Human phrasing for the retrieval-status vocabulary (T3.2.1): the review
# detail shows what the status means, not just the token.
_dashboard_status_phrase() { # status
    case "$1" in
        fresh)         printf 'fresh (retrieved this run)' ;;
        cached-fresh)  printf 'cached (reused, within freshness policy)' ;;
        stale)         printf 'stale cache (refresh failed; treated as unknown)' ;;
        rate-limited)  printf 'rate-limited by GitHub' ;;
        malformed)     printf 'malformed response' ;;
        contradictory) printf 'contradictory evidence' ;;
        unsupported)   printf 'unsupported source' ;;
        failed)        printf 'fetch failed' ;;
        unavailable)   printf 'no notes available upstream' ;;
        *)             printf '%s' "$1" ;;
    esac
}

# One actionable remediation line for unknown-class statuses (T3.2.1);
# empty when there is nothing useful to suggest.
_dashboard_status_hint() { # status
    case "$1" in
        rate-limited) printf 'authenticate GitHub for a higher limit: brew install gh && gh auth login' ;;
        stale)        printf 're-probe with: brew-change -u --fresh' ;;
        failed)       printf 'check network and re-run; cached evidence will be reused where available' ;;
        malformed)    printf 'upstream returned invalid data; re-probe later with --fresh' ;;
        unsupported|unavailable) printf 'open the evidence URL to review manually' ;;
        *)            return 0 ;;
    esac
}

# Differential token for one review-list row (same derivation as the
# dashboard rows):
#   attention -> matched_signals tokens comma-joined (fallback: compact
#                first reason when no signals matched);
#   unknown   -> retrieval_status token, except "unavailable" (the dominant
#                no-action case), which is suppressed exactly as in the
#                dashboard's Unknown group;
#   no-signal -> no suffix, except a one-word "cached" marker when the
#                evidence was served from a fresh cache entry (T3.2.1:
#                cache use stays visible in the compact list without
#                overwhelming it).
# A malformed record row must degrade to a tokenless line, never leak jq's
# parse error into a drawn screen (the record text is data, not code).
_dashboard_review_token() { # json-record
    local record="$1" token cls status
    cls=$(jq -r '.classification // "unknown"' <<< "$record" 2>/dev/null || true)
    case "$cls" in
        attention)
            token=$(jq -r '(.matched_signals // []) | join(", ")' \
                <<< "$record" 2>/dev/null || true)
            if [[ -z "$token" ]]; then
                token=$(_dashboard_compact_reason \
                    "$(jq -r '(.reasons // [])[0] // ""' \
                        <<< "$record" 2>/dev/null || true)")
            fi
            ;;
        unknown)
            token=$(jq -r '.retrieval_status // ""' <<< "$record" 2>/dev/null || true)
            [[ "$token" == "unavailable" ]] && token=""
            ;;
        *)
            status=$(jq -r '.retrieval_status // ""' <<< "$record" 2>/dev/null || true)
            if [[ "$status" == "cached-fresh" ]]; then
                token="cached"
            else
                token=""
            fi
            ;;
    esac
    printf '%s' "$token"
}

# Review-list display order: dashboard group order (attention, no-signal,
# unknown), alphabetical within each group. Empty groups are omitted from
# the list but simply contribute nothing here either.
_dashboard_review_order() { # records
    local records="$1" cls
    for cls in attention no-signal unknown; do
        jq -r --arg cls "$cls" 'select(.classification == $cls) | .package' \
            "$records" 2>/dev/null | LC_ALL=C sort
    done
}

# Render the grouped review index: dashboard group headers with counts,
# continuous numbering across groups, differential tokens per row.
_dashboard_review_list() { # records
    local records="$1"
    printf 'Review packages (%s):\n\n' "$(jq -s 'length' "$records" 2>/dev/null)"
    local idx=0 cls count line pkg token
    for cls in attention no-signal unknown; do
        count=$(jq -rs --arg cls "$cls" \
            '[.[] | select(.classification == $cls)] | length' \
            "$records" 2>/dev/null)
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        (( count == 0 )) && continue
        (( idx > 0 )) && printf '\n'
        printf '%s (%d)\n' "$(_dashboard_review_group_header "$cls")" "$count"
        while IFS=$'\t' read -r pkg line; do
            [[ -z "$pkg" ]] && continue
            idx=$(( idx + 1 ))
            token=$(_dashboard_review_token "$line")
            if [[ -n "$token" ]]; then
                printf '  %2d) %s — %s\n' "$idx" "$pkg" "$token"
            else
                printf '  %2d) %s\n' "$idx" "$pkg"
            fi
        # The record must round-trip byte-exact to the row's jq reads, so it
        # rides through as join("\t"), never @tsv: @tsv doubles backslashes,
        # and a record whose strings contain `\"` (quoted text in release
        # notes is common) then re-parses as a literal backslash plus an
        # unescaped quote — the JSON truncates mid-string, the row's token
        # reads fail, and jq parse errors leak into the drawn list. tostring
        # never emits a raw tab, so the delimiter stays unique.
        done < <(jq -r --arg cls "$cls" \
            'select(.classification == $cls)
             | [(.package // ""), (. | tostring)] | join("\t")' \
            "$records" 2>/dev/null | LC_ALL=C sort -t$'\t' -k1,1)
    done
    printf '\n[b]ack · [q]uit · package number or name for detail\n'
}

# Render one package's read-only detail from its record. Never refetches.
# Optional $3/$4: 1-based position and list size for a "(n/N)" browse marker.
_dashboard_review_detail() { # records package [position [total]]
    local records="$1" pkg="$2" pos="${3:-}" total="${4:-}"
    local line
    line=$(jq -c --arg p "$pkg" 'select(.package == $p)' "$records" 2>/dev/null | head -1)
    if [[ -z "$line" ]]; then
        printf 'No record for %s.\n' "$pkg"
        return 1
    fi

    # Field reads degrade to blanks on a malformed record instead of leaking
    # jq parse errors into the drawn screen.
    local kind inst avail cls reason src url status snap at
    kind=$(jq -r '.kind // "formula"' <<< "$line" 2>/dev/null || true)
    inst=$(jq -r '.installed_version // ""' <<< "$line" 2>/dev/null || true)
    avail=$(jq -r '.available_version // ""' <<< "$line" 2>/dev/null || true)
    cls=$(jq -r '.classification // "unknown"' <<< "$line" 2>/dev/null || true)
    reason=$(jq -r '(.reasons // []) | join("; ")' <<< "$line" 2>/dev/null || true)
    src=$(jq -r '.evidence_source // ""' <<< "$line" 2>/dev/null || true)
    url=$(jq -r '.evidence_url // empty' <<< "$line" 2>/dev/null || true)
    status=$(jq -r '.retrieval_status // "unavailable"' <<< "$line" 2>/dev/null || true)
    snap=$(jq -r '.evidence_snapshot // ""' <<< "$line" 2>/dev/null || true)
    at=$(jq -r '.retrieved_at // empty' <<< "$line" 2>/dev/null || true)

    if [[ "$pos" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]]; then
        printf -- '--- %s (%d/%d) ---\n' "$pkg" "$pos" "$total"
    else
        printf -- '--- %s ---\n' "$pkg"
    fi
    printf 'Package:          %s (%s)\n' "$pkg" "$kind"
    printf 'Versions:         %s → %s\n' "$inst" "$avail"
    printf 'Classification:   %s\n' "$(_dashboard_label "$cls")"
    printf 'Reason:           %s\n' "${reason:-none}"
    printf 'Evidence source:  %s\n' "${src:-none}"
    # URL only when the producer recorded one (destination policy already
    # applied at evidence time; nothing here refetches it).
    if [[ -n "$url" && "$url" != "null" ]]; then
        printf 'Evidence URL:     %s\n' "$url"
    fi
    # Truthful provenance (T3.2.1): human phrasing for the retrieval
    # vocabulary plus one actionable hint where a next step exists.
    printf 'Retrieval status: %s\n' "$(_dashboard_status_phrase "$status")"
    # T3.4.1 O2: rows without a retrieval timestamp read "retrieved
    # unknown" — state plainly that no timestamp was recorded instead.
    if [[ -n "$at" && "$at" != "null" ]]; then
        printf 'Freshness:        retrieved %s\n' "$(_dashboard_freshness "$at")"
    else
        printf 'Freshness:        not recorded\n'
    fi
    local hint
    hint=$(_dashboard_status_hint "$status")
    [[ -n "$hint" ]] && printf 'Next step:        %s\n' "$hint"
    if [[ -n "$snap" && "$snap" != "null" ]]; then
        printf 'Evidence snapshot:\n'
        while IFS= read -r snap; do
            printf '  %s\n' "$snap"
        done <<< "$snap"
    fi
}

# ---------------------------------------------------------------------------
# REVIEW state
# ---------------------------------------------------------------------------
# Resolve a Review/Select input line (1-based package number or exact
# canonical name) against the nameref'd list. Echoes the token, or nothing.
_dashboard_resolve_pkg_input() { # input pkgs_var
    local input="$1"
    local -n _pkgs="$2"
    local index p
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        index=$(( input - 1 ))
        if (( index >= 0 && index < ${#_pkgs[@]} )); then
            printf '%s' "${_pkgs[$index]}"
        fi
        return 0
    fi
    for p in ${_pkgs[@]+"${_pkgs[@]}"}; do
        if [[ "$p" == "$input" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 0
}

# 0-based position of a canonical token in the nameref'd list, -1 if absent.
# Keeps the browse index honest after number/name jumps.
_dashboard_pkg_index() { # pkg pkgs_var
    local target="$1"
    local -n _list="$2"
    local i
    for i in "${!_list[@]}"; do
        if [[ "${_list[$i]}" == "$target" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    printf '%s' -1
    return 0
}

# Read-only: renders the index, resolves number/name input to a record,
# shows the detail, and returns only on `b`. The detail view itself supports
# Enter/b back to the list, n/p walk, number/name jumps, and q. q/EOF/timeout
# exit 0.
_dashboard_review_state() { # records
    local records="$1"
    # Number/name selection resolves against the grouped display order so
    # the numbers shown in the list stay unambiguous.
    local -a pkgs=()
    mapfile -t pkgs < <(_dashboard_review_order "$records")

    local input rc index pkg jump skip_list=false
    while true; do
        # An invalid line re-prints only the Review: prompt; the list is
        # skipped on the iteration right after it.
        if [[ "$skip_list" != "true" ]]; then
            printf '\n'
            _dashboard_review_list "$records"
        fi
        skip_list=false
        printf 'Review: '
        rc=0; _dashboard_read_line input || rc=$?
        case $rc in
            1|2) _dashboard_exit_ok ;;
        esac

        case "$input" in
            b|B) return 0 ;;
            q|Q)
                _dashboard_say "Dashboard closed."
                _dashboard_exit_ok
                ;;
        esac

        pkg=$(_dashboard_resolve_pkg_input "$input" pkgs)
        if [[ -z "$pkg" ]]; then
            _dashboard_note "Invalid input '%s'. Type a package number/name, b, or q.\n" "$input"
            skip_list=true
            continue
        fi
        index=$(_dashboard_pkg_index "$pkg" pkgs)

        # Detail browsing: walking and jumping stay inside the detail view
        # so checking several packages does not round-trip through the list.
        while true; do
            printf '\n'
            _dashboard_review_detail "$records" "$pkg" "$(( index + 1 ))" "${#pkgs[@]}"
            printf '\nEnter or [b]ack for the list · [n]ext · [p]rev · number/name jumps · [q]uit\n'
            rc=0; _dashboard_read_line input || rc=$?
            case $rc in
                1|2) _dashboard_exit_ok ;;
            esac

            case "$input" in
                ''|b|B) break ;;
                q|Q)
                    _dashboard_say "Dashboard closed."
                    _dashboard_exit_ok
                    ;;
                n|N)
                    if (( index + 1 < ${#pkgs[@]} )); then
                        index=$(( index + 1 ))
                        pkg="${pkgs[$index]}"
                    else
                        _dashboard_note "No next package.\n"
                    fi
                    ;;
                p|P)
                    if (( index > 0 )); then
                        index=$(( index - 1 ))
                        pkg="${pkgs[$index]}"
                    else
                        _dashboard_note "No previous package.\n"
                    fi
                    ;;
                *)
                    jump=$(_dashboard_resolve_pkg_input "$input" pkgs)
                    if [[ -n "$jump" ]]; then
                        pkg="$jump"
                        index=$(_dashboard_pkg_index "$pkg" pkgs)
                    else
                        _dashboard_note "Invalid input '%s'. Enter, b, n, p, q, or a package number/name.\n" "$input"
                    fi
                    ;;
            esac
        done
    done
}

# ---------------------------------------------------------------------------
# SELECT state
# ---------------------------------------------------------------------------
# Explicit per-package toggles. No-signal preselected; attention and unknown
# never preselected. Returns 0 with DASHBOARD_SELECTED_PKGS=() holding the
# confirmed canonical tokens; returns 1 when `b` discards the staged set.
# q/EOF/timeout exit 0.
#
# Arrow navigation: the prompt reads in raw mode (-icanon -echo) scoped to
# this state — ↑/↓ (and j/k) move a text cursor, space toggles the cursor
# row, Enter confirms; typing a number/name still works (the typed buffer
# resolves on Enter, preserving the pre-arrow contract for muscle memory
# and the deterministic tests). The tty is restored on every exit path;
# signals/EXIT additionally restore the dashboard-saved canonical state
# via _dashboard_cleanup, and ISIG stays on so Ctrl-C behaves normally.
DASHBOARD_SELECTED_PKGS=()

# Terminal state scoped to the SELECT state's raw-mode reads.
dashboard_select_stty_state=""

_dashboard_select_restore_tty() {
    if [[ -n "${dashboard_select_stty_state:-}" ]]; then
        stty "$dashboard_select_stty_state" < /dev/tty 2>/dev/null || true
        dashboard_select_stty_state=""
    fi
}

# Read one SELECT interaction in raw mode. Actions: UP, DOWN, TOGGLE
# (space), CONFIRM (Enter with an empty buffer; a non-empty buffer is
# resolved by the caller), BS (backspace), CLEAR (bare/unknown ESC — drops
# the typed buffer), CHR:<byte> (printable input; the caller decides
# whether b/q act as back/quit or start a typed token like "bat").
# Same EOF/timeout contract as _dashboard_read_key: 1 = EOF, 2 = timeout.
# Args: $1 = variable name receiving the action
_dashboard_select_read_action() {
    local __var="$1"
    local total_timeout="${BREW_CHANGE_PROMPT_TIMEOUT:-300}"
    local countdown_window=10
    (( countdown_window > total_timeout )) && countdown_window=$total_timeout

    local waited=0 byte rc slice remaining b1 b2
    while true; do
        remaining=$(( total_timeout - waited ))
        if (( remaining <= countdown_window )); then
            slice=1
        else
            slice=$(( remaining - countdown_window ))
            (( slice > DASHBOARD_READ_SLICE_MAX )) && slice=$DASHBOARD_READ_SLICE_MAX
        fi
        byte=""
        rc=0
        IFS= read -r -N 1 -t "$slice" byte < /dev/tty 2>/dev/null || rc=$?
        if (( rc == 0 )); then
            case "$byte" in
                $'\x1b')
                    # Assemble a CSI sequence; anything unrecognized (or a
                    # bare ESC) just clears the typed buffer. Sequence
                    # leftovers are consumed with a tiny timeout so they
                    # cannot leak into the next interaction read.
                    b1=""; b2=""
                    IFS= read -r -N 1 -t 0.05 b1 < /dev/tty 2>/dev/null || true
                    if [[ "$b1" == "[" ]]; then
                        IFS= read -r -N 1 -t 0.05 b2 < /dev/tty 2>/dev/null || true
                        case "$b2" in
                            A) printf -v "$__var" 'UP'; return 0 ;;
                            B) printf -v "$__var" 'DOWN'; return 0 ;;
                        esac
                    fi
                    printf -v "$__var" 'CLEAR'; return 0
                    ;;
                $'\n'|$'\r') printf -v "$__var" 'CONFIRM'; return 0 ;;
                ' ') printf -v "$__var" 'TOGGLE'; return 0 ;;
                $'\x7f'|$'\x08') printf -v "$__var" 'BS'; return 0 ;;
                $'\x04') return 1 ;;
                *) printf -v "$__var" 'CHR:%s' "$byte"; return 0 ;;
            esac
        elif (( rc > 128 )); then
            waited=$(( waited + slice ))
            remaining=$(( total_timeout - waited ))
            if (( remaining <= 0 )); then
                _dashboard_timeout_notice "$total_timeout"
                return 2
            fi
            if (( remaining <= countdown_window )); then
                _dashboard_countdown_note "$remaining  "
            fi
        else
            return 1
        fi
    done
}

_dashboard_select_state() { # records
    local records="$1"
    local -a pkgs=()
    mapfile -t pkgs < <(_dashboard_all_pkgs "$records")

    # Staged selection keyed by canonical token; defaults mirror Phase 1.
    local -A staged=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && staged["$p"]=1
    done < <(_dashboard_default_selected_pkgs "$records")

    local input rc pkg sel_line count
    local cursor=1 buffer="" redraw=true
    local total=$(( ${#pkgs[@]} ))

    # Raw mode scoped to this prompt (see the state header comment).
    if (( total > 0 )); then
        dashboard_select_stty_state="$(stty -g < /dev/tty 2>/dev/null || true)"
        [[ -n "$dashboard_select_stty_state" ]] \
            && stty -icanon -echo < /dev/tty 2>/dev/null || true
    fi

    while true; do
        count=0
        for p in ${pkgs[@]+"${pkgs[@]}"}; do
            [[ -n "${staged[$p]:-}" ]] && count=$(( count + 1 ))
        done

        if [[ "$redraw" == "true" ]]; then
            printf '\nSelect packages (no-signal preselected; attention/unknown need an explicit toggle):\n'
            local idx=0 cls row cur_marker
            while IFS=$'\t' read -r p cls; do
                [[ -z "$p" ]] && continue
                idx=$(( idx + 1 ))
                if [[ -n "${staged[$p]:-}" ]]; then
                    sel_line="[x]"
                else
                    sel_line="[ ]"
                fi
                # Text-first cursor marker; color never carries meaning.
                if (( idx == cursor )); then
                    cur_marker=">"
                else
                    cur_marker=" "
                fi
                printf '%s %s %2d) %s — %s\n' "$cur_marker" "$sel_line" "$idx" "$p" "$(_dashboard_label "$cls")"
            done < <(jq -r '[.package, .classification] | @tsv' "$records" 2>/dev/null)
            printf '\n%d staged. ↑/↓ move · space toggles · number/name + Enter jumps · [b]ack discards · Enter confirms · [q]uit\n' "$count"
        fi
        # Buffer typing only rewrites the prompt line in place (raw mode
        # has no echo); structural changes reprint the list above.
        local prompt_width=$(( ${#buffer} + 8 ))
        (( prompt_width < 40 )) && prompt_width=40
        printf '\r%*s\rSelect: %s' "$prompt_width" "" "$buffer"
        redraw=false

        rc=0; _dashboard_select_read_action action || rc=$?
        case $rc in
            1|2) _dashboard_select_restore_tty; _dashboard_exit_ok ;;
        esac

        case "$action" in
            UP)
                (( cursor > 1 )) && cursor=$(( cursor - 1 ))
                buffer=""; redraw=true
                ;;
            DOWN)
                (( cursor < total )) && cursor=$(( cursor + 1 ))
                buffer=""; redraw=true
                ;;
            TOGGLE)
                p="${pkgs[$(( cursor - 1 ))]:-}"
                if [[ -n "$p" ]]; then
                    if [[ -n "${staged[$p]:-}" ]]; then
                        unset 'staged[$p]'
                    else
                        staged["$p"]=1
                    fi
                fi
                buffer=""; redraw=true
                ;;
            BS)
                buffer="${buffer%?}"
                ;;
            CLEAR)
                buffer=""
                ;;
            CHR:*)
                # Everything typed buffers (b/q included) — a name like
                # "bat" must remain typeable; back/quit resolve on Enter
                # below, after name matching has its chance.
                buffer+="${action#CHR:}"
                ;;
            CONFIRM)
                if [[ -n "$buffer" ]]; then
                    input="$buffer"; buffer=""
                else
                    input=""
                fi
                ;;
        esac

        # A resolved buffer (Enter after typing) keeps the legacy
        # number/name semantics; an empty Enter confirms the staged set.
        if [[ "$action" == "CONFIRM" ]]; then
            if [[ -z "$input" ]]; then
                if (( count == 0 )); then
                    _dashboard_note "\nNothing selected. Toggle at least one package first.\n"
                    redraw=true
                    continue
                fi
                DASHBOARD_SELECTED_PKGS=()
                for p in ${pkgs[@]+"${pkgs[@]}"}; do
                    [[ -n "${staged[$p]:-}" ]] && DASHBOARD_SELECTED_PKGS+=("$p")
                done
                _dashboard_select_restore_tty
                return 0
            fi

            pkg=$(_dashboard_resolve_pkg_input "$input" pkgs)
            if [[ -z "$pkg" ]]; then
                # Name matching had its chance; the single-letter
                # shortcuts resolve here (b + Enter = back, q + Enter =
                # quit), everything else is the invalid-input hint.
                case "$input" in
                    b|B)
                        _dashboard_select_restore_tty
                        return 1
                        ;;
                    q|Q)
                        _dashboard_select_restore_tty
                        _dashboard_say "Dashboard closed."
                        _dashboard_exit_ok
                        ;;
                esac
                _dashboard_note "\nInvalid input '%s'. Type a package number/name, b, Enter, or q.\n" "$input"
                # Prompt-only reprompt (v1.14.1 contract): the checkbox
                # list is not reprinted for an invalid line.
                continue
            fi
            if [[ -n "${staged[$pkg]:-}" ]]; then
                unset 'staged[$pkg]'
            else
                staged["$pkg"]=1
            fi
            redraw=true
        fi
    done
}

# ---------------------------------------------------------------------------
# UPGRADE state
# ---------------------------------------------------------------------------

# Current outdated inventory as JSON (isolated so tests can override).
_dashboard_fetch_outdated_json() {
    brew outdated --json=v2 2>/dev/null | grep -v '✔︎ JSON API' || true
}

# True when any of the named packages still appears in the outdated
# inventory (declined/failed upgrade -> keep the existing records).
_dashboard_any_still_outdated() {
    local json
    json=$(_dashboard_fetch_outdated_json)
    [[ -z "$json" ]] && return 1
    local token pkg
    while IFS=$'\t' read -r token _type; do
        [[ -z "$token" || "$token" == "null" ]] && continue
        for pkg in "$@"; do
            [[ "$token" == "$pkg" ]] && return 0
        done
    done < <(jq -r '(.formulae[]?.name // empty), (.casks[]?.token // .casks[]?.name // empty)' <<< "$json" 2>/dev/null)
    return 1
}

# Print the deferred completion summary (if any) to the terminal and clear
# it — mirrors the launcher's post-stop flush so the line never shares a
# rendered line with a spinner frame and never lands on captured stdout.
_dashboard_flush_pending_summary() {
    if [[ -n "${PARALLEL_PENDING_SUMMARY:-}" ]]; then
        _dashboard_say "$PARALLEL_PENDING_SUMMARY"
        PARALLEL_PENDING_SUMMARY=""
    fi
    return 0
}

# Production re-derive: rerun the evidence pipeline over the post-upgrade
# inventory and echo the new records path ("none" when nothing is outdated).
#
# Contract: stdout carries ONLY the records path (or "none") — the caller
# captures it with a command substitution, so every cosmetic line (worker
# chatter, banners, summaries) must go to /dev/tty or stay deferred; a
# polluted path made the caller's `jq -s length` fail into a wrong
# "No outdated packages." exit. The refresh fully re-derives records from
# the post-upgrade inventory, so the per-run progress state is reset first
# (fresh progress.jsonl, stop sentinel removed, assessment.jsonl re-inited)
# and the live renderer animates this pass exactly like the initial one.
dashboard_refresh_records() {
    local outdated
    outdated=$(_dashboard_fetch_outdated_json)
    local total
    total=$(jq -r '(.formulae | length) + (.casks | length)' <<< "$outdated" 2>/dev/null || echo 0)
    if [[ -z "$outdated" || "$total" == "0" ]]; then
        printf 'none'
        return 0
    fi

    if ! declare -F process_packages_parallel >/dev/null 2>&1; then
        printf 'none'
        return 0
    fi

    local run_dir="${UPGRADE_STATUS_DIR:?UPGRADE_STATUS_DIR set}"

    # Reset the progress state left behind by the completed initial pass: a
    # stale .progress_done sentinel would end a fresh renderer loop at once,
    # and progress.jsonl/assessment.jsonl must describe only this pass.
    : > "$run_dir/progress.jsonl"
    rm -f "$run_dir/.progress_done"
    if declare -F assessment_record_init >/dev/null 2>&1; then
        assessment_record_init "$run_dir" "$outdated"
    fi

    local defer_prev="${BREW_CHANGE_DEFER_SUMMARY:-0}"
    BREW_CHANGE_DEFER_SUMMARY=1

    # Controlling-terminal probe. This must be an actual open, not
    # [[ -w /dev/tty ]]: the device node is permission-writable even with no
    # controlling terminal attached, while the open fails (ENXIO) — a failed
    # redirect here would otherwise abort the worker phase outright.
    local tty_ok=false
    if : 2>/dev/null > /dev/tty; then
        tty_ok=true
    fi

    # The renderer start is TTY-gated on stdout, which here is the caller's
    # capture pipe; give the call the controlling terminal instead (the
    # dashboard already established the interactive context upstream).
    # PROGRESS_RENDERER_PID stays empty when there is none (piped runs).
    PROGRESS_RENDERER_PID=""
    if [[ "$tty_ok" == "true" ]]; then
        progress_renderer_start > /dev/tty 2>/dev/null || true
    fi

    # Worker-phase cosmetics stay off the capture: send them to the
    # terminal when one exists, discard them otherwise.
    local parallel_rc=0
    if [[ "$tty_ok" == "true" ]]; then
        process_packages_parallel "$outdated" "${PARALLEL_JOBS:-4}" \
            > /dev/tty || parallel_rc=$?
    else
        process_packages_parallel "$outdated" "${PARALLEL_JOBS:-4}" \
            > /dev/null || parallel_rc=$?
    fi
    if (( parallel_rc != 0 )); then
        progress_renderer_stop
        BREW_CHANGE_DEFER_SUMMARY="$defer_prev"
        _dashboard_flush_pending_summary
        printf 'none'
        return 0
    fi

    local -a tokens=()
    local pkg
    if declare -F extract_outdated_package_tokens >/dev/null 2>&1; then
        while IFS=$'\t' read -r pkg _ptype; do
            if [[ -n "$pkg" && "$pkg" != "null" ]]; then
                tokens+=("$pkg")
            fi
        done < <(extract_outdated_package_tokens "$outdated" 2>/dev/null)
    else
        while IFS= read -r pkg; do
            if [[ -n "$pkg" && "$pkg" != "null" ]]; then
                tokens+=("$pkg")
            fi
        done < <(jq -r '(.formulae[]?.name // empty), (.casks[]?.token // empty)' <<< "$outdated")
    fi

    local classify_rc=0
    classify_upgrade_evidence "$run_dir" \
        ${tokens[@]+"${tokens[@]}"} || classify_rc=$?
    progress_renderer_stop
    BREW_CHANGE_DEFER_SUMMARY="$defer_prev"
    _dashboard_flush_pending_summary
    if (( classify_rc != 0 )); then
        printf 'none'
        return 0
    fi
    printf '%s' "$run_dir/assessment.jsonl"
    return 0
}

# UPGRADE state: run_upgrade_with_preview is the sole execution boundary.
# Decline/preview failure returns to DASHBOARD with the plan discarded;
# completion re-derives records and returns to DASHBOARD.
_dashboard_upgrade_state() { # records_var refresh_func pkgs...
    local records_var="$1" refresh_func="$2"
    shift 2
    local -a pkgs=("$@")

    run_upgrade_with_preview ${pkgs[@]+"${pkgs[@]}"}
    local rc=$?

    if (( rc == 0 )) && ! _dashboard_any_still_outdated ${pkgs[@]+"${pkgs[@]}"}; then
        # Completed: re-derive from the post-upgrade inventory.
        local new_records
        new_records="$("$refresh_func")"
        if [[ -z "$new_records" || "$new_records" == "none" ]] \
            || [[ $(jq -s 'length' "$new_records" 2>/dev/null || echo 0) -eq 0 ]]; then
            printf 'No outdated packages.\n'
            _dashboard_exit_ok
        fi
        printf -v "$records_var" '%s' "$new_records"
    fi
    # Declined, failed, or partially upgraded: back to DASHBOARD with the
    # plan discarded and the existing records unchanged.
    return 0
}

# ---------------------------------------------------------------------------
# DASHBOARD state / entry point
# ---------------------------------------------------------------------------

# Human-readable age for the TTY cache banner (research-008 Decision 3).
_dashboard_humanize_age() { # seconds
    local s="$1"
    if (( s < 60 )); then printf '%ds' "$s"
    elif (( s < 3600 )); then printf '%dm' "$(( s / 60 ))"
    elif (( s < 86400 )); then printf '%dh' "$(( s / 3600 ))"
    else printf '%dd' "$(( s / 86400 ))"
    fi
}

# TTY-only cache summary (research-008 Decision 3): one line when cached
# responses were reused this run, aggregated from the run-scoped event
# files. Goes to the controlling terminal only — captured stdout stays
# pure — and does not promise that every probe was cached.
_dashboard_cache_banner() {
    local summary count oldest
    command -v http_cache_hit_summary >/dev/null 2>&1 || return 0
    summary=$(http_cache_hit_summary 2>/dev/null) || return 0
    count=${summary#count=}
    count=${count%% *}
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    (( count > 0 )) || return 0
    oldest="?"
    if [[ "$summary" =~ oldest_age=([0-9]+) ]]; then
        oldest=$(_dashboard_humanize_age "${BASH_REMATCH[1]}")
    fi
    _dashboard_say "Reusing $count cached responses (oldest $oldest old). Use --fresh to re-probe."
}

# Print the compact action prompt on its own line. Split out of
# _dashboard_render so the invalid-key path can re-print just the prompt
# without re-rendering the whole dashboard. Records the drawn width in
# dashboard_last_line_width so later in-place redraws (inactivity countdown,
# invalid-key message) clear at least the full drawn width.
_dashboard_print_prompt() { # records
    local records="$1"
    local ns prompt
    ns=$(jq -sr '[.[] | select(.classification == "no-signal")] | length' "$records" 2>/dev/null)
    # T3.4.1 O2: same bracketed-key, capitalized-word convention as the
    # static dashboard footer ("[r] Review details  [s] Select packages…")
    # — previously the prompt used a lowercase "[r]eview" style and the
    # two surfaces taught the same keys two ways.
    if [[ "$ns" =~ ^[0-9]+$ ]] && (( ns > 0 )); then
        prompt=$(printf '[r] Review · [s] Select · [u] Upgrade no-signal (%s) · [q] Quit (Enter = u): ' "$ns")
    else
        prompt='[r] Review · [s] Select · [q] Quit: '
    fi
    # Remember the prompt width so the inactivity countdown and the
    # invalid-key message can clear it (no stale prompt tail).
    dashboard_last_line_width=$(( ${#prompt} ))
    printf '\n%s' "$prompt"
    return 0
}

# Render the dashboard plus the action prompt line.
_dashboard_render() { # records
    local records="$1"
    local width=80
    if [[ -n "${COLUMNS:-}" && "${COLUMNS}" =~ ^[0-9]+$ ]]; then
        width="$COLUMNS"
    elif command -v tput >/dev/null 2>&1; then
        local w
        w=$(tput cols 2>/dev/null || true)
        [[ -n "$w" && "$w" =~ ^[0-9]+$ ]] && width="$w"
    fi
    render_dashboard_records "$records" "$width"
    _dashboard_print_prompt "$records"
    return 0
}

# Interactive dashboard action loop. Never returns: every terminal outcome
# (quit, EOF, inactivity timeout, empty post-upgrade dashboard) exits 0.
# Args:
#   $1: classified assessment records path (assessment.jsonl)
#   $2: optional refresh function name (default dashboard_refresh_records);
#       must echo the new records path or "none"
run_dashboard_mode() {
    local records="$1"
    local refresh_func="${2:-dashboard_refresh_records}"

    if [[ ! -f "$records" ]]; then
        printf 'brew-change: run_dashboard_mode: no record file: %s\n' "$records" >&2
        return 1
    fi

    _dashboard_install_traps

    # T3.2.2 re-entry banner: shown before the first render so it never
    # interleaves with dashboard frames. TTY-only (stdout purity).
    _dashboard_cache_banner

    local -a no_signal=() selected=()
    local key rc input msg clear_width skip_render=false

    while true; do
        if [[ "$skip_render" != "true" ]]; then
            _dashboard_render "$records"
        fi
        # Every path except the invalid-key reprompt re-renders on the next
        # iteration (state may have changed).
        skip_render=false

        rc=0; _dashboard_read_key key || rc=$?
        case $rc in
            1|2) _dashboard_exit_ok ;;
        esac

        case "$key" in
            r|R)
                _dashboard_say ""
                _dashboard_review_state "$records"
                ;;
            s|S)
                _dashboard_say ""
                if _dashboard_select_state "$records"; then
                    selected=("${DASHBOARD_SELECTED_PKGS[@]+"${DASHBOARD_SELECTED_PKGS[@]}"}")
                    _dashboard_upgrade_state records "$refresh_func" \
                        ${selected[@]+"${selected[@]}"}
                fi
                # b: staged selection discarded; fall through to re-render.
                ;;
            u|U)
                _dashboard_say ""
                no_signal=()
                mapfile -t no_signal < <(_dashboard_default_selected_pkgs "$records")
                if [[ ${#no_signal[@]} -eq 0 ]]; then
                    _dashboard_say "No no-signal packages to upgrade. Use [s] to select packages explicitly."
                    continue
                fi
                _dashboard_upgrade_state records "$refresh_func" \
                    ${no_signal[@]+"${no_signal[@]}"}
                ;;
            $'\n')
                # Phase 1 default semantics: Enter = u when a no-signal set
                # exists, otherwise quit.
                mapfile -t no_signal < <(_dashboard_default_selected_pkgs "$records")
                if [[ ${#no_signal[@]} -gt 0 ]]; then
                    _dashboard_say ""
                    _dashboard_upgrade_state records "$refresh_func" \
                        ${no_signal[@]+"${no_signal[@]}"}
                else
                    _dashboard_say ""
                    if (( ${#selected[@]} > 0 )); then
                        _dashboard_say "Review discarded. Re-run 'brew-change -u' — cached evidence will be reused where available."
                    fi
                    _dashboard_say "Dashboard closed."
                    _dashboard_exit_ok
                fi
                ;;
            q|Q)
                _dashboard_say ""
                # Quit with a staged selection remains an abort (research-008
                # Decision 2): selections never persist, and the TTY-only
                # hint tells the user a re-run is cheap, not that every
                # probe is cached.
                if (( ${#selected[@]} > 0 )); then
                    _dashboard_say "Review discarded. Re-run 'brew-change -u' — cached evidence will be reused where available."
                fi
                _dashboard_say "Dashboard closed."
                _dashboard_exit_ok
                ;;
            *)
                # Prompt-only reprompt: clear the wider of the last drawn
                # line (the prompt) and the message itself, print the hint,
                # then re-print just the prompt — no full dashboard
                # re-render for an invalid keystroke. Clearing less than
                # the drawn width would leave a stale prompt tail.
                printf -v msg "Invalid input '%s'. Type r/s/u/q (or Enter)." "$key"
                clear_width="${dashboard_last_line_width:-0}"
                (( ${#msg} > clear_width )) && clear_width=$(( ${#msg} ))
                _dashboard_note "\r%*s\r%s\n" "$clear_width" "" "$msg"
                _dashboard_print_prompt "$records"
                skip_render=true
                ;;
        esac
    done
}
