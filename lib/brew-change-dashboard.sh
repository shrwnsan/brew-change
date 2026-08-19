#!/usr/bin/env bash
# Static grouped dashboard renderer (T2.3.2).
#
# Renders classified assessment records (post classify_assessment_records,
# research-005 contract) as the approved grouped view pinned by the golden
# fixtures in tests/fixtures/dashboard/: summary line, attention -> no-signal
# -> unknown groups (empty groups omitted, rows alphabetical), one line per
# package, and a static footer.
#
# Label-free rows (ratified redesign): group headers state the
# classification, so rows are 2 indent + name + 2 + versions + 2 + reason
# with no per-row label column. Unknown rows additionally suppress the
# status token when it is exactly "unavailable" (the dominant no-action
# case); other tokens (rate-limited, stale, ...) still render.
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

# True when the shell's effective locale already counts characters (UTF-8
# codeset). Decided from the ambient locale variables without a fork when
# they carry an explicit UTF-8 codeset (POSIX precedence LC_ALL > LC_CTYPE >
# LANG; an empty value counts as unset), and without touching any locale
# variable: every creation, assignment, or reset of a locale variable runs
# setlocale(3) inside bash, and on macOS with Homebrew's libintl that
# consults CoreFoundation preferred-language preferences — a path observed
# to segfault bash intermittently under heavy process load (the intermittent
# T2.6.2 full-CLI PTY stall). When the ambient locale is already UTF-8,
# the helpers below need none of those operations.
_dashboard_locale_counts_chars() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]8*|*[Uu][Tt][Ff]-8*) return 0 ;;
    esac
    [[ "$(locale charmap 2>/dev/null)" == UTF-8 ]]
}

# Character length of a string (multi-byte safe under a UTF-8 locale).
_dashboard_len() { # string -> char count on stdout
    if _dashboard_locale_counts_chars; then
        printf '%s' "${#1}"
        return 0
    fi
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
    if _dashboard_locale_counts_chars; then
        len=${#s}
        if (( len <= w )); then
            printf '%s' "$s"
        else
            printf '%s…' "${s:0:w - 1}"
        fi
        return 0
    fi
    local LC_ALL
    _dashboard_utf8_locale LC_ALL
    len=${#s}
    if (( len <= w )); then
        printf '%s' "$s"
    else
        printf '%s…' "${s:0:w - 1}"
    fi
}

# Truncate to at most `width` characters at a token boundary, appending a
# single "…" when anything was removed — never mid-word when avoidable.
_dashboard_trunc_words() { # string width
    local s="$1" w="$2" cut b
    if _dashboard_locale_counts_chars; then
        if (( ${#s} <= w )); then
            printf '%s' "$s"
            return 0
        fi
        cut="${s:0:w - 1}"
        if [[ $cut == *" "* ]]; then
            b="${cut% *}"          # drop the trailing partial token
            b="${b%,}"             # ...and its joining comma
            (( ${#b} >= 1 )) && cut="$b"
        fi
        printf '%s…' "$cut"
        return 0
    fi
    local LC_ALL
    _dashboard_utf8_locale LC_ALL
    if (( ${#s} <= w )); then
        printf '%s' "$s"
        return 0
    fi
    cut="${s:0:w - 1}"
    if [[ $cut == *" "* ]]; then
        b="${cut% *}"          # drop the trailing partial token
        b="${b%,}"             # ...and its joining comma
        (( ${#b} >= 1 )) && cut="$b"
    fi
    printf '%s…' "$cut"
}

# Truncate while preserving the tail: a single leading "…" plus the last
# width-1 characters. Used for sentence fallbacks where the end carries the
# specifics (e.g. version numbers in "Major version transition (22 to 25)").
_dashboard_trunc_tail() { # string width
    local s="$1" w="$2" len
    if _dashboard_locale_counts_chars; then
        len=${#s}
        if (( len <= w )); then
            printf '%s' "$s"
        else
            printf '…%s' "${s: len - w + 1}"
        fi
        return 0
    fi
    local LC_ALL
    _dashboard_utf8_locale LC_ALL
    len=${#s}
    if (( len <= w )); then
        printf '%s' "$s"
    else
        printf '…%s' "${s: len - w + 1}"
    fi
}

# Classify -> group header. Group headers are the only place the
# classification words appear (ratified label-free redesign: rows carry no
# classification label column).
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
    # for character-based slicing) never leaks to the caller. When the
    # ambient locale already counts characters (the launcher exports a
    # UTF-8 LC_ALL, and interactive shells carry a UTF-8 LANG), skip the
    # locale-variable setup entirely: creating/resetting locale variables
    # runs setlocale(3) inside bash, an intermittent segfault vector under
    # heavy process load on macOS (Homebrew libintl -> CoreFoundation
    # preferred languages) — see _dashboard_locale_counts_chars.
    (
        if ! _dashboard_locale_counts_chars; then
            local LC_ALL
            _dashboard_utf8_locale LC_ALL
            export LC_ALL
        fi

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

        local vers_cap=26 vers_floor=12 reason_min=12
        local vw0=$(( vers_nat < vers_cap ? vers_nat : vers_cap ))
        local fixed=$(( 2 + name_w + 2 + vw0 + 2 ))
        local reason_budget=$(( width - fixed ))
        local show_reason=true show_versions=true

        if (( reason_budget < reason_min )); then
            show_reason=false
            # Re-grow the versions column into the space the reason freed,
            # still capped and never below the structural floor.
            vw=$(( width - (2 + name_w + 2 + 2) ))
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

            # NOTE: mode precedes reason because tab is IFS whitespace — an
            # empty reason field at the end simply leaves `reason` unset
            # instead of shifting the columns.
            local pkg inst avail mode reason row
            while IFS=$'\t' read -r pkg inst avail mode reason; do
                row="  $(_dashboard_pad "$pkg" "$name_w")"
                if $show_versions; then
                    row+="  "
                    local pair inst_s avail_s
                    inst_s=$(_dashboard_trunc "$inst" "$side")
                    avail_s=$(_dashboard_trunc "$avail" "$side")
                    pair="$(_dashboard_pad "$inst_s → $avail_s" "$vw")"
                    row+="$pair"
                fi
                if $show_reason && [[ -n $reason ]]; then
                    # Differential reasons (ratified label-free design):
                    # compact tokens when present, tail-preserving
                    # truncation for the rare empty-signals sentence
                    # fallback. Rows without reason content (no-signal, or
                    # unknown with the dominant "unavailable" status) end at
                    # the versions column with no trailing padding.
                    if [[ $mode == fallback ]]; then
                        reason=$(_dashboard_trunc_tail "$reason" "$reason_budget")
                    else
                        reason=$(_dashboard_trunc_words "$reason" "$reason_budget")
                    fi
                    row+="  $reason"
                else
                    # rstrip trailing padding so reason-less rows end at the
                    # last version character.
                    row="${row%"${row##*[! ]}"}"
                fi
                printf '%s\n' "$row"
            done < <(jq -r --arg cls "$cls" \
                'select(.classification == $cls)
                 | [.package, .installed_version, .available_version,
                    (if .classification == "attention"
                        and (((.matched_signals // []) | length) == 0)
                     then "fallback" else "plain" end),
                    (if .classification == "no-signal" then ""
                     elif .classification == "unknown"
                        and ((.retrieval_status // "unavailable") == "unavailable")
                     then ""
                     elif .classification == "unknown" then (.retrieval_status // "")
                     elif ((.matched_signals // []) | length) > 0
                     then ((.matched_signals // []) | join(", "))
                     else (((.reasons // [""])[0]) // "") end)] | @tsv' "$records" \
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
