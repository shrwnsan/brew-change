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
    local cache_key=$(echo "$url" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -d' ' -f1)
    echo "${CACHE_DIR}/${cache_key}.json"
}

# Function to get temporary cache file path (for atomic writes)
get_cache_temp_file() {
    local cache_file="$1"
    local cache_dir=$(dirname "$cache_file")
    local base_name=$(basename "$cache_file")
    echo "${cache_dir}/.${base_name}.tmp.${BASHPID:-$$}"
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

# =============================================================================
# URL POLICY — Single validation function for all runtime HTTP destinations
# =============================================================================
#
# SECURITY MODEL
#
# Every runtime curl / fetch call MUST pass through validate_url() (or
# fetch_url_with_retry / fetch_url_with_retry_text which call it
# internally).  Authenticated requests MUST go through
# fetch_url_policy_aware() which enforces the same policy and never
# leaks credentials outside api.github.com.
#
# ALLOWLIST (exact hostname match only — never subdomain / suffix tricks)
#
#   api.github.com           GitHub API (authenticated or unauthenticated)
#   crabnebula.app           CrabNebula package metadata
#   downloads.sourceforge.net SourceForge downloads metadata
#   factory.ai               Factory package metadata
#   github.com                GitHub site
#   raw.githubusercontent.com GitHub raw content
#   formulae.brew.sh         Homebrew formula/cask JSON API
#   registry.npmjs.org        npm registry
#   sourceforge.net           SourceForge project metadata
#
# REJECTIONS
#
#   • Non-HTTPS schemes (http, ftp, file, data, javascript, …)
#   • Arbitrary public hosts not in the allowlist
#   • Subdomains of allowed hosts (e.g. sub.api.github.com)
#   • Localhost / loopback / link-local / private IPv4 and IPv6
#   • Userinfo in authority component (user:pass@host)
#   • Encoded CR (%0D) or LF (%0A) in any casing, including double-encoding
#
# LIMITATIONS (portable Bash)
#
#   DNS rebinding cannot be fully prevented in a shell script.  After
#   validate_url() accepts a hostname, a malicious DNS server could
#   resolve it to a private IP on the actual TCP connect.  Mitigations
#   available to the operator include: local DNS-over-HTTPS, a hosts
#   file entry, or a proxy that enforces DNS pinning.
# =============================================================================

# Exact-allowlist hosts (sorted, one per line for easy diffing)
readonly _BC_ALLOWED_HOSTS=(
    "api.github.com"
    "crabnebula.app"
    "downloads.sourceforge.net"
    "factory.ai"
    "formulae.brew.sh"
    "github.com"
    "raw.githubusercontent.com"
    "registry.npmjs.org"
    "sourceforge.net"
)

# validate_url — enforce the single URL boundary policy.
#
# Returns 0 if the URL is permitted, 1 otherwise (with a diagnostic
# message on stderr).
validate_url() {
    local url="$1"

    # ---- Empty ----
    if [[ -z "$url" ]]; then
        echo "Error: Empty URL provided" >&2
        return 1
    fi

    # ---- Scheme: HTTPS only ----
    if [[ ! "$url" =~ ^https:// ]]; then
        echo "Error: Only HTTPS URLs are allowed: $url" >&2
        return 1
    fi

    if [[ "$url" == *$'\r'* || "$url" == *$'\n'* || "$url" == *$'\t'* || "$url" == *'\\'* ]]; then
        echo "Error: Control characters and backslashes are not allowed in URLs" >&2
        return 1
    fi

    # ---- Dangerous schemes already handled above, but guard anyway ----
    case "$url" in
        javascript:*|data:*|file:*|ftp:*|gopher:*|dict:*|ldap:*)
            echo "Error: Dangerous scheme: $url" >&2
            return 1
            ;;
    esac

    # ---- Strip userinfo: reject if present ----
    # After stripping "https://", everything up to the first path, query,
    # or fragment delimiter is the authority. If it contains "@" the
    # authority has userinfo.
    local authority="${url#https://}"
    authority="${authority%%/*}"
    authority="${authority%%\?*}"
    authority="${authority%%#*}"
    if [[ "$authority" == *"@"* ]]; then
        echo "Error: Userinfo not allowed in URL: $url" >&2
        return 1
    fi

    # ---- Extract host (strip port if present) ----
    local host=""
    local port=""
    if [[ "$authority" == \[*\]* ]]; then
        host="${authority#\[}"
        host="${host%%\]*}"
        local after_bracket="${authority#*\]}"
        [[ -z "$after_bracket" ]] || port="${after_bracket#:}"
    else
        host="${authority%%:*}"
        [[ "$authority" == *:* ]] && port="${authority#*:}"
    fi
    if [[ -n "$port" && "$port" != "443" ]]; then
        echo "Error: Only the default HTTPS port is allowed: $port" >&2
        return 1
    fi

    # ---- Reject encoded CR / LF (any casing, double-encoding) ----
    local lowered="${url,,}"
    # Check for raw percent-encoded CR/LF patterns at any depth
    if [[ "$lowered" == *"%0d"* || "$lowered" == *"%0a"* ]]; then
        echo "Error: Encoded CR/LF not allowed: $url" >&2
        return 1
    fi
    # Also check for double-encoded forms (%25 = literal %)
    if [[ "$lowered" == *"%250d"* || "$lowered" == *"%250a"* ]]; then
        echo "Error: Double-encoded CR/LF not allowed: $url" >&2
        return 1
    fi

    # ---- Reject private / loopback / link-local IPv4 ----
    case "$host" in
        127.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*|169.254.*)
            echo "Error: Private/reserved IPv4 not allowed: $host" >&2
            return 1
            ;;
    esac

    # ---- Reject localhost ----
    if [[ "$host" == "localhost" ]]; then
        echo "Error: localhost not allowed" >&2
        return 1
    fi

    # ---- Reject IPv6 loopback / link-local / ULA ----
    case "$host" in
        ::1|::|0:0:0:0:0:0:0:1|0:0:0:0:0:0:0:0)
            echo "Error: IPv6 loopback not allowed: $host" >&2
            return 1
            ;;
        fe80:*|fc00:*|fd00:*)
            echo "Error: IPv6 link-local/ULA not allowed: $host" >&2
            return 1
            ;;
    esac

    # ---- Exact host allowlist (no subdomain/suffix tricks) ----
    local allowed=false
    local ah
    for ah in "${_BC_ALLOWED_HOSTS[@]}"; do
        if [[ "$host" == "$ah" ]]; then
            allowed=true
            break
        fi
    done
    if [[ "$allowed" != "true" ]]; then
        echo "Error: Domain not allowed: $host" >&2
        return 1
    fi

    return 0
}

