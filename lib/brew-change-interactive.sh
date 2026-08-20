#!/usr/bin/env bash
# Interactive prompt functions for brew-change
# Provides reusable, interruptible prompt functions with proper variable scoping

# Upper bound (seconds) for a single timed read slice in the prompt reader.
# Bash's read builtin can swallow a trapped signal that arrives between the
# read starting and its blocking wait: the pending INT/TERM trap is then
# deferred until the read's timeout expires, so a Ctrl-C landing in that
# window freezes the prompt for the whole slice. Capping the slice bounds
# that deferral to this many seconds instead of (total_timeout -
# countdown_window) — 290s at the default 300s timeout. Timeout, EOF and key
# semantics are unchanged: a slice that expires without input just re-loops.
# prompt_for_confirmation_with_timeout already follows this pattern with
# fixed 1s reads.
PROMPT_READ_SLICE_MAX=1

# Prompt for yes/no confirmation with timeout and CTRL+C support
# Args:
#   $1: Prompt text (will be displayed as-is)
# Returns:
#   0: User confirmed (y/Y)
#   1: User declined or timeout
prompt_for_confirmation() {
    prompt_for_confirmation_with_timeout "$1" 300
}

# Prompt for yes/no confirmation with custom default timeout
# Args:
#   $1: Prompt text
#   $2: Total timeout in seconds (default: 300)
# Returns:
#   0: User confirmed (y/Y)
#   1: User declined or timeout
prompt_for_confirmation_with_timeout() {
    local prompt_text="$1"
    local custom_timeout="${2:-300}"
    local response=""
    local read_timeout=1
    local total_timeout="$custom_timeout"
    local elapsed=0

    echo -n "$prompt_text" > /dev/tty
    while [[ $elapsed -lt $total_timeout && -z "$response" ]]; do
        if IFS= read -r -t $read_timeout response 2>/dev/null; then
            break
        fi
        elapsed=$((elapsed + read_timeout))
    done

    [[ "$response" =~ ^[Yy]$ ]]
}

# Check if running in interactive mode (stdin is a terminal)
# Returns:
#   0: Interactive mode
#   1: Non-interactive mode (piped input)
is_interactive_mode() {
    [[ -t 0 ]]
}

# Convert one prompt response into the upgrade action vocabulary.
# May return "invalid" for unrecognized single-character input that is
# not a recognized command (u/c/q or their long forms). Callers that loop
# must handle "invalid" by reprompting.
#
# Empty response: selects "no-signal" only if no_signal_count > 0,
# otherwise cancels. This applies only to a deliberate empty Enter from
# the user (not EOF/timeout, which are handled by the caller).
upgrade_action_from_response() {
    local response="$1"
    local no_signal_count="$2"

    case "$response" in
        u|upgrade) echo "no-signal" ;;
        c|choose) echo "choose" ;;
        q|quit) echo "cancel" ;;
        ''|$'\n')
            if [[ "$no_signal_count" -gt 0 ]]; then
                echo "no-signal"
            else
                echo "cancel"
            fi
            ;;
        *) echo "invalid" ;;
    esac
}

# Keep a failed read (EOF or timeout) distinct from a deliberate empty Enter.
upgrade_action_from_read() {
    local read_succeeded="$1"
    local response="$2"
    local no_signal_count="$3"

    if [[ "$read_succeeded" != "true" ]]; then
        echo "cancel"
    else
        upgrade_action_from_response "$response" "$no_signal_count"
    fi
}

# Stop a spinner child and reap it.
_stop_spinner() {
    local spid="${1:-}"
    [[ -z "$spid" ]] && return 0
    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    if command -v unregister_pid >/dev/null 2>&1; then
        unregister_pid "$spid"
    fi
}

_restore_prompt_terminal() {
    if [[ -n "${prompt_stty_state:-}" ]]; then
        stty "$prompt_stty_state" < /dev/tty 2>/dev/null || true
        prompt_stty_state=""
    fi
    if command -v unregister_terminal_state >/dev/null 2>&1; then
        unregister_terminal_state
    fi
}

_cleanup_upgrade_prompt() {
    _restore_prompt_terminal
    _stop_spinner "${spinner_pid:-}"
    spinner_pid=""
}

_run_saved_trap() {
    local definition="$1"
    [[ -z "$definition" ]] && return 0
    definition="${definition#trap -- }"
    eval "set -- $definition"
    eval "$1"
}

_handle_prompt_signal() {
    local status="$1"
    local previous_trap="$2"
    _cleanup_upgrade_prompt
    _run_saved_trap "$previous_trap"
    exit "$status"
}

