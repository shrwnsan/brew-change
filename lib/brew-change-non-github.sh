#!/usr/bin/env bash
# Non-GitHub package release notes fetcher for brew-change

# Function to fetch release notes from SourceForge
fetch_sourceforge_release_notes() {
    local package_name="$1"
    local version="$2"
    local source_url="$3"

    # Extract project name from SourceForge URL
    # Examples:
    # https://downloads.sourceforge.net/project/libpng/libpng16/1.6.51/libpng-1.6.51.tar.xz
    # https://downloads.sourceforge.net/libpng/libpng-1.6.51.tar.xz
    local project_name=""
    if [[ "$source_url" =~ sourceforge\.net/project/([^/]+)/ ]]; then
        project_name="${BASH_REMATCH[1]}"
    elif [[ "$source_url" =~ sourceforge\.net/([^/]+)/ ]]; then
        project_name="${BASH_REMATCH[1]}"
    else
        return 1
    fi

    # Try to find the release page on SourceForge
    local release_url="https://sourceforge.net/projects/$project_name/files/$package_name-$version/"

    # Try to fetch the release page and look for release notes/changelog
    local release_page=""
    if release_page=$(fetch_url_with_retry "$release_url" 2>/dev/null); then
        # Extract release notes from the page if available
        local release_notes=""
        release_notes=$(echo "$release_page" | grep -A 20 -B 5 -i "release note\|changelog\|what.*new\|changes" | sed 's/<[^>]*>//g' | head -10 | tr -d '\n' | sed 's/^\s*//' | sed 's/\s*$//')

        if [[ -n "$release_notes" && ${#release_notes} -gt 20 ]]; then
            echo "$release_notes"
            return 0
        fi
    fi

    # Fallback: try main project page for recent news/updates
    local project_url="https://sourceforge.net/projects/$project_name/"
    local project_page=""
    if project_page=$(fetch_url_with_retry "$project_url" 2>/dev/null); then
        # Look for recent updates or news
        local recent_news=""
        recent_news=$(echo "$project_page" | grep -A 5 -B 2 -i "version.*$version\|$version.*release" | sed 's/<[^>]*>//g' | head -5 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

        if [[ -n "$recent_news" && ${#recent_news} -gt 15 ]]; then
            echo "$recent_news"
            return 0
        fi

        # If no specific version info, try to get general project description
        local project_desc=""
        project_desc=$(echo "$project_page" | grep -A 3 -B 1 -i "description\|about.*$project_name\|$project_name.*is" | sed 's/<[^>]*>//g' | head -3 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

        if [[ -n "$project_desc" && ${#project_desc} -gt 30 ]]; then
            echo "Version $version update of $project_name. $project_desc"
            echo "View release details: https://sourceforge.net/projects/$project_name/files/"
            return 0
        fi
    fi

    # No real release notes found - return empty to trigger simple "Learn more" link
    return 1
}

# Function to fetch release notes from CrabNebula packages
fetch_crabnebula_release_notes() {
    local package_name="$1"
    local version="$2"

    # CrabNebula hosts many developer tools, try their main site or docs
    
    # Try the official website first
    local official_url="https://crabnebula.app"
    local release_notes=""

    # For conductor, try to find release information
    if [[ "$package_name" == "conductor" ]]; then
        # Try CrabNebula's releases or changelog page
        local changelog_url="https://crabnebula.app/releases"
        local changelog_page=""
        if changelog_page=$(fetch_url_with_retry "$changelog_url" 2>/dev/null); then
            # Extract version-specific information
            release_notes=$(echo "$changelog_page" | grep -A 10 -B 2 -i "conductor.*$version\|$version" | sed 's/<[^>]*>//g' | head -8 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

            if [[ -n "$release_notes" && ${#release_notes} -gt 20 ]]; then
                echo "$release_notes"
                return 0
            fi
        fi

        # Try GitHub releases for CrabNebula conductor if it exists
        local github_url="https://api.github.com/repos/crabnebula/conductor/releases/tags/v$version"
        local github_response=""
        if github_response=$(fetch_url_with_retry "$github_url" 2>/dev/null); then
            if [[ "$github_response" != "null" && -n "$github_response" ]]; then
                local body=$(echo "$github_response" | jq -r '.body // ""' 2>/dev/null)
                if [[ -n "$body" && "$body" != "null" ]]; then
                    echo "$body"
                    return 0
                fi
            fi
        fi
    fi

    # General CrabNebula package search
    local search_url="https://crabnebula.app/packages/$package_name"
    local package_page=""
    if package_page=$(fetch_url_with_retry "$search_url" 2>/dev/null); then
        # Look for version information or changelog
        release_notes=$(echo "$package_page" | grep -A 8 -B 2 -i "version.*$version\|changelog\|release.*note" | sed 's/<[^>]*>//g' | head -6 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

        if [[ -n "$release_notes" && ${#release_notes} -gt 15 ]]; then
            echo "$release_notes"
            return 0
        fi

        # Try to get package description if no specific version info
        local package_desc=""
        package_desc=$(echo "$package_page" | grep -A 5 -B 2 -i "description\|about.*$package_name\|$package_name.*is" | sed 's/<[^>]*>//g' | head -4 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

        if [[ -n "$package_desc" && ${#package_desc} -gt 20 ]]; then
            echo "Version $version of $package_name. $package_desc"
            echo "Learn more: https://crabnebula.app/packages/$package_name"
            return 0
        fi
    fi

    # No real release notes found - return empty to trigger simple "Learn more" link
    return 1
}

# Function to fetch release notes from Factory AI packages
fetch_factory_ai_release_notes() {
    local package_name="$1"
    local version="$2"

    
    # Try Factory AI's website or API
    # For droid, try their official site or documentation
    if [[ "$package_name" == "droid" ]]; then
        # Try to find droid release information
        local droid_url="https://factory.ai/droid"
        local droid_page=""
        if droid_page=$(fetch_url_with_retry "$droid_url" 2>/dev/null); then
            # Look for version-specific information
            local release_notes=""
            release_notes=$(echo "$droid_page" | grep -A 8 -B 2 -i "version.*$version\|droid.*$version\|changelog\|release" | sed 's/<[^>]*>//g' | head -6 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

            if [[ -n "$release_notes" && ${#release_notes} -gt 20 ]]; then
                echo "$release_notes"
                return 0
            fi
        fi

        # Try GitHub if droid has a public repo
        local github_url="https://api.github.com/repos/factory-ai/droid/releases/tags/v$version"
        local github_response=""
        if github_response=$(fetch_url_with_retry "$github_url" 2>/dev/null); then
            if [[ "$github_response" != "null" && -n "$github_response" ]]; then
                local body=$(echo "$github_response" | jq -r '.body // ""' 2>/dev/null)
                if [[ -n "$body" && "$body" != "null" ]]; then
                    echo "$body"
                    return 0
                fi
            fi
        fi
    fi

    # General Factory AI search
    local search_url="https://factory.ai/packages/$package_name"
    local package_page=""
    if package_page=$(fetch_url_with_retry "$search_url" 2>/dev/null); then
        local release_notes=""
        release_notes=$(echo "$package_page" | grep -A 6 -B 2 -i "version.*$version\|release.*note" | sed 's/<[^>]*>//g' | head -5 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

        if [[ -n "$release_notes" && ${#release_notes} -gt 15 ]]; then
            echo "$release_notes"
            return 0
        fi
    fi

    return 1
}

# Function to fetch release notes from generic package websites
fetch_generic_release_notes() {
    local package_name="$1"
    local version="$2"
    local source_url="$3"
    local domain="$4"

    
    # Try to construct a release notes URL based on common patterns
    local release_patterns=(
        "https://$domain/$package_name/releases/tag/$version"
        "https://$domain/$package_name/releases/v$version"
        "https://$domain/$package_name/CHANGELOG"
        "https://$domain/$package_name/changelog"
        "https://$domain/$package_name/releases"
        "https://$domain/releases/$package_name-$version"
        "https://$domain/blog/$package_name-$version-release"
        "https://$domain/news/release-$package_name-$version"
    )

    for pattern in "${release_patterns[@]}"; do
        local release_url="${pattern//\{package_name\}/$package_name}"
        release_url="${release_url//\{version\}/$version}"

        local release_page=""
        if release_page=$(fetch_url_with_retry "$release_url" 2>/dev/null); then
            # Look for release content
            local release_notes=""
            release_notes=$(echo "$release_page" | grep -A 15 -B 3 -i "version.*$version\|$version.*release\|changelog\|what.*new" | sed 's/<[^>]*>//g' | head -10 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

            if [[ -n "$release_notes" && ${#release_notes} -gt 25 ]]; then
                echo "$release_notes"
                echo "📖 Source: $release_url"
                return 0
            fi
        fi
    done

    # Try to find official website and look for contact/links to release info
    local official_patterns=(
        "https://$domain/"
        "https://$package_name.$domain/"
        "https://$domain/$package_name/"
    )

    for pattern in "${official_patterns[@]}"; do
        local official_url="${pattern//\{package_name\}/$package_name}"

        local official_page=""
        if official_page=$(fetch_url_with_retry "$official_url" 2>/dev/null); then
            # Look for links to release notes, changelog, or documentation
            local release_link=""
            release_link=$(echo "$official_page" | grep -i -o 'href="[^"]*\(changelog\|release\|news\|blog\)[^"]*"' | head -3 | sed 's/href="//' | sed 's/"//' | head -1)

            if [[ -n "$release_link" ]]; then
                # Make relative URLs absolute
                if [[ "$release_link" =~ ^/ ]]; then
                    release_link="https://$domain$release_link"
                elif [[ ! "$release_link" =~ ^https?:// ]]; then
                    release_link="https://$domain/$release_link"
                fi

                local release_page=""
                if release_page=$(fetch_url_with_retry "$release_link" 2>/dev/null); then
                    local release_notes=""
                    release_notes=$(echo "$release_page" | grep -A 10 -B 2 -i "version.*$version\|$version" | sed 's/<[^>]*>//g' | head -8 | tr '\n' ' ' | sed 's/^\s*//' | sed 's/\s*$//')

                    if [[ -n "$release_notes" && ${#release_notes} -gt 20 ]]; then
                        echo "$release_notes"
                        echo "📖 Source: $release_link"
                        return 0
                    fi
                fi
            fi
        fi
    done

    return 1
}

# Function to construct smart project page URLs
construct_project_page_url() {
    local package_name="$1"
    local source_url="$2"
    local domain=""
    domain=$(echo "$source_url" | sed -E 's|^https?://([^/]+).*$|\1|' | sed 's|^www\.||')

    case "$domain" in
        "downloads.sourceforge.net"|"sourceforge.net")
            # Extract project name from SourceForge URL
            local project_name=""
            if [[ "$source_url" =~ sourceforge\.net/project/([^/]+)/ ]]; then
                project_name="${BASH_REMATCH[1]}"
            elif [[ "$source_url" =~ sourceforge\.net/([^/]+)/ ]]; then
                project_name="${BASH_REMATCH[1]}"
            fi
            if [[ -n "$project_name" ]]; then
                echo "https://sourceforge.net/projects/$project_name/"
                return 0
            fi
            ;;
        "cdn.crabnebula.app"|"crabnebula.app")
            echo "https://crabnebula.app/packages/$package_name"
            return 0
            ;;
        "downloads.factory.ai"|"factory.ai")
            echo "https://factory.ai/packages/$package_name"
            return 0
            ;;
    esac

    # Generic fallback - try common patterns
    if [[ -n "$domain" ]]; then
        echo "https://$domain/"
        return 0
    fi

    return 1
}

# Main function to fetch release notes for non-GitHub packages
fetch_non_github_release_notes() {
    local package_name="$1"
    local version="$2"
    local source_url="$3"
    local homepage="$4"  # Add homepage parameter

    if [[ -z "$source_url" || "$source_url" == "null" ]]; then
        # Try documentation repo approach using homepage
        if [[ -n "$homepage" && "$homepage" != "null" ]]; then
            if fetch_documentation_repo_release_notes "$package_name" "$version" "$homepage"; then
                return 0
            fi
        fi
        return 1
    fi

    # Extract domain from source URL
    local domain=""
    domain=$(echo "$source_url" | sed -E 's|^https?://([^/]+).*$|\1|' | sed 's|^www\.||')

    # Try the documentation repository pattern first if enabled
    if [[ "$BREW_CHANGE_DOCS_REPO" == "true" || "$BREW_CHANGE_DOCS_REPO" == "1" ]] && [[ -n "$homepage" && "$homepage" != "null" ]]; then
        if fetch_documentation_repo_release_notes "$package_name" "$version" "$homepage"; then
            return 0
        fi
    fi

    # Route to appropriate fetcher based on domain
    case "$domain" in
        "downloads.sourceforge.net"|"sourceforge.net")
            fetch_sourceforge_release_notes "$package_name" "$version" "$source_url"
            ;;
        "cdn.crabnebula.app"|"crabnebula.app")
            fetch_crabnebula_release_notes "$package_name" "$version"
            ;;
        "downloads.factory.ai"|"factory.ai")
            fetch_factory_ai_release_notes "$package_name" "$version"
            ;;
        *)
            fetch_generic_release_notes "$package_name" "$version" "$source_url" "$domain"
            ;;
    esac
}

# Documentation-Repository Pattern functions for brew-change

# Function to update pattern cache
#
# Stores discovered GitHub repository mappings for packages in a JSON cache file.
# This enables faster lookups on subsequent runs by avoiding re-analysis of homepages.
#
# Parameters:
#   $1 - package_name: The name of the package (e.g., "awscli")
#   $2 - homepage: The package's homepage URL (e.g., "https://aws.amazon.com/cli/")
#   $3 - github_repo: The discovered GitHub repository (e.g., "aws/aws-cli")
#
# Returns:
#   0 on successful cache update, 1 on failure
#
# Side effects:
#   Creates/updates ~/.cache/brew-change/github-patterns.json with secure permissions
update_pattern_cache() {
    local package="$1"
    local homepage="$2"
    local github_repo="$3"

    local cache_dir="${CACHE_DIR:-${HOME}/.cache/brew-change}"
    local cache_file="$cache_dir/github-patterns.json"

    # Ensure cache directory exists with secure permissions
    mkdir -p -m 700 "$cache_dir"

    # Update JSON file (atomic write)
    local temp_file=$(mktemp)

    if [[ -f "$cache_file" ]] && command -v jq >/dev/null 2>&1; then
        # Update existing entry or add new one
        jq --arg pkg "$package" \
           --arg home "$homepage" \
           --arg repo "$github_repo" \
           --arg now "$(date +%Y-%m-%d)" '
           .[$pkg] = {
             "homepage": $home,
             "github": $repo,
             "discovered": $now,
             "success_count": (.[$pkg].success_count // 0) + 1
           }' "$cache_file" > "$temp_file" 2>/dev/null || {
            # Fallback if jq fails - use printf for safe JSON escaping
            printf '{\n  "%s": {\n    "homepage": "%s",\n    "github": "%s",\n    "discovered": "%s",\n    "success_count": 1\n  }\n}' \
                "$(printf '%s' "$package" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
                "$(printf '%s' "$homepage" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
                "$(printf '%s' "$github_repo" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
                "$(date +%Y-%m-%d)" > "$temp_file"
        }
    else
        # Create new cache file - use printf for safe JSON escaping
        printf '{\n  "%s": {\n    "homepage": "%s",\n    "github": "%s",\n    "discovered": "%s",\n    "success_count": 1\n  }\n}' \
            "$(printf '%s' "$package" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
            "$(printf '%s' "$homepage" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
            "$(printf '%s' "$github_repo" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
            "$(date +%Y-%m-%d)" > "$temp_file"
    fi

    mv "$temp_file" "$cache_file"
}

# Function to get cached pattern
get_cached_pattern() {
    local package="$1"
    local cache_file="${CACHE_DIR:-${HOME}/.cache/brew-change}/github-patterns.json"

    # Quick check without jq (faster, no dependency)
    if [[ -f "$cache_file" ]]; then
        # Simple grep approach (works without jq)
        grep -o "\"$package\":{[^}]*}" "$cache_file" 2>/dev/null | \
        sed 's/.*"github":"\([^"]*\)".*/\1/' | head -1
    fi
}

# Function to analyze homepage for GitHub repository links
#
# Attempts to discover the GitHub repository for a package by analyzing its homepage.
# Uses a combination of known domain mappings and HTML content analysis to find
# GitHub links.
#
# Parameters:
#   $1 - homepage: The package's homepage URL to analyze
#   $2 - package_name: The name of the package (for context, not used in analysis)
#
# Returns:
#   0 and prints the GitHub repository (format: "owner/repo") if found
#   1 if no GitHub repository could be discovered
#
# Side effects:
#   May fetch the homepage content via network requests
analyze_homepage_for_github() {
    local homepage="$1"
    local package_name="$2"  # Parameter kept for API consistency, though not used in analysis

    # Skip if no homepage provided
    [[ -n "$homepage" && "$homepage" != "null" ]] || return 1

    # Fast path: Known domain-to-repo mappings (no network required)
    local domain=""
    domain=$(echo "$homepage" | sed -E 's|^https?://([^/]+).*$|\1|' 2>/dev/null | sed 's|^www\.||' 2>/dev/null)
    if [[ -n "$domain" ]]; then
        case "$domain" in
            "anthropic.com"|"claude.ai")
                echo "anthropics/claude-code"
                return 0
                ;;
            "aws.amazon.com"|"awscli.amazonaws.com")
                echo "aws/aws-cli"
                return 0
                ;;
            "cli.github.com")
                echo "cli/cli"
                return 0
                ;;
            "cloud.google.com"|"cloud.google.com/sdk/gcloud")
                echo "GoogleCloudPlatform/google-cloud-sdk"
                return 0
                ;;
        esac
    fi

    # Pattern 1: Direct GitHub repository in homepage URL
    if [[ "$homepage" =~ github\.com/([^/]+/[^/?#]+) ]]; then
        local github_repo="${BASH_REMATCH[1]}"
        # Clean up common suffixes
        github_repo="${github_repo%.git}"
        echo "$github_repo"
        return 0
    fi

    # Pattern 2: Try to fetch homepage and look for GitHub links
    local homepage_content=""
    if homepage_content=$(fetch_url_with_retry_text "$homepage" 2>/dev/null); then
        # Look for GitHub repository links in various formats:
        # - <a href="https://github.com/user/repo">
        # - "repository": "https://github.com/user/repo"
        # - github.com/user/repo in meta tags
        local github_link=""
        
        # Try to find GitHub links in href attributes
        github_link=$(echo "$homepage_content" | grep -i -o 'href="https://github\.com/[^"]*"' | head -1 | sed 's/href="//' | sed 's/"//')
        
        # If no href found, try to find GitHub URLs in JSON (for API responses)
        if [[ -z "$github_link" ]]; then
            github_link=$(echo "$homepage_content" | grep -i -o '"https://github\.com/[^"]*"' | head -1 | tr -d '"')
        fi
        
        # If no quotes, try plain text GitHub URLs
        if [[ -z "$github_link" ]]; then
            github_link=$(echo "$homepage_content" | grep -i -o 'https://github\.com/[^[:space:]<>"]*' | head -1)
        fi

        if [[ -n "$github_link" ]]; then
            # Extract clean repo path (user/repo)
            if [[ "$github_link" =~ github\.com/([^/]+/[^/?#]+) ]]; then
                local github_repo="${BASH_REMATCH[1]}"
                # Clean up common paths that aren't the repo root
                github_repo="${github_repo%/tree/*}"
                github_repo="${github_repo%/blob/*}"
                github_repo="${github_repo%/releases/*}"
                github_repo="${github_repo%/issues/*}"
                github_repo="${github_repo%.git}"
                echo "$github_repo"
                return 0
            fi
        fi
    fi

    return 1
}

# Function to fetch and parse CHANGELOG from GitHub repository
#
# Fetches and displays changelog information for a specific version from a GitHub
# repository's CHANGELOG.md file. This is part of the documentation-repository
# pattern for CLI tools.
#
# Parameters:
#   $1 - github_repo: GitHub repository in "owner/repo" format
#   $2 - version: Version to look for in the changelog (e.g., "2.1.0")
#
# Returns:
#   0 if changelog entries were found and displayed
#   1 if no changelog could be found or fetched
#
# Environment variables:
#   BREW_CHANGE_DOCS_REPO - Must be set to "1" to enable this feature
#
# Side effects:
#   Prints formatted changelog entries to stdout
fetch_changelog_from_github_repo() {
    local github_repo="$1"
    local version="$2"

    [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Fetching CHANGELOG.md from $github_repo for version $version" >&2

    # Convert web URL to raw content URL
    local raw_url="https://raw.githubusercontent.com/$github_repo/main/CHANGELOG.md"
    
    # Try to fetch the raw CHANGELOG
    local changelog_content=""
    if ! changelog_content=$(fetch_url_with_retry_text "$raw_url" 2>/dev/null); then
        [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: CHANGELOG.md not found on main branch, trying master" >&2
        # Try master branch if main doesn't work
        raw_url="https://raw.githubusercontent.com/$github_repo/master/CHANGELOG.md"
        if ! changelog_content=$(fetch_url_with_retry_text "$raw_url" 2>/dev/null); then
            [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: CHANGELOG.md not found on master branch either" >&2
            return 1
        fi
        [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Found CHANGELOG.md on master branch" >&2
    else
        [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Found CHANGELOG.md on main branch" >&2
    fi
    
    # Parse the changelog for the specific version
    # Look for version header patterns like:
    # ## [2.0.71] or ## 2.0.71 or # [2.0.71]
    local version_section=""
    local in_version=false
    local found_version=false
    
    # Clean up version string (remove 'v' prefix if present)
    local clean_version="${version#v}"
    
    while IFS= read -r line; do
        # Check if this line is a version header
        if [[ "$line" =~ ^##?[[:space:]]*\[?v?"$clean_version"\]? ]] || \
           [[ "$line" =~ ^##?[[:space:]]+v?"$clean_version"[[:space:]]* ]] || \
           [[ "$line" =~ ^##[[:space:]]*\[v?"$clean_version"\] ]]; then
            in_version=true
            found_version=true
            continue
        fi
        
        # Check if we've hit the next version section (stop parsing)
        if [[ "$in_version" == true ]] && [[ "$line" =~ ^##?[[:space:]]*\[?[0-9]+\.[0-9]+ ]]; then
            break
        fi
        
        # Collect lines for this version
        if [[ "$in_version" == true ]]; then
            version_section+="$line"$'\n'
        fi
    done <<< "$changelog_content"
    
    if [[ "$found_version" == true ]] && [[ -n "$version_section" ]]; then
        # Return the parsed version section (remove trailing newlines)
        echo "${version_section%$'\n'}"
        echo ""
        echo "→ Full changelog: https://github.com/$github_repo/blob/main/CHANGELOG.md"
        echo "__BLANK_LINE_MARKER__"
        echo "🌐 Learn more: https://github.com/$github_repo/"
        return 0
    fi
    
    # If we couldn't find the specific version, return a link to the full changelog
    echo "Version $version released."
    echo ""
    echo "→ View changelog: https://github.com/$github_repo/blob/main/CHANGELOG.md"
    echo "__BLANK_LINE_MARKER__"
    echo "🌐 Learn more: https://github.com/$github_repo/"
    return 0
}

# Function to get changelog link from documentation repository
#
# Attempts to find changelog information for packages that follow the
# documentation-repository pattern (docs on GitHub, binaries distributed elsewhere).
#
# Parameters:
#   $1 - package_name: Name of the package to look up
#   $2 - version: Version to search for in changelogs
#   $3 - homepage: Package's homepage URL for analysis
#
# Returns:
#   0 if changelog information was found and displayed
#   1 if no documentation repository could be found or accessed
#
# Environment variables:
#   BREW_CHANGE_DOCS_REPO - Must be set to "true" or "1" to enable this feature
#
# Debug information:
#   When BREW_CHANGE_DEBUG is set, prints detailed progress information
fetch_documentation_repo_release_notes() {
    local package_name="$1"
    local version="$2"
    local homepage="$3"

    # Check if feature is enabled (accept both "true" and "1")
    if [[ "$BREW_CHANGE_DOCS_REPO" != "true" && "$BREW_CHANGE_DOCS_REPO" != "1" ]]; then
        [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Docs-repo pattern disabled (BREW_CHANGE_DOCS_REPO not set)" >&2
        return 1
    fi

    # Check cache first for known pattern
    local cached_repo=""
    if cached_repo=$(get_cached_pattern "$package_name"); then
        if [[ -n "$cached_repo" ]]; then
            [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Using cached repo for $package_name: $cached_repo" >&2
            if fetch_changelog_from_github_repo "$cached_repo" "$version"; then
                [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Successfully fetched changelog from cached repo" >&2
                return 0
            else
                [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Failed to fetch changelog from cached repo, continuing discovery" >&2
            fi
        else
            [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: No cached pattern found for $package_name" >&2
        fi
    else
        [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Could not read cache for $package_name" >&2
    fi

    # Try to analyze homepage for GitHub repository links
    local discovered_repo=""
    if [[ -n "$homepage" && "$homepage" != "null" ]]; then
        [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Analyzing homepage for GitHub repo: $homepage" >&2
        if discovered_repo=$(analyze_homepage_for_github "$homepage" "$package_name"); then
            [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Discovered GitHub repo: $discovered_repo" >&2
            # Try to fetch changelog from discovered repo
            if fetch_changelog_from_github_repo "$discovered_repo" "$version"; then
                # Success! Update cache for next time
                update_pattern_cache "$package_name" "$homepage" "$discovered_repo"
                [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Successfully fetched changelog from discovered repo and cached it" >&2
                return 0
            else
                [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Failed to fetch changelog from discovered repo: $discovered_repo" >&2
            fi
        else
            [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Could not discover GitHub repo from homepage" >&2
        fi
    else
        [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: No homepage provided for $package_name" >&2
    fi

    [[ "${BREW_CHANGE_DEBUG:-}" == "1" ]] && echo "DEBUG: Documentation repository pattern failed for $package_name" >&2
    return 1
}
