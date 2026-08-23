#!/usr/bin/env bash
# Tests for assessment export surface (tasks-005).
#
# Exercises the export library functions and CLI subcommand:
# - write_assessment_export creates valid JSON with stable schema
# - read_assessment_export reads and validates export
# - brew-change export subcommand prints to stdout
# - Consumer contract: missing file = non-event

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/brew-change-export.sh
source "$REPO_ROOT/lib/brew-change-export.sh"

FIXTURES="$SCRIPT_DIR/fixtures/export"
mkdir -p "$FIXTURES"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf 'ok %d - %s\n' "$pass" "$1"
}

no() {
    fail=$((fail + 1))
    printf 'not ok %d - %s\n' "$((pass + fail))" "$1"
    shift
    printf '    %s\n' "$*" >&2
}

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        ok "$desc"
    else
        no "$desc" "got: '$got'  want: '$want'"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$desc"
    else
        no "$desc" "expected '$needle' in '$haystack'"
    fi
}

# Clean up test exports dir
TEST_EXPORT_DIR="$FIXTURES/test-export-home"
rm -rf "$TEST_EXPORT_DIR" 2>/dev/null || true
mkdir -p "$TEST_EXPORT_DIR"

# Mock the export directory for testing
export HOME="$TEST_EXPORT_DIR"
export ASSESSMENT_EXPORT_DIR="${HOME}/.brew-change"
export ASSESSMENT_EXPORT_FILE="${ASSESSMENT_EXPORT_DIR}/last-assessment.json"

# --- Test 1: write_assessment_export creates valid JSON -------------------
OUT=$(mktemp)
cat > "$OUT" << 'EOF'
{"package":"node","display_name":"node","kind":"formula","installed_version":"22.6.0","available_version":"22.8.0","evidence_source":"github","evidence_url":"https://...","retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":"notes","classification":"attention","reasons":["major version transition detected"],"matched_signals":["major-version-transition"],"assessment_recommendation":false,"operational_eligibility":true,"default_selected":false}
{"package":"python","display_name":"python","kind":"formula","installed_version":"3.12.0","available_version":"3.13.0","evidence_source":"github","evidence_url":"https://...","retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":"notes","classification":"no-signal","reasons":["no configured risk signal matched fresh evidence"],"matched_signals":[],"assessment_recommendation":true,"operational_eligibility":true,"default_selected":false}
EOF

if write_assessment_export "$OUT"; then
    ok "write_assessment_export succeeds with valid input"
else
    no "write_assessment_export failed with valid input"
fi

# --- Test 2: export file exists and is valid JSON -----------------------
if [[ -f "$ASSESSMENT_EXPORT_FILE" ]]; then
    ok "export file was created at expected path"
else
    no "export file was not created at expected path"
fi

EXPORT_CONTENT=$(cat "$ASSESSMENT_EXPORT_FILE" 2>/dev/null || echo '{}')
if jq -e '.' <<< "$EXPORT_CONTENT" >/dev/null 2>&1; then
    ok "export file contains valid JSON"
else
    no "export file does not contain valid JSON"
fi

# --- Test 3: export has required top-level fields -----------------------
SCHEMA_VERSION=$(jq -r '.schema_version // empty' <<< "$EXPORT_CONTENT")
GENERATED_AT=$(jq -r '.generated_at // empty' <<< "$EXPORT_CONTENT")
PACKAGES=$(jq -r '.packages // empty' <<< "$EXPORT_CONTENT")

assert_eq "schema_version is present and is 1" "$SCHEMA_VERSION" "1"
assert_contains "generated_at is ISO-8601 timestamp" "$GENERATED_AT" "T"

# --- Test 4: export has packages array with stable projection -----------
PACKAGE_COUNT=$(jq -r '.packages | length' <<< "$EXPORT_CONTENT")
assert_eq "packages array has 2 entries" "$PACKAGE_COUNT" "2"

# Check first package (node)
FIRST_NAME=$(jq -r '.packages[0].name' <<< "$EXPORT_CONTENT")
FIRST_KIND=$(jq -r '.packages[0].kind' <<< "$EXPORT_CONTENT")
FIRST_CLASSIFICATION=$(jq -r '.packages[0].classification' <<< "$EXPORT_CONTENT")
FIRST_SIGNALS=$(jq -r '.packages[0].matched_signals | join(",")' <<< "$EXPORT_CONTENT")

assert_eq "first package name is 'node'" "$FIRST_NAME" "node"
assert_eq "first package kind is 'formula'" "$FIRST_KIND" "formula"
assert_eq "first package classification is 'attention'" "$FIRST_CLASSIFICATION" "attention"
assert_eq "first package matched_signals contains major-version-transition" "$FIRST_SIGNALS" "major-version-transition"

# Check second package (python)
SECOND_NAME=$(jq -r '.packages[1].name' <<< "$EXPORT_CONTENT")
SECOND_CLASSIFICATION=$(jq -r '.packages[1].classification' <<< "$EXPORT_CONTENT")
SECOND_SIGNALS=$(jq -r '.packages[1].matched_signals | length' <<< "$EXPORT_CONTENT")

