#!/usr/bin/env bash
# GitHub API functions for brew-change

# Global variable for GitHub authentication token
GITHUB_AUTH_TOKEN=""

# Function to initialize GitHub CLI authentication
init_github_auth() {
    # Only check once
    if [[ -n "$GITHUB_AUTH_TOKEN" ]]; then
        return 0
    fi

    # Check if GitHub CLI is installed
    if ! command -v gh >/dev/null 2>&1; then
        echo "Warning: GitHub CLI (gh) not found. Install for higher API rate limits:" >&2
        echo "  brew install gh" >&2
        echo "  Then run: gh auth login" >&2
        return 1
    fi

    # Check if authenticated
    if ! gh auth status >/dev/null 2>&1; then
        echo "Warning: Not authenticated with GitHub CLI. Run 'gh auth login' for higher API rate limits." >&2
        echo "  Current rate limit: 60 requests/hour (unauthenticated)" >&2
        echo "  With auth: 5000 requests/hour" >&2
        return 1
    fi

    # Get and store the token
    if GITHUB_AUTH_TOKEN=$(gh auth token 2>/dev/null); then
        # Successfully authenticated, no need to show message for each package
        return 0
    else
        echo "Warning: Failed to get GitHub token. Using unauthenticated requests (60/hour limit)." >&2
        return 1
    fi
}

# Function to extract GitHub owner/repo from various URL formats
extract_github_repo() {
    local source_url="$1"
    local homepage="$2"
    local package_name="$3"

    # Extract base package name (handle tap-prefixed names like charmbracelet/tap/crush -> crush)
    local base_package="$package_name"
    if [[ "$package_name" =~ ^[^/]+/[^/]+/([^/]+)$ ]]; then
        base_package="${BASH_REMATCH[1]}"
    elif [[ "$package_name" =~ ^[^/]+/([^/]+)$ ]]; then
        # Handle simple tap format like homebrew/cask/crush -> crush
        base_package="${BASH_REMATCH[1]}"
    fi

    # Try homepage first (it's more reliable than registry URLs)
    if [[ -n "$homepage" && "$homepage" != "null" ]]; then
        local repo_from_homepage
        repo_from_homepage=$(echo "$homepage" | sed -E 's|.*github\.com/([^/]+)/([^/]+).*|\1/\2|' 2>/dev/null)
        if [[ -n "$repo_from_homepage" && "$repo_from_homepage" != "$homepage" ]]; then
            echo "$repo_from_homepage"
            return 0
        fi
    fi

    # Try source URL (but prioritize homepage over registry URLs)
    if [[ -n "$source_url" && "$source_url" != "null" ]]; then
        # Check if source_url is from a package registry (PyPI, crates.io, etc.)
        if [[ "$source_url" =~ (files\.pythonhosted\.org|pypi\.io|crates\.io|registry\.npmjs\.org) ]]; then
            # Skip registry URLs - they don't contain GitHub repo info
            :
        else
            local repo_from_url
            repo_from_url=$(echo "$source_url" | sed -E 's|.*github\.com/([^/]+)/([^/]+).*|\1/\2|' 2>/dev/null)
            if [[ -n "$repo_from_url" && "$repo_from_url" != "$source_url" ]]; then
                echo "$repo_from_url"
                return 0
            fi
        fi
    fi

    # Special case: try to infer from package name for known patterns
    case "$base_package" in
        "vercel-cli")
            echo "vercel/vercel"
            return 0
            ;;
        "gh")
            echo "cli/cli"
            return 0
            ;;
        "node")
            echo "nodejs/node"
            return 0
            ;;
        "yarn")
            echo "yarnpkg/yarn"
            return 0
            ;;
        "crush")
            echo "charmbracelet/crush"
            return 0
            ;;
        "emdash")
            echo "generalaction/emdash"
            return 0
            ;;
    esac
    
    # Only try generic pattern if we have some indication this might be a GitHub package
    # For example, if package name contains common GitHub patterns or if source/homepage hint at GitHub
    if [[ "$package_name" != *"/"* ]]; then
        # Only suggest generic pattern if we found some GitHub-related indicators
        if [[ -n "$source_url" && "$source_url" == *"github"* ]] || [[ -n "$homepage" && "$homepage" == *"github"* ]]; then
            echo "${package_name}/${package_name}"
            return 0
        fi
    fi
    
    return 1
}

# =============================================================================
# SELF-IMPLEMENTED FUNCTIONS (Phase 1)
# =============================================================================

