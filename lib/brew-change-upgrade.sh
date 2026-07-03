#!/usr/bin/env bash
# Upgrade orchestration functions for brew-change
# Handles the interactive selective upgrade flow triggered by -u/--upgrade flag

# Arrays populated by collect_upgrade_status
BREAKING_PKGS=()
SAFE_PKGS=()

# Collect breaking-change status from parallel processing subshells
# Args:
#   $1: Path to the temporary directory containing results.tsv
# Populates global arrays:
#   BREAKING_PKGS[] - packages flagged with breaking changes
#   SAFE_PKGS[]     - packages not flagged
collect_upgrade_status() {
    local status_dir="$1"
    local results_file="${status_dir}/results.tsv"

    BREAKING_PKGS=()
    SAFE_PKGS=()

    if [[ ! -f "$results_file" ]]; then
        return 0  # No status file means no breaking data available
    fi

    while IFS=$'\t' read -r pkg_name breaking_status; do
        if [[ -z "$pkg_name" ]]; then
            continue
        fi

        if [[ "$breaking_status" == "true" ]]; then
            BREAKING_PKGS+=("$pkg_name")
        else
            SAFE_PKGS+=("$pkg_name")
        fi
    done < "$results_file"
}

# Check if a package was flagged as having breaking changes
# Args:
#   $1: Package name
# Returns:
#   0 if package has breaking changes, 1 otherwise
is_package_breaking() {
    local target="$1"
    local pkg
    for pkg in "${BREAKING_PKGS[@]+"${BREAKING_PKGS[@]}"}"; do
        if [[ "$pkg" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

# Print the upgrade summary line
# Args:
#   $1: The outdated packages JSON from brew outdated --json=v2
print_upgrade_summary() {
    local outdated_packages="$1"

    local total_count=0
    local breaking_count=${#BREAKING_PKGS[@]}
    local safe_count=${#SAFE_PKGS[@]}

    # Calculate total from JSON
    total_count=$(echo "$outdated_packages" | jq -r '(.formulae | length) + (.casks | length)' 2>/dev/null || echo "0")

    # Packages with no status entry (release notes unavailable) count as safe
    local known_count=$((breaking_count + safe_count))
    local unknown_count=$((total_count - known_count))
    safe_count=$((safe_count + unknown_count))

    echo ""
    echo "---"
    echo "Summary: $total_count packages outdated · $breaking_count with breaking changes · $safe_count appear safe"
}

# Print suggested upgrade command without executing
# Args:
#   $1: The outdated packages JSON
print_upgrade_suggestion() {
    local outdated_packages="$1"

    local total_count=0
    local breaking_count=${#BREAKING_PKGS[@]}
    local safe_count=${#SAFE_PKGS[@]}

    total_count=$(echo "$outdated_packages" | jq -r '(.formulae | length) + (.casks | length)' 2>/dev/null || echo "0")
    # Packages with no status entry (release notes unavailable) count as safe
    local unknown_count=$((total_count - breaking_count - safe_count))
    safe_count=$((safe_count + unknown_count))

    echo ""

    if [[ $breaking_count -gt 0 ]]; then
        if [[ ${#SAFE_PKGS[@]} -gt 0 ]]; then
            echo "Suggested safe upgrade:"
            echo "  brew upgrade ${SAFE_PKGS[*]}"
            echo ""
        fi
        echo "To upgrade all packages:"
        echo "  brew upgrade"
    else
        echo "No breaking changes detected. To upgrade all packages:"
        echo "  brew upgrade"
    fi

    echo ""
    echo "Tip: Set BREW_CHANGE_UPGRADE_INTERACTIVE=true to enable the interactive upgrade prompt."
}

# Run the interactive upgrade flow
# Args:
#   $1: The outdated packages JSON from brew outdated --json=v2
run_upgrade_prompt() {
    local outdated_packages="$1"

    local breaking_count=${#BREAKING_PKGS[@]}

    # Calculate safe count (including packages with no status)
    local total_count=0
    total_count=$(echo "$outdated_packages" | jq -r '(.formulae | length) + (.casks | length)' 2>/dev/null || echo "0")
    local safe_count=$((total_count - breaking_count))

    # Print summary (always shown in upgrade mode)
    print_upgrade_summary "$outdated_packages"

    # Non-interactive mode: print suggestion and exit
    if ! is_interactive_mode; then
        echo ""
        echo "Non-interactive mode. Upgrade skipped."
        if [[ ${#SAFE_PKGS[@]} -gt 0 ]]; then
            echo "Suggested safe upgrade: brew upgrade ${SAFE_PKGS[*]}"
        fi
        echo "To upgrade all: brew upgrade"
        return 0
    fi

    # Check safety gate: env var must be true for interactive prompt
    if [[ "$BREW_CHANGE_UPGRADE_INTERACTIVE" != "true" ]]; then
        print_upgrade_suggestion "$outdated_packages"
        return 0
    fi

    # Interactive prompt
    local action
    action=$(prompt_upgrade_action "$breaking_count" "$safe_count" "$total_count")

    case "$action" in
        all)
            execute_upgrade "all outdated packages" "all"
            ;;
        safe)
            if [[ ${#SAFE_PKGS[@]} -eq 0 ]]; then
                echo ""
                echo "No safe packages to upgrade."
                echo "All packages have breaking changes. Use [a]ll to upgrade everything."
                return 0
            fi
            execute_upgrade "${#SAFE_PKGS[@]} safe packages" "safe"
            ;;
        choose)
            # Build full package list from JSON
            local all_pkgs=()
            while IFS= read -r pkg; do
                [[ -n "$pkg" && "$pkg" != "null" ]] && all_pkgs+=("$pkg")
            done < <(echo "$outdated_packages" | jq -r '.formulae[].name // empty' 2>/dev/null)
            while IFS= read -r pkg; do
                [[ -n "$pkg" && "$pkg" != "null" ]] && all_pkgs+=("$pkg")
            done < <(echo "$outdated_packages" | jq -r '.casks[].name // empty' 2>/dev/null)

            if [[ ${#all_pkgs[@]} -eq 0 ]]; then
                echo "No packages to choose from."
                return 0
            fi

            local selected
            selected=$(prompt_package_selection "${all_pkgs[@]}")

            if [[ -z "$selected" ]]; then
                echo ""
                echo "No packages selected."
                return 0
            fi

            local selected_count
            selected_count=$(echo "$selected" | wc -l | tr -d ' ')
            execute_upgrade "$selected_count selected packages" "selected" "$selected"
            ;;
        cancel|*)
            echo ""
            echo "Upgrade cancelled."
            return 0
            ;;
    esac
}

# Execute brew upgrade for selected packages
# Args:
#   $1: Human-readable description of what's being upgraded
#   $2: Mode - "all", "safe", or "selected"
#   $3: (Optional) Newline-separated list of package names for "selected" mode
execute_upgrade() {
    local description="$1"
    local mode="$2"
    shift 2
    local package_list="${*:-}"

    local cmd_args=()

    case "$mode" in
        all)
            # No args = upgrade everything outdated
            ;;
        safe)
            cmd_args=("${SAFE_PKGS[@]}")
            ;;
        selected)
            # Convert newline-separated to array
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] && cmd_args+=("$pkg")
            done <<< "$package_list"
            ;;
    esac

    echo ""
    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        echo "Running: brew upgrade"
    else
        echo "Running: brew upgrade ${cmd_args[*]}"
    fi
    echo ""

    # Execute brew upgrade, capturing output
    local upgrade_exit_code=0

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        brew upgrade || upgrade_exit_code=$?
    else
        brew upgrade "${cmd_args[@]}" || upgrade_exit_code=$?
    fi

    echo ""

    if [[ $upgrade_exit_code -eq 0 ]]; then
        echo "Upgrade completed successfully. ✓"
    else
        echo "Upgrade completed with errors (exit code $upgrade_exit_code)."
        echo "Some packages may have failed to upgrade."
        echo "Check the output above for details, or run 'brew doctor' to diagnose issues."
    fi

    return $upgrade_exit_code
}
