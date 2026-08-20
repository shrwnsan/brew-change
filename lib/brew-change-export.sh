#!/usr/bin/env bash
# Export surface for brew-change assessments (tasks-005).
#
# Provides a stable JSON projection of assessment data for external consumers.
# The export format is versioned and deliberately smaller than the internal
# assessment record contract — it's a public interface, not an internal dump.

# Schema version for the export format. Increment when the schema changes
# in ways that require consumer updates.
ASSESSMENT_EXPORT_SCHEMA_VERSION=1

# Directory where the export file is written
ASSESSMENT_EXPORT_DIR="${HOME}/.brew-change"
ASSESSMENT_EXPORT_FILE="${ASSESSMENT_EXPORT_DIR}/last-assessment.json"

# ---------------------------------------------------------------------------
# write_assessment_export <assessment_jsonl_file>
#
# Reads assessment JSONL records and writes a stable export JSON to
# ~/.brew-change/last-assessment.json. The export is a deliberate projection
# of the internal schema, not a full dump.
#
# Args:
#   $1: Path to assessment.jsonl file (must exist and be readable)
#
# Returns: 0 on success, 1 on error
# ---------------------------------------------------------------------------
write_assessment_export() {
    local assessment_file="$1"

    # Validate input
    if [[ ! -r "$assessment_file" ]]; then
        echo "Error: Assessment file not readable: $assessment_file" >&2
        return 1
    fi

    # Create export directory if it doesn't exist
    if [[ ! -d "$ASSESSMENT_EXPORT_DIR" ]]; then
        mkdir -p "$ASSESSMENT_EXPORT_DIR" 2>/dev/null || {
            echo "Error: Cannot create export directory: $ASSESSMENT_EXPORT_DIR" >&2
            return 1
        }
    fi

    # Generate ISO-8601 timestamp
    local generated_at
    generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Build the export JSON
    # This is a stable projection — only fields that are part of the public contract.
    # Records are validated per line: one malformed line is skipped, never allowed
    # to poison the whole projection (jq -s over the raw file would fail entirely).
    local valid_records
    valid_records="$(
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            printf '%s' "$line" \
                | jq -c 'select(type == "object" and .package != null)' 2>/dev/null || true
        done < "$assessment_file" | jq -s '.'
    )"
    local export_json
    export_json="$(jq -n \
        --argjson schema_version "$ASSESSMENT_EXPORT_SCHEMA_VERSION" \
        --arg generated_at "$generated_at" \
        --argjson assessment_data "${valid_records:-[]}" \
        '{
            schema_version: $schema_version,
            generated_at: $generated_at,
            packages: [
                $assessment_data | map({
                    name: .package,
                    display_name: .display_name,
                    kind: .kind,
                    installed_version: (.installed_version // null),
                    available_version: (.available_version // null),
                    classification: .classification,
                    matched_signals: ((.matched_signals // []) | map(select(. != ""))),
                    retrieval_status: .retrieval_status
                }) | .[]
            ]
        }' 2>/dev/null)" || {
        echo "Error: Failed to generate export JSON" >&2
        return 1
    }

    # Write atomically to avoid partial reads
    local tmp_file="${ASSESSMENT_EXPORT_FILE}.$$"
    if ! printf '%s' "$export_json" > "$tmp_file"; then
        echo "Error: Failed to write export file" >&2
        rm -f "$tmp_file"
        return 1
    fi

    if ! mv "$tmp_file" "${ASSESSMENT_EXPORT_FILE}"; then
        echo "Error: Failed to finalize export file" >&2
        rm -f "$tmp_file"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# read_assessment_export
#
# Reads and prints the export JSON to stdout.
#
# Returns: 0 on success, 1 if file doesn't exist or is unreadable
# ---------------------------------------------------------------------------
read_assessment_export() {
    if [[ ! -r "${ASSESSMENT_EXPORT_FILE}" ]]; then
        echo "Error: Assessment export file not found: ${ASSESSMENT_EXPORT_FILE}" >&2
        echo "Run 'brew-change -u' or 'brew-change -b' to generate an assessment." >&2
        return 1
    fi

    # Validate that we can read it as JSON
    if ! jq -e '.' "${ASSESSMENT_EXPORT_FILE}" >/dev/null 2>&1; then
        echo "Error: Assessment export file is corrupted or invalid JSON" >&2
        return 1
    fi

    cat "${ASSESSMENT_EXPORT_FILE}"
    return 0
}

# ---------------------------------------------------------------------------
# validate_assessment_export_schema [max_schema_version]
#
# Validates that the export file exists and has a supported schema version.
#
# Args:
#   $1: (Optional) Maximum supported schema version (default: current version)
#
# Returns: 0 if valid, 1 if invalid or unsupported
# ---------------------------------------------------------------------------
validate_assessment_export_schema() {
    local max_version="${1:-$ASSESSMENT_EXPORT_SCHEMA_VERSION}"

    if [[ ! -r "${ASSESSMENT_EXPORT_FILE}" ]]; then
        return 1
    fi

    local schema_version
    schema_version="$(jq -r '.schema_version // empty' "${ASSESSMENT_EXPORT_FILE}" 2>/dev/null)"

    if [[ -z "$schema_version" ]]; then
        return 1
    fi

    # Check if schema version is within supported range
    if [[ "$schema_version" -lt 1 ]] || [[ "$schema_version" -gt "$max_version" ]]; then
        return 1
    fi

    return 0
}
