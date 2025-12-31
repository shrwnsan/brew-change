#!/bin/bash
# Tests for breaking changes detection functionality

# Get script directory for loading utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for --ci flag
CI_MODE=false
if [[ "$1" == "--ci" ]]; then
    CI_MODE=true
    export TEST_OUTPUT_MODE="ci"
fi

# Load test utilities
source "$SCRIPT_DIR/lib/test-utils.sh"

# Load breaking changes detection functions
source "$(dirname "$SCRIPT_DIR")/lib/brew-change-breaking.sh"

# Test suite for breaking changes detection
test_breaking_changes_detection() {
    log_info "Testing breaking changes detection..."

    # Test 1: Basic "Breaking Changes" pattern
    local test_notes="Breaking Changes in API"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Breaking Changes Pattern" "pass"
    else
        log_test_result "Breaking Changes Pattern" "fail" "Failed to detect 'Breaking Changes'"
    fi

    # Test 2: "deprecated:" pattern
    test_notes="## Deprecated
This function is deprecated:"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Deprecated Pattern" "pass"
    else
        log_test_result "Deprecated Pattern" "fail" "Failed to detect 'deprecated:'"
    fi

    # Test 3: "removed support" pattern
    test_notes="We have removed support for old API"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Removed Support Pattern" "pass"
    else
        log_test_result "Removed Support Pattern" "fail" "Failed to detect 'removed support'"
    fi

    # Test 4: "incompatible" pattern
    test_notes="This version is incompatible with previous versions"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Incompatible Pattern" "pass"
    else
        log_test_result "Incompatible Pattern" "fail" "Failed to detect 'incompatible'"
    fi

    # Test 5: "not backward compatible" pattern
    test_notes="⚠️ This version is not backward compatible"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Not Backward Compatible Pattern" "pass"
    else
        log_test_result "Not Backward Compatible Pattern" "fail" "Failed to detect 'not backward compatible'"
    fi

    # Test 6: "migration required" pattern
    test_notes="Migration required for this version"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Migration Required Pattern" "pass"
    else
        log_test_result "Migration Required Pattern" "fail" "Failed to detect 'migration required'"
    fi

    # Test 7: "drop support" pattern
    test_notes="We will drop support for Python 3.7"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Drop Support Pattern" "pass"
    else
        log_test_result "Drop Support Pattern" "fail" "Failed to detect 'drop support'"
    fi

    # Test 8: "replaced by" pattern
    test_notes="The old API is replaced by new API"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Replaced By Pattern" "pass"
    else
        log_test_result "Replaced By Pattern" "fail" "Failed to detect 'replaced by'"
    fi

    # Test 9: Negative case - no breaking changes
    test_notes="Added new feature and fixed bug. Improved performance."
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Negative Case (No Breaking)" "fail" "False positive detected"
    else
        log_test_result "Negative Case (No Breaking)" "pass"
    fi

    # Test 10: Case insensitivity
    test_notes="BREAKING CHANGES: Major API overhaul"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Case Insensitivity" "pass"
    else
        log_test_result "Case Insensitivity" "fail" "Failed to detect uppercase 'BREAKING CHANGES'"
    fi

    # Test 11: Markdown header pattern
    test_notes="### Breaking
- Removed deprecated function
- Changed API signature"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Markdown Header Pattern" "pass"
    else
        log_test_result "Markdown Header Pattern" "fail" "Failed to detect '### Breaking' header"
    fi

    # Test 12: "will be removed" pattern
    test_notes="This feature will be removed in version 2.0"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Will Be Removed Pattern" "pass"
    else
        log_test_result "Will Be Removed Pattern" "fail" "Failed to detect 'will be removed'"
    fi

    # Test 13: "to be deprecated" pattern
    test_notes="The old API is to be deprecated"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "To Be Deprecated Pattern" "pass"
    else
        log_test_result "To Be Deprecated Pattern" "fail" "Failed to detect 'to be deprecated'"
    fi

    # Test 14: "signature changed" pattern
    test_notes="Function signature changed for better error handling"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Signature Changed Pattern" "pass"
    else
        log_test_result "Signature Changed Pattern" "fail" "Failed to detect 'signature changed'"
    fi

    # Test 15: "schema changed" pattern
    test_notes="Database schema changed - migration required"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Schema Changed Pattern" "pass"
    else
        log_test_result "Schema Changed Pattern" "fail" "Failed to detect 'schema changed'"
    fi

    # Test 16: Empty input
    test_notes=""
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Empty Input" "fail" "False positive on empty input"
    else
        log_test_result "Empty Input" "pass"
    fi

    # Test 17: Multi-line release notes with breaking changes
    test_notes="## What's Changed
* Added new feature
* Fixed bug

## Breaking Changes
- Removed old API endpoint
- Changed authentication method"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Multi-line Release Notes" "pass"
    else
        log_test_result "Multi-line Release Notes" "fail" "Failed to detect breaking in multi-line notes"
    fi

    # Test 18: "api changes" pattern
    test_notes="API changes in this version require update"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "API Changes Pattern" "pass"
    else
        log_test_result "API Changes Pattern" "fail" "Failed to detect 'api changes'"
    fi

    # Test 19: "behavior changes" pattern
    test_notes="Default behavior changes for consistency"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "Behavior Changes Pattern" "pass"
    else
        log_test_result "Behavior Changes Pattern" "fail" "Failed to detect 'behavior changes'"
    fi

    # Test 20: "no longer available" pattern
    test_notes="This option is no longer available"
    if detect_breaking_changes "$test_notes"; then
        log_test_result "No Longer Available Pattern" "pass"
    else
        log_test_result "No Longer Available Pattern" "fail" "Failed to detect 'no longer available'"
    fi
}

