#!/usr/bin/env bash
# Upgrade orchestration functions for brew-change
# Handles the interactive selective upgrade flow triggered by -u/--upgrade flag
# Use -n/--dry-run with -u to preview without executing

# Three-tier outcome arrays (Task 4)
ATTENTION_PKGS=()
NO_SIGNAL_PKGS=()
UNKNOWN_PKGS=()

_classify_evidence_rank() {
    local retrieval_status="$1"
    local retrieved_at="$2"
    local risk_signal="$3"

    if [[ -n "$risk_signal" ]]; then
        printf '3\n'
    elif [[ "$retrieval_status" =~ ^(fresh|cached-fresh)$ ]] && [[ "$retrieved_at" =~ ^[1-9][0-9]*$ ]]; then
        printf '2\n'
    else
        printf '1\n'
    fi
}

_evidence_rank_to_classification() {
    case "$1" in
        3) printf 'attention\n' ;;
        2) printf 'no-signal\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# ---------------------------------------------------------------------------
# classify_upgrade_evidence
#
# Reads producer TSV rows from status_dir/results.tsv and classifies each
# package into ATTENTION_PKGS, NO_SIGNAL_PKGS, or UNKNOWN_PKGS.
#
# Producer row schema (6 fields, TSV):
#   package  source  retrieval_status  retrieved_at  reason  risk_signal
#
# Classification rules (PRD 7.2):
#   1. Any non-empty risk_signal                -> attention
#   2. retrieval_status in {fresh,cached-fresh}
#      AND retrieved_at is a non-empty positive
#      integer AND risk_signal is empty          -> no-signal
#   3. Everything else                            -> unknown
#
# Deduplication: when results.tsv contains multiple rows for the same
# package, the strongest classification wins (attention > no-signal > unknown).
#
# Inventory filtering: when an inventory is supplied (positional args after
# status_dir), rows whose package is NOT in the inventory are ignored.
# Missing inventory tokens are synthesized as unknown.
#
# Outcomes: an outcomes.tsv is written to status_dir with one row per
# inventory token, preserving inventory order.
#   Schema: package<TAB>source<TAB>retrieval_status<TAB>retrieved_at
#           <TAB>reason<TAB>risk_signal<TAB>classification
#
# Args:
#   $1: Path to the temporary directory containing results.tsv
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

    local results_file="${status_dir}/results.tsv"
    local _pkg

    # Build set of inventory tokens for fast lookup and deduplication.
    local -A in_inventory=()
    for _pkg in "${inventory_pkgs[@]}"; do
        in_inventory["$_pkg"]=1
    done

    # Per-package best classification and best row data.
    # Precedence: attention (3) > no-signal (2) > unknown (1).
    # Value 0 = not yet seen.
    local -A best_rank
    local -A best_source best_retrieval_status best_retrieved_at best_reason best_risk_signal
    for _pkg in "${inventory_pkgs[@]}"; do
        best_rank["$_pkg"]=0
    done

    if [[ -f "$results_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue

            local pkg_name source retrieval_status retrieved_at reason risk_signal
            pkg_name=$(cut -f1 <<< "$line")
            source=$(cut -f2 <<< "$line")
            retrieval_status=$(cut -f3 <<< "$line")
            retrieved_at=$(cut -f4 <<< "$line")
            reason=$(cut -f5 <<< "$line")
            risk_signal=$(cut -f6 <<< "$line")

            [[ -z "$pkg_name" ]] && continue

            # With inventory: skip rows not in inventory.
            if [[ ${#inventory_pkgs[@]} -gt 0 ]]; then
                [[ -z "${in_inventory["$pkg_name"]:-}" ]] && continue
            fi

            # Classify this row.
            local row_rank
            row_rank=$(_classify_evidence_rank "$retrieval_status" "$retrieved_at" "$risk_signal")

            # Apply strongest-precedence dedup.
            if [[ "$row_rank" -ge "${best_rank["$pkg_name"]:-0}" ]]; then
                best_rank["$pkg_name"]="$row_rank"
                best_source["$pkg_name"]="$source"
                best_retrieval_status["$pkg_name"]="$retrieval_status"
                best_retrieved_at["$pkg_name"]="$retrieved_at"
                best_reason["$pkg_name"]="$reason"
                best_risk_signal["$pkg_name"]="$risk_signal"
            fi
        done < "$results_file"
    fi

    # Build outcome arrays and outcomes.tsv in inventory order.
    # When no inventory is supplied, iterate over packages seen in results.
    : > "${status_dir}/outcomes.tsv"

    if [[ ${#inventory_pkgs[@]} -gt 0 ]]; then
        # Inventory-driven: iterate in inventory order.
        for _pkg in "${inventory_pkgs[@]}"; do
            local rank="${best_rank["$_pkg"]:-0}"
            if [[ "$rank" -eq 0 ]]; then
                # Synthesized missing row: no producer data available.
                rank=1
                best_source["$_pkg"]=""
                best_retrieval_status["$_pkg"]="unavailable"
                best_retrieved_at["$_pkg"]=""
                best_reason["$_pkg"]="missing"
                best_risk_signal["$_pkg"]=""
            fi

            local classification
            classification=$(_evidence_rank_to_classification "$rank")

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_pkg" \
                "${best_source["$_pkg"]}" \
                "${best_retrieval_status["$_pkg"]}" \
                "${best_retrieved_at["$_pkg"]}" \
                "${best_reason["$_pkg"]}" \
                "${best_risk_signal["$_pkg"]}" \
                "$classification" \
                >> "${status_dir}/outcomes.tsv"

            case "$classification" in
                attention) ATTENTION_PKGS+=("$_pkg") ;;
                no-signal) NO_SIGNAL_PKGS+=("$_pkg") ;;
                *)         UNKNOWN_PKGS+=("$_pkg") ;;
            esac
        done
    else
        # No inventory: iterate over packages that had rows.
        for _pkg in "${!best_rank[@]}"; do
            local rank="${best_rank["$_pkg"]}"
            local classification
            classification=$(_evidence_rank_to_classification "$rank")

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_pkg" \
                "${best_source["$_pkg"]}" \
                "${best_retrieval_status["$_pkg"]}" \
                "${best_retrieved_at["$_pkg"]}" \
                "${best_reason["$_pkg"]}" \
                "${best_risk_signal["$_pkg"]}" \
                "$classification" \
                >> "${status_dir}/outcomes.tsv"

            case "$classification" in
                attention) ATTENTION_PKGS+=("$_pkg") ;;
                no-signal) NO_SIGNAL_PKGS+=("$_pkg") ;;
                *)         UNKNOWN_PKGS+=("$_pkg") ;;
            esac
        done
    fi
}

# Collect upgrade status from parallel processing subshells (backward compat).
# Wraps classify_upgrade_evidence; callers that already have the inventory list
# should call classify_upgrade_evidence directly.
# Args:
#   $1: Path to the temporary directory containing results.tsv
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