# Function to identify GitHub owner/repo from various URL formats (enhanced)
# Supports GitHub release download URLs, archive URLs, and repository URLs
extract_github_repo_from_url() {
    local url="$1"

    # GitHub release download URLs: https://github.com/user/repo/releases/download/v1.2.3/file.tar.gz
    local github_repo
    github_repo=$(echo "$url" | sed -E 's|.*github\.com/([^/]+)/([^/]+)/releases/download/.*|\1/\2|' 2>/dev/null)
    if [[ -n "$github_repo" && "$github_repo" != "$url" ]]; then
        echo "$github_repo"
        return 0
    fi

    # GitHub archive URLs: https://github.com/user/repo/archive/v1.2.3.tar.gz or .zip
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/archive/ ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi

    # GitHub repository URLs with .git extension: https://github.com/user/repo.git
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)\.git$ ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi

    # GitHub repository URLs: https://github.com/user/repo
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi

    # GitHub releases/latest URLs: https://github.com/user/repo/releases/latest
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/latest$ ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi

    # GitHub comparison URLs: https://github.com/user/repo/compare/v1.2.3...v1.2.4
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/compare/ ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi

    # GitHub commit URLs: https://github.com/user/repo/commit/abcdef123456
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/commit/ ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi

    return 1
}

# Function to identify GitHub repository from package file using self-contained approach
extract_github_repo_from_package_file() {
    local package="$1"
    local is_cask="$2"

    # Get package file location using tap detection
    local package_file=""
    if ! package_file=$(find_package_file "$package" "$is_cask"); then
        echo "⚠️ Could not find package file for $package" >&2
        return 1
    fi

    # Extract URLs from package file
    local source_url=""
    local homepage=""

    if [[ "$is_cask" == "true" ]]; then
        # For casks, look for url and homepage in different patterns
        source_url=$(grep -E "^\s*url\s+" "$package_file" | head -1 | sed -E 's/.*url "([^"]+)".*/\1/' || echo "")
        homepage=$(grep -E "^\s*homepage\s+" "$package_file" | head -1 | sed -E 's/.*homepage "([^"]+)".*/\1/' || echo "")
    else
        # For formulae, look for standard url patterns
        source_url=$(grep -E "^\s*url\s+" "$package_file" | head -1 | sed -E 's/.*url "([^"]+)".*/\1/' || echo "")
        homepage=$(grep -E "^\s*homepage\s+" "$package_file" | head -1 | sed -E 's/.*homepage "([^"]+)".*/\1/' || echo "")

        # Also try to find stable urls specifically
        if [[ -z "$source_url" ]]; then
            source_url=$(grep -E "^\s*stable.*url\s+" "$package_file" | head -1 | sed -E 's/.*url "([^"]+)".*/\1/' || echo "")
        fi
    fi

    # Try to extract GitHub repo from URLs
    local github_repo=""

    # Try source URL first
    if [[ -n "$source_url" ]]; then
        github_repo=$(extract_github_repo_from_url "$source_url")
    fi

    # Fallback to homepage if source URL didn't work
    if [[ -z "$github_repo" && -n "$homepage" ]]; then
        github_repo=$(extract_github_repo_from_url "$homepage")
    fi

    if [[ -n "$github_repo" ]]; then
        echo "$github_repo"
        return 0
    fi

    echo "⚠️ Could not extract GitHub repo from package file $package_file" >&2
    echo "   Source URL: $source_url" >&2
    echo "   Homepage: $homepage" >&2
    return 1
}

