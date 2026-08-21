#!/usr/bin/env bash
# npm registry functions for brew-change

# Function to extract npm package name from registry URL
extract_npm_package_name() {
    local url="$1"

    # Remove the registry prefix to get the package path
    local package_path="${url#https://registry.npmjs.org/}"

    # Extract the part before the "/-/" which contains the package name
    local package_name="${package_path%%/-/*}"

    # Validate that we got a package name
    if [[ -n "$package_name" && "$package_name" != "$url" ]]; then
        echo "$package_name"
        return 0
    fi

    return 1
}

# Function to detect if a URL is from npm registry
is_npm_registry_url() {
    local url="$1"

    # Check for npm registry domain
    if [[ "$url" =~ ^https://registry\.npmjs\.org/ ]]; then
        return 0
    fi

    return 1
}

# Function to fetch npm package information from registry.
# Optional second arg: request-scoped provenance metadata path (T3.2.1).
fetch_npm_package_info() {
    local package_name="$1"
    local meta_path="${2:-}"
    local registry_url="https://registry.npmjs.org/${package_name}"

    # Use existing fetch_url_with_retry function which handles caching
    fetch_url_with_retry "$registry_url" "$meta_path"
}

# Function to extract release date for specific version from npm package info
extract_npm_release_date() {
    local package_info="$1"
    local version="$2"

    if [[ -z "$package_info" || "$package_info" == "null" ]]; then
        echo ""
        return 1
    fi

    # Extract the release date from the time field for the specific version
    local release_date
    release_date=$(echo "$package_info" | jq -r ".time[\"$version\"] // empty" 2>/dev/null)

    if [[ -n "$release_date" && "$release_date" != "null" && "$release_date" != "" ]]; then
        echo "$release_date"
        return 0
    fi

    return 1
}

# Function to get npm release date for a package version.
# Optional third arg: request-scoped provenance metadata path (T3.2.1).
get_npm_release_date() {
    local url="$1"
    local version="$2"
    local meta_path="${3:-}"

    # Extract package name from URL
    local package_name
    if ! package_name=$(extract_npm_package_name "$url"); then
        return 1
    fi

    # Fetch package information from npm registry
    local package_info
    if ! package_info=$(fetch_npm_package_info "$package_name" "$meta_path"); then
        return 1
    fi

    # Extract release date for the specific version
    local release_date
    if ! release_date=$(extract_npm_release_date "$package_info" "$version"); then
        return 1
    fi

    echo "$release_date"
    return 0
}

# Resolve the upstream GitHub repository from npm registry metadata
# (research-009 §1c npm→GitHub notes fallback). The registry carries no
# release notes, but its repository field usually points at the GitHub
# repo that publishes them — including monorepo changeset tags like
# vercel@59.1.4 that the registry itself never describes.
# Echoes "owner/repo"; returns 1 when no GitHub repository is named or
# the registry document is unavailable.
# Args:
#   $1: package registry URL (registry.npmjs.org/<name>)
#   $2: optional request-scoped provenance metadata path (T3.2.1)
get_npm_github_repo() {
    local url="$1"
    local meta_path="${2:-}"

    local package_name
    if ! package_name=$(extract_npm_package_name "$url"); then
        return 1
    fi

    local package_info
    if ! package_info=$(fetch_npm_package_info "$package_name" "$meta_path"); then
        return 1
    fi

    # repository is an object {type,url} or a plain string; accept full
    # git URLs and the "github:owner/repo" shorthand.
    local repo_url
    repo_url=$(echo "$package_info" | jq -r '
        if (.repository | type) == "object" then (.repository.url // empty)
        else (.repository // empty) end | tostring' 2>/dev/null)
    [[ -n "$repo_url" && "$repo_url" != "null" ]] || return 1

    local github_url_re='github\.com[/:]([^/]+)/([^/]+)'
    local github_shorthand_re='^github:([^/]+)/([^/]+)'
    local owner_repo=""
    if [[ "$repo_url" =~ $github_url_re || "$repo_url" =~ $github_shorthand_re ]]; then
        owner_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        return 1
    fi
    owner_repo="${owner_repo%.git}"

    # Conservative shape check: exactly owner/repo of sane characters
    # (also rejects any trailing URL junk the capture picked up).
    [[ "$owner_repo" =~ ^[[:alnum:]._-]+/[[:alnum:]._-]+$ ]] || return 1

    printf '%s\n' "$owner_repo"
    return 0
}

# Function to create a minimal npm package info JSON for display
create_npm_package_info() {
    local package_name="$1"
    local version="$2"
    local release_date="$3"

    # Create a JSON structure similar to GitHub release for consistency
    jq -n \
        --arg name "$package_name" \
        --arg version "$version" \
        --arg published_at "$release_date" \
        --arg html_url "https://www.npmjs.com/package/$package_name/v/$version" \
        '{
            name: $name,
            tag_name: $version,
            published_at: $published_at,
            html_url: $html_url,
            body: ("Release " + $version + " published to npm registry")
        }'
}