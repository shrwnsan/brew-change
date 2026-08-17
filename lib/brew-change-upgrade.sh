#!/usr/bin/env bash
# Upgrade orchestration functions for brew-change
# Handles the interactive selective upgrade flow triggered by -u/--upgrade flag
# Use -n/--dry-run with -u to preview without executing

# Three-tier outcome arrays (Task 4). Since T2.1.2 these are DERIVED views
# built from classified assessment records; presentation still consumes them.
ATTENTION_PKGS=()
NO_SIGNAL_PKGS=()
UNKNOWN_PKGS=()

# Ensure the pure assessment engine is available even when this module is
# sourced standalone (tests). brew-change sources it before this module.
if ! declare -F classify_assessment_records >/dev/null 2>&1; then
    _UPGRADE_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091 # dynamic sibling path
    [[ -f "$_UPGRADE_MODULE_DIR/brew-change-assessment.sh" ]] && \
        source "$_UPGRADE_MODULE_DIR/brew-change-assessment.sh"
    unset _UPGRADE_MODULE_DIR
fi

_classification_rank() {
    case "$1" in
        attention) printf '3\n' ;;
        no-signal) printf '2\n' ;;
        *)         printf '1\n' ;;
    esac
}

# Synthesize a full-schema unknown record for an inventory package that has
# no record (no producer evidence at all).
_synthesize_missing_record() {
    local pkg="$1"

    jq -cn --arg package "$pkg" '
    {
        package: $package,
        display_name: $package,
        kind: "formula",
        installed_version: "",
        available_version: "",
        evidence_source: "",
        evidence_url: "",
        retrieved_at: null,
        retrieval_status: "unavailable",
        evidence_snapshot: "",
        classification: "unknown",
        reasons: ["missing"],
        matched_signals: [],
        assessment_recommendation: false,
        operational_eligibility: false,
        default_selected: false
    }'
}