# Function to fetch GitHub release notes with retry
fetch_github_release() {
    local repo="$1"
    local tag="$2"
    local release_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"

    # Try the exact tag first
    local response=""

    # Initialize GitHub authentication
    init_github_auth

    # Try authenticated requests first if token exists
    if [[ -n "$GITHUB_AUTH_TOKEN" ]]; then
        response=$(curl -s -H "Authorization: token ${GITHUB_AUTH_TOKEN}" --max-time 10 "$release_url" 2>/dev/null)
    fi

    # Fallback to unauthenticated if auth failed or not available
    if [[ -z "$response" ]]; then
        response=$(fetch_url_with_retry "$release_url" 2>/dev/null)
    fi

    # If direct tag lookup failed, try with 'v' prefix if not already present
    if [[ -z "$response" || "$response" == "null" || $(echo "$response" | jq -r '.message' 2>/dev/null) == "Not Found" ]]; then
        if [[ ! "$tag" =~ ^v ]]; then
            local vtag="v${tag}"
            local vrelease_url="https://api.github.com/repos/${repo}/releases/tags/${vtag}"

            # Try with v prefix
            if [[ -n "$GITHUB_AUTH_TOKEN" ]]; then
                response=$(curl -s -H "Authorization: token ${GITHUB_AUTH_TOKEN}" --max-time 10 "$vrelease_url" 2>/dev/null)
            fi

            if [[ -z "$response" ]]; then
                response=$(fetch_url_with_retry "$vrelease_url" 2>/dev/null)
            fi

            # If we found a response with v prefix, update the tag for later use
            if [[ -n "$response" && "$response" != "null" && $(echo "$response" | jq -r '.message // empty' 2>/dev/null) != "Not Found" ]]; then
                tag="$vtag"
            fi
        fi
    fi

    # If direct tag lookup failed, try to find the latest release that contains the version
    if [[ -z "$response" || "$response" == "null" || $(echo "$response" | jq -r '.message' 2>/dev/null) == "Not Found" ]]; then
        local latest_releases_url="https://api.github.com/repos/${repo}/releases"
        local latest_response=""

        # Try authenticated for latest releases
        if [[ -n "$GITHUB_AUTH_TOKEN" ]]; then
            latest_response=$(curl -s -H "Authorization: token ${GITHUB_AUTH_TOKEN}" --max-time 10 "$latest_releases_url" 2>/dev/null)
        fi

        # Fallback for latest releases
        if [[ -z "$latest_response" ]]; then
            latest_response=$(fetch_url_with_retry "$latest_releases_url" 2>/dev/null)
        fi

        # Find a release that contains our version number (handle various formats)
        if [[ -n "$latest_response" && "$latest_response" != "null" ]]; then
            local matching_release
            # Try to match version in tag_name (handle prefixes like "v", "vercel@", etc.)
            matching_release=$(echo "$latest_response" | jq --arg version "$tag" '[.[] | select(.tag_name | test($version; "i"))] | .[0] // empty' 2>/dev/null)

            if [[ -n "$matching_release" && "$matching_release" != "null" ]]; then
                echo "$matching_release"
                return 0
            fi
        fi
    fi

    # Return the original response if we found one
    if [[ -n "$response" && "$response" != "null" ]]; then
        # Check if it's an error response (404 or API error)
        local error_msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null)
        if [[ -n "$error_msg" && "$error_msg" != "null" ]]; then
            # This is an error response, return null JSON
            echo "null"
            return 0
        fi
        echo "$response"
        return 0
    fi

    # If no releases found, try to get tag info from Git API
    local tag_url="https://api.github.com/repos/${repo}/git/refs/tags/${tag}"
    local tag_response=""

    # Try authenticated for tag lookup
    if [[ -n "$GITHUB_AUTH_TOKEN" ]]; then
        tag_response=$(curl -s -H "Authorization: token ${GITHUB_AUTH_TOKEN}" --max-time 10 "$tag_url" 2>/dev/null)
    fi

    # Fallback for tag lookup
    if [[ -z "$tag_response" ]]; then
        tag_response=$(fetch_url_with_retry "$tag_url" 2>/dev/null)
    fi

    # If we found tag info, create a minimal release-like response
    if [[ -n "$tag_response" && "$tag_response" != "null" && $(echo "$tag_response" | jq -r '.message // empty' 2>/dev/null) != "Not Found" ]]; then
        # Try to get the commit date from the tag
        local commit_url=$(echo "$tag_response" | jq -r '.object.url // empty' 2>/dev/null)
        if [[ -n "$commit_url" && "$commit_url" != "null" && "$commit_url" != "" ]]; then
            local commit_response=""

            # Try authenticated for commit lookup
            if [[ -n "$GITHUB_AUTH_TOKEN" ]]; then
                commit_response=$(curl -s -H "Authorization: token ${GITHUB_AUTH_TOKEN}" --max-time 10 "$commit_url" 2>/dev/null)
            fi

            # Fallback for commit lookup
            if [[ -z "$commit_response" ]]; then
                commit_response=$(fetch_url_with_retry "$commit_url" 2>/dev/null)
            fi

            if [[ -n "$commit_response" && "$commit_response" != "null" ]]; then
                local commit_date=$(echo "$commit_response" | jq -r '.committer.date // empty' 2>/dev/null)
                if [[ -n "$commit_date" && "$commit_date" != "null" && "$commit_date" != "" ]]; then
                    # Create a minimal release-like response with tag date
                    echo "{\"tag_name\":\"$tag\",\"published_at\":\"$commit_date\",\"message\":\"Tag $tag\",\"html_url\":\"https://github.com/${repo}/releases/tag/${tag}\"}"
                    return 0
                fi
            fi
        fi
    fi

    return 1
}
