#!/usr/bin/env bash
# Interactive prompt functions for brew-change
# Provides reusable, interruptible prompt functions with proper variable scoping

# Prompt for yes/no confirmation with timeout and CTRL+C support
# Args:
#   $1: Prompt text (will be displayed with ": " suffix)
# Returns:
#   0: User confirmed (y/Y)
#   1: User declined or timeout
prompt_for_confirmation() {
    local prompt_text="$1"
    local response=""
    local read_timeout=1  # Check every second for timeout/interrupt
    local total_timeout=300  # 5 minutes total wait time
    local elapsed=0

    echo -n "$prompt_text"
    while [[ $elapsed -lt $total_timeout && -z "$response" ]]; do
        if IFS= read -r -t $read_timeout response 2>/dev/null; then
            break
        fi
        elapsed=$((elapsed + read_timeout))
    done

    [[ "$response" =~ ^[Yy]$ ]]
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

    echo -n "$prompt_text"
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