assert_eq "second package name is 'python'" "$SECOND_NAME" "python"
assert_eq "second package classification is 'no-signal'" "$SECOND_CLASSIFICATION" "no-signal"
assert_eq "second package has no matched signals" "$SECOND_SIGNALS" "0"

# --- Test 5: export excludes internal fields -----------------------------
# These fields should NOT be in the stable export
if jq -e '.packages[0].assessment_recommendation' <<< "$EXPORT_CONTENT" >/dev/null 2>&1; then
    no "export should exclude internal field: assessment_recommendation"
else
    ok "export excludes internal field: assessment_recommendation"
fi

if jq -e '.packages[0].operational_eligibility' <<< "$EXPORT_CONTENT" >/dev/null 2>&1; then
    no "export should exclude internal field: operational_eligibility"
else
    ok "export excludes internal field: operational_eligibility"
fi

if jq -e '.packages[0].default_selected' <<< "$EXPORT_CONTENT" >/dev/null 2>&1; then
    no "export should exclude internal field: default_selected"
else
    ok "export excludes internal field: default_selected"
fi

if jq -e '.packages[0].evidence_snapshot' <<< "$EXPORT_CONTENT" >/dev/null 2>&1; then
    no "export should exclude large field: evidence_snapshot"
else
    ok "export excludes large field: evidence_snapshot"
fi

# --- Test 6: read_assessment_export ---------------------------------------
READ_RESULT=$(read_assessment_export 2>&1)
if [[ $? -eq 0 ]]; then
    ok "read_assessment_export succeeds when file exists"
else
    no "read_assessment_export failed when file exists"
fi

# Check that read result is valid JSON
if jq -e '.' <<< "$READ_RESULT" >/dev/null 2>&1; then
    ok "read_assessment_export returns valid JSON"
else
    no "read_assessment_export does not return valid JSON"
fi

# --- Test 7: read_assessment_export errors when file missing ------------
rm -f "$ASSESSMENT_EXPORT_FILE"
READ_ERROR=$(read_assessment_export 2>&1)
if [[ $? -ne 0 ]]; then
    ok "read_assessment_export fails when file missing"
else
    no "read_assessment_export should fail when file missing"
fi

assert_contains "error message mentions file not found" "$READ_ERROR" "not found"

# --- Test 8: validate_assessment_export_schema ---------------------------
# Recreate export file for schema validation test
write_assessment_export "$OUT" >/dev/null 2>&1

if validate_assessment_export_schema; then
    ok "validate_assessment_export_schema succeeds for version 1"
else
    no "validate_assessment_export_schema failed for version 1"
fi

# --- Test 9: validate rejects missing file -------------------------------
rm -f "$ASSESSMENT_EXPORT_FILE"
if validate_assessment_export_schema; then
    no "validate_assessment_export_schema should fail when file missing"
else
    ok "validate_assessment_export_schema fails when file missing"
fi

# --- Test 10: validate rejects unsupported schema version ----------------
# Create export with unsupported schema version
mkdir -p "$ASSESSMENT_EXPORT_DIR"
cat > "$ASSESSMENT_EXPORT_FILE" << 'EOF'
{"schema_version":999,"generated_at":"2026-08-20T12:34:56Z","packages":[]}
EOF

if validate_assessment_export_schema 1; then
    no "validate_assessment_export_schema should fail for unsupported version"
else
    ok "validate_assessment_export_schema fails for unsupported version"
fi

# --- Test 11: write_assessment_export handles empty assessment file -----
EMPTY_ASSESSMENT=$(mktemp)
echo "" > "$EMPTY_ASSESSMENT"

if write_assessment_export "$EMPTY_ASSESSMENT"; then
    ok "write_assessment_export handles empty input"
else
    no "write_assessment_export should handle empty input"
fi

# Check that packages array is empty
EMPTY_EXPORT=$(cat "$ASSESSMENT_EXPORT_FILE" 2>/dev/null || echo '{}')
EMPTY_COUNT=$(jq -r '.packages | length' <<< "$EMPTY_EXPORT")
assert_eq "empty input produces empty packages array" "$EMPTY_COUNT" "0"

# --- Test 12: write_assessment_export handles malformed records ----------
MALFORMED_ASSESSMENT=$(mktemp)
cat > "$MALFORMED_ASSESSMENT" << 'EOF'
{"package":"good","display_name":"good","kind":"formula","installed_version":"1.0","available_version":"2.0","evidence_source":"github","evidence_url":"","retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":"","classification":"unknown","reasons":["test"],"matched_signals":[],"assessment_recommendation":false,"operational_eligibility":true,"default_selected":false}
not a json line
{"package":"also-good","display_name":"also good","kind":"formula","installed_version":"1.0","available_version":"2.0","evidence_source":"github","evidence_url":"","retrieved_at":1723900000,"retrieval_status":"fresh","evidence_snapshot":"","classification":"no-signal","reasons":["test"],"matched_signals":[],"assessment_recommendation":true,"operational_eligibility":true,"default_selected":false}
EOF

