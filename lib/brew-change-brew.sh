#!/usr/bin/env bash
# Homebrew integration functions for brew-change
#
# Also hosts the assessment record pipeline primitives (T2.1.2) defined by
# docs/research-005-assessment-record-contract.md: inventory record emission,
# two-layer brew info caching, worker evidence appends, stage-boundary
# consolidation, and progress events. This module is sourced before the
# display/parallel/upgrade modules, so the primitives are available to all
# pipeline stages.

# Cross-run brew info cache TTL in seconds (contract: 5 minutes).
BREW_CHANGE_BREW_INFO_TTL="${BREW_CHANGE_BREW_INFO_TTL:-300}"

# Per-process brew info memo (first layer; avoids repeated jq-heavy reads).
declare -gA _BREW_INFO_MEMO=()

# ---------------------------------------------------------------------------
# Record pipeline helpers
# ---------------------------------------------------------------------------

# Filesystem-safe encoding for a package token (jq URI encoding).
record_encode_name() {
    printf '%s' "$1" | jq -sRr '@uri'
}

# Epoch "now" honoring the deterministic test clock when present.
_record_now_epoch() {
    if declare -F brew_change_test_now >/dev/null 2>&1; then
        brew_change_test_now
    else
        date +%s
    fi
}

# File mtime in epoch seconds (macOS/BSD stat, then GNU stat). The first
# command's output is validated numerically rather than chained on exit
# status: GNU stat treats -f as filesystem mode, fails, and still writes
# a filesystem dump to stdout that would pollute the fallback's result.
_record_file_mtime() {
    local m
    m=$(stat -f %m "$1" 2>/dev/null) || true
    [[ "$m" =~ ^[0-9]+$ ]] || m=$(stat -c %Y "$1" 2>/dev/null)
    printf '%s\n' "${m:-0}"
}

