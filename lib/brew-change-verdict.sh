#!/usr/bin/env bash
# End-of-run verdict summary for plain -b runs (tasks-004 Task 1).
#
# A `brew-change -b` run processes every outdated package and then, before
# this module existed, ended with nothing but the generic "Run 'brew
# upgrade'" hint — the per-package [breaking] markers were buried somewhere
# in the scrollback and the run never answered the only question the user
# had: are there any breaking packages or none?
#
# render_verdict_summary reads the same classified assessment.jsonl the -u
# workflow produces (inventory init -> worker evidence rows -> consolidate
# -> classify) and prints a compact honest verdict block:
#
#   Verdict: 4 attention · 2 no-signal · 2 unknown
#
#   Breaking changes (3)
#     abseil 20260526.0 → 20260817.0
#       absl::void_t is now deprecated; users should use C++17 std::void_t…
#     ...
#   Major version transitions (1)
#     vercel 58.9.0 → 59.1.4
#   No risk signal found (2)
#   Unknown (2) — no usable release notes; review individually
#
# Vocabulary matches the -u dashboard on purpose (attention / no-signal /
# unknown): the all-clear line claims only that no breaking-change patterns
# or major version transitions were detected — it never claims the upgrade
# is safe, and the unknown count always stays visible because packages
# without release notes are not verified clean (T1.3.2 no-safe-claims).
#
# Plain-render contract (T3.3.1): text labels carry all meaning; the ⚠️
# glyph on the breaking header is strictly additive decoration on a TTY
# without NO_COLOR, so piped output equals the base render by construction.

# Maximum evidence-excerpt length before word-boundary truncation.
VERDICT_EXCERPT_MAX=72

# True when the decorative header glyph may be drawn (same policy as the
# breaking-change markers in brew-change-breaking.sh).
_verdict_header_glyph() {
    if _breaking_emoji_allowed; then
        printf ' ⚠️'
    fi
}

