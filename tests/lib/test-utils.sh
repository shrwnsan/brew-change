#!/bin/bash
# Shared test utilities for brew-change testing
# Provides common functions for test assertion and execution

# Test state tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_OUTPUT_MODE="${TEST_OUTPUT_MODE:-interactive}"  # interactive or ci

# Install deterministic brew/curl executables at the front of PATH. Each call is
# logged as command<TAB>arg... in COMMAND_HARNESS_LOG; no host command is run.
setup_command_harness() {
    if [[ -n "${COMMAND_HARNESS_ROOT:-}" ]]; then
        teardown_command_harness
    fi

    COMMAND_HARNESS_ORIGINAL_PATH="$PATH"
    if [[ ${BREW_CHANGE_TEST_NOW+x} ]]; then
        COMMAND_HARNESS_ORIGINAL_NOW_SET=1
        COMMAND_HARNESS_ORIGINAL_NOW="$BREW_CHANGE_TEST_NOW"
    else
        COMMAND_HARNESS_ORIGINAL_NOW_SET=0
        COMMAND_HARNESS_ORIGINAL_NOW=""
    fi
    COMMAND_HARNESS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/brew-change-harness.XXXXXX") || return 1
    COMMAND_HARNESS_BIN="$COMMAND_HARNESS_ROOT/bin"
    COMMAND_HARNESS_CONFIG="$COMMAND_HARNESS_ROOT/config"
    COMMAND_HARNESS_LOG="$COMMAND_HARNESS_ROOT/argv.log"
    mkdir -p "$COMMAND_HARNESS_BIN" "$COMMAND_HARNESS_CONFIG" || return 1
    : >"$COMMAND_HARNESS_LOG"
    COMMAND_HARNESS_SENTINEL="harness-$$-$RANDOM"
    printf '%s\n' "$COMMAND_HARNESS_SENTINEL" >"$COMMAND_HARNESS_ROOT/sentinel"
    export COMMAND_HARNESS_ROOT COMMAND_HARNESS_BIN COMMAND_HARNESS_CONFIG COMMAND_HARNESS_LOG COMMAND_HARNESS_SENTINEL

    local command_name
    for command_name in brew curl; do
        cat >"$COMMAND_HARNESS_BIN/$command_name" <<'EOF'
#!/bin/bash
command_name=${0##*/}
IFS= read -r expected_sentinel <"$COMMAND_HARNESS_ROOT/sentinel" || exit 125
[[ "$COMMAND_HARNESS_SENTINEL" == "$expected_sentinel" ]] || exit 125
config="$COMMAND_HARNESS_CONFIG/$command_name"
[[ -d "$config" ]] || exit 125
: >"$COMMAND_HARNESS_ROOT/$command_name.invoked"
{
    printf '%s' "$command_name"
    for argument in "$@"; do
        printf '\t%s' "$argument"
    done
    printf '\n'
} >>"$COMMAND_HARNESS_LOG"
if [[ -n "${COMMAND_HARNESS_ENV_LOG:-}" && -n "${COMMAND_HARNESS_ENV_CAPTURE_VARS:-}" ]]; then
    saved_ifs="$IFS"
    IFS=':'
    for env_name in $COMMAND_HARNESS_ENV_CAPTURE_VARS; do
        printf '%s=%s\n' "$env_name" "${!env_name:-}" >>"$COMMAND_HARNESS_ENV_LOG"
    done
    IFS="$saved_ifs"
    printf '%s\n' '---ENV-SEP---' >>"$COMMAND_HARNESS_ENV_LOG"
fi
if [[ "$command_name" == curl ]]; then
    headers_target=""
    write_out=""
    effective_url=""
    while (( $# )); do
        case "$1" in
            -D|--dump-header) headers_target="${2:-}"; shift 2; continue ;;
            -w|--write-out) write_out="${2:-}"; shift 2; continue ;;
            http://*|https://*) effective_url="$1" ;;
        esac
        shift
    done
    if [[ -n "$headers_target" && -f "$config/headers" ]]; then
        if [[ "$headers_target" == - ]]; then cat "$config/headers"; else cat "$config/headers" >"$headers_target"; fi
    fi
fi
[[ -f "$config/stdout" ]] && cat "$config/stdout"
[[ -f "$config/stderr" ]] && cat "$config/stderr" >&2
if [[ "$command_name" == curl && -n "$write_out" ]]; then
    http_status=000
    redirect_url=""
    [[ ! -f "$config/http-status" ]] || IFS= read -r http_status <"$config/http-status"
    [[ ! -f "$config/redirect-url" ]] || IFS= read -r redirect_url <"$config/redirect-url"
    write_out=${write_out//'%{http_code}'/$http_status}
    write_out=${write_out//'%{response_code}'/$http_status}
    write_out=${write_out//'%{url_effective}'/$effective_url}
    write_out=${write_out//'%{redirect_url}'/$redirect_url}
    printf '%b' "$write_out"
fi
status=0
[[ -f "$config/status" ]] && IFS= read -r status <"$config/status"
exit "$status"
EOF
        chmod +x "$COMMAND_HARNESS_BIN/$command_name"
    done
    PATH="$COMMAND_HARNESS_BIN:$PATH"
    export PATH
}

# Extend the default command harness to optionally capture selected env vars
# from fake commands. Creates COMMAND_HARNESS_ENV_LOG containing captured
# environment values separated by "---ENV-SEP---" per invocation.
#
# Args:
#   $1...: Environment variable names to capture (e.g., HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP)
# If called with no args, env capture is disabled (default).
#
# NOTE: Uses a colon-separated string (COMMAND_HARNESS_ENV_CAPTURE_VARS) rather
# than an array, because bash arrays cannot be exported to child processes.
configure_harness_env_capture() {
    if [[ $# -gt 0 ]]; then
        # Join args with colon for export (array can't be exported)
        local _IFS="$IFS"; IFS=':'; COMMAND_HARNESS_ENV_CAPTURE_VARS="$*"; IFS="$_IFS"
        COMMAND_HARNESS_ENV_LOG="$COMMAND_HARNESS_ROOT/env.log"
        : >"$COMMAND_HARNESS_ENV_LOG"
        export COMMAND_HARNESS_ENV_LOG COMMAND_HARNESS_ENV_CAPTURE_VARS
    else
        unset COMMAND_HARNESS_ENV_LOG COMMAND_HARNESS_ENV_CAPTURE_VARS
    fi
}

# Configure curl response metadata from a status fixture containing
# "HTTP_STATUS [REDIRECT_URL]" and an optional raw response-headers fixture.
configure_fake_curl_metadata() {
    local status_fixture="$1"
    local headers_fixture="${2:-}"
    local http_status redirect_url
    read -r http_status redirect_url <"$status_fixture" || return 1
    case "$http_status" in ???) ;; *) return 2 ;; esac
    mkdir -p "$COMMAND_HARNESS_CONFIG/curl" || return 1
    printf '%s\n' "$http_status" >"$COMMAND_HARNESS_CONFIG/curl/http-status"
    printf '%s\n' "${redirect_url:-}" >"$COMMAND_HARNESS_CONFIG/curl/redirect-url"
    rm -f "$COMMAND_HARNESS_CONFIG/curl/headers"
    [[ -z "$headers_fixture" ]] || cp "$headers_fixture" "$COMMAND_HARNESS_CONFIG/curl/headers" || return 1
}

# Configure a fake command with stdout/stderr fixture paths and an exit status.
# Empty fixture paths produce no output. Files are copied into temporary state.
configure_fake_command() {
    local command_name="$1"
    local stdout_fixture="${2:-}"
    local stderr_fixture="${3:-}"
    local status="${4:-0}"
    local config="$COMMAND_HARNESS_CONFIG/$command_name"

    case "$command_name" in brew|curl) ;; *) return 2 ;; esac
    case "$status" in ''|*[!0-9]*) return 2 ;; esac
    mkdir -p "$config" || return 1
    rm -f "$config/stdout" "$config/stderr"
    [[ -z "$stdout_fixture" ]] || cp "$stdout_fixture" "$config/stdout" || return 1
    [[ -z "$stderr_fixture" ]] || cp "$stderr_fixture" "$config/stderr" || return 1
    printf '%s\n' "$status" >"$config/status"
}

# Restore PATH and delete all temporary command configuration and logs.
teardown_command_harness() {
    if [[ -n "${COMMAND_HARNESS_ORIGINAL_PATH:-}" ]]; then
        PATH="$COMMAND_HARNESS_ORIGINAL_PATH"
        export PATH
    fi
    if [[ "${COMMAND_HARNESS_ORIGINAL_NOW_SET:-0}" == 1 ]]; then
        BREW_CHANGE_TEST_NOW="$COMMAND_HARNESS_ORIGINAL_NOW"
        export BREW_CHANGE_TEST_NOW
    else
        unset BREW_CHANGE_TEST_NOW
    fi
    [[ -z "${COMMAND_HARNESS_ROOT:-}" ]] || rm -rf "$COMMAND_HARNESS_ROOT"
    unset COMMAND_HARNESS_ROOT COMMAND_HARNESS_BIN COMMAND_HARNESS_CONFIG COMMAND_HARNESS_LOG COMMAND_HARNESS_SENTINEL
    unset COMMAND_HARNESS_ENV_LOG COMMAND_HARNESS_ENV_CAPTURE_VARS
    unset COMMAND_HARNESS_ORIGINAL_PATH COMMAND_HARNESS_ORIGINAL_NOW_SET COMMAND_HARNESS_ORIGINAL_NOW
}

# Return an explicitly injected epoch, falling back to the system clock.
brew_change_test_now() {
    if [[ -n "${BREW_CHANGE_TEST_NOW:-}" ]]; then
        printf '%s\n' "$BREW_CHANGE_TEST_NOW"
    else
        date +%s
    fi
}

# Classify a fixture timestamp against the injected/current time and max age.
cache_fixture_state() {
    local timestamp_file="$1"
    local max_age="$2"
    local timestamp
    IFS= read -r timestamp <"$timestamp_file" || return 1
    if (( $(brew_change_test_now) - timestamp <= max_age )); then
        printf 'fresh\n'
    else
        printf 'stale\n'
    fi
}

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

# Assert that command output contains expected string, ignoring exit code
# Use for error-path tests where non-zero exit is expected
# Usage: assert_output_contains "test_name" "expected_string" command [args...]
assert_output_contains() {
    local test_name="$1"
    local expected="$2"
    shift 2
    local output

    output=$("$@" 2>&1) || true

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
