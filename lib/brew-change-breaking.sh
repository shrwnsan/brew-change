#!/usr/bin/env bash
# Breaking changes detection functions for brew-change

# =============================================================================
# Breaking Changes Detection
# =============================================================================

# Function to check if release notes contain breaking changes
# Returns 0 if breaking changes detected, 1 otherwise
detect_breaking_changes() {
    local release_notes="$1"

    # If no release notes, no breaking changes to detect
    if [[ -z "$release_notes" || "$release_notes" == "null" ]]; then
        return 1
    fi

    # Convert to lowercase for case-insensitive matching
    local notes_lower
    notes_lower=$(echo "$release_notes" | tr '[:upper:]' '[:lower:]')

    # Define breaking change patterns (case-insensitive)
    # These are common indicators of breaking changes in release notes
    local breaking_patterns=(
        "breaking"                    # General breaking indicator
        "breaking change"             # Full phrase
        "breaking changes"            # Plural
        "breaking:"                   # With colon
        "breaking changes:"           # Full phrase with colon
        "⚠️"                          # Warning emoji often used for breaking changes
        "removed:"                    # Features/APIs removed
        "removed "                    # With space
        "deprecated:"                 # Deprecated features
        "deprecated "                 # With space
        "incompatible"                # Incompatible changes
        "incompatible:"               # With colon
        "not backward compatible"     # Explicit statement
        "no longer supported"         # Feature dropped
        "no longer works"             # Functionality removed
        "requires manual"             # Manual intervention needed
        "requires migration"          # Migration required
        "migration required"          # Alternative phrasing
        "major changes"               # Significant changes
        "api changes"                 # API modifications
        "behavior changes"            # Behavior modifications
        "backward incompatible"       # Technical term
        "compatibility breaking"      # Alternative phrasing
        "drop support"                # Dropped support
        "drop support for"            # Full phrase
        "removed support"             # Alternative
        "removed support for"         # Full phrase
        "replaced by"                 # Feature replaced
        "replaced with"               # Alternative
        "replaced:"                   # With colon
        "no longer available"         # Feature unavailable
        "will be removed"             # Future removal
        "will be deprecated"          # Future deprecation
        "to be removed"               # Planned removal
        "to be deprecated"            # Planned deprecation
        "must be updated"             # Required update
        "need to update"              # Required action
        "require update"              # Required action
        "requires update"             # Required action
        "signature changed"           # API/function signature change
        "signature changes"           # Plural
        "parameter changes"           # Parameter modifications
        "argument changes"            # Argument modifications
        "return type changed"         # Return type modification
        "interface changed"           # Interface modification
        "interface changes"           # Plural
        "contract changed"            # Contract modification
        "contract changes"            # Plural
        "format changed"              # Format modification
        "schema changed"              # Schema modification
        "schema changes"              # Plural
        "protocol changed"            # Protocol modification
        "protocol changes"            # Plural
    )

    # Check for breaking change patterns
    for pattern in "${breaking_patterns[@]}"; do
        if echo "$notes_lower" | grep -q "$pattern"; then
            return 0  # Breaking changes detected
        fi
    done

    # Also check for common markdown patterns that indicate breaking sections
    if echo "$notes_lower" | grep -q "###\?\s*breaking"; then
        return 0
    fi

    # Check for version bump patterns (e.g., "2.0.0" usually indicates breaking changes)
    if echo "$notes_lower" | grep -qE "major (version )?release|major update|v[0-9]+\.0\.0"; then
        return 0
    fi

    return 1  # No breaking changes detected
}

# Function to get breaking changes summary
# Extracts and returns the breaking changes section from release notes
get_breaking_changes_summary() {
    local release_notes="$1"

    if [[ -z "$release_notes" || "$release_notes" == "null" ]]; then
        return 1
    fi

    # Convert to lowercase for case-insensitive matching
    local notes_lower
    notes_lower=$(echo "$release_notes" | tr '[:upper:]' '[:lower:]')

    # Check if there are breaking changes
    if ! detect_breaking_changes "$release_notes"; then
        return 1
    fi

    # Try to extract breaking changes section
    # Look for common headers like "## Breaking", "### BREAKING CHANGES", etc.
    local breaking_section
    breaking_section=$(echo "$release_notes" | perl -pe '
        BEGIN { undef $/; }
        # Try to match breaking section headers
        if (/(?:^|\n)[#]+\s*\[?(?:BREAKING|Breaking|breaking)[\s:]?(?:CHANGES|Changes)?\]?\s*?\n(.*?)(?:(?:[#]+)|$)/s) {
            print $1;
        }
        elsif (/(?:^|\n)[*-]\s*\[?BREAKING\]?\s*:\s*(.*?)(?:(?:\n[*-])|$)/s) {
            print $1;
        }
    ' 2>/dev/null || true)

    if [[ -n "$breaking_section" ]]; then
        echo "$breaking_section"
        return 0
    fi

    # If no specific section found, return a general message
    return 1
}

# Function to format breaking changes indicator for display
format_breaking_indicator() {
    local has_breaking="$1"

    if [[ "$has_breaking" == "true" || "$has_breaking" == "1" ]]; then
        echo "⚠️"
    else
        echo ""
    fi
}

# Function to add breaking changes prefix to package header
add_breaking_prefix() {
    local package_name="$1"
    local has_breaking="$2"

    if [[ "$has_breaking" == "true" || "$has_breaking" == "1" ]]; then
        echo "⚠️ $package_name (contains breaking changes)"
    else
        echo "$package_name"
    fi
}