# Test suite for format_breaking_indicator function
test_format_breaking_indicator() {
    log_info "Testing format_breaking_indicator function..."

    # Test with breaking changes
    local result
    result=$(format_breaking_indicator "true")
    if [[ "$result" == "⚠️" ]]; then
        log_test_result "Format Indicator (Breaking)" "pass"
    else
        log_test_result "Format Indicator (Breaking)" "fail" "Expected '⚠️', got '$result'"
    fi

    # Test without breaking changes
    result=$(format_breaking_indicator "false")
    if [[ -z "$result" ]]; then
        log_test_result "Format Indicator (No Breaking)" "pass"
    else
        log_test_result "Format Indicator (No Breaking)" "fail" "Expected empty, got '$result'"
    fi
}

# Test suite for add_breaking_prefix function
test_add_breaking_prefix() {
    log_info "Testing add_breaking_prefix function..."

    # Test with breaking changes
    local result
    result=$(add_breaking_prefix "mypackage" "true")
    if [[ "$result" == "⚠️ mypackage (contains breaking changes)" ]]; then
        log_test_result "Breaking Prefix (Breaking)" "pass"
    else
        log_test_result "Breaking Prefix (Breaking)" "fail" "Unexpected result: '$result'"
    fi

    # Test without breaking changes
    result=$(add_breaking_prefix "mypackage" "false")
    if [[ "$result" == "mypackage" ]]; then
        log_test_result "Breaking Prefix (No Breaking)" "pass"
    else
        log_test_result "Breaking Prefix (No Breaking)" "fail" "Expected 'mypackage', got '$result'"
    fi
}

# Main test execution
main() {
    log_info "Starting breaking changes detection tests..."
    echo ""

    test_breaking_changes_detection
    echo ""
    test_format_breaking_indicator
    echo ""
    test_add_breaking_prefix
    echo ""

    # Print summary
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All breaking changes tests passed! ($TESTS_PASSED/$TESTS_RUN)"
        return 0
    else
        log_error "Some tests failed ($TESTS_FAILED/$TESTS_RUN failed, $TESTS_PASSED/$TESTS_RUN passed)"
        return 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