# INVENTORY: emit one initial 16-key record per outdated package to
# <run_dir>/assessment.jsonl (evidence fields null, classification "").
# Also invalidates cross-run brew-info cache entries whose current version is
# older than the version brew outdated reports (contract invalidation rule).
# Args:
#   $1: run status dir
#   $2: brew outdated --json=v2 output
assessment_record_init() {
    local run_dir="$1" outdated_json="$2"

    mkdir -p "$run_dir"
    : > "$run_dir/assessment.jsonl"

    jq -c '
      (.formulae[]? |
        {
            package: .name,
            display_name: .name,
            kind: "formula",
            installed_version: (.installed_versions[0] // ""),
            available_version: .current_version,
            evidence_source: null,
            evidence_url: null,
            retrieved_at: null,
            retrieval_status: null,
            evidence_snapshot: null,
            classification: "",
            reasons: [],
            matched_signals: [],
            assessment_recommendation: false,
            operational_eligibility: true,
            default_selected: false
        }),
      (.casks[]? |
        (.token // (if (.name | type) == "array" then .name[0] else .name end)) as $tok |
        select($tok != null and $tok != "") |
        {
            package: $tok,
            display_name: (if (.name | type) == "array" then (.name | join(" / ")) else .name end),
            kind: "cask",
            installed_version: (.installed_versions[0] // ""),
            available_version: .current_version,
            evidence_source: null,
            evidence_url: null,
            retrieved_at: null,
            retrieval_status: null,
            evidence_snapshot: null,
            classification: "",
            reasons: [],
            matched_signals: [],
            assessment_recommendation: false,
            operational_eligibility: true,
            default_selected: false
        })
    ' <<< "$outdated_json" 2>/dev/null >> "$run_dir/assessment.jsonl"

    _invalidate_stale_brew_info_cache "$outdated_json"

    # T2.4.3 progress: emit the inventory stage event. Inventory is one
    # atomic jq batch over the outdated JSON — there are no per-package work
    # moments, and the event contract reserves package labels for the
    # evidence/classify stages — so the stage unit is the batch itself:
    # a single event with total=1 lets the renderer reach its
    # completed==total termination deterministically.
    if [[ "${UPGRADE_STATUS_DIR:-}" == "$run_dir" ]] \
        && declare -F append_progress_event >/dev/null 2>&1; then
        append_progress_event "inventory" 1 1
    fi
}

# Remove cross-run brew info cache entries that are older than the version
# brew outdated reports (brew outdated is the uncached source of truth).
_invalidate_stale_brew_info_cache() {
    local outdated_json="$1"
    local cache_dir="${CACHE_DIR:-$HOME/.cache/brew-change}/brew-info"
    [[ -d "$cache_dir" ]] || return 0

    local pkg outdated_version encoded cached_version sorted oldest
    while IFS=$'\t' read -r pkg outdated_version; do
        [[ -n "$pkg" && -n "$outdated_version" ]] || continue
        encoded=$(record_encode_name "$pkg")
        local cache_file="$cache_dir/$encoded.json"
        [[ -f "$cache_file" ]] || continue
        cached_version=$(jq -r '.formulae[0].versions.stable // .casks[0].version // ""' "$cache_file" 2>/dev/null)
        [[ -n "$cached_version" && "$cached_version" != "null" ]] || continue
        sorted=$(printf '%s\n%s\n' "$cached_version" "$outdated_version" | sort -V 2>/dev/null)
        oldest=$(head -1 <<< "$sorted")
        # Outdated reports something newer than the cached info: refetch.
        # if/then, not [[ ]] && rm: a false test as the function's last
        # statement returns 1, which errexit (the launcher runs set -euo
        # pipefail) turns into a silent whole-run exit.
        if [[ "$cached_version" == "$oldest" && "$cached_version" != "$outdated_version" ]]; then
            rm -f "$cache_file"
        fi
    done < <(jq -r '
        (.formulae[]? | [.name, .current_version] | @tsv),
        (.casks[]? |
          ((.token // (if (.name | type) == "array" then .name[0] else .name end)) as $tok |
           select($tok != null and $tok != "") | [$tok, .current_version] | @tsv))
    ' <<< "$outdated_json" 2>/dev/null)
    return 0
}

# BREW INFO two-layer cache: fetch `brew info --json=v2 <pkg>` at most once
# per run. Layers: in-process memo, per-run memo file
# (<run_dir>/brew-info/<encoded>.json), then cross-run cache
# (<CACHE_DIR>/brew-info/<encoded>.json, TTL 300s by mtime).
# Args:
#   $1: package token
# Prints the brew info JSON on success; returns 1 when brew fails.
get_brew_info() {
    local package="$1"

    if [[ -n "${_BREW_INFO_MEMO[$package]+x}" ]]; then
        printf '%s' "${_BREW_INFO_MEMO[$package]}"
        return 0
    fi

    local encoded
    encoded=$(record_encode_name "$package")

    local run_memo=""
    if [[ -n "${UPGRADE_STATUS_DIR:-}" && -d "$UPGRADE_STATUS_DIR" ]]; then
        run_memo="$UPGRADE_STATUS_DIR/brew-info/$encoded.json"
        if [[ -f "$run_memo" ]]; then
            local memo_data
            memo_data=$(<"$run_memo")
            _BREW_INFO_MEMO["$package"]="$memo_data"
            printf '%s' "$memo_data"
            return 0
        fi
    fi

    local cache_dir="${CACHE_DIR:-$HOME/.cache/brew-change}/brew-info"
    local cache_file="$cache_dir/$encoded.json"
    if [[ -f "$cache_file" ]]; then
        local now mtime
        now=$(_record_now_epoch)
        mtime=$(_record_file_mtime "$cache_file")
        if (( now - mtime <= BREW_CHANGE_BREW_INFO_TTL )); then
            local cached_data
            cached_data=$(<"$cache_file")
            if [[ -n "$run_memo" ]]; then
                # The memo dir must exist on the cache-hit path too: with a
                # fresh run dir and a warm cross-run cache this write runs
                # before any fetch has created <run_dir>/brew-info (the fetch
                # path mkdirs below). The write stays best-effort like the
                # fetch path's so a memo failure never fails the cache hit.
                mkdir -p "$UPGRADE_STATUS_DIR/brew-info" 2>/dev/null || true
                printf '%s' "$cached_data" > "$run_memo" 2>/dev/null || true
            fi
            _BREW_INFO_MEMO["$package"]="$cached_data"
            printf '%s' "$cached_data"
            return 0
        fi
    fi

    local info
    if ! info=$(brew info --json=v2 "$package" 2>/dev/null); then
        return 1
    fi

    mkdir -p "$cache_dir" 2>/dev/null
    chmod 700 "$cache_dir" 2>/dev/null || true
    local tmp_cache="$cache_dir/.$encoded.tmp.${BASHPID:-$$}"
    if printf '%s' "$info" > "$tmp_cache" 2>/dev/null; then
        chmod 600 "$tmp_cache" 2>/dev/null || true
        mv "$tmp_cache" "$cache_file" 2>/dev/null || rm -f "$tmp_cache"
    fi
    if [[ -n "$run_memo" ]]; then
        mkdir -p "$UPGRADE_STATUS_DIR/brew-info" 2>/dev/null || true
        printf '%s' "$info" > "$run_memo" 2>/dev/null || true
    fi

    _BREW_INFO_MEMO["$package"]="$info"
    printf '%s' "$info"
}

# EVIDENCE: workers append one compact evidence row per package to
# <run_dir>/evidence.jsonl (append-only; a stage boundary merges it into
# assessment.jsonl). Evidence rows are partial records; absent/null fields do
# not clobber existing record values during consolidation.
# Args:
#   $1: package token
#   $2: evidence source (github|npm|<domain>|inventory|...)
#   $3: evidence URL ("" -> null)
#   $4: retrieved_at epoch seconds ("" / non-numeric -> null)
#   $5: retrieval_status (vocabulary per contract; "" -> null)
#   $6: evidence snapshot (multiline/unicode safe; "" -> null)
append_assessment_evidence() {
    local package="$1" source="$2" url="$3" retrieved_at="$4" status="$5" snapshot="$6"

    [[ -n "${UPGRADE_STATUS_DIR:-}" && -d "$UPGRADE_STATUS_DIR" ]] || return 0

    jq -cn \
        --arg package "$package" \
        --arg source "$source" \
        --arg url "$url" \
        --arg retrieved_at "$retrieved_at" \
        --arg status "$status" \
        --arg snapshot "$snapshot" '
        {
            package: $package,
            evidence_source: (if $source == "" then null else $source end),
            evidence_url: (if $url == "" then null else $url end),
            retrieved_at: (if ($retrieved_at | test("^[1-9][0-9]*$")) then ($retrieved_at | tonumber) else null end),
            retrieval_status: (if $status == "" then null else $status end),
            evidence_snapshot: (if $snapshot == "" then null else $snapshot end)
        }' >> "$UPGRADE_STATUS_DIR/evidence.jsonl"
}

# PROGRESS: append a single-line JSON event to <run_dir>/progress.jsonl per
# the T2.4.1 contract. Workers never draw terminal frames.
# Args:
#   $1: stage (inventory|evidence|classify)
#   $2: worker-local completed ordinal
#   $3: fixed stage total
#   $4: optional package label
append_progress_event() {
    local stage="$1" completed="$2" total="$3" package="${4:-}"

    [[ -n "${UPGRADE_STATUS_DIR:-}" && -d "$UPGRADE_STATUS_DIR" ]] || return 0

    jq -cn \
        --arg stage "$stage" \
        --argjson completed "$completed" \
        --argjson total "$total" \
        --arg package "$package" '
        {stage: $stage, completed: $completed, total: $total} +
        (if $package == "" then {} else {package: $package} end)' \
        >> "$UPGRADE_STATUS_DIR/progress.jsonl"
}

# Malformed-line tolerant reader: emits parseable object lines unchanged and
# synthesizes a malformed/unknown record (contract vocabulary) for lines that
# do not parse, logging them to stderr. Nothing is silently dropped.
# Args:
#   $1: input JSONL file
#   $2: output file
_record_tolerant_read() {
    local input="$1" output="$2"
    local line pkg

    : > "$output"
    if [[ ! -f "$input" ]]; then
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
            printf '%s\n' "$line" >> "$output"
        else
            echo "brew-change: malformed record line skipped: $line" >&2
            pkg=$(printf '%s' "$line" | jq -r '.package? // empty' 2>/dev/null || true)
            jq -cn --arg package "${pkg:-unknown}" '
                {
                    package: $package,
                    display_name: $package,
                    kind: "formula",
                    installed_version: "",
                    available_version: "",
                    evidence_source: "unsupported",
                    evidence_url: "",
                    retrieved_at: null,
                    retrieval_status: "malformed",
                    evidence_snapshot: "",
                    classification: "unknown",
                    reasons: ["malformed record"],
                    matched_signals: [],
                    assessment_recommendation: false,
                    operational_eligibility: false,
                    default_selected: false
                }' >> "$output"
        fi
    done < "$input"
}

# STAGE BOUNDARY: merge worker evidence rows (evidence.jsonl) into
# assessment.jsonl by package, last-writer-wins per evidence field, via
# temp file + atomic mv. Strict validation: every output record must carry
# the full 16-key schema or the stage fails.
# Args:
#   $1: run status dir
consolidate_assessment_records() {
    local run_dir="$1"
    local records="$run_dir/assessment.jsonl"
    local evidence="$run_dir/evidence.jsonl"

    [[ -f "$records" ]] || return 0

    local tmp_dir="$run_dir/.consolidate.$$"
    mkdir -p "$tmp_dir" || return 1

    _record_tolerant_read "$records" "$tmp_dir/records.jsonl"
    _record_tolerant_read "$evidence" "$tmp_dir/evidence.jsonl"

    local tmp_out="$tmp_dir/assessment.jsonl"
    if ! jq -c -n \
        --rawfile recs "$tmp_dir/records.jsonl" \
        --rawfile ev "$tmp_dir/evidence.jsonl" '
        ($recs | split("\n") | map(select(length > 0) | fromjson)) as $r |
        ($ev   | split("\n") | map(select(length > 0) | fromjson)) as $e |
        $r
        | map(. as $rec
            | ($e | map(select(.package == $rec.package))) as $rows
            | reduce $rows[] as $row (
                  $rec;
                  (if ($row.evidence_source != null) then .evidence_source = $row.evidence_source else . end)
                | (if ($row.evidence_url != null) then .evidence_url = $row.evidence_url else . end)
                | (if ($row.retrieved_at != null) then .retrieved_at = $row.retrieved_at else . end)
                | (if ($row.retrieval_status != null) then .retrieval_status = $row.retrieval_status else . end)
                | (if ($row.evidence_snapshot != null) then .evidence_snapshot = $row.evidence_snapshot else . end)
              ))
        | (.[]),
        ($e
         | map(select(.package as $p | ($r | map(.package) | index($p)) == null))
         | map(
             # Evidence-only package: expand to the full 16-key schema.
             {
                 package: .package,
                 display_name: .package,
                 kind: "formula",
                 installed_version: "",
                 available_version: "",
                 evidence_source: null,
                 evidence_url: null,
                 retrieved_at: null,
                 retrieval_status: null,
                 evidence_snapshot: null,
                 classification: "",
                 reasons: [],
                 matched_signals: [],
                 assessment_recommendation: false,
                 operational_eligibility: false,
                 default_selected: false
             } + .
            )
         | .[])
        ' > "$tmp_out"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    # Strict stage-boundary validation: every output line must be an object.
    if ! jq -s -e 'all(type == "object")' "$tmp_out" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        return 1
    fi

    mv "$tmp_out" "$records" || { rm -rf "$tmp_dir"; return 1; }
    rm -rf "$tmp_dir"
    return 0
}

# Function to extract canonical package tokens from brew outdated --json=v2 output.
# Emits one "token<TAB>type" line per package (formula or cask).
# For formulae, the token is .name. For casks, a null .token falls back to .name
# (array -> first element, string -> as-is). Rows with empty/null tokens are
# omitted.
# Args:
#   $1: The outdated JSON string.
# Outputs: TSV lines to stdout.
extract_outdated_package_tokens() {
    local outdated_json="$1"

    # Check jq availability
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq command not found - required for JSON processing" >&2
        return 1
    fi

    jq -r '
      # Formulae: .name is the command token
      (.formulae[]? |
        .name as $tok |
        select($tok != null and $tok != "") |
        [$tok, "formula"] |
        @tsv
      ),

      # Casks: prefer .token; fall back to .name (array -> first element, string -> as-is)
      (.casks[]? |
        (.token // (if (.name | type) == "array" then .name[0] else .name end)) as $tok |
        [$tok, "cask"] |
        select($tok != null and $tok != "") |
        @tsv
      )
    ' <<< "$outdated_json" 2>/dev/null
}

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
    if ! brew_info=$(get_brew_info "$package"); then
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
    # Note: .name field is used because .token can be null in brew outdated output
    # The .name field can be either a string or array depending on the cask structure
    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        # Handle both null tokens (name may be string) and non-null tokens (name is array)
        latest_version=$(echo "$outdated_json" | jq -r ".casks[] | select(.name == \"$package\" or (.name[]? == \"$package\")) | .current_version" 2>/dev/null)
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
        echo "$outdated_packages" | jq -r '.casks[] | "\(.name | if type == "array" then join(" / ") else . end) (\(.installed_versions | join(", ")) → \(.current_version))"' 2>/dev/null
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

        # Skip interactive prompts in parallel mode to avoid hanging
        if [[ "${BREW_CHANGE_PARALLEL_MODE:-false}" == "true" ]]; then
            echo "Skipping package in parallel mode (interactive prompts disabled)"
            echo ""
            return 1
        fi

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
            # No suggestions found, show pipeline-free search guidance
            # (T3.1.2: never ask users to construct 'brew list | grep')
            if [[ ${#normalized_package} -ge 3 ]]; then
                echo "No similar installed packages found."
                echo "Search Homebrew for the exact name with: brew search $normalized_package"
            else
                echo "Package name too short for suggestions (minimum 3 characters)"
                echo "Search Homebrew for the exact name with: brew search $normalized_package"
            fi
        fi
        return 1
    fi

    # Check if user passed a base name but has an @version variant installed
    # e.g. "claude-code" when "claude-code@latest" is installed
    local resolved_variant=""
    if resolved_variant=$(resolve_installed_variant "$normalized_package" 2>/dev/null); then
        echo "Note: '$normalized_package' is not installed, but '$resolved_variant' is."
        echo "Using '$resolved_variant' instead."
        echo ""
        # Recursively call with the correct installed variant
        show_package_changelog "$resolved_variant"
        return $?
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
        if brew_info=$(get_brew_info "$package"); then
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
            if brew_cask_info=$(get_brew_info "$base_package"); then
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

        # Normalize display version: "unknown" or empty -> "[not installed]"
        local display_current="${current_version:-[not installed]}"
        [[ "$display_current" == "unknown" ]] && display_current="[not installed]"
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
        latest_version="$actual_latest_version"
    fi

    # Check for version skew: when the installed version is newer than brew's
    # "latest" (e.g. auto-updater installed a newer build before the cask/formula
    # definition caught up). Try to resolve the real latest version from the
    # GitHub CHANGELOG if the docs-repo feature is enabled.
    if [[ "$current_version" != "$latest_version" ]]; then
        local sorted_versions
        sorted_versions=$(printf '%s\n%s\n' "$current_version" "$latest_version" | sort -V 2>/dev/null)
        local oldest_version
        oldest_version=$(echo "$sorted_versions" | head -1)
        if [[ "$latest_version" == "$oldest_version" ]]; then
            # Version skew detected — installed is newer than brew's "latest"
            if [[ "$BREW_CHANGE_DOCS_REPO" == "true" || "$BREW_CHANGE_DOCS_REPO" == "1" ]]; then
                local brew_pkg_info
                if brew_pkg_info=$(get_brew_info "$base_package"); then
                    local pkg_homepage
                    pkg_homepage=$(echo "$brew_pkg_info" | jq -r '.formulae[0].homepage // .casks[0].homepage // ""' 2>/dev/null)
                    local github_repo=""
                    # Check cache first, then try homepage analysis
                    if github_repo=$(get_cached_pattern "$base_package" 2>/dev/null); then
                        :
                    elif [[ -n "$pkg_homepage" && "$pkg_homepage" != "null" ]]; then
                        github_repo=$(analyze_homepage_for_github "$pkg_homepage" "$base_package" 2>/dev/null)
                    fi
                    if [[ -n "$github_repo" ]]; then
                        local changelog_latest
                        if changelog_latest=$(get_changelog_latest_version "$github_repo" 2>/dev/null); then
                            # Verify the changelog version is actually newer than installed
                            local sorted_check
                            sorted_check=$(printf '%s\n%s\n' "$current_version" "$changelog_latest" | sort -V 2>/dev/null)
                            local check_oldest
                            check_oldest=$(echo "$sorted_check" | head -1)
                            if [[ "$current_version" == "$check_oldest" ]]; then
                                latest_version="$changelog_latest"
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi

    # Check if package is up to date
    if [[ "$current_version" == "$latest_version" ]]; then
        local install_date=""
        # Get installation time from local brew info, not from API
        local local_brew_info
        if local_brew_info=$(get_brew_info "$base_package"); then
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
