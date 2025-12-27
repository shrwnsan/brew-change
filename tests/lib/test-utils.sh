#!/bin/bash
# Shared test utilities for brew-change testing
# Provides common functions for test assertion and execution

# Test state tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_OUTPUT_MODE="${TEST_OUTPUT_MODE:-interactive}"  # interactive or ci

# Colors (only used in interactive mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Detect brew-change command location
# Returns the command to use (either "brew-change" or "./brew-change")
# Exits with error if command is not found
get_brew_change_cmd() {
    if command -v brew-change >/dev/null 2>&1; then
        echo "brew-change"
    elif [[ -f "./brew-change" ]]; then
        echo "./brew-change"
    elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../../brew-change" ]]; then
        echo "$(dirname "${BASH_SOURCE[0]}")/../../brew-change"
    else
        log_error "brew-change command not found"
        log_info "Try: export PATH=\"\$(pwd):\$PATH\""
        return 1
    fi
}

# Setup test environment
# Ensures required dependencies are available
setup_test_environment() {
    local brew_change_cmd
    brew_change_cmd=$(get_brew_change_cmd) || return 1
    
    # Verify brew-change is executable
    if [[ ! -x "$brew_change_cmd" ]]; then
        log_error "brew-change is not executable: $brew_change_cmd"
        log_info "Run: chmod +x $brew_change_cmd"
        return 1
    fi
    
    return 0
}

# Logging functions
log_info() {
    if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
        echo "[INFO] $*"
    else
        echo -e "${BLUE}ℹ️  $*${NC}"
    fi
}

log_success() {
    if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
        echo "[PASS] $*"
    else
        echo -e "${GREEN}✅ $*${NC}"
    fi
}

log_error() {
    if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
        echo "[FAIL] $*" >&2
    else
        echo -e "${RED}❌ $*${NC}" >&2
    fi
}

log_warning() {
    if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
        echo "[WARN] $*"
    else
        echo -e "${YELLOW}⚠️  $*${NC}"
    fi
}

# Record test result
log_test_result() {
    local test_name="$1"
    local result="$2"  # "pass" or "fail"
    local message="${3:-}"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$result" == "pass" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        if [[ -n "$message" ]]; then
            log_success "$test_name: $message"
        else
            log_success "$test_name"
        fi
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        if [[ -n "$message" ]]; then
            log_error "$test_name: $message"
        else
            log_error "$test_name"
        fi
    fi
}

# Print test summary
print_test_summary() {
    echo ""
    if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
        echo "===== TEST SUMMARY ====="
        echo "Tests run: $TESTS_RUN"
        echo "Passed: $TESTS_PASSED"
        echo "Failed: $TESTS_FAILED"
        echo "======================="
    else
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║         TEST SUMMARY                 ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} Tests run:    ${YELLOW}$TESTS_RUN${NC}"
        echo -e "${CYAN}║${NC} Passed:       ${GREEN}$TESTS_PASSED${NC}"
        echo -e "${CYAN}║${NC} Failed:       ${RED}$TESTS_FAILED${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    fi
    echo ""
}

# Get exit code based on test results
get_test_exit_code() {
    if [[ $TESTS_FAILED -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Assert that a command succeeds
# Usage: assert_command_success "test_name" command [args...]
assert_command_success() {
    local test_name="$1"
    shift
    local output
    local exit_code
    
    output=$("$@" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}
    
    if [[ $exit_code -eq 0 ]]; then
        log_test_result "$test_name" "pass"
        return 0
    else
        log_test_result "$test_name" "fail" "Command failed with exit code $exit_code"
        if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
            echo "Command output:" >&2
            echo "$output" >&2
        fi
        return 1
    fi
}

# Assert that a command fails (non-zero exit code)
# Usage: assert_command_fails "test_name" command [args...]
assert_command_fails() {
    local test_name="$1"
    shift
    local output
    local exit_code
    
    output=$("$@" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}
    
    if [[ $exit_code -ne 0 ]]; then
        log_test_result "$test_name" "pass"
        return 0
    else
        log_test_result "$test_name" "fail" "Command should have failed but succeeded"
        return 1
    fi
}

# Assert that command output contains expected string
# Usage: assert_command_output_contains "test_name" "expected_string" command [args...]
assert_command_output_contains() {
    local test_name="$1"
    local expected="$2"
    shift 2
    local output
    local exit_code
    
    output=$("$@" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}
    
    if [[ $exit_code -ne 0 ]]; then
        log_test_result "$test_name" "fail" "Command failed with exit code $exit_code"
        return 1
    fi
    
    if echo "$output" | grep -q "$expected"; then
        log_test_result "$test_name" "pass"
        return 0
    else
        log_test_result "$test_name" "fail" "Output does not contain expected string: '$expected'"
        if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
            echo "Command output:" >&2
            echo "$output" >&2
        fi
        return 1
    fi
}

# Assert that command output does NOT contain string
# Usage: assert_command_output_not_contains "test_name" "unexpected_string" command [args...]
assert_command_output_not_contains() {
    local test_name="$1"
    local unexpected="$2"
    shift 2
    local output
    local exit_code
    
    output=$("$@" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}
    
    if [[ $exit_code -ne 0 ]]; then
        log_test_result "$test_name" "fail" "Command failed with exit code $exit_code"
        return 1
    fi
    
    if echo "$output" | grep -q "$unexpected"; then
        log_test_result "$test_name" "fail" "Output contains unexpected string: '$unexpected'"
        if [[ "$TEST_OUTPUT_MODE" == "ci" ]]; then
            echo "Command output:" >&2
            echo "$output" >&2
        fi
        return 1
    else
        log_test_result "$test_name" "pass"
        return 0
    fi
}

# Run a command and capture output for manual inspection
# Usage: run_command_capture_output command [args...]
# Returns: Sets $COMMAND_OUTPUT and $COMMAND_EXIT_CODE
run_command_capture_output() {
    COMMAND_OUTPUT=$("$@" 2>&1) || COMMAND_EXIT_CODE=$?
    COMMAND_EXIT_CODE=${COMMAND_EXIT_CODE:-0}
}

# Check if running in CI mode
is_ci_mode() {
    [[ "$TEST_OUTPUT_MODE" == "ci" ]]
}

# Wait for user input (only in interactive mode)
wait_for_user() {
    if ! is_ci_mode; then
        read -p "Press Enter to continue..."
    fi
}