# ---------------------------------------------------------------------------
# classify_upgrade_evidence
#
# Consumes the approved-contract record stream in status_dir:
#   1. Stage boundary: consolidate_assessment_records merges worker evidence
#      rows (evidence.jsonl) into assessment.jsonl via temp + atomic mv.
#   2. Delegates classification to the pure engine
#      (classify_assessment_records; PRD 7.2 precedence) with tolerant read:
#      malformed lines become unknown.
#   3. Builds the derived presentation arrays with strongest-precedence
#      dedup (attention > no-signal > unknown) and inventory filtering;
#      missing inventory tokens are synthesized as unknown.
#   4. Rewrites assessment.jsonl with the classified records (atomic),
#      preserving inventory order when an inventory is supplied.
#
# Args:
#   $1: Path to the run status directory containing assessment.jsonl
#   $2..: (Optional) inventory package names for missing-row synthesis
# Populates global arrays:
#   ATTENTION_PKGS[], NO_SIGNAL_PKGS[], UNKNOWN_PKGS[]
# ---------------------------------------------------------------------------
classify_upgrade_evidence() {
    local status_dir="$1"
    shift
    local -a inventory_pkgs=("$@")

    ATTENTION_PKGS=()
    NO_SIGNAL_PKGS=()
    UNKNOWN_PKGS=()

    local records_file="${status_dir}/assessment.jsonl"
    [[ -f "$records_file" ]] || : > "$records_file"

    # Stage boundary: merge evidence rows before classification. (Standalone
    # sourcing of this module without brew.sh implies no evidence stream.)
    if declare -F consolidate_assessment_records >/dev/null 2>&1; then
        consolidate_assessment_records "$status_dir" || return 1
    fi

    local classified_tmp="${status_dir}/.classified.$$"
    if ! classify_assessment_records "$records_file" > "$classified_tmp"; then
        rm -f "$classified_tmp"
        return 1
    fi

    local _pkg
    # Build set of inventory tokens for fast lookup and deduplication.
    local -A in_inventory=()
    for _pkg in ${inventory_pkgs[@]+"${inventory_pkgs[@]}"}; do
        in_inventory["$_pkg"]=1
    done

    # Per-package best classification rank (attention 3 > no-signal 2 >
    # unknown 1; 0 = not yet seen) and the winning classified record line.
    local -A best_rank=()
    local -A best_line=()

    local line pkg_name classification row_rank
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        pkg_name=$(printf '%s' "$line" | jq -r '.package // empty' 2>/dev/null)
        [[ -z "$pkg_name" ]] && continue

        # With inventory: skip records not in inventory.
        if [[ ${#inventory_pkgs[@]} -gt 0 ]]; then
            [[ -z "${in_inventory["$pkg_name"]:-}" ]] && continue
        fi

        classification=$(printf '%s' "$line" | jq -r '.classification // "unknown"' 2>/dev/null)
        row_rank=$(_classification_rank "$classification")

        if [[ "$row_rank" -ge "${best_rank["$pkg_name"]:-0}" ]]; then
            best_rank["$pkg_name"]="$row_rank"
            best_line["$pkg_name"]="$line"
        fi
    done < "$classified_tmp"
    rm -f "$classified_tmp"

    # Emit classified records (inventory order when supplied) and build the
    # derived presentation arrays.
    local out_tmp="${status_dir}/.assessment.out.$$"
    : > "$out_tmp"

    local -a ordered_pkgs=()
    if [[ ${#inventory_pkgs[@]} -gt 0 ]]; then
        ordered_pkgs=("${inventory_pkgs[@]}")
    else
        ordered_pkgs=("${!best_line[@]}")
    fi

    for _pkg in ${ordered_pkgs[@]+"${ordered_pkgs[@]}"}; do
        line="${best_line["$_pkg"]:-}"
        if [[ -z "$line" ]]; then
            line=$(_synthesize_missing_record "$_pkg")
        fi
        printf '%s\n' "$line" >> "$out_tmp"

        classification=$(printf '%s' "$line" | jq -r '.classification // "unknown"' 2>/dev/null)
        case "$classification" in
            attention) ATTENTION_PKGS+=("$_pkg") ;;
            no-signal) NO_SIGNAL_PKGS+=("$_pkg") ;;
            *)         UNKNOWN_PKGS+=("$_pkg") ;;
        esac
    done

    # T2.4.3 progress: one classify event per package (inventory order),
    # after the classified assessment.jsonl is committed. The renderer
    # dedups by package and reaches completed==total deterministically.
    if [[ "${UPGRADE_STATUS_DIR:-}" == "$status_dir" ]] \
        && declare -F append_progress_event >/dev/null 2>&1; then
        local _prog_idx=0
        for _pkg in ${ordered_pkgs[@]+"${ordered_pkgs[@]}"}; do
            _prog_idx=$((_prog_idx + 1))
            append_progress_event "classify" "$_prog_idx" \
                "${#ordered_pkgs[@]}" "$_pkg"
        done
    fi

    mv "$out_tmp" "$records_file" || { rm -f "$out_tmp"; return 1; }
    return 0
}

# Collect upgrade status from parallel processing subshells (backward compat).
# Wraps classify_upgrade_evidence; callers that already have the inventory list
# should call classify_upgrade_evidence directly.
# Args:
#   $1: Path to the run status directory containing assessment.jsonl
collect_upgrade_status() {
    local status_dir="$1"
    classify_upgrade_evidence "$status_dir"
}

# Check if a package is in the ATTENTION tier
# Args:
#   $1: Package name
# Returns:
#   0 if package needs attention, 1 otherwise
is_package_breaking() {
    local target="$1"
    local pkg
    for pkg in "${ATTENTION_PKGS[@]+"${ATTENTION_PKGS[@]}"}"; do
        if [[ "$pkg" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

# Only no-signal packages are selected by default. Attention, unknown, and
# unclassified packages require an explicit affirmative choice.
is_package_default_selected() {
    local target="$1"
    local pkg
    for pkg in "${NO_SIGNAL_PKGS[@]+"${NO_SIGNAL_PKGS[@]}"}"; do
        [[ "$pkg" == "$target" ]] && return 0
    done
    return 1
}

# Print the upgrade summary line
# Args:
#   $1: The outdated packages JSON from brew outdated --json=v2
print_upgrade_summary() {
    local outdated_packages="$1"

    local total_count=0
    local attention_count=${#ATTENTION_PKGS[@]}
    local no_signal_count=${#NO_SIGNAL_PKGS[@]}
    local unknown_count=${#UNKNOWN_PKGS[@]}

    # Calculate total from JSON
    total_count=$(echo "$outdated_packages" | jq -r '(.formulae | length) + (.casks | length)' 2>/dev/null || echo "0")

    # Prefer explicit counts; fall back to total - known if synthesis wasn't used
    if [[ $((attention_count + no_signal_count + unknown_count)) -eq 0 ]]; then
        unknown_count=$((total_count - attention_count - no_signal_count))
    fi

    echo ""
    echo "---"
    echo "Summary: $total_count packages outdated · $attention_count need attention · $no_signal_count no risk signal · $unknown_count unknown"
}

# Print suggested upgrade command without executing.
# Default/bulk action includes only NO_SIGNAL_PKGS.
# Args:
#   $1: The outdated packages JSON
print_upgrade_suggestion() {
    local outdated_packages="$1"

    local no_signal_count=${#NO_SIGNAL_PKGS[@]}

    echo ""

    if [[ $no_signal_count -gt 0 ]]; then
        echo "No-signal packages (no risk signal found):"
        echo "  brew upgrade ${NO_SIGNAL_PKGS[*]}"
    fi

    if [[ ${#ATTENTION_PKGS[@]} -gt 0 ]]; then
        echo ""
        echo "Attention packages (review before upgrading):"
        local pkg
        for pkg in "${ATTENTION_PKGS[@]}"; do
            echo "  - $pkg"
        done
    fi

    if [[ ${#UNKNOWN_PKGS[@]} -gt 0 ]]; then
        echo ""
        echo "Unknown packages (evidence unavailable):"
        local pkg
        for pkg in "${UNKNOWN_PKGS[@]}"; do
            echo "  - $pkg"
        done
    fi

    echo ""
}

# Run the interactive upgrade flow
# Args:
#   $1: The outdated packages JSON from brew outdated --json=v2
run_upgrade_prompt() {
    local outdated_packages="$1"

    local attention_count=${#ATTENTION_PKGS[@]}
    local no_signal_count=${#NO_SIGNAL_PKGS[@]}
    local unknown_count=${#UNKNOWN_PKGS[@]}

    # Calculate total from JSON
    local total_count=0
    total_count=$(echo "$outdated_packages" | jq -r '(.formulae | length) + (.casks | length)' 2>/dev/null || echo "0")

    # Print summary (always shown in upgrade mode)
    print_upgrade_summary "$outdated_packages"

    # Dry-run mode: run real brew upgrade --dry-run on no-signal packages,
    # no confirmation, no mutation. If no no-signal packages, do not call brew.
    if [[ "${DRY_RUN_MODE:-false}" == "true" ]]; then
        if [[ ${#NO_SIGNAL_PKGS[@]} -eq 0 ]]; then
            echo ""
            echo "No no-signal packages to dry-run."
            print_upgrade_suggestion "$outdated_packages"
            return 0
        fi
        preview_upgrade_packages "${NO_SIGNAL_PKGS[@]}"
        return $?
    fi

    # Non-interactive mode (piped input): print suggestion and exit
    if ! is_interactive_mode; then
        echo ""
        echo "Non-interactive mode. Upgrade skipped."
        print_upgrade_suggestion "$outdated_packages"
        return 0
    fi

    # Interactive prompt
    local action
    prompt_upgrade_action "$attention_count" "$no_signal_count" "$total_count" action

    case "$action" in
        no-signal)
            if [[ ${#NO_SIGNAL_PKGS[@]} -eq 0 ]]; then
                echo ""
                echo "No no-signal packages to upgrade."
                return 0
            fi
            run_upgrade_with_preview "${NO_SIGNAL_PKGS[@]}"
            ;;
        choose)
            # Build full package list from JSON using canonical tokens
            local -a all_pkgs=()
            while IFS=$'\t' read -r pkg pkg_type; do
                [[ -n "$pkg" && "$pkg" != "null" ]] && all_pkgs+=("$pkg")
            done < <(extract_outdated_package_tokens "$outdated_packages" 2>/dev/null)

            if [[ ${#all_pkgs[@]} -eq 0 ]]; then
                echo "No packages to choose from."
                return 0
            fi

            local selected_output
            selected_output=$(prompt_package_selection "${all_pkgs[@]}")

            if [[ -z "$selected_output" ]]; then
                echo ""
                echo "No packages selected."
                return 0
            fi

            # Convert newline-separated selection into a proper array
            local -a selected_pkgs=()
            mapfile -t selected_pkgs <<< "$selected_output"

            if [[ ${#selected_pkgs[@]} -eq 0 ]]; then
                echo ""
                echo "No packages selected."
                return 0
            fi

            run_upgrade_with_preview "${selected_pkgs[@]}"
            ;;
        cancel|*)
            echo ""
            echo "Upgrade cancelled."
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# execute_upgrade
#
# THE single mutation entry point. All real `brew upgrade --yes` calls must
# go through this function. Called internally by run_upgrade_with_preview
# after preview + confirmation succeed.
#
# Args:
#   $1...: Package names to upgrade (passed as array elements)
# Returns:
#   0 on successful upgrade
#   Non-zero on failure
# ---------------------------------------------------------------------------
execute_upgrade() {
    local -a packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo ""
        echo "No packages selected for upgrade."
        return 0
    fi

    echo ""
    echo "Running: brew upgrade --yes ${packages[*]}"
    echo ""

    local upgrade_exit_code=0

    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
        brew upgrade --yes "${packages[@]}" || upgrade_exit_code=$?

    echo ""

    if [[ $upgrade_exit_code -eq 0 ]]; then
        echo "Upgrade completed successfully."
    else
        echo "Upgrade completed with errors (exit code $upgrade_exit_code)."
        echo "Some packages may have failed to upgrade."
        echo "Check the output above for details, or run 'brew doctor' to diagnose issues."
    fi

    return $upgrade_exit_code
}

# ---------------------------------------------------------------------------
# preview_upgrade_packages
#
# Run `brew upgrade --dry-run` for the given package array, capture and
# display the output, and show a dependency/dependent warning.
#
# Args:
#   $1...: Package names to preview
# Returns:
#   0 on successful preview (dry-run exit 0)
#   1 on preview failure (dry-run non-zero exit)
# ---------------------------------------------------------------------------
preview_upgrade_packages() {
    local -a packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No packages to preview." >&2
        return 1
    fi

    echo ""
    echo "Preview: brew upgrade --dry-run ${packages[*]}"
    echo ""

    local preview_exit_code=0
    local preview_output

    preview_output=$(HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --dry-run "${packages[@]}" 2>&1) || preview_exit_code=$?

    echo "$preview_output"

    echo ""
    echo "Warning: Homebrew may also act on dependencies and dependents of these packages." >&2
    echo ""

    return $preview_exit_code
}

# ---------------------------------------------------------------------------
# run_upgrade_with_preview
#
# THE single entry point for preview-confirm-mutate. All actual upgrade
# flows (no-signal, choose, any future path) must call this. No mutation
# may occur outside this function.
#
# Flow: preview_upgrade_packages -> prompt_upgrade_confirmation -> execute_upgrade
#
# Args:
#   $1...: Package names to upgrade
# Returns:
#   0 on successful upgrade (or declined confirmation)
#   1 on preview failure or upgrade execution failure
# ---------------------------------------------------------------------------
run_upgrade_with_preview() {
    local -a packages=("$@")

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No packages selected for upgrade."
        return 0
    fi

    local pkg_count=${#packages[@]}
    local desc="$pkg_count package"
    [[ "$pkg_count" -ne 1 ]] && desc="$pkg_count packages"

    # Step 1: Preview dry-run
    if ! preview_upgrade_packages "${packages[@]}"; then
        echo "Preview failed. Upgrade cancelled." >&2
        return 1
    fi

    # Step 2: Prompt for final confirmation
    if ! prompt_upgrade_confirmation "$desc" "${packages[@]}"; then
        echo ""
        echo "Upgrade cancelled."
        return 0
    fi

    # Step 3: Execute mutation through single entry point, same package argv
    execute_upgrade "${packages[@]}"
}
