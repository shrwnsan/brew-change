#!/usr/bin/env bash
# TTY progress renderer for brew-change (T2.4.2).
#
# Implements the approved progress event contract
# (docs/research-006-progress-event-contract.md): workers append single-line
# JSON events to <run_dir>/progress.jsonl; this renderer is the only code
# that draws terminal frames. It animates a single status line to /dev/tty
# while blocking work proceeds, bounds its own redraw rate, clears the final
# frame, and restores terminal state on every exit path.
#
# Workers never write to the terminal; redraw rate is renderer-owned.

# Rate limit: minimum microseconds between drawn frames (150ms).
PROGRESS_REDRAW_US=150000
# Idle window after a stage reaches its total before returning, so a
# following stage's first event is not missed. Test-overridable.
PROGRESS_IDLE_US="${BREW_CHANGE_PROGRESS_IDLE_US:-300000}"
# Safety bound for a stalled run: if events stop before the stage total is
# reached (worker crash), return after this window instead of spinning
# forever. Generous default; test-overridable.
PROGRESS_STALL_US="${BREW_CHANGE_PROGRESS_STALL_US:-30000000}"
# Fixed clear width; avoids depending on $COLUMNS being exported.
PROGRESS_LINE_WIDTH=78
PROGRESS_SPIN_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

# Monotonic-ish clock in microseconds. Uses bash 5 EPOCHREALTIME when
# available; otherwise approximates via the poll loop (each poll is one
# PROGRESS_POLL_US step), which still bounds the redraw rate.
PROGRESS_POLL_US=50000
_progress_now_us() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        PROGRESS_NOW_US="${EPOCHREALTIME/./}"
    else
        PROGRESS_NOW_US=$(( ${PROGRESS_NOW_US:-0} + PROGRESS_POLL_US ))
    fi
}

