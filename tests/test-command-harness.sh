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
setup_command_harness
trap teardown_command_harness EXIT

[[ "$(command -v brew)" == "$COMMAND_HARNESS_BIN/brew" ]] || fail "brew did not resolve to the harness"
[[ "$(command -v curl)" == "$COMMAND_HARNESS_BIN/curl" ]] || fail "curl did not resolve to the harness"

configure_fake_command brew "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json" "" 0
brew_output=$(brew outdated --json=v2 --greedy) || fail "configured brew should succeed"
assert_equal "$(cat "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json")" "$brew_output" "brew stdout"

configure_fake_command curl "$SCRIPT_DIR/fixtures/http/not-found.body" "$SCRIPT_DIR/fixtures/http/not-found.stderr" 22
curl_stdout="$COMMAND_HARNESS_ROOT/curl.stdout"
curl_stderr="$COMMAND_HARNESS_ROOT/curl.stderr"
curl_status=0
curl -L --max-time 4 "https://example.invalid/releases?q=a b" >"$curl_stdout" 2>"$curl_stderr" || curl_status=$?
assert_equal "22" "$curl_status" "curl exit status"
assert_equal "$(cat "$SCRIPT_DIR/fixtures/http/not-found.body")" "$(cat "$curl_stdout")" "curl stdout"
assert_equal "$(cat "$SCRIPT_DIR/fixtures/http/not-found.stderr")" "$(cat "$curl_stderr")" "curl stderr"

expected_log=$(printf 'brew\toutdated\t--json=v2\t--greedy\ncurl\t-L\t--max-time\t4\thttps://example.invalid/releases?q=a b')
assert_equal "$expected_log" "$(cat "$COMMAND_HARNESS_LOG")" "tab-separated argv log"

export BREW_CHANGE_TEST_NOW=1700000000
assert_equal "1700000000" "$(brew_change_test_now)" "deterministic current time"
assert_equal "fresh" "$(cache_fixture_state "$SCRIPT_DIR/fixtures/http/cache-fresh.timestamp" 300)" "fresh cache fixture"
assert_equal "stale" "$(cache_fixture_state "$SCRIPT_DIR/fixtures/http/cache-stale.timestamp" 300)" "stale cache fixture"

harness_root="$COMMAND_HARNESS_ROOT"
teardown_command_harness
trap - EXIT
assert_equal "$original_path" "$PATH" "PATH restoration"
[[ ! -e "$harness_root" ]] || fail "temporary harness state was not removed"

printf 'PASS: deterministic command harness\n'
