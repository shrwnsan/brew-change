#!/usr/bin/env bash
# research-009 §1c — npm→GitHub notes fallback.
#
# Field origin: `vercel 58→59` rendered as major-only attention with "no
# notes" in both the v1.16.0 and v1.17.0 runs, while the notes exist as
# per-package changeset releases on github.com/vercel/vercel (tag
# `vercel@59.0.0`) — the npm-first path never looked there because the
# homepage is not GitHub.
#
# Deterministic assertions:
#   1. get_npm_github_repo resolves owner/repo from npm registry
#      metadata (object url, shorthand, plain string) and fails clean
#      without a repository field or a fetchable registry document.
#   2. Display wiring (fetch functions shadowed — no network, no shared
#      harness changes): the vercel-class package resolves its GitHub
#      repo from registry metadata, fetches the GitHub release, renders
#      its body, and records evidence with source github.
#   3. Regression guards: no repository field keeps today's non-GitHub
#      path (no GitHub fetch attempted); npm packages with a GitHub
#      homepage keep today's no-extra-fetch behavior.
#
# Usage: bash tests/test-npm-github-fallback.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test-utils.sh"
setup_command_harness || exit 1

export BREW_CHANGE_SUBPROCESS="true"
export BREW_CHANGE_CACHE_DIR="$COMMAND_HARNESS_ROOT/cache"
mkdir -p "$BREW_CHANGE_CACHE_DIR"

# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-config.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-utils.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-breaking.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-assessment.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-github.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-npm.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-brew.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-non-github.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/brew-change-display.sh"

IDENTIFY_BREAKING="${IDENTIFY_BREAKING:-false}"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
        ((pass++))
    else
        echo "FAIL: $desc (expected='$expected', actual='$actual')" >&2
        ((fail++))
    fi
}

assert_contains() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo "PASS: $desc"
        ((pass++))
    else
        echo "FAIL: $desc (expected to contain '$expected')" >&2
        ((fail++))
    fi
}

assert_not_contains() {
    local desc="$1" unexpected="$2" actual="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then
        echo "PASS: $desc"
        ((pass++))
    else
        echo "FAIL: $desc (should not contain '$unexpected')" >&2
        ((fail++))
    fi
}

registry_json() { cat "$COMMAND_HARNESS_CONFIG/curl/stdout"; }

# Configure fake curl to serve $1 as a successful (HTTP 200) response
# body. Without the 200 status fixture the fake curl reports 000 and
# fetch_url_with_retry (correctly) fails every fetch.
fake_curl_json() {
    configure_fake_command curl "" "" 0
    printf '%s' "$1" > "$COMMAND_HARNESS_CONFIG/curl/stdout"
    printf '200\n' > "$COMMAND_HARNESS_ROOT/http-status"
    configure_fake_curl_metadata "$COMMAND_HARNESS_ROOT/http-status"
}

github_fetch_marker="$COMMAND_HARNESS_ROOT/github-fetched"
run_dir=""
setup_run() {
    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-change-npmfb.XXXXXX")
    export UPGRADE_STATUS_DIR="$run_dir"
}
teardown_run() {
    unset UPGRADE_STATUS_DIR
    [[ -z "$run_dir" ]] || rm -rf "$run_dir"
    run_dir=""
}

# Shadow the fetch surface (no network): the registry document comes from
# fake curl (single-stdout is fine — every registry call wants the same
# doc); the GitHub release is a function shadow with a call canary.
shadow_github_release() {
    fetch_github_release() {
        touch "$github_fetch_marker"
        printf '%s' '{"tag_name":"vercel@59.1.4","html_url":"https://github.com/vercel/vercel/releases/tag/vercel@59.1.4","published_at":"2026-08-11T00:00:00Z","body":"## Major Changes\n- Removed the legacy builder; deploy hooks must migrate."}'
        return 0
    }
}
unshadow_github_release() {
    unset -f fetch_github_release
}

vercel_brew_info='{"homepage":"https://vercel.com/home","urls":{"stable":{"url":"https://registry.npmjs.org/vercel"}}}'

trap 'teardown_run; unshadow_github_release; teardown_command_harness' EXIT

echo "======================================"
echo "npm→GitHub Notes Fallback Tests (research-009 §1c)"
echo "======================================"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 1: get_npm_github_repo over registry metadata ==="
echo ""

fake_curl_json '{"name":"vercel","time":{"59.1.4":"2026-08-11T00:00:00Z"},"repository":{"type":"git","url":"git+https://github.com/vercel/vercel.git"}}'
result=$(get_npm_github_repo "https://registry.npmjs.org/vercel" 2>/dev/null)
assert_eq "object repository url resolves" "vercel/vercel" "$result"

fake_curl_json '{"repository":"github:foo/bar"}'
result=$(get_npm_github_repo "https://registry.npmjs.org/foo-bar" 2>/dev/null)
assert_eq "github: shorthand resolves" "foo/bar" "$result"

