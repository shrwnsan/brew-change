#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-utils.sh
source "$SCRIPT_DIR/lib/test-utils.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

original_path="$PATH"
export BREW_CHANGE_TEST_NOW="preexisting-value"
setup_command_harness
trap teardown_command_harness EXIT

[[ "$(command -v brew)" == "$COMMAND_HARNESS_BIN/brew" ]] || fail "brew did not resolve to the harness"
[[ "$(command -v curl)" == "$COMMAND_HARNESS_BIN/curl" ]] || fail "curl did not resolve to the harness"

configure_fake_command brew "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json" "" 0
brew_output=$(brew outdated --json=v2 --greedy) || fail "configured brew should succeed"
assert_equal "$(cat "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json")" "$brew_output" "brew stdout"
assert_equal "array" "$(jq -r '.casks[] | select(.token == "visual-app") | .name | type' "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json")" "string-token cask name type"
assert_equal "false" "$(jq -r '[.casks[] | has("names")] | any' "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json")" "casks omit nonstandard names field"
assert_equal "array" "$(jq -r '.casks[] | select(.token == null) | .name | type' "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json")" "null-token cask name fallback"

configure_fake_command curl "$SCRIPT_DIR/fixtures/http/not-found.body" "$SCRIPT_DIR/fixtures/http/not-found.stderr" 22
curl_stdout="$COMMAND_HARNESS_ROOT/curl.stdout"
curl_stderr="$COMMAND_HARNESS_ROOT/curl.stderr"
curl_status=0
curl -L --max-time 4 "https://example.invalid/releases?q=a b" >"$curl_stdout" 2>"$curl_stderr" || curl_status=$?
assert_equal "22" "$curl_status" "curl exit status"
assert_equal "$(cat "$SCRIPT_DIR/fixtures/http/not-found.body")" "$(cat "$curl_stdout")" "curl stdout"
assert_equal "$(cat "$SCRIPT_DIR/fixtures/http/not-found.stderr")" "$(cat "$curl_stderr")" "curl stderr"

configure_fake_command curl "$SCRIPT_DIR/fixtures/http/redirect-allowed.body" "" 0
configure_fake_curl_metadata "$SCRIPT_DIR/fixtures/http/redirect-allowed.status" "$SCRIPT_DIR/fixtures/http/redirect-allowed.headers"
curl_headers="$COMMAND_HARNESS_ROOT/curl.headers"
curl_metadata=$(curl -D "$curl_headers" -w '%{http_code}\t%{url_effective}\t%{redirect_url}' "https://example.invalid/start") || fail "metadata curl should succeed"
assert_equal $'redirect accepted\n302\thttps://example.invalid/start\thttps://github.com/example/project/releases' "$curl_metadata" "curl write-out metadata"
assert_equal "$(cat "$SCRIPT_DIR/fixtures/http/redirect-allowed.headers")" "$(cat "$curl_headers")" "curl response headers"

expected_log=$(printf 'brew\toutdated\t--json=v2\t--greedy\ncurl\t-L\t--max-time\t4\thttps://example.invalid/releases?q=a b\ncurl\t-D\t%s\t-w\t%%{http_code}\\t%%{url_effective}\\t%%{redirect_url}\thttps://example.invalid/start' "$curl_headers")
assert_equal "$expected_log" "$(cat "$COMMAND_HARNESS_LOG")" "tab-separated argv log"
[[ -f "$COMMAND_HARNESS_ROOT/brew.invoked" ]] || fail "fake brew invocation sentinel missing"
[[ -f "$COMMAND_HARNESS_ROOT/curl.invoked" ]] || fail "fake curl invocation sentinel missing"

export BREW_CHANGE_TEST_NOW=1700000000
assert_equal "1700000000" "$(brew_change_test_now)" "deterministic current time"
assert_equal "fresh" "$(cache_fixture_state "$SCRIPT_DIR/fixtures/http/cache-fresh.timestamp" 300)" "fresh cache fixture"
assert_equal "stale" "$(cache_fixture_state "$SCRIPT_DIR/fixtures/http/cache-stale.timestamp" 300)" "stale cache fixture"

harness_root="$COMMAND_HARNESS_ROOT"
teardown_command_harness
trap - EXIT
assert_equal "$original_path" "$PATH" "PATH restoration"
assert_equal "preexisting-value" "$BREW_CHANGE_TEST_NOW" "BREW_CHANGE_TEST_NOW restoration"
[[ ! -e "$harness_root" ]] || fail "temporary harness state was not removed"

unset BREW_CHANGE_TEST_NOW
setup_command_harness
export BREW_CHANGE_TEST_NOW=1700000000
teardown_command_harness
[[ ! ${BREW_CHANGE_TEST_NOW+x} ]] || fail "previously unset BREW_CHANGE_TEST_NOW was not unset"

printf 'PASS: deterministic command harness\n'
