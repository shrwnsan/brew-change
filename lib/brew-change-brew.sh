#!/usr/bin/env bash
# Homebrew integration functions for brew-change

# Function to fetch package info from Homebrew
fetch_package_info() {
    local package="$1"
    local is_cask="$2"

    local package_type="formula"
    [[ "$is_cask" == "true" ]] && package_type="cask"

    # Extract package name from tap format (e.g., "oven-sh/bun/bun" -> "bun", "homebrew/cask/visual-studio-code" -> "visual-studio-code")
    local clean_package="$package"
    if [[ "$package" =~ ^[^/]+/[^/]+/(.+)$ ]]; then
        clean_package="${BASH_REMATCH[1]}"
    elif [[ "$package" =~ ^[^/]+/(.+)$ ]]; then
        # Handle simple tap format like "homebrew/cask/visual-studio-code"
        clean_package="${BASH_REMATCH[1]}"
    fi

    local info_url="https://formulae.brew.sh/api/${package_type}/${clean_package}.json"
    fetch_url_with_retry "$info_url"
}

# Function to get installed version of a package
get_installed_version() {
    local package="$1"
    local is_cask="$2"

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq command not found - required for JSON processing" >&2
        return 1
    fi

    local brew_info
    if ! brew_info=$(brew info --json=v2 "$package" 2>/dev/null); then
        return 1
    fi

    if [[ "$is_cask" == "true" ]]; then
        echo "$brew_info" | jq -r '.casks[0].installed // ""' 2>/dev/null || echo ""
    else
        echo "$brew_info" | jq -r '.formulae[0].installed[0].version // ""' 2>/dev/null || echo ""
    fi
}

# Function to get the latest available version from brew outdated (includes revision numbers)
get_latest_outdated_version() {
    local package="$1"

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq command not found - required for JSON processing" >&2
        return 1
    fi

    local outdated_json
    if ! outdated_json=$(brew outdated --json=v2 2>/dev/null); then
        return 1
    fi

    # Try to find the package in formulae first
    local latest_version
    latest_version=$(echo "$outdated_json" | jq -r ".formulae[] | select(.name == \"$package\") | .current_version" 2>/dev/null)

    # If not found in formulae, try casks
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        latest_version=$(echo "$outdated_json" | jq -r ".casks[] | select(.token == \"$package\") | .current_version" 2>/dev/null)
    fi

    if [[ -n "$latest_version" && "$latest_version" != "null" ]]; then
        echo "$latest_version"
        return 0
    fi

    return 1
}

# Function to show simple outdated list (package names only)
show_outdated_simple_names() {
    local outdated_packages
    if ! outdated_packages=$(brew outdated 2>/dev/null); then
        echo "Error: Unable to check for outdated packages"
        exit 1
    fi

    # Output the outdated packages (this was missing!)
    if [[ -n "$outdated_packages" ]]; then
        echo "$outdated_packages"
    else
        echo "No outdated packages found."
    fi
}

# Function to show outdated list with versions
show_outdated_with_versions() {
    local outdated_packages
    if ! outdated_packages=$(brew outdated --json=v2 2>/dev/null | grep -v '✔︎ JSON API'); then
        echo "Error: Unable to check for outdated packages"
        exit 1
    fi

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq command not found - required for JSON processing" >&2
        exit 1
    fi

    # Check if there are any outdated packages (both formulae and casks empty)
    local formulae_empty
    local casks_empty

    if formulae_empty=$(echo "$outdated_packages" | jq -r '.formulae | length' 2>/dev/null); then
        if [[ "$formulae_empty" == "0" ]]; then
            if casks_empty=$(echo "$outdated_packages" | jq -r '.casks | length' 2>/dev/null); then
                if [[ "$casks_empty" == "0" ]]; then
                    echo "No outdated packages found."
                    return
                fi
            else
                # If casks check fails, just check formulae
                if [[ "$formulae_empty" == "0" ]]; then
                    echo "No outdated packages found."
                    return
                fi
            fi
        fi
    fi

    # Process formulas with error handling
    if echo "$outdated_packages" | jq -e '.formulae | length > 0' >/dev/null 2>&1; then
        echo "$outdated_packages" | jq -r '.formulae[] | "\(.name) (\(.installed_versions | join(", ")) → \(.current_version))"' 2>/dev/null
    fi

    # Process casks with error handling
    if echo "$outdated_packages" | jq -e '.casks | length > 0' >/dev/null 2>&1; then
        echo "$outdated_packages" | jq -r '.casks[] | "\(.name | join(" / ")) (\(.installed_versions | join(", ")) → \(.current_version))"' 2>/dev/null
    fi
}