fake_curl_json '{"repository":"https://github.com/a/b.git"}'
result=$(get_npm_github_repo "https://registry.npmjs.org/b" 2>/dev/null)
assert_eq "plain string repository resolves" "a/b" "$result"

fake_curl_json '{"name":"x","time":{"1.0.0":"2026-01-01T00:00:00Z"}}'
get_npm_github_repo "https://registry.npmjs.org/x" >/dev/null 2>&1
assert_eq "no repository field fails clean" "1" "$?"

# Genuine fetch failure: curl exits nonzero.
configure_fake_command curl "" "" 1
get_npm_github_repo "https://registry.npmjs.org/unreachable" >/dev/null 2>&1
assert_eq "registry fetch failure fails clean" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: vercel-class display wiring ==="
echo ""

# Real registry metadata (date + repository), shadowed GitHub release.
fake_curl_json '{"name":"vercel","time":{"59.1.4":"2026-08-11T00:00:00Z"},"repository":{"type":"git","url":"git+https://github.com/vercel/vercel.git"}}'
shadow_github_release
setup_run
rm -f "$github_fetch_marker"
display_out=$(_show_package_changelog_full_body "vercel" "58.9.0" "59.1.4" "$vercel_brew_info" 2>/dev/null)

assert_eq "GitHub release fetched via fallback" "1" "$([[ -f "$github_fetch_marker" ]] && echo 1 || echo 0)"
assert_contains "GitHub body rendered" "Removed the legacy builder" "$display_out"
assert_contains "release link rendered" "https://github.com/vercel/vercel/releases/tag/vercel@59.1.4" "$display_out"

# Evidence rows append in stage order (an inventory/major-version row
# may precede the evidence row; consolidation merges by package), so the
# fetched evidence is the LAST row for the package.
evidence_row=$(grep -F '"package":"vercel"' "$run_dir/evidence.jsonl" 2>/dev/null | tail -1)
assert_contains "evidence source is github" '"evidence_source":"github"' "${evidence_row:-}"
assert_contains "evidence url is the GitHub release" '"evidence_url":"https://github.com/vercel/vercel/releases/tag/vercel@59.1.4"' "${evidence_row:-}"
assert_contains "evidence snapshot carries the body" "Removed the legacy builder" "${evidence_row:-}"

teardown_run
unshadow_github_release

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: regression guards ==="
echo ""

# No repository field: today's non-GitHub path, no GitHub fetch.
fake_curl_json '{"name":"e2b","time":{"2.16.2":"2026-08-02T00:00:00Z"}}'
shadow_github_release
setup_run
rm -f "$github_fetch_marker"
e2b_info='{"homepage":"https://e2b.dev","urls":{"stable":{"url":"https://registry.npmjs.org/e2b"}}}'
display_out=$(_show_package_changelog_full_body "e2b" "2.16.1" "2.16.2" "$e2b_info" 2>/dev/null)

assert_eq "no repository field: no GitHub fetch" "0" "$([[ -f "$github_fetch_marker" ]] && echo 1 || echo 0)"
assert_contains "non-GitHub search path preserved" "Searching for release notes from registry.npmjs.org" "$display_out"
evidence_row=$(grep -F '"package":"e2b"' "$run_dir/evidence.jsonl" 2>/dev/null | head -1)
assert_contains "evidence stays unavailable" '"retrieval_status":"unavailable"' "${evidence_row:-}"

teardown_run
unshadow_github_release

# npm package WITH a GitHub homepage: unchanged behavior — the render
# path fetches the GitHub release (display.sh's npm+GitHub branch) and
# renders it with the npm date; the npm-placeholder fallback line is not
# shown. The registry fallback itself is not consulted.
fake_curl_json '{"name":"lazygit-npm-shape","time":{"1.0.0":"2026-08-01T00:00:00Z"}}'
shadow_github_release
setup_run
rm -f "$github_fetch_marker"
gh_home_info='{"homepage":"https://github.com/jesseduffield/lazygit","urls":{"stable":{"url":"https://registry.npmjs.org/lazygit-npm-shape"}}}'
display_out=$(_show_package_changelog_full_body "lazygit-npm-shape" "0.9.0" "1.0.0" "$gh_home_info" 2>/dev/null)

assert_eq "github render fetch still happens (today's behavior)" "1" "$([[ -f "$github_fetch_marker" ]] && echo 1 || echo 0)"
assert_contains "github-homepage npm package renders GitHub notes" "Removed the legacy builder" "$display_out"
assert_not_contains "npm placeholder fallback not shown" "published to npm registry" "$display_out"

teardown_run
unshadow_github_release

# ---------------------------------------------------------------------------
echo ""
printf 'npm→GitHub fallback tests: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
