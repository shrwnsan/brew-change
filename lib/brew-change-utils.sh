#!/usr/bin/env bash
# Utility functions for brew-change with robust error recovery

# Function to sanitize environment for subprocess security (minimal)
sanitize_environment() {
    # Only clear the most critical variables that don't break functionality
    unset ENV BASH_ENV ENVIRONMENT 2>/dev/null || true
    unset PROMPT_COMMAND 2>/dev/null || true
    
    # Try to unset SHELLOPTS, but ignore if it's readonly
    unset SHELLOPTS 2>/dev/null || true
    
    # Set secure umask for subprocesses
    umask 077
}

# Function to validate package name format
validate_package_name() {
    local package="$1"
    
    # Check for empty input
    if [[ -z "$package" ]]; then
        echo "Error: Package name cannot be empty" >&2
        exit 1
    fi
    
    # Check for path traversal attempts
    if [[ "$package" == *"../"* ]] || [[ "$package" == *"..\\"* ]] || [[ "$package" == "~/"* ]] || [[ "$package" == "/"* ]]; then
        echo "Error: Invalid characters in package name (potential path traversal): $package" >&2
        exit 1
    fi
    
    # Sanitize input: remove any control characters
    package=$(echo "$package" | tr -d '\000-\037\177')
    
    # Validate format: allow alphanumeric, dots, underscores, hyphens, at symbols, and forward slashes (for taps)
    if [[ ! "$package" =~ ^[a-zA-Z0-9._/@-]+$ ]]; then
        echo "Error: Invalid package name format: $package" >&2
        echo "       Package names should contain only letters, numbers, dots, underscores, hyphens, at symbols, and forward slashes" >&2
        exit 1
    fi
    
    # Length check to prevent buffer overflow attempts
    if [[ ${#package} -gt 100 ]]; then
        echo "Error: Package name too long (max 100 characters): $package" >&2
        exit 1
    fi
}

# Function to add delay for rate limiting
rate_limit_delay() {
    sleep "$API_RATE_LIMIT_DELAY"
}

# Function to get cache file path for a URL
get_cache_file() {
    local url="$1"
    local cache_key=$(echo "$url" | sha256sum | cut -d' ' -f1)
    echo "${CACHE_DIR}/${cache_key}.json"
}

# Function to get temporary cache file path (for atomic writes)
get_cache_temp_file() {
    local cache_file="$1"
    local cache_dir=$(dirname "$cache_file")
    local base_name=$(basename "$cache_file")
    echo "${cache_dir}/.${base_name}.tmp.$$"
}

# Function to check if cache is valid (with atomic check)
is_cache_valid() {
    local cache_file="$1"
    local temp_file="${cache_file}.tmp"
    
    # Check if cache file exists and temp file doesn't exist (indicates incomplete write)
    if [[ -f "$cache_file" && ! -f "$temp_file" ]]; then
        local cache_age
        if cache_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null))); then
            if [[ $cache_age -lt $CACHE_EXPIRY ]]; then
                return 0
            fi
        fi
    fi
    return 1
}

# Function to write cache atomically with secure permissions
write_cache_atomic() {
    local content="$1"
    local cache_file="$2"
    local temp_file
    temp_file=$(get_cache_temp_file "$cache_file")
    
    # Create temporary file with secure permissions
    if ! (umask 077 && echo "$content" > "$temp_file"); then
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
    
    # Set explicit permissions for security
    chmod 600 "$temp_file" 2>/dev/null
    
    # Sync to disk to ensure data is written
    sync "$temp_file" 2>/dev/null
    
    # Atomic rename to final location
    if ! mv "$temp_file" "$cache_file"; then
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
    
    # Ensure final file has secure permissions
    chmod 600 "$cache_file" 2>/dev/null
    
    return 0
}

# Function to cleanup stale temp files
cleanup_stale_temp_files() {
    # Remove temp files older than 5 minutes (indicates crashed processes)
    find "$CACHE_DIR" -name ".*.tmp.*" -type f -mmin +5 -delete 2>/dev/null || true
}

