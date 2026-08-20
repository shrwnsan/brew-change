#!/usr/bin/env bash
# Tests for plain-language remediation wording (Task T3.1.2).
# Validates:
#   Missing required dependencies (jq, curl) print exact supported install
#     commands on stderr and exit 1
#   Zero-argument simple-list and -v runs print NO GitHub auth guidance when
#     gh is absent (no warnings on every invocation)
#   Evidence-mode runs (-a) print exactly ONE benefit-focused auth tip line
#     on stderr, and none when a token is already available
#   Non-interactive package-not-found output shows "Did you mean:" style
#     suggestions and never tells users to build a "brew list | grep" pipeline
#
# Determinism: brew-change runs under a fully controlled PATH built from
# symlinked host tools plus stub brew/curl (no network, no real Homebrew).
# gh is deliberately NOT linked so the gh-absent remediation path is
# deterministic even on hosts that have gh installed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
BREW_CHANGE="$PROJECT_DIR/brew-change"

# Source shared test utilities (logging/summary conventions).
source "$SCRIPT_DIR/lib/test-utils.sh"

# ---------------------------------------------------------------------------
# Minimal assertion harness (same pattern as test-cli-validation.sh)
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
        ((fail++))
    fi
}

assert_contains() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected to contain '$expected')"
        ((fail++))
    fi
}

assert_not_contains() {
    local desc="$1" unexpected="$2" actual="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (should not contain '$unexpected')"
        ((fail++))
    fi
}

# ---------------------------------------------------------------------------
# Controlled PATH construction
# ---------------------------------------------------------------------------

# Symlink the host tools brew-change's startup needs into $1. jq, gh, and
# curl are NEVER linked here; tests control those explicitly.
link_base_tools() {
    local bin="$1" tool path
    mkdir -p "$bin"
    for tool in bash sh env locale grep sed awk cat sort uniq wc tr paste \
                head tail cut mktemp mkdir chmod rm mv cp find date sleep \
                dirname basename sysctl tput uname stty; do
        path=$(command -v "$tool" 2>/dev/null) || continue
        ln -s "$path" "$bin/$tool"
    done
}

link_jq() {
    local bin="$1" path
    path=$(command -v jq 2>/dev/null) || {
        echo "FATAL: jq must be installed on the host to run this suite" >&2
        exit 2
    }
    ln -s "$path" "$bin/jq"
}

# Dispatching brew stub:
#   brew outdated --json=v2  -> contents of $BREW_STUB_OUTDATED
#   brew outdated (other)    -> success, no output
#   brew list [...]          -> contents of $BREW_STUB_LIST
#   anything else            -> failure (package not found)
make_brew_stub() {
    local bin="$1"
    cat >"$bin/brew" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "outdated" ]]; then
    if [[ "${2:-}" == "--json=v2" ]]; then
        printf '%s\n' "$BREW_STUB_OUTDATED"
    fi
    exit 0
fi
if [[ "${1:-}" == "list" ]]; then
    printf '%s\n' "$BREW_STUB_LIST"
    exit 0
fi
exit 1
STUB
    chmod +x "$bin/brew"
}

# curl stub: succeeds with empty output (no network).
make_curl_stub() {
    local bin="$1"
    printf '#!/bin/bash\nexit 0\n' >"$bin/curl"
    chmod +x "$bin/curl"
}

# gh stub that reports an authenticated session with a token.
make_gh_authenticated_stub() {
    local bin="$1"
    cat >"$bin/gh" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
    exit 0
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
    echo "test-token"
    exit 0
fi
exit 1
STUB
    chmod +x "$bin/gh"
}