# Internal helper: perform a single policy-checked HTTP request without
# auto-following redirects. Returns a body with status 0, a resolved redirect
# URL with status 2, or status 1 on request failure.
#
# Args:
#   $1  URL (must already pass validate_url)
#   $2  GitHub token (optional; sent only to api.github.com)
_bc_fetch_one() {
    local url="$1"
    local token="${2:-}"

    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/bcfetch.XXXXXX") || return 1

    local headers_file="$tmpdir/headers"
    local body_file="$tmpdir/body"
    local status=0
    local curl_args=(
        -s -o "$body_file" -D "$headers_file"
        --max-time 10
        --connect-timeout 5
        --fail
        --proto =https
        --user-agent "brew-change/1.0"
        --no-progress-meter
    )

    if [[ -n "$token" && "$url" == https://api.github.com/* ]]; then
        curl_args+=(-H "Authorization: token ${token}")
    fi
    curl_args+=("$url")

    # Request without --location: capture headers, don't auto-follow
    curl "${curl_args[@]}" 2>/dev/null || status=$?

    local http_code=""
    http_code=$(grep -i '^HTTP/' "$headers_file" 2>/dev/null | tail -1 | grep -o '[0-9]\{3\}' || true)

    # 3xx redirect: parse Location header
    if [[ "$http_code" =~ ^3 ]]; then
        local location=""
        location=$(grep -i '^location:' "$headers_file" 2>/dev/null | head -1 | sed 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r\n' || true)
        if [[ -n "$location" ]]; then
            # Resolve relative URLs against the request URL (same origin only)
            if [[ "$location" != https://* && "$location" != http://* ]]; then
                if [[ "$location" == //* ]]; then
                    location="https:${location}"
                elif [[ "$location" == /* ]]; then
                    # Absolute path: prepend scheme + host
                    local host_part="${url#https://}"
                    host_part="${host_part%%[/?#]*}"
                    location="https://${host_part}${location}"
                elif [[ "$location" == \?* ]]; then
                    # Query-only reference: retain the current path.
                    local current_without_query="${url%%\?*}"
                    current_without_query="${current_without_query%%#*}"
                    location="${current_without_query}${location}"
                else
                    # Relative path: prepend directory of current URL
                    local base_url="${url%%[?#]*}"
                    local origin_authority="${base_url#https://}"
                    origin_authority="${origin_authority%%/*}"
                    local origin="https://${origin_authority}"
                    local base_path="${base_url#${origin}}"
                    if [[ -z "$base_path" || "$base_path" != */* ]]; then
                        location="${origin}/${location}"
                    else
                        location="${origin}${base_path%/*}/${location}"
                    fi
                fi
            fi
            printf '%s\n' "$location"
        fi
        rm -rf "$tmpdir"
        return 2
    fi

    if [[ $status -ne 0 ]]; then
        rm -rf "$tmpdir"
        return 1
    fi

    cat "$body_file"
    rm -rf "$tmpdir"
    return 0
}

_bc_fetch_with_redirects() {
    local current_url="$1"
    local token="${2:-}"
    local redirects=0
    local response=""
    local fetch_status=0

    while true; do
        if response=$(_bc_fetch_one "$current_url" "$token"); then
            printf '%s' "$response"
            return 0
        else
            fetch_status=$?
        fi

        [[ $fetch_status -eq 2 && -n "$response" ]] || return 1
        if ! validate_url "$response"; then
            echo "Warning: Redirect target not allowed: $response" >&2
            return 1
        fi
        if [[ $redirects -ge 2 ]]; then
            echo "Warning: Too many redirects for URL: $1" >&2
            return 1
        fi

        current_url="$response"
        redirects=$((redirects + 1))
    done
}

# =============================================================================
# HTTP RESPONSE CACHE (T3.2.2, docs/research-008-evidence-cache-resume.md)
# =============================================================================
# One raw-response cache boundary shared by fetch_url_with_retry,
# fetch_url_with_retry_text, and fetch_url_policy_aware. Only successful
# responses accepted by the caller's validator are stored; classification
# always re-runs over the cached body so pattern changes take effect
# immediately. Entries live in a dedicated $CACHE_DIR/http/ namespace with
# owner-only permissions and atomic writes.

_http_cache_dir() { printf '%s/http' "$CACHE_DIR"; }

# Test-overridable clock (BREW_CHANGE_PROMPT_TIMEOUT testability precedent).
_http_cache_now() { printf '%s\n' "${BREW_CHANGE_TEST_NOW:-$(date +%s)}"; }

_http_cache_sha256() { # stdin -> hex digest
    { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -d' ' -f1
}

# Auth partition label: "anon" or a truncated SHA-256 token fingerprint.
# The complete key material (URL + partition) is hashed again before it
# becomes a filename; raw tokens and standalone fingerprints are never
# written to disk, logs, or UI (research-008 Decision 1).
_http_cache_partition() { # token
    local token="${1:-}"
    if [[ -z "$token" ]]; then
        printf 'anon\n'
    else
        printf '%s\n' "$token" | _http_cache_sha256 | cut -c1-16
    fi
}

_http_cache_path() { # url token
    local key
    key=$(printf '%s\n%s\n' "$1" "$(_http_cache_partition "$2")" | _http_cache_sha256)
    printf '%s/%s.cache\n' "$(_http_cache_dir)" "$key"
}

# Endpoint-class TTL (research-008): low-volatility exact GitHub tag, ref,
# and commit-SHA objects may use 24h — they are not immutable (release bodies
# can be edited, refs can move) but change rarely. Mutable collections
# (/releases), npm responses, scraped pages, and branch-based content use
# at most 1h.
_http_cache_ttl() { # url
    local url="$1"
    if [[ "$url" == https://api.github.com/* ]]; then
        if [[ "$url" == */releases/tags/* || "$url" == */git/refs/tags/* ]]; then
            printf '%s\n' "$HTTP_CACHE_TTL_EXACT_GITHUB_SECONDS"
            return
        fi
        if [[ "$url" =~ (/git/)?/commits/[0-9a-f]{40}$ ]]; then
            printf '%s\n' "$HTTP_CACHE_TTL_EXACT_GITHUB_SECONDS"
            return
        fi
    fi
    printf '%s\n' "$HTTP_CACHE_TTL_DEFAULT_SECONDS"
}

# Quiet body validator used at every cache read and write: syntactically
# valid JSON for json requests (GitHub error envelopes rejected), or a
# non-empty body for text requests.
_http_cache_validate_body() { # body kind
    local body="$1" kind="$2"
    if [[ "$kind" == "json" ]]; then
        printf '%s' "$body" | jq . >/dev/null 2>&1 || return 1
        if printf '%s' "$body" | jq -e '.message' >/dev/null 2>&1; then return 1; fi
        if printf '%s' "$body" | jq -e '.documentation_url' >/dev/null 2>&1; then return 1; fi
        return 0
    fi
    [[ -n "$body" ]]
}

# Entry file format: one jq -c metadata header line
# {"retrieved_at":<epoch>,"ttl":<seconds>,"kind":"json|text"}, body on the
# remaining lines. Returns 0 and prints the body when a validated unexpired
# entry exists; 2 when the entry is expired but was valid at read time
# (kept on disk as the stale-fallback candidate); 1 on miss or corruption
# (corrupt entries are deleted and fail closed — never used as fallback).
_http_cache_lookup() { # url token kind
    local url="$1" token="$2" kind="$3"
    local path body header retrieved ttl now
    path=$(_http_cache_path "$url" "$token")
    [[ -f "$path" ]] || return 1
    header=$(head -n 1 "$path" 2>/dev/null) || return 1
    if ! printf '%s' "$header" | jq -e 'type=="object" and (.retrieved_at|type=="number") and (.ttl|type=="number")' >/dev/null 2>&1; then
        rm -f "$path" 2>/dev/null || true
        return 1
    fi
    body=$(tail -n +2 "$path" 2>/dev/null)
    if ! _http_cache_validate_body "$body" "$kind"; then
        rm -f "$path" 2>/dev/null || true
        return 1
    fi
    retrieved=$(printf '%s' "$header" | jq -r '.retrieved_at')
    ttl=$(printf '%s' "$header" | jq -r '.ttl')
    now=$(_http_cache_now)
    if (( now - retrieved < ttl )); then
        printf '%s\n' "$body"
        return 0
    fi
    return 2
}

_http_cache_store() { # body url token kind
    local body="$1" url="$2" token="$3" kind="$4"
    local dir path tmp
    dir=$(_http_cache_dir)
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true
    path=$(_http_cache_path "$url" "$token")
    # Leading-dot temp name so the existing crashed-writer cleanup pattern
    # (.*.tmp.*) also covers this namespace.
    tmp="$(dirname "$path")/.$(basename "$path").tmp.${BASHPID:-$$}"
    if ! ( umask 077
           jq -cn --argjson retrieved "$(_http_cache_now)" \
                   --argjson ttl "$(_http_cache_ttl "$url")" \
                   --arg kind "$kind" \
                   '{retrieved_at:$retrieved, ttl:$ttl, kind:$kind}' > "$tmp"
           printf '%s\n' "$body" >> "$tmp" ); then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$path" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$path" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Negative probe cache. A performance memo, not evidence: records "the
# probe chain for this key concluded NOTHING at <time>" so an immediate
# re-run skips the (up to ~14-URL, retried) chain. Short TTL — a release
# published mid-window is picked up after expiry. Lives in the same HTTP
# namespace (same hashing, same prune budgets, --fresh clears it); entries
# are metadata-only (kind "negative", no body). Never carries tokens.
# Keys are arbitrary strings ("probe <package> <version>"); URLs succeed
# through the normal cache, and a successful probe CLEARS the negative
# entry so regained notes are seen immediately.
# ---------------------------------------------------------------------------

_http_cache_negative_path() { # key
    _http_cache_path "negative://$1" ""
}

# Returns 0 when a fresh negative entry exists for the key.
http_cache_negative_get() { # key
    local path header retrieved ttl now
    path=$(_http_cache_negative_path "$1")
    [[ -f "$path" ]] || return 1
    header=$(head -n 1 "$path" 2>/dev/null) || return 1
    # Corrupt entries fail closed (deleted, treated as miss).
    if ! printf '%s' "$header" | jq -e 'type=="object" and .kind=="negative" and (.retrieved_at|type=="number") and (.ttl|type=="number")' >/dev/null 2>&1; then
        rm -f "$path" 2>/dev/null || true
        return 1
    fi
    retrieved=$(printf '%s' "$header" | jq -r '.retrieved_at')
    ttl=$(printf '%s' "$header" | jq -r '.ttl')
    now=$(_http_cache_now)
    (( now - retrieved < ttl )) && return 0
    return 1
}

http_cache_negative_put() { # key
    local key="$1" dir path tmp
    dir=$(_http_cache_dir)
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true
    path=$(_http_cache_negative_path "$key")
    tmp="$(dirname "$path")/.$(basename "$path").tmp.${BASHPID:-$$}"
    if ! ( umask 077
           jq -cn --argjson retrieved "$(_http_cache_now)" \
                   --argjson ttl "$HTTP_CACHE_NEGATIVE_TTL_SECONDS" \
                   '{retrieved_at:$retrieved, ttl:$ttl, kind:"negative"}' > "$tmp" ); then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
    chmod 600 "$path" 2>/dev/null || true
}

http_cache_negative_clear() { # key
    rm -f "$(_http_cache_negative_path "$1")" 2>/dev/null || true
    return 0
}

# Request-scoped provenance written atomically to a caller-supplied path:
# {"provenance":"network-fresh|cached-fresh|cached-stale",
#  "retrieved_at":<epoch>,"age_seconds":<n>}. File side effects survive
# command-substitution subshells and parallel workers, which shell globals
# cannot (research-008 Decision 3).
_http_cache_write_meta() { # meta_path provenance retrieved_at
    local meta_path="$1" provenance="$2" retrieved_at="$3"
    [[ -n "$meta_path" ]] || return 0
    [[ "$retrieved_at" =~ ^[0-9]+$ ]] || return 0
    local age=$(( $(_http_cache_now) - retrieved_at ))
    (( age < 0 )) && age=0
    local tmp="${meta_path}.tmp.${BASHPID:-$$}"
    if ! jq -cn --arg p "$provenance" --argjson r "$retrieved_at" --argjson a "$age" \
            '{provenance:$p, retrieved_at:$r, age_seconds:$a}' > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 0
    fi
    mv "$tmp" "$meta_path" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# Run-scoped hit accounting: every cache serve appends one uniquely named
# event file ("<epoch> <class>") to $BREW_CHANGE_HTTP_CACHE_EVENTS. Unique
# filenames avoid concurrent counter updates across subshells and parallel
# workers.
_http_cache_emit_event() { # class retrieved_at
    local dir="${BREW_CHANGE_HTTP_CACHE_EVENTS:-}"
    [[ -n "$dir" ]] || return 0
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
    local f="$dir/e$$.$RANDOM.$(date +%s%N 2>/dev/null || date +%s)"
    printf '%s %s\n' "$2" "$1" > "$f" 2>/dev/null || true
    chmod 600 "$f" 2>/dev/null || true
}

# Aggregate event files for the TTY banner: "count=N oldest_age=S".
http_cache_hit_summary() {
    local dir="${BREW_CHANGE_HTTP_CACHE_EVENTS:-}"
    local now count=0 oldest="" f epoch cls
    now=$(_http_cache_now)
    if [[ -n "$dir" && -d "$dir" ]]; then
        for f in "$dir"/*; do
            [[ -f "$f" ]] || continue
            IFS=' ' read -r epoch cls < "$f" || continue
            [[ "$epoch" =~ ^[0-9]+$ ]] || continue
            count=$((count + 1))
            if [[ -z "$oldest" ]] || (( epoch < oldest )); then oldest="$epoch"; fi
        done
    fi
    if (( count == 0 )); then
        printf 'count=0\n'
    else
        printf 'count=%d oldest_age=%d\n' "$count" "$(( now - oldest ))"
    fi
}

# Enforce budgets on the HTTP namespace only: at most 512 entries and
# 100 MiB total, evicting oldest-retrieved entries first (research-008
# Decision 4). Entries carry their own retrieval epoch, so no stat-mtime
# portability surface is involved; sizes come from wc -c; dot-prefixed
# temporary write artifacts are never counted as entries. Unrelated caches
# are untouched.
http_cache_prune() {
    local dir; dir=$(_http_cache_dir)
    [[ -d "$dir" ]] || return 0
    local max_entries=${BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES:-512}
    local max_bytes=${BREW_CHANGE_HTTP_CACHE_MAX_BYTES:-104857600}
    local -a entries=() lines=()
    local f epoch size total=0 count
    while IFS= read -r f; do
        entries+=("$f")
        total=$(( total + $(wc -c < "$f") ))
    done < <(find "$dir" -maxdepth 1 -type f -name '*.cache' 2>/dev/null)
    count=${#entries[@]}
    (( count <= max_entries && total <= max_bytes )) && return 0
    for f in "${entries[@]}"; do
        epoch=$(head -n 1 "$f" 2>/dev/null | jq -r '.retrieved_at // 0' 2>/dev/null) || epoch=0
        [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
        lines+=("$(printf '%020d %s' "$epoch" "$f")")
    done
    while IFS= read -r line; do
        (( count <= max_entries && total <= max_bytes )) && break
        f=${line#* }
        size=$(wc -c < "$f" 2>/dev/null) || size=0
        rm -f "$f" 2>/dev/null || true
        total=$(( total - size ))
        count=$((count - 1))
    done < <(printf '%s\n' "${lines[@]}" | sort -n)
    return 0
}

# --fresh: remove and recreate ONLY the HTTP namespace. github-patterns.json,
# brew-info caches, the legacy flat JSON cache, and all unrelated state are
# preserved. Because old HTTP entries are gone for this run, --fresh cannot
# fall back to them (research-008 Decision 4).
http_cache_reset_fresh() {
    local dir; dir=$(_http_cache_dir)
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true
}

# Shared cached fetch backing all three public fetch functions.
# Args: url token kind meta_path
# Stdout: the response body. Provenance goes to meta_path; cache serves also
# emit run-scoped event files. Lifecycle: validated unexpired entry ->
# cached-fresh; expired -> network refresh (validated, atomically replaced)
# -> network-fresh; failed refresh -> previously validated entry ->
# cached-stale; corrupt entry deleted and failed closed (research-008 D4).
_fetch_url_cached() {
    local url="$1" token="$2" kind="$3" meta_path="$4"

    # Enforce URL policy before any cache or network activity.
    if ! validate_url "$url"; then
        return 1
    fi

    local path body rc retrieved
    path=$(_http_cache_path "$url" "$token")
    if body=$(_http_cache_lookup "$url" "$token" "$kind"); then
        rc=0
    else
        rc=$?
    fi
    if (( rc == 0 )); then
        retrieved=$(head -n 1 "$path" | jq -r '.retrieved_at' 2>/dev/null)
        printf '%s\n' "$body"
        _http_cache_write_meta "$meta_path" cached-fresh "$retrieved"
        _http_cache_emit_event cached-fresh "$retrieved"
        return 0
    fi
    # rc == 2: entry expired but valid — retained on disk as the stale
    # fallback candidate while the refresh runs.

    local attempt=1 response=""
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if response=$(_bc_fetch_with_redirects "$url" "$token"); then
            if [[ -n "$response" ]] && _http_cache_validate_body "$response" "$kind"; then
                if ! _http_cache_store "$response" "$url" "$token" "$kind"; then
                    echo "Warning: Failed to cache response for $url" >&2
                fi
                printf '%s\n' "$response"
                _http_cache_write_meta "$meta_path" network-fresh "$(_http_cache_now)"
                return 0
            fi
        fi

        # Handle retry logic
        if handle_network_error $attempt $MAX_RETRIES "$url"; then
            break
        fi
        ((attempt++))
    done

    # Refresh failed: only a previously validated entry may be served as
    # cached-stale. A stale no-signal result remains unknown (classification
    # vocabulary already encodes this; see assessment.sh).
    if (( rc == 2 )) && body=$(tail -n +2 "$path" 2>/dev/null) \
        && _http_cache_validate_body "$body" "$kind"; then
        retrieved=$(head -n 1 "$path" | jq -r '.retrieved_at' 2>/dev/null)
        echo "Warning: Using stale cache for $url" >&2
        printf '%s\n' "$body"
        _http_cache_write_meta "$meta_path" cached-stale "$retrieved"
        _http_cache_emit_event cached-stale "$retrieved"
        return 0
    fi
    return 1
}

# Function to fetch text content (non-JSON) with retries, caching, and
# policy enforcement. Optional second arg: request-scoped provenance
# metadata path (T3.2.1/T3.2.2).
fetch_url_with_retry_text() {
    local url="$1" meta_path="${2:-}"
    _fetch_url_cached "$url" "" text "$meta_path"
}

# Shared policy-aware authenticated fetch for GitHub API requests.
# Sends Authorization header ONLY when the host is api.github.com.
# All requests go through validate_url, the shared HTTP response cache
# (partitioned by token fingerprint), and manual redirect following.
#
# Args:
#   $1  URL
#   $2  Auth token (optional; if empty, request is unauthenticated)
#   $3  Optional request-scoped provenance metadata path (T3.2.1/T3.2.2)
#
# Stdout: response body on success
# Returns: 0 on success, 1 on failure
fetch_url_policy_aware() {
    local url="$1"
    local token="${2:-}"
    local meta_path="${3:-}"
    _fetch_url_cached "$url" "$token" json "$meta_path"
}

# Function to fetch URL with robust retries, caching, and policy enforcement.
# Uses validate_url(), manual redirect following (max 2 hops), and the shared
# HTTP response cache (T3.2.2). Optional second arg: request-scoped
# provenance metadata path.
fetch_url_with_retry() {
    local url="$1"
    local meta_path="${2:-}"
    _fetch_url_cached "$url" "" json "$meta_path"
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

# Function to resolve installed @version variant of a cask
# When a user passes a base name like "claude-code" but has "claude-code@latest"
# installed, this detects and returns the installed variant.
# Returns the installed variant name (stdout) or empty string if not applicable.
resolve_installed_variant() {
    local package="$1"

    # Only applies to package names without @version suffix
    if [[ "$package" == *"@"* ]]; then
        return 1
    fi

    # Check if the exact name is already installed — no redirect needed
    if brew list 2>/dev/null | grep -q "^${package}$"; then
        return 1
    fi

    # Look for installed @version variants
    local variant=""
    variant=$(brew list 2>/dev/null | grep "^${package}@" | head -1)

    if [[ -n "$variant" ]]; then
        echo "$variant"
        return 0
    fi

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
        validate_url "$url" >/dev/null 2>&1 || continue
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

    # Normalize display version: "unknown" or empty -> "[not installed]"
    current_version="${current_version:-[not installed]}"
    [[ "$current_version" == "unknown" ]] && current_version="[not installed]"

    # Build package header with the text-first breaking marker (T3.3.1):
    # the "[breaking]" label always carries the meaning; the ⚠️ glyph is a
    # strictly additive overlay, drawn only when stdout is a TTY without
    # NO_COLOR and without the explicit BREW_CHANGE_NO_EMOJI=1 opt-out.
    local breaking_indicator=""
    if [[ "$IDENTIFY_BREAKING" == "true" && "$has_breaking" == "true" ]]; then
        breaking_indicator=" [breaking]"
        if [[ -t 1 && -z "${NO_COLOR:-}" && "${BREW_CHANGE_NO_EMOJI:-0}" != "1" ]]; then
            breaking_indicator=" [breaking] ⚠️"
        fi
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
    # Callers historically supplied $homepage via dynamic scoping only;
    # declare it so this function is safe standalone under `set -u`. No cheap
    # homepage source exists in this scope (fetching brew info would add a
    # network call), so the no-notes fallback below derives the review URL
    # from the source domain when homepage is empty.
    local homepage=""

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
                # Function returned 1 - no release notes found at all.
                # Record the terminal no-notes outcome before delegating to
                # the shared fallback, mirroring the fixed display.sh branch
                # (commit dfe2997): without this row, a record whose only
                # producer hit this path would be synthesized as
                # missing/unknown by classify_upgrade_evidence instead of
                # the more accurate unavailable.
                local no_notes_url="$homepage"
                if [[ -z "$no_notes_url" || "$no_notes_url" == "null" ]]; then
                    no_notes_url="https://$domain"
                fi
                append_assessment_evidence "$package" "$domain" "$no_notes_url" "" "unavailable" ""
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