# Function to handle network errors with exponential backoff
handle_network_error() {
    local attempt="$1"
    local max_attempts="$2"
    local url="$3"

    if [[ $attempt -lt $max_attempts ]]; then
        # Exponential backoff: 2s, 4s, 8s, 16s
        local base_delay=$((RETRY_DELAY * attempt))
        # Add jitter using better approach: ±25% of base_delay without integer division loss
        # For small delays, use direct jitter calculation
        if [[ $base_delay -le 4 ]]; then
            # For delays 4s or less, use 0.5s jitter units
            local jitter_units=$((RANDOM % 3 - 1))  # Random between -1 and +1
            local jitter_delay=$((jitter_units))
        else
            # For larger delays, use percentage-based jitter
            local jitter_percent=$((RANDOM % 51 - 25))  # Random between -25 and +25
            local jitter_delay=$((base_delay * jitter_percent / 100))
        fi
        local backoff_time=$((base_delay + jitter_delay))

        # Ensure minimum delay of 1 second
        [[ $backoff_time -lt 1 ]] && backoff_time=1

        # Only show retry messages for higher attempts to reduce noise
        if [[ $attempt -gt 1 ]]; then
            echo "Warning: Network request failed (attempt $attempt/$max_attempts), retrying in ${backoff_time}s..." >&2
        fi
        sleep "$backoff_time"
        return 1  # Continue retrying
    else
        echo "Error: Failed to fetch URL after $max_attempts attempts: $url" >&2
        return 0  # Stop retrying
    fi
}

# Function to validate JSON response
validate_json_response() {
    local response="$1"
    local url="$2"
    
    # Check if response is empty
    if [[ -z "$response" ]]; then
        echo "Warning: Empty response from $url" >&2
        return 1
    fi
    
    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq command not found - required for JSON processing" >&2
        return 1
    fi
    
    # Check if response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        echo "Warning: Invalid JSON response from $url" >&2
        return 1
    fi
    
    # Check for common error responses with proper error handling
    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        local error_msg
        if ! error_msg=$(echo "$response" | jq -r '.message // "Unknown error"' 2>/dev/null); then
            error_msg="Unknown error (failed to extract message)"
        fi
        echo "Warning: API error response from $url: $error_msg" >&2
        return 1
    fi
    
    # Check for GitHub rate limit with proper error handling
    if echo "$response" | jq -e '.documentation_url' >/dev/null 2>&1; then
        echo "Warning: GitHub rate limit exceeded for $url" >&2
        return 1
    fi
    
    return 0
}