# Run brew-change under the controlled bin (clean env, piped stdin).
# Sets RUN_EXIT, RUN_STDOUT, RUN_STDERR, RUN_COMBINED.
# Usage: run_bc <bin-dir> [brew-change args...]
run_bc() {
    local bin="$1"; shift
    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/bc-remediation.XXXXXX") || exit 2
    mkdir -p "$work/home"
    RUN_EXIT=0
    env -i \
        PATH="$bin" \
        HOME="$work/home" \
        TMPDIR="${TMPDIR:-/tmp}" \
        BREW_CHANGE_CACHE_DIR="$work/cache" \
        BREW_STUB_OUTDATED="${BREW_STUB_OUTDATED:-}" \
        BREW_STUB_LIST="${BREW_STUB_LIST:-}" \
        "$bin/bash" "$BREW_CHANGE" "$@" \
        >"$work/out" 2>"$work/err" </dev/null || RUN_EXIT=$?
    RUN_STDOUT="$(cat "$work/out" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$work/err" 2>/dev/null || true)"
    RUN_COMBINED="$RUN_STDOUT"$'\n'"$RUN_STDERR"
    rm -rf "$work"
}

# Count lines in $1 that start with "Tip:".
count_tip_lines() {
    printf '%s\n' "$1" | grep -c '^Tip:'
}

# ---------------------------------------------------------------------------
# Suites
# ---------------------------------------------------------------------------
echo "======================================"
echo "Remediation Wording Tests (T3.1.2)"
echo "======================================"
echo ""

echo "=== Suite 1: missing required dependencies name exact install commands ==="
echo ""

echo "Test 1: missing jq exits 1 with the exact 'brew install jq' command"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
make_curl_stub "$BIN"
# jq deliberately NOT linked: it is the missing dependency
run_bc "$BIN"
assert_eq "missing jq exit code" "1" "$RUN_EXIT"
assert_contains "missing jq gives exact install command" "brew install jq" "$RUN_STDERR"
assert_contains "missing jq explains purpose" "JSON" "$RUN_STDERR"
rm -rf "$BIN"

echo ""
echo "Test 2: missing curl exits 1 with the exact 'brew install curl' command"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
link_jq "$BIN"
# curl deliberately NOT linked: it is the missing dependency
run_bc "$BIN"
assert_eq "missing curl exit code" "1" "$RUN_EXIT"
assert_contains "missing curl gives exact install command" "brew install curl" "$RUN_STDERR"
rm -rf "$BIN"

echo ""
echo "=== Suite 2: no auth output on non-evidence runs (gh absent) ==="
echo ""

echo "Test 3: zero-arg simple list prints no auth guidance anywhere"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
make_curl_stub "$BIN"
link_jq "$BIN"
# gh deliberately NOT linked
BREW_STUB_OUTDATED='{"formulae":[],"casks":[]}'
BREW_STUB_LIST=""
run_bc "$BIN"
assert_eq "zero-arg exit code" "0" "$RUN_EXIT"
assert_not_contains "zero-arg has no auth tip" "Tip:" "$RUN_COMBINED"
assert_not_contains "zero-arg has no gh guidance" "gh" "$RUN_COMBINED"
assert_not_contains "zero-arg has no GitHub guidance" "GitHub" "$RUN_COMBINED"
assert_not_contains "zero-arg has no warning tone" "Warning" "$RUN_COMBINED"
rm -rf "$BIN"

echo ""
echo "Test 4: -v run prints no auth guidance anywhere"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
make_curl_stub "$BIN"
link_jq "$BIN"
BREW_STUB_OUTDATED='{"formulae":[],"casks":[]}'
BREW_STUB_LIST=""
run_bc "$BIN" -v
assert_eq "-v exit code" "0" "$RUN_EXIT"
assert_not_contains "-v has no auth tip" "Tip:" "$RUN_COMBINED"
assert_not_contains "-v has no gh guidance" "gh" "$RUN_COMBINED"
assert_not_contains "-v has no GitHub guidance" "GitHub" "$RUN_COMBINED"
assert_not_contains "-v has no warning tone" "Warning" "$RUN_COMBINED"
rm -rf "$BIN"

