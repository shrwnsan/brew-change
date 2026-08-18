#!/usr/bin/env bash
# Interactive dashboard action loop (T2.5.2).
#
# Implements the approved action-state machine from
# docs/research-007-dashboard-actions.md on top of the pure renderer in
# brew-change-dashboard.sh:
#
#   DASHBOARD: r -> REVIEW, s -> SELECT, u/Enter -> UPGRADE (no-signal set),
#              q/EOF/inactivity-timeout -> exit 0, invalid -> reprompt+hint.
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

# Read one line from /dev/tty with the same timeout/countdown contract.
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

# Differential token for one review-list row (same derivation as the
# dashboard rows):
#   attention -> matched_signals tokens comma-joined (fallback: compact
#                first reason when no signals matched);
#   unknown   -> retrieval_status token only;
#   no-signal -> no suffix.
_dashboard_review_token() { # json-record
    local record="$1" token
    case "$(jq -r '.classification // "unknown"' <<< "$record")" in
        attention)
            token=$(jq -r '(.matched_signals // []) | join(", ")' <<< "$record")
            if [[ -z "$token" ]]; then
                token=$(_dashboard_compact_reason \
                    "$(jq -r '(.reasons // [])[0] // ""' <<< "$record")")
            fi
            ;;
        unknown)
            token=$(jq -r '.retrieval_status // "unavailable"' <<< "$record")
            ;;
        *)
            token=""
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
        done < <(jq -r --arg cls "$cls" \
            'select(.classification == $cls)
             | [(.package // ""), (. | tostring)] | @tsv' \
            "$records" 2>/dev/null | LC_ALL=C sort -t$'\t' -k1,1)
    done
    printf '\n[b]ack · [q]uit · package number or name for detail\n'
}

# Render one package's read-only detail from its record. Never refetches.
_dashboard_review_detail() { # records package
    local records="$1" pkg="$2"
    local line
    line=$(jq -c --arg p "$pkg" 'select(.package == $p)' "$records" 2>/dev/null | head -1)
    if [[ -z "$line" ]]; then
        printf 'No record for %s.\n' "$pkg"
        return 1
    fi

    local kind inst avail cls reason src url status snap at
    kind=$(jq -r '.kind // "formula"' <<< "$line")
    inst=$(jq -r '.installed_version // ""' <<< "$line")
    avail=$(jq -r '.available_version // ""' <<< "$line")
    cls=$(jq -r '.classification // "unknown"' <<< "$line")
    reason=$(jq -r '(.reasons // []) | join("; ")' <<< "$line")
    src=$(jq -r '.evidence_source // ""' <<< "$line")
    url=$(jq -r '.evidence_url // empty' <<< "$line")
    status=$(jq -r '.retrieval_status // "unavailable"' <<< "$line")
    snap=$(jq -r '.evidence_snapshot // ""' <<< "$line")
    at=$(jq -r '.retrieved_at // empty' <<< "$line")

    printf -- '--- %s ---\n' "$pkg"
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
    printf 'Retrieval status: %s\n' "$status"
    printf 'Freshness:        retrieved %s\n' "$(_dashboard_freshness "$at")"
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
# Read-only: renders the index, resolves number/name input to a record,
# shows the detail, and returns only on `b`. q/EOF/timeout exit 0.
_dashboard_review_state() { # records
    local records="$1"
    # Number/name selection resolves against the grouped display order so
    # the numbers shown in the list stay unambiguous.
    local -a pkgs=()
    mapfile -t pkgs < <(_dashboard_review_order "$records")

    local input rc index pkg
    while true; do
        printf '\n'
        _dashboard_review_list "$records"
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

        pkg=""
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            index=$(( input - 1 ))
            if (( index >= 0 && index < ${#pkgs[@]} )); then
                pkg="${pkgs[$index]}"
            fi
        else
            local p
            for p in ${pkgs[@]+"${pkgs[@]}"}; do
                [[ "$p" == "$input" ]] && pkg="$p" && break
            done
        fi

        if [[ -z "$pkg" ]]; then
            _dashboard_note "Invalid input '%s'. Type a package number/name, b, or q.\n" "$input"
            continue
        fi

        printf '\n'
        _dashboard_review_detail "$records" "$pkg"
        printf '\nPress Enter to return to the review list...\n'
        rc=0; _dashboard_read_line input || rc=$?
        case $rc in
            1|2) _dashboard_exit_ok ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# SELECT state
# ---------------------------------------------------------------------------
# Explicit per-package toggles. No-signal preselected; attention and unknown
# never preselected. Returns 0 with DASHBOARD_SELECTED_PKGS=() holding the
# confirmed canonical tokens; returns 1 when `b` discards the staged set.
# q/EOF/timeout exit 0.
DASHBOARD_SELECTED_PKGS=()
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

    local input rc index pkg sel_line count
    while true; do
        count=0
        for p in ${pkgs[@]+"${pkgs[@]}"}; do
            [[ -n "${staged[$p]:-}" ]] && count=$(( count + 1 ))
        done

        printf '\nSelect packages (no-signal preselected; attention/unknown need an explicit toggle):\n'
        local idx=0 cls
        while IFS=$'\t' read -r p cls; do
            [[ -z "$p" ]] && continue
            idx=$(( idx + 1 ))
            if [[ -n "${staged[$p]:-}" ]]; then
                sel_line="[x]"
            else
                sel_line="[ ]"
            fi
            printf '  %s %2d) %s — %s\n' "$sel_line" "$idx" "$p" "$(_dashboard_label "$cls")"
        done < <(jq -r '[.package, .classification] | @tsv' "$records" 2>/dev/null)
        printf '\n%d staged. Toggle number/name · [b]ack discards · Enter confirms · [q]uit\n' "$count"
        printf 'Select: '
        rc=0; _dashboard_read_line input || rc=$?
        case $rc in
            1|2) _dashboard_exit_ok ;;
        esac

        case "$input" in
            b|B)
                # Discard the staged selection; nothing persists.
                return 1
                ;;
            q|Q)
                _dashboard_say "Dashboard closed."
                _dashboard_exit_ok
                ;;
            '')
                if (( count == 0 )); then
                    _dashboard_say "Nothing selected. Toggle at least one package first."
                    continue
                fi
                DASHBOARD_SELECTED_PKGS=()
                for p in ${pkgs[@]+"${pkgs[@]}"}; do
                    [[ -n "${staged[$p]:-}" ]] && DASHBOARD_SELECTED_PKGS+=("$p")
                done
                return 0
                ;;
        esac

        pkg=""
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            index=$(( input - 1 ))
            if (( index >= 0 && index < ${#pkgs[@]} )); then
                pkg="${pkgs[$index]}"
            fi
        else
            for p in ${pkgs[@]+"${pkgs[@]}"}; do
                [[ "$p" == "$input" ]] && pkg="$p" && break
            done
        fi

        if [[ -z "$pkg" ]]; then
            _dashboard_note "Invalid input '%s'. Type a package number/name, b, Enter, or q.\n" "$input"
            continue
        fi

        if [[ -n "${staged[$pkg]:-}" ]]; then
            unset 'staged[$pkg]'
        else
            staged["$pkg"]=1
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

# Production re-derive: rerun the evidence pipeline over the post-upgrade
# inventory and echo the new records path ("none" when nothing is outdated).
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
    process_packages_parallel "$outdated" "${PARALLEL_JOBS:-4}" || { printf 'none'; return 0; }

    local -a tokens=()
    local pkg
    if declare -F extract_outdated_package_tokens >/dev/null 2>&1; then
        while IFS=$'\t' read -r pkg _ptype; do
            [[ -n "$pkg" && "$pkg" != "null" ]] && tokens+=("$pkg")
        done < <(extract_outdated_package_tokens "$outdated" 2>/dev/null)
    else
        while IFS= read -r pkg; do
            [[ -n "$pkg" && "$pkg" != "null" ]] && tokens+=("$pkg")
        done < <(jq -r '(.formulae[]?.name // empty), (.casks[]?.token // empty)' <<< "$outdated")
    fi

    if ! classify_upgrade_evidence "${UPGRADE_STATUS_DIR:?UPGRADE_STATUS_DIR set}" \
        ${tokens[@]+"${tokens[@]}"}; then
        printf 'none'
        return 0
    fi
    printf '%s' "$UPGRADE_STATUS_DIR/assessment.jsonl"
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
    local ns prompt
    ns=$(jq -sr '[.[] | select(.classification == "no-signal")] | length' "$records" 2>/dev/null)
    if [[ "$ns" =~ ^[0-9]+$ ]] && (( ns > 0 )); then
        prompt=$(printf '[r]eview · [s]elect · [u]pgrade no-signal (%s) · [q]uit (Enter = u): ' "$ns")
    else
        prompt='[r]eview · [s]elect · [q]uit: '
    fi
    # Remember the prompt width so the inactivity countdown can clear it.
    dashboard_last_line_width=$(( ${#prompt} ))
    printf '\n%s' "$prompt"
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

    local -a no_signal=() selected=()
    local key rc input

    while true; do
        _dashboard_render "$records"

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
                    _dashboard_say "Dashboard closed."
                    _dashboard_exit_ok
                fi
                ;;
            q|Q)
                _dashboard_say ""
                _dashboard_say "Dashboard closed."
                _dashboard_exit_ok
                ;;
            *)
                _dashboard_note "\r%*s\r" 40 ""
                _dashboard_note "Invalid input '%s'. Type r/s/u/q (or Enter).\n" "$key"
                ;;
        esac
    done
}