# Strip the leading markdown decorations a release-notes line can carry:
# whitespace, heading hashes, bullets, and block quotes (repeatedly, so
# "  ## - text" reduces to "text").
_verdict_strip_line() {
    local line="$1"
    line="${line#"${line%%[![:space:]]*}"}"
    while [[ "$line" =~ ^([#]+[[:space:]]*|[-*][[:space:]]+|>[[:space:]]*) ]]; do
        line="${line:${#BASH_REMATCH}}"
    done
    printf '%s' "$line"
}

# Truncate to VERDICT_EXCERPT_MAX characters at a word boundary; append the
# ellipsis character only when truncation actually happened.
_verdict_truncate() {
    local text="$1"
    local max="${VERDICT_EXCERPT_MAX:-72}"
    if (( ${#text} <= max )); then
        printf '%s' "$text"
        return 0
    fi
    local cut="${text:0:max}"
    if [[ "$cut" == *" "* ]]; then
        cut="${cut% *}"
    fi
    printf '%s…' "$cut"
}

# Pick the one-line evidence excerpt for a breaking row. Preference order:
#   1. the first line of an explicit breaking-changes section, when the
#      notes have one (get_breaking_changes_summary);
#   2. the first line that itself matches the breaking-change patterns —
#      pattern-only matches must not surface the release title;
#   3. the first non-empty line.
# Returns 1 when the snapshot has no usable line at all.
_verdict_excerpt() {
    local snapshot="$1"
    [[ -z "$snapshot" || "$snapshot" == "null" ]] && return 1

    local section line stripped
    section=$(get_breaking_changes_summary "$snapshot" 2>/dev/null || true)
    if [[ -n "$section" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            stripped="$(_verdict_strip_line "$line")"
            if [[ -n "$stripped" ]]; then
                _verdict_truncate "$stripped"
                return 0
            fi
        done <<< "$section"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        stripped="$(_verdict_strip_line "$line")"
        [[ -z "$stripped" ]] && continue
        if detect_breaking_changes "$stripped"; then
            _verdict_truncate "$stripped"
            return 0
        fi
    done <<< "$snapshot"

    while IFS= read -r line || [[ -n "$line" ]]; do
        stripped="$(_verdict_strip_line "$line")"
        if [[ -n "$stripped" ]]; then
            _verdict_truncate "$stripped"
            return 0
        fi
    done <<< "$snapshot"
    return 1
}

# Render the verdict block for a classified assessment.jsonl.
# Pure: reads the record file, writes the block to stdout, touches nothing
# else. A missing or record-less file renders nothing (the caller skips
# the block entirely); malformed lines are skipped, never fatal — the -u
# stage boundary already rewrote them as unknown records.
# Args:
#   $1: path to classified assessment.jsonl
render_verdict_summary() {
    local records_file="$1"

    [[ -f "$records_file" ]] || return 0

    # Attention rows are decorated "pkg<US>installed<US>available<US>excerpt"
    # (US = unit separator, never whitespace, so empty fields survive the
    # round trip) and sorted as whole strings — equivalent to sorting by
    # package name within each group.
    local -a breaking_rows=() major_rows=()
    local no_signal_count=0 unknown_count=0 total=0

    local line cls pkg inst avail signals snapshot excerpt
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1 || continue

        cls=$(printf '%s' "$line" | jq -r '.classification // ""' 2>/dev/null)
        [[ -z "$cls" ]] && continue

        total=$((total + 1))
        case "$cls" in
            no-signal) no_signal_count=$((no_signal_count + 1)); continue ;;
            unknown)   unknown_count=$((unknown_count + 1)); continue ;;
            attention) ;;
            *) continue ;;
        esac

        pkg=$(printf '%s' "$line" | jq -r '.package // ""' 2>/dev/null)
        [[ -z "$pkg" ]] && continue
        inst=$(printf '%s' "$line" | jq -r '.installed_version // ""' 2>/dev/null)
        avail=$(printf '%s' "$line" | jq -r '.available_version // ""' 2>/dev/null)
        signals=$(printf '%s' "$line" | jq -r '.matched_signals // [] | join(",")' 2>/dev/null)

        # Breaking wins when both signals matched: the evidence pattern is
        # the stronger, more actionable claim than the version heuristic.
        if [[ ",$signals," == *",breaking-change-pattern,"* ]]; then
            snapshot=$(printf '%s' "$line" | jq -r '
                if (.evidence_snapshot | type) == "object" then
                    (.evidence_snapshot | tostring)
                else
                    (.evidence_snapshot // "" | tostring)
                end' 2>/dev/null)
            excerpt=$(_verdict_excerpt "$snapshot") || excerpt=""
            excerpt="${excerpt//$'\x1f'/ }"
            breaking_rows+=("$(printf '%s\x1f%s\x1f%s\x1f%s' "$pkg" "$inst" "$avail" "$excerpt")")
        else
            major_rows+=("$(printf '%s\x1f%s\x1f%s' "$pkg" "$inst" "$avail")")
        fi
    done < "$records_file"

    (( total > 0 )) || return 0

    local attention_count=$(( ${#breaking_rows[@]} + ${#major_rows[@]} ))
    printf 'Verdict: %d attention · %d no-signal · %d unknown\n' \
        "$attention_count" "$no_signal_count" "$unknown_count"
    printf '\n'

    if (( attention_count == 0 )); then
        printf 'No breaking-change patterns or major version transitions detected across %d packages.\n' "$total"
    fi

    if (( ${#breaking_rows[@]} > 0 )); then
        printf 'Breaking changes (%d)%s\n' "${#breaking_rows[@]}" "$(_verdict_header_glyph)"
        while IFS= read -r row; do
            IFS=$'\x1f' read -r pkg inst avail excerpt <<< "$row"
            printf '  %s %s → %s\n' "$pkg" "$inst" "$avail"
            [[ -n "${excerpt:-}" ]] && printf '    %s\n' "$excerpt"
        done < <(printf '%s\n' "${breaking_rows[@]}" | LC_ALL=C sort)
    fi

    if (( ${#major_rows[@]} > 0 )); then
        printf 'Major version transitions (%d)\n' "${#major_rows[@]}"
        while IFS= read -r row; do
            IFS=$'\x1f' read -r pkg inst avail <<< "$row"
            printf '  %s %s → %s\n' "$pkg" "$inst" "$avail"
        done < <(printf '%s\n' "${major_rows[@]}" | LC_ALL=C sort)
    fi

    printf 'No risk signal found (%d)\n' "$no_signal_count"
    printf 'Unknown (%d) — no usable release notes; review individually\n' "$unknown_count"
    return 0
}