_restore_prompt_traps() {
    trap - INT TERM
    [[ -n "${prompt_previous_int_trap:-}" ]] && eval "$prompt_previous_int_trap"
    [[ -n "${prompt_previous_term_trap:-}" ]] && eval "$prompt_previous_term_trap"
    # Use an explicit if (not a trailing && chain): when no EXIT trap was
    # installed the test evaluates false, and a false-returning final
    # command makes the whole function return 1 — under the launcher's
    # set -e that aborted the CLI with exit 1 on a plain quit (found by
    # the T2.6.2 --plain full-CLI PTY tests).
    if [[ "${prompt_installed_exit_trap:-false}" == "true" ]]; then
        trap - EXIT
    fi
    return 0
}

# Restricted upgrade action prompt with spinner animation.
# Invalid input reprompts. q cancels. EOF/timeout cancels.
# Empty Enter selects no-signal only if no_signal_count > 0, else cancels.
#
# Args:
#   $1: Count of packages needing attention
#   $2: Count of no-signal packages
#   $3: Total outdated package count
#   $4: Optional variable name to receive the action without a subshell
# Returns (via the named variable, or stdout when omitted):
#   "no-signal", "choose", or "cancel"  (never "invalid")
prompt_upgrade_action() {
    local no_signal_count="$2"
    local output_var="${4:-}"

    # Build prompt text based on context
    local prompt_text
    if [[ "$no_signal_count" -gt 0 ]]; then
        prompt_text="[u]pgrade no-signal ($no_signal_count) / [c]hoose / [q]uit? "
    else
        prompt_text="[c]hoose / [q]uit? "
    fi

    # Helper text
    echo "" > /dev/tty
    echo "Select upgrade mode:" > /dev/tty
    echo "" > /dev/tty

    local prompt_width=$(( ${#prompt_text} + 6 ))
    local spinner_pid=""
    local prompt_stty_state=""
    local prompt_previous_int_trap
    local prompt_previous_term_trap
    local prompt_installed_exit_trap=false

    prompt_previous_int_trap="$(trap -p INT)"
    prompt_previous_term_trap="$(trap -p TERM)"
    trap '_handle_prompt_signal 130 "$prompt_previous_int_trap"' INT
    trap '_handle_prompt_signal 143 "$prompt_previous_term_trap"' TERM
    if [[ -z "$(trap -p EXIT)" ]]; then
        trap '_cleanup_upgrade_prompt' EXIT
        prompt_installed_exit_trap=true
    fi

    local total_timeout="${BREW_CHANGE_PROMPT_TIMEOUT:-300}"
    local countdown_window=10
    if (( countdown_window > total_timeout )); then
        countdown_window=$total_timeout
    fi

    while true; do
        (
            local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
            local idx=0
            local len=${#chars}
            while true; do
                printf "\r%s %s" "$prompt_text" "${chars:idx:1}" > /dev/tty
                idx=$(( (idx + 1) % len ))
                sleep 0.12
            done
        ) < /dev/null &
        spinner_pid=$!
        if command -v register_pid >/dev/null 2>&1; then
            register_pid "$spinner_pid"
        fi

        prompt_stty_state="$(stty -g < /dev/tty)"
        if command -v register_terminal_state >/dev/null 2>&1; then
            register_terminal_state "$prompt_stty_state"
        fi

        # Read in slices so the final countdown window is visible. A failed
        # read slice only means "no key yet"; the timeout is announced
        # instead of exiting silently.
        local waited=0
        local response=""
        local timed_out=false
        while true; do
            local remaining=$(( total_timeout - waited ))
            local slice
            if (( remaining <= countdown_window )); then
                slice=1
            else
                slice=$(( remaining - countdown_window ))
                (( slice > PROMPT_READ_SLICE_MAX )) && slice=$PROMPT_READ_SLICE_MAX
            fi
            if IFS= read -r -N 1 -t "$slice" response 2>/dev/null; then
                # Drain the rest of the typed line (e.g. the Enter after
                # the keypress) so it cannot leak into a later line-based
                # prompt such as the final y/N confirmation.
                local _discard=""
                IFS= read -r -t 0.1 _discard 2>/dev/null || true
                break
            fi
            waited=$(( waited + slice ))
            remaining=$(( total_timeout - waited ))
            if (( remaining <= 0 )); then
                timed_out=true
                break
            fi
            if (( remaining <= countdown_window )); then
                # Countdown phase: stop the spinner and own the line. Clear
                # the wider of the prompt line and the countdown text so no
                # prompt tail survives the redraw.
                _cleanup_upgrade_prompt
                local countdown_text
                printf -v countdown_text \
                    "Still there? Inactivity timeout exiting in... %d  " "$remaining"
                (( ${#countdown_text} > prompt_width )) \
                    && prompt_width=$(( ${#countdown_text} ))
                printf "\r%*s\r%s" "$prompt_width" "" "$countdown_text" > /dev/tty
            fi
        done

        if [[ "$timed_out" == "true" ]]; then
            _cleanup_upgrade_prompt
            local now_text="Still there? Inactivity timeout exiting in... now"
            (( ${#now_text} > prompt_width )) && prompt_width=$(( ${#now_text} ))
            printf "\r%*s\r%s\n" "$prompt_width" "" "$now_text" > /dev/tty
            local human="$(( total_timeout / 60 ))m"
            if (( total_timeout < 60 )); then
                human="${total_timeout}s"
            fi
            echo "Upgrade cancelled (inactivity timeout after ${human})." > /dev/tty
            _restore_prompt_traps
            if [[ -n "$output_var" ]]; then
                printf -v "$output_var" '%s' "cancel"
            else
                printf '%s\n' "cancel"
            fi
            return 0
        fi

        _cleanup_upgrade_prompt

        local resolved_action
        resolved_action=$(upgrade_action_from_read "true" "$response" "$no_signal_count")

        case "$resolved_action" in
            invalid)
                # Reprompt with hint
                printf "\r%*s\r" "$prompt_width" "" > /dev/tty
                echo "Invalid input '$response'. Type u/c/q." > /dev/tty
                continue
                ;;
            *)
                # Valid action (no-signal, choose, cancel)
                printf "\r%*s\r" "$prompt_width" "" > /dev/tty
                printf "%s%s" "$prompt_text" "$response" > /dev/tty
                echo "" > /dev/tty
                _restore_prompt_traps
                if [[ -n "$output_var" ]]; then
                    printf -v "$output_var" '%s' "$resolved_action"
                else
                    printf '%s\n' "$resolved_action"
                fi
                return 0
                ;;
        esac
    done
}

# Breaking marker for the selection prompt (T3.3.1 accessibility contract):
# the "[breaking]" text label always carries the meaning; the ⚠️ glyph is
# strictly additive decoration. The prompt itself is written to /dev/tty (it
# only exists in the interactive flow), so the gate here is the env policy:
# NO_COLOR convention plus the explicit BREW_CHANGE_NO_EMOJI=1 opt-out.
selection_breaking_marker() {
    if [[ -z "${NO_COLOR:-}" && "${BREW_CHANGE_NO_EMOJI:-0}" != "1" ]]; then
        printf ' [breaking] ⚠️'
    else
        printf ' [breaking]'
    fi
}

# Interactive per-package selection prompt
# Args:
#   $@: Array of package names to choose from
# Returns (via echo to stdout):
#   Newline-separated list of selected package names
prompt_package_selection() {
    local packages=("$@")
    local selected=()

    echo "" > /dev/tty
    echo "Select packages to upgrade:" > /dev/tty
    echo "" > /dev/tty

    for pkg in "${packages[@]}"; do
        local default_response="n"
        local breaking_marker=""

        if is_package_breaking "$pkg"; then
            breaking_marker="$(selection_breaking_marker)"
        elif is_package_default_selected "$pkg"; then
            default_response="y"
        else
            breaking_marker=" ?"
        fi

        local prompt_text="  Upgrade $pkg$breaking_marker? [Y/n]: "
        if [[ "$default_response" == "n" ]]; then
            prompt_text="  Upgrade $pkg$breaking_marker? [y/N]: "
        fi

        local response=""
        local read_timeout=1
        local total_timeout=60
        local elapsed=0

        echo -n "$prompt_text" > /dev/tty
        while [[ $elapsed -lt $total_timeout && -z "$response" ]]; do
            if IFS= read -r -t $read_timeout response 2>/dev/null; then
                break
            fi
            elapsed=$((elapsed + read_timeout))
        done

        if [[ -z "$response" ]]; then
            response="$default_response"
        fi

        if [[ "$response" =~ ^[Yy]$ ]]; then
            selected+=("$pkg")
        elif [[ "$response" =~ ^[Nn]$ ]]; then
            :
        else
            # On invalid input, use default
            if [[ "$default_response" == "y" ]]; then
                selected+=("$pkg")
            fi
        fi
    done

    if [[ ${#selected[@]} -gt 0 ]]; then
        printf '%s\n' "${selected[@]}"
    fi
}

# Final confirmation before running brew upgrade
# Args:
#   $1: Description of what will be upgraded (e.g., "3 no-signal packages")
#   $2...: Package names (optional, for display)
# Returns:
#   0: User confirmed
#   1: User declined or timeout
prompt_upgrade_confirmation() {
    local description="$1"
    shift
    local packages=("$@")

    echo "" > /dev/tty
    if [[ ${#packages[@]} -gt 0 ]]; then
        echo "About to upgrade: $description" > /dev/tty
        echo "  ${packages[*]}" > /dev/tty
    else
        echo "About to upgrade: $description" > /dev/tty
    fi
    echo "" > /dev/tty

    if prompt_for_confirmation "Proceed with upgrade? (y/N): "; then
        return 0
    else
        echo "Upgrade cancelled." > /dev/tty
        return 1
    fi
}