# Function to validate URL and prevent malicious redirects
validate_url() {
    local url="$1"
    
    # Check for empty URL
    if [[ -z "$url" ]]; then
        echo "Error: Empty URL provided" >&2
        return 1
    fi
    
    # Allow only HTTPS (secure) or HTTP for specific endpoints
    if [[ ! "$url" =~ ^https?:// ]]; then
        echo "Error: Only HTTP/HTTPS URLs are allowed: $url" >&2
        return 1
    fi
    
    # Define allowed domains
    local allowed_domains=(
        "api.github.com"
        "github.com"
        "raw.githubusercontent.com"
        "formulae.brew.sh"
        "registry.npmjs.org"
    )
    
    # Extract domain from URL
    local domain
    domain=$(echo "$url" | sed -E 's|^https?://([^/]*).*|\1|')
    
    # Check if domain is in allowed list
    local allowed=false
    for allowed_domain in "${allowed_domains[@]}"; do
        if [[ "$domain" == "$allowed_domain" || "$domain" == *".$allowed_domain" ]]; then
            allowed=true
            break
        fi
    done
    
    if [[ "$allowed" != "true" ]]; then
        echo "Error: Domain not allowed: $domain" >&2
        return 1
    fi
    
    # Check for suspicious URL patterns (allow @ in legitimate package repository URLs)
    if [[ "$url" == *"%0a"* ]] || [[ "$url" == *"%0d"* ]] || [[ "$url" == "javascript:"* ]] || [[ "$url" == "data:"* ]] || [[ "$url" == "file:"* ]] || ([[ "$url" == *"@"* ]] && [[ ! "$url" =~ ^https://(registry\.npmjs\.org|formulae\.brew\.sh|raw\.githubusercontent\.com|api\.github\.com)/ ]]); then
        echo "Error: Suspicious URL pattern detected: $url" >&2
        return 1
    fi
    
    return 0
}

# Function to fetch text content (non-JSON) with retries
fetch_url_with_retry_text() {
    local url="$1"
    
    # Validate URL before processing (but skip JSON validation)
    if ! validate_url "$url"; then
        return 1
    fi
    
    local attempt=1
    while [[ $attempt -le $MAX_RETRIES ]]; do
        local response
        local curl_exit_code
        
        # Use curl for text content (no JSON validation)
        if response=$(curl -s \
            --max-time 10 \
            --connect-timeout 5 \
            --retry 1 \
            --retry-delay 1 \
            --retry-max-time 15 \
            --fail \
            --location \
            --max-redirs 2 \
            --proto =https,http \
            --proto-redir =https,http \
            --user-agent "brew-change/1.0" \
            --no-progress-meter \
            "$url" 2>/dev/null); then
            
            # Return response if not empty
            if [[ -n "$response" ]]; then
                echo "$response"
                return 0
            fi
        else
            curl_exit_code=$?
            # Only show curl errors for final attempt
            if [[ $attempt -eq $MAX_RETRIES ]]; then
                case $curl_exit_code in
                    6)  echo "Warning: Could not resolve host for URL: $url" >&2 ;;
                    7)  echo "Warning: Failed to connect to host for URL: $url" >&2 ;;
                    22) echo "Warning: HTTP error returned for URL: $url" >&2 ;;
                    28) echo "Warning: Operation timeout for URL: $url" >&2 ;;
                    35) echo "Warning: SSL connect error for URL: $url" >&2 ;;
                    60) echo "Warning: SSL certificate problem for URL: $url" >&2 ;;
                    *)  echo "Warning: Curl error $curl_exit_code for URL: $url" >&2 ;;
                esac
            fi
        fi
        
        # Handle retry logic
        if handle_network_error $attempt $MAX_RETRIES "$url"; then
            return 1
        fi
        ((attempt++))
    done
    
    return 1
}

# Function to fetch URL with robust retries and caching
fetch_url_with_retry() {
    local url="$1"
    local cache_file=$(get_cache_file "$url")
    
    # Validate URL before processing
    if ! validate_url "$url"; then
        return 1
    fi
    
    # Check cache first
    if is_cache_valid "$cache_file"; then
        local cached_response
        if cached_response=$(cat "$cache_file" 2>/dev/null); then
            if validate_json_response "$cached_response" "$url"; then
                echo "$cached_response"
                return 0
            else
                # Cache contains invalid data, remove it
                rm -f "$cache_file" 2>/dev/null
            fi
        fi
    fi
    
    local attempt=1
    while [[ $attempt -le $MAX_RETRIES ]]; do
        local response
        local curl_exit_code
        
        # Use curl with comprehensive security and error handling
        if response=$(curl -s \
            --max-time 5 \
            --connect-timeout 3 \
            --retry 1 \
            --retry-delay 1 \
            --retry-max-time 10 \
            --fail \
            --location \
            --max-redirs 2 \
            --proto =https,http \
            --proto-redir =https,http \
            --user-agent "brew-change/1.0" \
            --no-progress-meter \
            "$url" 2>/dev/null); then
            
            # Validate response
            if validate_json_response "$response" "$url"; then
                # Cache validated response atomically
                if write_cache_atomic "$response" "$cache_file"; then
                    echo "$response"
                    return 0
                else
                    echo "Warning: Failed to cache response for $url" >&2
                    echo "$response"
                    return 0
                fi
            fi
        else
            curl_exit_code=$?
            # Only show curl errors for final attempt to reduce noise
            if [[ $attempt -eq $MAX_RETRIES ]]; then
                case $curl_exit_code in
                    6)  echo "Warning: Could not resolve host for URL: $url" >&2 ;;
                    7)  echo "Warning: Failed to connect to host for URL: $url" >&2 ;;
                    22) echo "Warning: HTTP error returned for URL: $url" >&2 ;;
                    28) echo "Warning: Operation timeout for URL: $url" >&2 ;;
                    35) echo "Warning: SSL connect error for URL: $url" >&2 ;;
                    60) echo "Warning: SSL certificate problem for URL: $url" >&2 ;;
                    *)  echo "Warning: Curl error $curl_exit_code for URL: $url" >&2 ;;
                esac
            fi
        fi
        
        # Handle retry logic
        if handle_network_error $attempt $MAX_RETRIES "$url"; then
            return 1
        fi
        ((attempt++))
    done
    
    # All retries failed, try to use stale cache if available
    if [[ -f "$cache_file" ]]; then
        echo "Warning: Using stale cache for $url" >&2
        cat "$cache_file"
        return 0
    fi
    
    return 1
}