# Function to show changelog for a single package
show_package_changelog() {
    local package="$1"
    validate_package_name "$package"

    # Initialize GitHub authentication to get higher rate limits
    init_github_auth

    # Extract base package name first to normalize tap/package format
    local normalized_package=$(extract_base_package_name "$package")

    # Check if package exists in Homebrew before proceeding
    if ! check_package_exists "$normalized_package"; then
        echo "Error: Package '$package' not found in Homebrew"
        echo ""

        # Check for similar packages if package is long enough
        local best_suggestion=""
        if best_suggestion=$(get_best_suggestion "$normalized_package" 2>/dev/null); then
            echo "Similar installed packages:"
            find_similar_packages "$normalized_package"
            echo ""
            echo "Continue with '$best_suggestion'? (y/N): "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                echo ""
                echo "Processing changelog for 1 package..."
                echo ""
                # Recursively call with the suggested package
                show_package_changelog "$best_suggestion"
                return $?
            else
                echo ""
            fi
        else
            # No suggestions found, show general search advice
            if [[ ${#normalized_package} -ge 3 ]]; then
                echo "To search installed packages, try: brew list | grep $normalized_package"
            else
                echo "Package name too short for suggestions (minimum 3 characters)"
                echo "To search installed packages, try: brew list | grep $normalized_package"
            fi
        fi
        return 1
    fi

    # ENHANCED: Check if this is a tap package using our new detection
    local base_package=""
    local detected_tap=""

    # Use the normalized package name for all further processing
    base_package="$normalized_package"

    # Detect if this is a tap package using the normalized package name
    if detected_tap=$(detect_package_tap "$base_package" "false" 2>/dev/null); then
        # This is a tap package - get version info from brew info first
        local brew_info
        if brew_info=$(brew info --json=v2 "$package" 2>/dev/null); then
            # Extract URLs from brew info (handle both .urls.url and .urls.stable.url patterns)
            local source_url=$(echo "$brew_info" | jq -r '.formulae[0].urls.stable.url // .formulae[0].urls.url // ""' 2>/dev/null || echo "")
            local homepage=$(echo "$brew_info" | jq -r '.formulae[0].homepage // ""' 2>/dev/null || echo "")

            # Try to extract GitHub repo using our enhanced method
            local github_repo=""
            if github_repo=$(extract_github_repo "$source_url" "$homepage" "$base_package"); then
                local current_version=""
                local latest_version=""

                # Extract version info from brew info
                current_version=$(echo "$brew_info" | jq -r '.formulae[0].installed[0].version // ""' 2>/dev/null)
                latest_version=$(echo "$brew_info" | jq -r '.formulae[0].versions.stable // ""' 2>/dev/null)

                if [[ -n "$current_version" && -n "$latest_version" && "$current_version" != "$latest_version" ]]; then
                    # Create minimal package_info JSON for show_package_changelog_full
                    local minimal_package_info="{\"homepage\":\"$homepage\",\"url\":\"$source_url\"}"
                    show_package_changelog_full "$package" "$current_version" "$latest_version" "$minimal_package_info"
                    return 0
                else
                    if [[ -n "$current_version" && "$current_version" != "null" && "$current_version" == "$latest_version" ]]; then
                        echo "📦 $package: $current_version → $latest_version"
                        echo ""
                        echo "Already up to date at version $current_version ✓"
                        return 0
                    else
                        local display_current="${current_version:-[not installed]}"
                        local display_latest="${latest_version:-unknown}"
                        echo "📦 $package: $display_current → $display_latest"
                        echo ""
                        echo "Version information unavailable."
                        return 0
                    fi
                fi
            else
                echo "Error: Could not get brew info for $base_package"
                return 1
            fi
            fi
    fi

    # Try as formula first, then as cask
    local package_info
    local is_cask="false"
    local formula_error=""
    local cask_error=""

    if ! package_info=$(fetch_package_info "$base_package" "false" 2>/dev/null); then
        formula_error="Formula fetch failed"
        # Try as cask
        if ! package_info=$(fetch_package_info "$base_package" "true" 2>/dev/null); then
            cask_error="Cask fetch failed"
            echo "Error: Could not fetch information for package: $package"
            echo "       Both formula and cask information unavailable"
            echo "       This might be due to network issues or the package not existing"
            return 1
        else
            is_cask="true"
        fi
    fi

    # Get current version from brew outdated (more accurate)
    local current_version
    current_version=$(get_installed_version "$base_package" "$is_cask")
    if [[ -z "$current_version" || "$current_version" == "null" ]]; then
        if [[ "$is_cask" == "true" ]]; then
            current_version=$(echo "$package_info" | jq -r '.installed_version // "unknown"' 2>/dev/null || echo "unknown")
        else
            current_version=$(echo "$package_info" | jq -r '.installed[0].version // "unknown"' 2>/dev/null || echo "unknown")
        fi
    fi
    
    local latest_version
    if [[ "$is_cask" == "true" ]]; then
        latest_version=$(echo "$package_info" | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
    else
        latest_version=$(echo "$package_info" | jq -r '.versions.stable // "unknown"' 2>/dev/null || echo "unknown")
    fi
    
    # Special case: Handle casks with null latest_version but potential GitHub URLs
    if [[ "$latest_version" == "null" || "$latest_version" == "unknown" || -z "$latest_version" ]]; then
        if [[ "$is_cask" == "true" ]]; then
            # Try to get GitHub URL from brew info for casks with null latest_version
            local brew_cask_info=""
            if brew_cask_info=$(brew info --json=v2 "$base_package" 2>/dev/null); then
                local cask_url=""
                cask_url=$(echo "$brew_cask_info" | jq -r '.casks[0].url // ""' 2>/dev/null || echo "")
                if [[ -n "$cask_url" && "$cask_url" != "null" && "$cask_url" =~ github\.com ]]; then
                    # Found GitHub URL - extract version and proceed
                    if [[ -n "$current_version" && "$current_version" != "unknown" ]]; then
                        latest_version="$current_version"  # Use current as fallback
                        # Extract GitHub repo from cask URL and show changelog
                        local github_repo=""
                        if github_repo=$(extract_github_repo_from_url "$cask_url"); then
                            show_package_changelog_full "$package" "$current_version" "$latest_version" "" "$github_repo"
                            return 0
                        fi
                    fi
                fi
            fi
        fi

        local display_current="$current_version"
        if [[ "$display_current" == "unknown" || -z "$display_current" ]]; then
            display_current="[not installed]"
        fi
        echo "📦 $package: $display_current → unknown"
        echo "Package information not available - this might be:"
        echo "  • A cask without GitHub repository"
        echo "  • A package using non-GitHub download sources"
        echo "  • A custom/tap package not in Homebrew's main repository"
        echo ""
        return 1
    fi

    # First check if the package is actually outdated using brew outdated
    # This catches revision numbers (e.g., 0.61 vs 0.61_1) that the API doesn't track
    local actual_latest_version
    if actual_latest_version=$(get_latest_outdated_version "$base_package" 2>/dev/null); then
        # Package is outdated, use the actual latest version
        latest_version="$actual_latest_version"
    fi

    # Check if package is up to date
    if [[ "$current_version" == "$latest_version" ]]; then
        local install_date=""
        # Get installation time from local brew info, not from API
        local local_brew_info
        if local_brew_info=$(brew info --json=v2 "$base_package" 2>/dev/null); then
            local install_timestamp
            if [[ "$is_cask" == "true" ]]; then
                # Cask installation time
                if install_timestamp=$(echo "$local_brew_info" | jq -r '.casks[0].installed_time // ""' 2>/dev/null); then
                    if [[ -n "$install_timestamp" && "$install_timestamp" != "null" && "$install_timestamp" != "" ]]; then
                        install_date="$install_timestamp"
                    fi
                fi
            else
                # Formula installation time
                if install_timestamp=$(echo "$local_brew_info" | jq -r '.formulae[0].installed[0].time // ""' 2>/dev/null); then
                    if [[ -n "$install_timestamp" && "$install_timestamp" != "null" && "$install_timestamp" != "" ]]; then
                        install_date="$install_timestamp"
                    fi
                fi
            fi
        fi

        # Format installation date if available (install_date is now a Unix timestamp)
        local formatted_date=""
        if [[ -n "$install_date" && "$install_date" != "null" && "$install_date" != "" ]]; then
            if command -v date &> /dev/null; then
                local now_timestamp=$(date +%s)
                local diff=$((now_timestamp - install_date))

                if [[ $diff -lt 3600 ]]; then
                    formatted_date="$((diff / 60)) minutes ago"
                elif [[ $diff -lt 86400 ]]; then
                    formatted_date="$((diff / 3600)) hours ago"
                elif [[ $diff -lt 604800 ]]; then
                    formatted_date="$((diff / 86400)) days ago"
                else
                    formatted_date=$(date -r "$install_date" "+%Y-%m-%d" 2>/dev/null || echo "unknown date")
                fi
            else
                formatted_date="unknown date"
            fi
        fi

        if [[ -n "$formatted_date" ]]; then
            echo "📦 $package: $current_version → latest (installed $formatted_date)"
        else
            echo "📦 $package: $current_version → latest"
        fi
        echo ""
        echo "No new releases."
        echo ""
        return 0
    fi

      show_package_changelog_full "$package" "$current_version" "$latest_version" "$package_info"
}
