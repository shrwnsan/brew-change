#!/usr/bin/env bash
# Interactive prompt functions for brew-change
# Provides reusable, interruptible prompt functions with proper variable scoping

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

# Four-option upgrade action prompt with spinner animation
# Args:
#   $1: Count of packages with breaking changes
#   $2: Count of packages without breaking changes (safe)
#   $3: Total outdated package count
# Returns (via echo to stdout):
#   "all", "safe", "choose", or "cancel"
prompt_upgrade_action() {
    local breaking_count="$1"
    local safe_count="$2"
    local total_count="$3"

    # Determine default based on whether breaking changes exist
    local default_option="a"
    if [[ "$breaking_count" -gt 0 ]]; then
        default_option="s"
    fi

    # Helper text
    echo "" > /dev/tty
    echo "Select upgrade mode:" > /dev/tty
    echo "" > /dev/tty

    local prompt_text="[a]ll / [s]afe-only ($safe_count) / [c]hoose / cancel [$default_option]: "
    local spinner_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local read_timeout=0.1
    local spinner_idx=0
    local prompt_width=$(( ${#prompt_text} + 6 ))

    local response=""

    while [[ -z "$response" ]]; do
        # Draw spinner in-place via carriage return (no timeout, waits indefinitely)
        local frame=" ${spinner_chars:spinner_idx:1}"
        printf "\r%s%s" "$prompt_text" "$frame" > /dev/tty
        spinner_idx=$(( (spinner_idx + 1) % ${#spinner_chars} ))

        if IFS= read -r -t $read_timeout response 2>/dev/null; then
            break
        fi
    done

    # Clear the spinner line
    printf "\r%*s\r" "$prompt_width" "" > /dev/tty

    # Empty response -> use default
    if [[ -z "$response" ]]; then
        response="$default_option"
    fi

    case "$response" in
        a|all)    echo "all" ;;
        s|safe)   echo "safe" ;;
        c|choose) echo "choose" ;;
        *)        echo "cancel" ;;
    esac
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
        local default_response="y"
        local breaking_marker=""

        if is_package_breaking "$pkg"; then
            default_response="n"
            breaking_marker=" ⚠️"
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
#   $1: Description of what will be upgraded (e.g., "3 safe packages")
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