# Function to find similar package names with length threshold
find_similar_packages() {
    local package="$1"
    local similar_packages=()

    # Only suggest for packages longer than 2 characters to avoid noise
    if [[ ${#package} -lt 3 ]]; then
        return 0
    fi

    # Search for packages containing the search term
    while IFS= read -r pkg; do
        if [[ "$pkg" == *"$package"* || "$package" == *"$pkg"* ]]; then
            similar_packages+=("$pkg")
        fi
    done < <(brew list 2>/dev/null)

    # Limit to 5 suggestions
    if [[ ${#similar_packages[@]} -gt 0 ]]; then
        echo "Did you mean:"
        printf '  • %s\n' "${similar_packages[@]:0:5}"
        # Return the first suggestion for potential interactive use
        return 0
    fi

    return 1
}

# Function to get the best matching suggestion for interactive use
get_best_suggestion() {
    local package="$1"
    local best_match=""

    # Only suggest for packages longer than 2 characters
    if [[ ${#package} -lt 3 ]]; then
        return 1
    fi

    # Find exact prefix matches first, then substring matches
    while IFS= read -r pkg; do
        if [[ "$pkg" == "${package}"* ]]; then
            echo "$pkg"
            return 0
        fi
    done < <(brew list 2>/dev/null)

    # If no exact prefix match, find first substring match
    while IFS= read -r pkg; do
        if [[ "$pkg" == *"$package"* ]]; then
            echo "$pkg"
            return 0
        fi
    done < <(brew list 2>/dev/null)

    return 1
}

# Function to check if package exists in Homebrew
check_package_exists() {
    local package="$1"

    # Extract package name from tap format (e.g., "oven-sh/bun/bun" -> "bun", "homebrew/cask/visual-studio-code" -> "visual-studio-code")
    local clean_package="$package"
    if [[ "$package" =~ ^[^/]+/[^/]+/(.+)$ ]]; then
        clean_package="${BASH_REMATCH[1]}"
    elif [[ "$package" =~ ^[^/]+/(.+)$ ]]; then
        # Handle simple tap format like "homebrew/cask/visual-studio-code"
        clean_package="${BASH_REMATCH[1]}"
    fi

    # First check if it's installed locally (most efficient check)
    if brew list 2>/dev/null | grep -q "^${clean_package}$"; then
        return 0
    fi

    # If not installed locally, check if it exists in Homebrew (for uninstalled packages)
    if brew info "$clean_package" >/dev/null 2>&1; then
        return 0
    fi

    # Check cask info as well
    if brew info --cask "$clean_package" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Function to test network connectivity
test_network_connectivity() {
    local test_urls=(
        "https://api.github.com/rate_limit"
        "https://formulae.brew.sh/api/formula"
    )
    
    for url in "${test_urls[@]}"; do
        if curl -s --max-time 3 --connect-timeout 2 "$url" >/dev/null 2>&1; then
            return 0
        fi
    done
  
    echo "Warning: Network connectivity issues detected" >&2
    return 1
}

# =============================================================================
# SELF-IMPLEMENTED FUNCTIONS (Phase 1)
# =============================================================================

# Function to extract base package name from tap-prefixed name
extract_base_package_name() {
    local package_name="$1"

    # If package has tap prefix (user/repo/package), extract just the package name
    if [[ "$package_name" =~ ^[^/]+/[^/]+/([^/]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    # If package has simple prefix (user/package), extract the package name
    if [[ "$package_name" =~ ^[^/]+/([^/]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    # No prefix, return as-is
    echo "$package_name"
}

# Function to detect which tap a package belongs to (self-contained approach)
detect_package_tap() {
    local package="$1"
    local is_cask="$2"

    # Check all installed taps for the package
    for tap in $(brew tap); do
        # Convert tap name to directory name
        # Homebrew stores taps as: user/repo -> user/homebrew-repo
        # But there are special cases and the "tap" suffix pattern
        local tap_path=""
        if [[ "$tap" == "charmbracelet/tap" ]]; then
            tap_path="$(brew --repository)/Library/Taps/charmbracelet/homebrew-tap"
        elif [[ "$tap" == "oven-sh/bun" ]]; then
            tap_path="$(brew --repository)/Library/Taps/oven-sh/homebrew-bun"
        elif [[ "$tap" == "sst/tap" ]]; then
            tap_path="$(brew --repository)/Library/Taps/sst/homebrew-tap"
        elif [[ "$tap" =~ ^[^/]+/tap$ ]]; then
            # Handle the "*/tap" pattern generically (e.g., shrwnsan/tap -> shrwnsan/homebrew-tap)
            local user="${tap%/*}"
            tap_path="$(brew --repository)/Library/Taps/${user}/homebrew-tap"
        else
            # Default conversion: replace / with nothing
            tap_path="$(brew --repository)/Library/Taps/${tap//\//}"
        fi
        local search_paths=()

        if [[ "$is_cask" == "true" ]]; then
            # Check multiple possible cask directories
            search_paths=(
                "$tap_path/Casks"
                "$tap_path/Cask"
                "$tap_path"
            )
        else
            # Check multiple possible formula directories
            search_paths=(
                "$tap_path/Formula"
                "$tap_path"
            )
        fi

        for search_path in "${search_paths[@]}"; do
            if [[ -f "$search_path/$package.rb" ]]; then
                echo "$tap"
                return 0
            fi
        done
    done

    # Check homebrew-core and homebrew-cask
    local brew_repo="$(brew --repository)"

    if [[ "$is_cask" == "true" ]]; then
        # Check Cask directory structure (including subdirectories)
        if [[ -f "$brew_repo/Cask/$package.rb" ]]; then
            echo "homebrew-cask"
            return 0
        fi

        # Search in Cask subdirectories
        if find "$brew_repo/Cask" -name "$package.rb" -type f -maxdepth 2 2>/dev/null | grep -q .; then
            echo "homebrew-cask"
            return 0
        fi
    else
        # Check Formula directory structure (including subdirectories)
        if [[ -f "$brew_repo/Formula/$package.rb" ]]; then
            echo "homebrew-core"
            return 0
        fi

        # Search in Formula subdirectories
        if find "$brew_repo/Formula" -name "$package.rb" -type f -maxdepth 2 2>/dev/null | grep -q .; then
            echo "homebrew-core"
            return 0
        fi
    fi

    return 1
}

# Helper function to find package file location
find_package_file() {
    local package="$1"
    local is_cask="$2"
    local tap=""

    # Detect tap first
    if ! tap=$(detect_package_tap "$package" "$is_cask"); then
        return 1
    fi

    # Build file path
    local package_file=""
    if [[ "$tap" == "homebrew-core" || "$tap" == "homebrew-cask" ]]; then
        local brew_repo="$(brew --repository)"

        if [[ "$is_cask" == "true" ]]; then
            # First check direct path
            if [[ -f "$brew_repo/Cask/$package.rb" ]]; then
                echo "$brew_repo/Cask/$package.rb"
                return 0
            fi

            # Search in Cask subdirectories
            package_file=$(find "$brew_repo/Cask" -name "$package.rb" -type f -maxdepth 2 2>/dev/null | head -1)
        else
            # First check direct path
            if [[ -f "$brew_repo/Formula/$package.rb" ]]; then
                echo "$brew_repo/Formula/$package.rb"
                return 0
            fi

            # Search in Formula subdirectories
            package_file=$(find "$brew_repo/Formula" -name "$package.rb" -type f -maxdepth 2 2>/dev/null | head -1)
        fi
    else
        # Convert tap name to directory name (same logic as detect_package_tap)
        local tap_path=""
        if [[ "$tap" == "charmbracelet/tap" ]]; then
            tap_path="$(brew --repository)/Library/Taps/charmbracelet/homebrew-tap"
        elif [[ "$tap" == "oven-sh/bun" ]]; then
            tap_path="$(brew --repository)/Library/Taps/oven-sh/homebrew-bun"
        elif [[ "$tap" == "sst/tap" ]]; then
            tap_path="$(brew --repository)/Library/Taps/sst/homebrew-tap"
        elif [[ "$tap" =~ ^[^/]+/tap$ ]]; then
            # Handle the "*/tap" pattern generically (e.g., shrwnsan/tap -> shrwnsan/homebrew-tap)
            local user="${tap%/*}"
            tap_path="$(brew --repository)/Library/Taps/${user}/homebrew-tap"
        else
            # Default conversion: replace / with nothing
            tap_path="$(brew --repository)/Library/Taps/${tap//\//}"
        fi

        if [[ "$is_cask" == "true" ]]; then
            # Try multiple cask directory structures
            if [[ -f "$tap_path/$package.rb" ]]; then
                package_file="$tap_path/$package.rb"
            elif [[ -f "$tap_path/Casks/$package.rb" ]]; then
                package_file="$tap_path/Casks/$package.rb"
            elif [[ -f "$tap_path/Cask/$package.rb" ]]; then
                package_file="$tap_path/Cask/$package.rb"
            fi
        else
            # Try multiple formula directory structures
            if [[ -f "$tap_path/$package.rb" ]]; then
                package_file="$tap_path/$package.rb"
            elif [[ -f "$tap_path/Formula/$package.rb" ]]; then
                package_file="$tap_path/Formula/$package.rb"
            fi
        fi
    fi

    if [[ -f "$package_file" ]]; then
        echo "$package_file"
        return 0
    fi

    return 1
}

# =============================================================================
# SHARED DISPLAY AND PROCESSING FUNCTIONS
# =============================================================================

# Function to format timestamp to relative date
format_timestamp_to_relative() {
    local timestamp="$1"
    local current_time=$(date +%s)
    local diff=$((current_time - timestamp))

    if [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60)) minutes ago"
    elif [[ $diff -lt 86400 ]]; then
        echo "$((diff / 3600)) hours ago"
    elif [[ $diff -lt 604800 ]]; then
        echo "$((diff / 86400)) days ago"
    else
        # Format the date nicely for older releases
        date -r "$timestamp" "+%Y-%m-%d" 2>/dev/null || echo "unknown date"
    fi
}

# Function to parse ISO date string to timestamp
parse_date_to_timestamp() {
    local date_string="$1"
    local timestamp=""

    # Method 1: macOS date with timezone handling
    if [[ -z "$timestamp" ]]; then
        # Remove Z suffix for UTC timezone
        local clean_date="${date_string%Z}"
        clean_date="${clean_date%+00:00}"
        clean_date="${clean_date%.*}"  # Remove fractional seconds

        timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_date" +%s 2>/dev/null)
    fi

    # Method 2: GNU date (Linux)
    if [[ -z "$timestamp" ]]; then
        timestamp=$(date -d "$date_string" +%s 2>/dev/null)
    fi

    # Method 3: Try macOS with just the date part
    if [[ -z "$timestamp" ]]; then
        local date_part="${date_string%%T*}"
        timestamp=$(date -j -f "%Y-%m-%d" "$date_part" +%s 2>/dev/null)
    fi

    echo "$timestamp"
}

# Function to get installation date for a package
get_package_install_date() {
    local package="$1"
    local install_date=""

    # Try direct brew info fetch first
    local brew_info=""
    if brew_info=$(brew info --json=v2 "$package" 2>/dev/null); then
        # Try formula structure
        install_date=$(echo "$brew_info" | jq -r '.formulae[0].installed[0].time // empty' 2>/dev/null)
        # Try cask structure
        if [[ -z "$install_date" || "$install_date" == "null" ]]; then
            install_date=$(echo "$brew_info" | jq -r '.casks[0].installed_time // empty' 2>/dev/null)
        fi
    fi

    echo "$install_date"
}

# Function to create package header with date information
create_package_header() {
    local package="$1"
    local current_version="$2"
    local latest_version="$3"
    local release_date="$4"
    local package_info="$5"
    local has_breaking="${6:-false}"  # Optional breaking changes flag

    # Skip if versions are the same
    if [[ "$current_version" == "$latest_version" ]]; then
        return 0
    fi

    local time_context="$release_date"

    # If no release date, try installation date as fallback
    if [[ "$release_date" == "Unknown date" ]]; then
        local install_date=""

        # Try from package_info first if provided
        if [[ -n "$package_info" ]]; then
            # Try formula structure first
            install_date=$(echo "$package_info" | jq -r '.formulae[0].installed[0].time // empty' 2>/dev/null)
            # If not found, try cask structure (wrapped in casks array)
            if [[ -z "$install_date" || "$install_date" == "null" ]]; then
                install_date=$(echo "$package_info" | jq -r '.casks[0].installed_time // empty' 2>/dev/null)
            fi
            # If still not found, try direct cask structure (unwrapped)
            if [[ -z "$install_date" || "$install_date" == "null" ]]; then
                install_date=$(echo "$package_info" | jq -r '.installed_time // empty' 2>/dev/null)
            fi
        fi

        # If still not found, fetch directly
        if [[ -z "$install_date" || "$install_date" == "null" ]]; then
            install_date=$(get_package_install_date "$package")
        fi

        if [[ -n "$install_date" && "$install_date" != "null" && "$install_date" != "" ]]; then
            time_context="$(format_timestamp_to_relative "$install_date")"
        else
            time_context="no release date"
        fi
    fi

    # Replace "unknown" with "[not installed]" for better UX
    if [[ "$current_version" == "unknown" ]]; then
        current_version="[not installed]"
    fi

    # Build package header with optional breaking changes indicator
    local breaking_indicator=""
    if [[ "$IDENTIFY_BREAKING" == "true" && "$has_breaking" == "true" ]]; then
        breaking_indicator=" ⚠️"
    fi
    echo "📦 $package: $current_version → $latest_version ($time_context)$breaking_indicator"
}

# Function to display non-GitHub package fallback (shared between display and utils)
show_non_github_fallback() {
    local package="$1"
    local source_url="$2"

    # Extract domain from source URL for searching
    local domain=""
    if [[ -n "$source_url" && "$source_url" != "null" && "$source_url" != "" ]]; then
        domain=$(echo "$source_url" | sed -E 's|^https?://([^/]+).*$|\1|' | sed 's|^www\.||')
    fi

    # Show searching message if we have a domain
    if [[ -n "$domain" ]]; then
        echo "🔍 Searching for release notes from $domain..."
        echo "🚫 No release notes available."
        echo ""
    else
        echo "🚫 No release notes available."
        echo ""
    fi

    # Try to get homepage from brew info
    local brew_info=""
    local homepage=""
    if brew_info=$(brew info --json=v2 "$package" 2>/dev/null); then
        homepage=$(echo "$brew_info" | jq -r '.formulae[0].homepage // .casks[0].homepage // ""' 2>/dev/null || echo "")

        # Convert http to https
        if [[ -n "$homepage" && "$homepage" =~ ^http:// ]]; then
            homepage="https://${homepage#http://}"
        fi

        if [[ -n "$homepage" && "$homepage" != "null" && "$homepage" != "" ]]; then
            echo "🌐 Learn more: $homepage"
            return 0
        fi
    fi

    # Fallback to construct smart project page URL
    local project_url=""
    if project_url=$(construct_project_page_url "$package" "$source_url"); then
        echo "🌐 Learn more: $project_url"
    else
        echo "🌐 Package: More info available via 'brew info $package'"
    fi
}

# Function to process and display release notes
process_release_notes() {
    local package="$1"
    local latest_version="$2"
    local github_repo="$3"
    local source_url="$4"
    local release_json="$5"

    if [[ -n "$release_json" && "$release_json" != "null" ]]; then
        # Extract and display the body content
        local body
        body=$(echo "$release_json" | jq -r '.body // empty' 2>/dev/null)
        local html_url
        html_url=$(echo "$release_json" | jq -r '.html_url // ""' 2>/dev/null || echo "")

        if [[ -n "$body" && "$body" != "null" && "$body" != "" ]]; then
            # Sanitize body and apply formatting
            local sanitized_body
            sanitized_body=$(sanitize_output "$body")

            # Apply markdown optimization
            optimize_github_markdown "$sanitized_body"
        else
            echo "Release note has no details."
            # Add info about non-GitHub source if that's why we couldn't get releases
            if [[ -n "$source_url" && "$source_url" != "null" && "$source_url" != "" && ! "$source_url" =~ github\.com ]]; then
                # Extract domain for cleaner display
                local domain=$(echo "$source_url" | sed -E 's|^https?://([^/]+).*$|\1|' | sed 's|^www\.||')
                echo "Non-GitHub package via: $domain"
            fi
        fi

        # Add release link at the end if available
        if [[ -n "$html_url" && "$html_url" != "null" && "$html_url" != "" ]]; then
            echo ""
            echo "📋 Release: $html_url"
        fi
    else
        echo "No release notes found for $latest_version"
        # Try to fetch non-GitHub release notes if we couldn't get GitHub releases
        if [[ -n "$source_url" && "$source_url" != "null" && "$source_url" != "" && ! "$source_url" =~ github\.com ]]; then
            # Extract domain for cleaner display
            local domain=$(echo "$source_url" | sed -E 's|^https?://([^/]+).*$|\1|' | sed 's|^www\.||')

            # Try to fetch release notes from non-GitHub sources
            echo "🔍 Searching for release notes from $domain..."
            local non_github_result=""
            if non_github_result=$(fetch_non_github_release_notes "$package" "$latest_version" "$source_url" "$homepage"); then
                # Extract the actual web URL from the result (lines containing URLs)
                local web_url=""
                web_url=$(echo "$non_github_result" | grep -o -E 'https?://[^[:space:]]+' | tail -1)

                # Extract release notes (everything except the URL lines)
                local release_notes=""
                release_notes=$(echo "$non_github_result" | grep -v -E '^https?://' | sed '/^$/d')

                if [[ -n "$release_notes" && "$release_notes" != "null" ]]; then
                    # Real release notes found - show them
                    echo "📋 Release Notes:"
                    # Sanitize and format the release notes
                    local sanitized_notes
                    sanitized_notes=$(sanitize_output "$release_notes")
                    # Convert blank line markers to actual blank lines
                    sanitized_notes="${sanitized_notes//__BLANK_LINE_MARKER__/}"
                    echo "$sanitized_notes"
                    echo ""
                    # Only show "Learn more" if we have a URL that's NOT already in the release notes
                    if [[ -n "$web_url" ]]; then
                        # Check if the URL is already mentioned in the release notes
                        if [[ ! "$sanitized_notes" =~ $web_url ]]; then
                            echo "🌐 Learn more: $web_url"
                        fi
                    fi
                else
                    # No real release notes found - show clean link only
                    echo ""
                    if [[ -n "$web_url" ]]; then
                        echo "🌐 Learn more: $web_url"
                    else
                        echo "🌐 Package: $domain"
                    fi
                fi
            else
                # Function returned 1 - no release notes found at all
                show_non_github_fallback "$package" "$source_url"
            fi
        fi
    fi
}

# Function to get relative date from release JSON
get_release_relative_date() {
    local release_json="$1"
    local relative_date="Unknown date"

    if [[ -n "$release_json" && "$release_json" != "null" ]]; then
        local published_at
        published_at=$(echo "$release_json" | jq -r '.published_at // "Unknown date"' 2>/dev/null || echo "Unknown date")

        if [[ "$published_at" != "null" && "$published_at" != "" && "$published_at" != "Unknown date" ]]; then
            local published_timestamp
            published_timestamp=$(parse_date_to_timestamp "$published_at")

            if [[ -n "$published_timestamp" ]]; then
                relative_date=$(format_timestamp_to_relative "$published_timestamp")
            fi
        fi
    fi

    echo "$relative_date"
}