echo ""
echo "=== Suite 3: evidence-mode runs print exactly one auth tip ==="
echo ""

echo "Test 5: -a run with gh absent prints one tip with remediation and benefit"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
make_curl_stub "$BIN"
link_jq "$BIN"
# gh deliberately NOT linked
BREW_STUB_OUTDATED='{"formulae":[{"name":"node","installed_versions":["22.6.0"],"current_version":"22.8.0"}],"casks":[]}'
BREW_STUB_LIST="node"
run_bc "$BIN" -a
assert_eq "-a run exit code" "0" "$RUN_EXIT"
assert_eq "-a prints exactly one tip line on stderr" "1" "$(count_tip_lines "$RUN_STDERR")"
assert_eq "-a prints no tip on stdout" "0" "$(count_tip_lines "$RUN_STDOUT")"
assert_contains "tip gives exact remediation" "gh auth login" "$RUN_STDERR"
assert_contains "tip states the rate-limit benefit" "5000" "$RUN_STDERR"
assert_not_contains "no warning tone for auth" "Warning: GitHub" "$RUN_COMBINED"
rm -rf "$BIN"

echo ""
echo "Test 6: -a run with an authenticated gh prints no auth output"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
make_curl_stub "$BIN"
link_jq "$BIN"
make_gh_authenticated_stub "$BIN"
BREW_STUB_OUTDATED='{"formulae":[{"name":"node","installed_versions":["22.6.0"],"current_version":"22.8.0"}],"casks":[]}'
BREW_STUB_LIST="node"
run_bc "$BIN" -a
assert_eq "authenticated -a exit code" "0" "$RUN_EXIT"
assert_eq "authenticated -a prints no tip" "0" "$(count_tip_lines "$RUN_COMBINED")"
assert_not_contains "authenticated -a has no warning tone" "Warning: GitHub" "$RUN_COMBINED"
rm -rf "$BIN"

echo ""
echo "=== Suite 4: package-not-found suggestions need no pipelines ==="
echo ""

echo "Test 7: non-interactive not-found shows 'Did you mean:' list"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
make_curl_stub "$BIN"
link_jq "$BIN"
BREW_STUB_OUTDATED='{"formulae":[],"casks":[]}'
BREW_STUB_LIST=$'nodejs\npython\nwget'
run_bc "$BIN" nod
assert_eq "not-found exit code" "1" "$RUN_EXIT"
assert_contains "shows Did you mean suggestions" "Did you mean:" "$RUN_COMBINED"
assert_contains "suggestion includes matching package" "nodejs" "$RUN_COMBINED"
assert_not_contains "no brew list pipeline" "brew list | grep" "$RUN_COMBINED"
assert_not_contains "no pipeline-building hint" "To search installed packages" "$RUN_COMBINED"
rm -rf "$BIN"

echo ""
echo "Test 8: not-found without suggestions gives pipeline-free guidance"
BIN=$(mktemp -d "${TMPDIR:-/tmp}/bc-remed-bin.XXXXXX")
link_base_tools "$BIN"
make_brew_stub "$BIN"
make_curl_stub "$BIN"
link_jq "$BIN"
BREW_STUB_OUTDATED='{"formulae":[],"casks":[]}'
BREW_STUB_LIST=$'nodejs\npython\nwget'
run_bc "$BIN" zzzz
assert_eq "no-suggestion exit code" "1" "$RUN_EXIT"
assert_not_contains "no brew list pipeline" "brew list | grep" "$RUN_COMBINED"
assert_not_contains "no pipeline-building hint" "To search installed packages" "$RUN_COMBINED"
assert_contains "gives brew search guidance" "brew search zzzz" "$RUN_COMBINED"
rm -rf "$BIN"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================"
echo "Test Results Summary"
echo "======================================"
echo "Total tests:  $((pass + fail))"
echo "Passed:       $pass"
echo "Failed:       $fail"
echo ""

if [[ $fail -gt 0 ]]; then
    exit 1
fi
