#!/usr/bin/env bash
# Static grouped dashboard renderer (T2.3.2).
#
# Renders classified assessment records (post classify_assessment_records,
# research-005 contract) as the approved grouped view pinned by the golden
# fixtures in tests/fixtures/dashboard/: summary line, attention -> no-signal
# -> unknown groups (empty groups omitted, rows alphabetical), one line per
# package, and a static footer.
#
# Contract properties:
#   - Pure output: reads the record file, writes the view to stdout, returns
#     0. No prompts, no file writes, no color, no emoji, no terminal queries.
#   - All column math is character-based (never `printf %-Ns`, which pads by
#     bytes and corrupts columns containing multi-byte characters such as the
#     "→" arrow and the "…" ellipsis).
#   - Degradation ladder (applied table-wide, never per row):
#       1. reason column dropped when its budget falls below 12 chars;
#       2. versions column shrunk toward a floor of 12 (per-side "…" keeps
#          the "inst → avail" arrow intact), dropped below that floor;
#       3. package names are never truncated; the name column widens to the
#          longest name present (minimum 12).
#   - Footer degrades by dropping "[s] Select packages" first; "[q] Quit" is
#     never dropped.

# Character length of a string (multi-byte safe under a UTF-8 locale).
_dashboard_len() { # string -> char count on stdout
    local LC_ALL
    _dashboard_utf8_locale LC_ALL
    printf '%s' "${#1}"
}

# Pick a UTF-8 locale so bash string slicing counts characters, not bytes.
# Sets the named variable; falls back to the current locale if none exists.
_dashboard_utf8_locale() { # varname
    local __var="$1" __l
    if [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then
        printf -v "$__var" '%s' "${LC_ALL:-${LANG:-}}"
        return 0
    fi
    while IFS= read -r __l; do
        case $__l in
            *UTF-8*|*utf8*|*UTF8*)
                printf -v "$__var" '%s' "$__l"
                return 0
                ;;
        esac
    done < <(locale -a 2>/dev/null)
    printf -v "$__var" '%s' "${LC_ALL:-C}"
}

# Right-pad a string with spaces to the given character width (no truncation).
_dashboard_pad() { # string width
    local s="$1" w="$2" len
    len=$(_dashboard_len "$s")
    if (( len < w )); then
        printf '%s%*s' "$s" "$((w - len))" ''
    else
        printf '%s' "$s"
    fi
}

# Truncate a string to at most `width` characters, appending "…" when any
# characters were removed. Character-based.
_dashboard_trunc() { # string width
    local s="$1" w="$2" len
    local LC_ALL
    _dashboard_utf8_locale LC_ALL
    len=${#s}
    if (( len <= w )); then
        printf '%s' "$s"
    else
        printf '%s…' "${s:0:w - 1}"
    fi
}

# Classify -> row label (color-independent; the label carries the meaning).
_dashboard_label() { # classification
    case "$1" in
        attention) printf 'Needs attention' ;;
        no-signal) printf 'No risk signal' ;;
        *)         printf 'Unknown' ;;
    esac
}

# Classify -> group header.
_dashboard_group_header() { # classification
    case "$1" in
        attention) printf 'Needs attention' ;;
        no-signal) printf 'No risk signal found' ;;
        *)         printf 'Unknown' ;;
    esac
}