# Parse one progress.jsonl line per the contract.
# Sets PROG_LINE_STAGE/COMPLETED/TOTAL/PACKAGE; returns 1 for malformed
# lines, wrong-typed fields, or stages outside the fixed vocabulary
# (unknown stages are ignored for forward compatibility).
_progress_parse_line() {
    local out
    out=$(printf '%s' "$1" | jq -er '
        select((.stage | type) == "string")
        | select((.completed | type) == "number")
        | select((.total | type) == "number")
        | select(.completed >= 0 and .total >= 0)
        | [.stage, (.completed | floor), (.total | floor), (.package // "" | tostring)]
        | @tsv' 2>/dev/null) || return 1
    # The event's completed ordinal is validated but not used for display:
    # the renderer derives the global count from event counts per contract.
    IFS=$'\t' read -r PROG_LINE_STAGE _ PROG_LINE_TOTAL \
        PROG_LINE_PACKAGE <<<"$out" || return 1
    case "$PROG_LINE_STAGE" in
        inventory|evidence|classify) return 0 ;;
        *) return 1 ;;
    esac
}

# Draw one frame to /dev/tty, overwriting the previous frame.
_progress_draw() {
    local frame="${PROG_SPIN_CHAR} ${PROG_STAGE} ${PROG_COMPLETED}/${PROG_TOTAL}"
    if [[ -n "$PROG_PACKAGE" ]]; then
        frame+=" $PROG_PACKAGE"
    fi
    printf '\r%*s\r%s' "$PROGRESS_LINE_WIDTH" '' "$frame" > /dev/tty
}

# Clear the status line completely (the dashboard output follows).
_progress_clear_line() {
    printf '\r%*s\r' "$PROGRESS_LINE_WIDTH" '' > /dev/tty
}

# Test-only observable state dump (mirrors the BREW_CHANGE_PROMPT_TIMEOUT
# testability precedent; never a user API).
_progress_dump_state() {
    [[ -n "${BREW_CHANGE_PROGRESS_DUMP:-}" ]] || return 0
    printf 'STAGE=%s COUNT=%d TOTAL=%d\n' \
        "$PROG_STAGE" "$PROG_COMPLETED" "$PROG_TOTAL"
}

_restore_progress_terminal() {
    if [[ -n "${progress_stty_state:-}" ]]; then
        stty "$progress_stty_state" < /dev/tty 2>/dev/null || true
        progress_stty_state=""
    fi
    if command -v unregister_terminal_state >/dev/null 2>&1; then
        unregister_terminal_state
    fi
}

_cleanup_progress() {
    if [[ "${progress_animating:-false}" == "true" ]]; then
        _progress_clear_line
    fi
    _restore_progress_terminal
    if [[ -n "${progress_fd:-}" ]]; then
        eval "exec ${progress_fd}<&-" 2>/dev/null || true
        progress_fd=""
    fi
}

_run_saved_trap() {
    local definition="$1"
    [[ -z "$definition" ]] && return 0
    definition="${definition#trap -- }"
    eval "set -- $definition"
    eval "$1"
}

_handle_progress_signal() {
    local status="$1"
    local previous_trap="$2"
    _cleanup_progress
    _run_saved_trap "$previous_trap"
    exit "$status"
}

_restore_progress_traps() {
    trap - INT TERM
    [[ -n "${progress_previous_int_trap:-}" ]] \
        && eval "$progress_previous_int_trap"
    [[ -n "${progress_previous_term_trap:-}" ]] \
        && eval "$progress_previous_term_trap"
    [[ "${progress_installed_exit_trap:-false}" == "true" ]] && trap - EXIT
}

# Render live progress for a run directory (public API).
#
# Tails <run_dir>/progress.jsonl and animates a single status line
# (e.g. "⠸ evidence 7/23 node") to /dev/tty while blocking work proceeds.
# Returns when the current stage's derived count reaches its total and the
# idle window passes with no further events (so a following stage is picked
# up), or immediately when the file does not exist.
#
# Safety: no animation when stdout is not a TTY or
# BREW_CHANGE_PARALLEL_MODE=true (events are still consumed silently);
# stty saved before the first draw and restored on all exits; INT/TERM
# trap to cleanup + exit 130/143; no background child is spawned.
render_progress() {
    local run_dir="$1"
    local file="$run_dir/progress.jsonl"
    [[ -f "$file" ]] || return 0

    local animate=true
    [[ -t 1 ]] || animate=false
    [[ "${BREW_CHANGE_PARALLEL_MODE:-}" == "true" ]] && animate=false

    # Renderer state. PROG_COMPLETED is the derived global count (number of
    # events for the stage, deduped by package); it only grows within a
    # stage, so the displayed count is monotonic by construction.
    local PROG_STAGE="" PROG_COMPLETED=0 PROG_TOTAL=0 PROG_PACKAGE=""
    local PROG_SPIN_IDX=0 PROG_SPIN_CHAR="${PROGRESS_SPIN_CHARS:0:1}"
    local -A prog_seen=()
    local line
    local -i last_draw_us=0 last_event_us=0
    local saw_event=false
    local fd
    exec {fd}<"$file"

    if [[ "$animate" == "true" ]]; then
        progress_animating=true
        progress_fd="$fd"
        progress_previous_int_trap="$(trap -p INT)"
        progress_previous_term_trap="$(trap -p TERM)"
        trap '_handle_progress_signal 130 "$progress_previous_int_trap"' INT
        trap '_handle_progress_signal 143 "$progress_previous_term_trap"' TERM
        if [[ -z "$(trap -p EXIT)" ]]; then
            trap '_cleanup_progress' EXIT
            progress_installed_exit_trap=true
        fi
        progress_stty_state="$(stty -g < /dev/tty)"
        if command -v register_terminal_state >/dev/null 2>&1; then
            register_terminal_state "$progress_stty_state"
        fi
    else
        progress_animating=false
    fi

    while true; do
        if IFS=$ read -r -u "$fd" line; then
            if _progress_parse_line "$line"; then
                saw_event=true
                _progress_now_us
                last_event_us=$PROGRESS_NOW_US
                if [[ "$PROG_LINE_STAGE" != "$PROG_STAGE" ]]; then
                    # Stage transition: reset the line for the new stage.
                    PROG_STAGE="$PROG_LINE_STAGE"
                    PROG_COMPLETED=0
                    PROG_TOTAL=0
                    prog_seen=()
                    if [[ "$animate" == "true" ]]; then
                        _progress_clear_line
                        last_draw_us=0
                    fi
                fi
                if [[ -n "$PROG_LINE_PACKAGE" ]]; then
                    if [[ -n "${prog_seen[$PROG_LINE_PACKAGE]+_}" ]]; then
                        PROG_PACKAGE="$PROG_LINE_PACKAGE"
                    else
                        prog_seen[$PROG_LINE_PACKAGE]=1
                        PROG_COMPLETED=$((PROG_COMPLETED + 1))
                        PROG_PACKAGE="$PROG_LINE_PACKAGE"
                    fi
                else
                    PROG_COMPLETED=$((PROG_COMPLETED + 1))
                    PROG_PACKAGE=""
                fi
                if (( PROG_LINE_TOTAL > PROG_TOTAL )); then
                    PROG_TOTAL=$PROG_LINE_TOTAL
                fi
            fi
            # Malformed or unknown-stage lines are skipped as no-ops.
        else
            sleep 0.05
        fi

        _progress_now_us
        if [[ "$animate" == "true" ]]; then
            if (( last_draw_us == 0 )) \
                || (( PROGRESS_NOW_US - last_draw_us >= PROGRESS_REDRAW_US )); then
                PROG_SPIN_IDX=$(( (PROG_SPIN_IDX + 1) % ${#PROGRESS_SPIN_CHARS} ))
                PROG_SPIN_CHAR="${PROGRESS_SPIN_CHARS:PROG_SPIN_IDX:1}"
                _progress_draw
                last_draw_us=$PROGRESS_NOW_US
            fi
        fi

        # Completion: the stage reached its total and stayed idle long
        # enough that no follow-on stage event arrived. A stalled run
        # (events stop before the total) is bounded by the stall window.
        if [[ "$saw_event" == "true" ]]; then
            local quiet_for=$(( PROGRESS_NOW_US - last_event_us ))
            if (( PROG_TOTAL > 0 && PROG_COMPLETED >= PROG_TOTAL )) \
                && (( quiet_for >= PROGRESS_IDLE_US )); then
                break
            fi
            if (( quiet_for >= PROGRESS_STALL_US )); then
                break
            fi
        fi
    done

    if [[ "$animate" == "true" ]]; then
        _progress_clear_line
        _restore_progress_terminal
        _restore_progress_traps
    fi
    eval "exec ${fd}<&-"
    progress_fd=""
    progress_animating=false
    _progress_dump_state
    return 0
}