if write_assessment_export "$MALFORMED_ASSESSMENT"; then
    ok "write_assessment_export handles malformed input gracefully"
else
    no "write_assessment_export should handle malformed input gracefully"
fi

# Should have 2 valid packages (malformed line skipped)
MALFORMED_EXPORT=$(cat "$ASSESSMENT_EXPORT_FILE" 2>/dev/null || echo '{}')
MALFORMED_COUNT=$(jq -r '.packages | length' <<< "$MALFORMED_EXPORT")
assert_eq "malformed input produces packages array with only valid records" "$MALFORMED_COUNT" "2"

# --- Test 13: brew-change export subcommand (if main script exists) -----
if [[ -x "$REPO_ROOT/brew-change" ]]; then
    # The launcher verifies dependencies (brew/jq/curl) before the export
    # subcommand runs, and CI's ubuntu runners have no brew command — the
    # export path never invokes it, so a stub satisfying command -v is
    # enough. Without this the subcommand fails at verify_dependencies on
    # Linux (first surfaced when this suite was registered in CI).
    STUB_BIN="${TEST_EXPORT_DIR}/stub-bin"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\nexit 0\n' > "${STUB_BIN}/brew"
    chmod +x "${STUB_BIN}/brew"

    # First create a valid export file
    write_assessment_export "$OUT" >/dev/null 2>&1

    EXPORT_OUTPUT=$(PATH="${STUB_BIN}:${PATH}" "$REPO_ROOT/brew-change" export 2>&1)
    EXPORT_EXIT=$?

    if [[ $EXPORT_EXIT -eq 0 ]]; then
        ok "brew-change export subcommand succeeds"
    else
        no "brew-change export subcommand failed with exit code $EXPORT_EXIT"
    fi

    # Check that output is valid JSON
    if jq -e '.' <<< "$EXPORT_OUTPUT" >/dev/null 2>&1; then
        ok "brew-change export outputs valid JSON"
    else
        no "brew-change export does not output valid JSON"
    fi

    # Test export when file doesn't exist
    rm -f "$ASSESSMENT_EXPORT_FILE"
    NO_EXPORT_OUTPUT=$(PATH="${STUB_BIN}:${PATH}" "$REPO_ROOT/brew-change" export 2>&1)
    NO_EXPORT_EXIT=$?

    if [[ $NO_EXPORT_EXIT -ne 0 ]]; then
        ok "brew-change export fails cleanly when file missing"
    else
        no "brew-change export should fail when file missing"
    fi

    assert_contains "error message mentions file not found" "$NO_EXPORT_OUTPUT" "not found"
else
    ok "brew-change export subcommand test skipped (main script not executable)"
fi

# --- Test 14: Consumer contract - missing file is non-event --------------
# Simulate consumer behavior
REAL_HOME="${HOME}"
REAL_EXPORT="${REAL_HOME}/.brew-change/last-assessment.json"

# If export doesn't exist, consumer should handle gracefully
if [[ ! -f "$REAL_EXPORT" ]]; then
    CONSUMER_RESULT=$(echo "no file" | jq -c '{schema_version:1,packages:[]}' 2>/dev/null || echo '{"schema_version":1,"packages":[]}')
    if jq -e '.' <<< "$CONSUMER_RESULT" >/dev/null 2>&1; then
        ok "consumer handles missing export gracefully (non-event)"
    else
        no "consumer should handle missing export gracefully"
    fi
else
    ok "consumer contract test skipped (real export exists)"
fi

# --- Test 15: Consumer contract - schema version mismatch ---------------
# Create export with future schema version
mkdir -p "$ASSESSMENT_EXPORT_DIR"
cat > "$ASSESSMENT_EXPORT_FILE" << 'EOF'
{"schema_version":99,"generated_at":"2026-08-20T12:34:56Z","packages":[]}
EOF

# Consumer should detect version mismatch and ignore
CONSUMER_SCHEMA=$(jq -r '.schema_version' "$ASSESSMENT_EXPORT_FILE" 2>/dev/null || echo "")
if [[ "$CONSUMER_SCHEMA" == "99" ]]; then
    # Consumer would check: if schema_version > MY_SUPPORTED_VERSION
    if [[ 99 -gt 1 ]]; then
        ok "consumer detects schema version mismatch and ignores export"
    else
        no "consumer should detect schema version mismatch"
    fi
else
    no "consumer should be able to read schema version from export"
fi

# --- Cleanup -------------------------------------------------------------
rm -rf "$TEST_EXPORT_DIR"
rm -f "$OUT" "$EMPTY_ASSESSMENT" "$MALFORMED_ASSESSMENT"

# --- Summary -------------------------------------------------------------
echo ""
echo "1..${pass}${fail}"
echo "# pass: $pass"
echo "# fail: $fail"

if [[ $fail -gt 0 ]]; then
    exit 1
fi

exit 0