# Render the grouped static dashboard for a classified record file.
#
# Usage: render_dashboard_records <assessment.jsonl> [width]
#   width: terminal column budget for degradation (default 80).
# Output goes to stdout; the function has no other side effects.
render_dashboard_records() {
    local records="${1:-}" width="${2:-80}"

    if [[ -z $records || ! -f $records ]]; then
        printf 'brew-change: render_dashboard_records: no record file\n' >&2
        return 1
    fi

    # Run the whole render in a subshell so the UTF-8 locale override (needed
    # for character-based slicing) never leaks to the caller.
    (
        local LC_ALL
        _dashboard_utf8_locale LC_ALL
        export LC_ALL

        local total att ns unk
        total=$(jq -s 'length' "$records")
        att=$(jq -sr '[.[] | select(.classification == "attention")] | length' "$records")
        ns=$(jq -sr '[.[] | select(.classification == "no-signal")] | length' "$records")
        unk=$(jq -sr '[.[] | select(.classification == "unknown")] | length' "$records")

        if (( total == 0 )); then
            printf 'No outdated packages.\n'
            exit 0
        fi

        printf '%d outdated · %d attention · %d no-signal · %d unknown\n' \
            "$total" "$att" "$ns" "$unk"

        # ---- Column budgets (table-wide) --------------------------------
        local name_w=12 vers_nat=0 pkg inst avail
        while IFS=$'\t' read -r pkg inst avail; do
            (( ${#pkg} > name_w )) && name_w=${#pkg}
            local pair="${inst} → ${avail}"
            (( ${#pair} > vers_nat )) && vers_nat=${#pair}
        done < <(jq -r '[.package, .installed_version, .available_version] | @tsv' "$records")

        local label_w=15 vers_cap=26 vers_floor=12 reason_min=12
        local vw0=$(( vers_nat < vers_cap ? vers_nat : vers_cap ))
        local fixed=$(( 2 + name_w + 2 + vw0 + 2 + label_w + 2 ))
        local reason_budget=$(( width - fixed ))
        local show_reason=true show_versions=true

        if (( reason_budget < reason_min )); then
            show_reason=false
            # Re-grow the versions column into the space the reason freed,
            # still capped and never below the structural floor.
            vw=$(( width - (2 + name_w + 2 + 2 + label_w) ))
            (( vw > vw0 )) && vw=$vw0
            if (( vw < vers_floor )); then
                show_versions=false
            fi
        else
            vw=$vw0
        fi

        # Per-side version truncation budget keeps "inst → avail" readable.
        local side=$(( (vw - 3) / 2 ))

        # ---- Groups ------------------------------------------------------
        local cls header
        for cls in attention no-signal unknown; do
            local count
            case $cls in
                attention) count=$att ;;
                no-signal) count=$ns ;;
                *)         count=$unk ;;
            esac
            (( count == 0 )) && continue

            printf '\n'
            header=$(_dashboard_group_header "$cls")
            printf '%s (%d)\n' "$header" "$count"

            local label
            label=$(_dashboard_label "$cls")
            local pkg inst avail reason row
            while IFS=$'\t' read -r pkg inst avail reason; do
                row="  $(_dashboard_pad "$pkg" "$name_w")"
                if $show_versions; then
                    row+="  "
                    local pair inst_s avail_s
                    inst_s=$(_dashboard_trunc "$inst" "$side")
                    avail_s=$(_dashboard_trunc "$avail" "$side")
                    pair="$(_dashboard_pad "$inst_s → $avail_s" "$vw")"
                    row+="$pair  "
                fi
                if $show_reason; then
                    row+="$(_dashboard_pad "$label" "$label_w")"
                    if [[ -n $reason ]]; then
                        row+="  $(_dashboard_trunc "$reason" "$reason_budget")"
                    fi
                else
                    row+=$label
                fi
                printf '%s\n' "$row"
            done < <(jq -r --arg cls "$cls" \
                'select(.classification == $cls)
                 | [.package, .installed_version, .available_version,
                    (.reasons | join("; "))] | @tsv' "$records" \
                | LC_ALL=C sort)
        done

        # ---- Footer --------------------------------------------------------
        local parts=("[r] Review details" "[s] Select packages")
        (( ns > 0 )) && parts+=("[u] Upgrade no-signal ($ns)")
        parts+=("[q] Quit")

        local footer
        footer="$(printf '%s  ' "${parts[@]}")"
        footer="${footer%  }"
        if (( ${#footer} > width )); then
            # Drop [s] first; [q] is never dropped.
            parts=("[r] Review details")
            (( ns > 0 )) && parts+=("[u] Upgrade no-signal ($ns)")
            parts+=("[q] Quit")
            footer="$(printf '%s  ' "${parts[@]}")"
            footer="${footer%  }"
            if (( ${#footer} > width && ns > 0 )); then
                footer="[r] Review details  [q] Quit"
            fi
        fi

        printf '\n%s\n' "$footer"
        exit 0
    )
}
