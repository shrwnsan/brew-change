#!/usr/bin/env bash
# Negative probe cache (field feedback 2026-08-25): when the non-GitHub
# notes chain concludes "nothing" for package@version, a short-TTL
# negative entry lets an immediate re-run skip the whole probe chain
# (up to ~14 URLs x retries); a successful chain clears the entry; the
# TTL expiry re-probes; --fresh clears the namespace.
#
# Usage: bash tests/test-negative-cache.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test-utils.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
pass=0
fail=0
pass() { pass=$((pass + 1)); printf "${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { fail=$((fail + 1)); printf "${RED}FAIL${NC}: %s\n" "$1" >&2; }
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc (expected='$expected' actual='$actual')"
    fi
}

echo "======================================"
echo "Negative Probe Cache Tests"
echo "======================================"

# Module deps for the helpers and the probe chain. The probe chain never
# reaches brew (all fetches fail) but non-github.sh references brew info
# helpers lazily; stub what the chain can touch.
# Exports BEFORE module sourcing: config.sh resolves CACHE_DIR and
# MAX_RETRIES readonly at source time — after setup they would lock in the
# real user cache and 3 retries.
export BREW_CHANGE_MAX_RETRIES=1
export BREW_CHANGE_SUBPROCESS="true"
setup_command_harness || exit 1
export BREW_CHANGE_CACHE_DIR="$COMMAND_HARNESS_ROOT/cache"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-breaking.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-non-github.sh"
get_brew_info() { return 1; }

# A fake curl that logs every invocation (url-level) and always fails to
# connect — the expensive no-notes probe shape.
cat > "$COMMAND_HARNESS_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
    case "$arg" in https://*) url="$arg";; esac
done
{
    printf 'curl\t%s\n' "$url"
} >> "$COMMAND_HARNESS_LOG"
exit 7
FAKE_CURL
chmod +x "$COMMAND_HARNESS_BIN/curl"

curl_calls() { grep -c $'^curl\t' "$COMMAND_HARNESS_LOG" 2>/dev/null || true; }

KEY="probe some-app 2.0.0"

# --- 1. Helpers: put/get roundtrip, TTL expiry, clear ------------------------

assert_eq "get on empty cache: miss (rc 1)" "1" "$(http_cache_negative_get "$KEY" >/dev/null 2>&1; echo $?)"
http_cache_negative_put "$KEY"
assert_eq "put then get: hit (rc 0)" "0" "$(http_cache_negative_get "$KEY" >/dev/null 2>&1; echo $?)"
http_cache_negative_clear "$KEY"
assert_eq "clear then get: miss again" "1" "$(http_cache_negative_get "$KEY" >/dev/null 2>&1; echo $?)"

# TTL expiry: entry written "now", clock advanced past the negative TTL.
http_cache_negative_put "$KEY"
BREW_CHANGE_TEST_NOW=$(( $(brew_change_test_now) + HTTP_CACHE_NEGATIVE_TTL_SECONDS + 5 ))
assert_eq "entry expired after negative TTL" "1" "$(http_cache_negative_get "$KEY" >/dev/null 2>&1; echo $?)"
unset BREW_CHANGE_TEST_NOW
http_cache_negative_clear "$KEY"

# Corrupt entry fails closed (deleted, treated as miss).
http_cache_negative_put "$KEY"
npath=$(_http_cache_negative_path "$KEY")
printf 'garbage\n' > "$npath"
assert_eq "corrupt negative entry: miss, not crash" "1" "$(http_cache_negative_get "$KEY" >/dev/null 2>&1; echo $?)"
[[ ! -f "$npath" ]] && pass "corrupt entry deleted (fail closed)" || fail "corrupt entry kept on disk"

# --- 2. Probe chain integration: first run probes, second run skips ----------

SOURCE_URL="https://registry.npmjs.org/some-app"

# Run 1: full chain (11 pattern URLs x 1 retry each) — counts curl calls.
before=$(curl_calls)
rc1=0
fetch_non_github_release_notes "some-app" "2.0.0" "$SOURCE_URL" "" >/dev/null 2>&1 || rc1=$?
run1_calls=$(( $(curl_calls) - before ))
assert_eq "run 1 concludes nothing (rc 1)" "1" "$rc1"
if (( run1_calls > 0 )); then
    pass "run 1 performed the probe chain on the network ($run1_calls curl calls)"
else
    fail "run 1 must perform network probes"
fi

# Run 2 immediately after: negative hit — zero curl calls, same outcome.
before=$(curl_calls)
rc2=0
fetch_non_github_release_notes "some-app" "2.0.0" "$SOURCE_URL" "" >/dev/null 2>&1 || rc2=$?
run2_calls=$(( $(curl_calls) - before ))
assert_eq "run 2 concludes nothing (rc 1)" "1" "$rc2"
assert_eq "run 2 skipped the chain entirely (0 curl calls)" "0" "$run2_calls"

# --- 3. TTL expiry re-probes --------------------------------------------------

BREW_CHANGE_TEST_NOW=$(( $(brew_change_test_now) + HTTP_CACHE_NEGATIVE_TTL_SECONDS + 5 ))
before=$(curl_calls)
fetch_non_github_release_notes "some-app" "2.0.0" "$SOURCE_URL" "" >/dev/null 2>&1
run3_calls=$(( $(curl_calls) - before ))
if (( run3_calls > 0 )); then
    pass "expired entry re-probes the chain"
else
    fail "expired entry must re-probe"
fi
unset BREW_CHANGE_TEST_NOW

# --- 4. Success clears the negative entry -------------------------------------

# A version whose probe SUCCEEDS: point the domain at a winning fixture
# pattern URL, run the chain (clears any negative for that key), then
# verify the negative entry for that key is gone.
WIN_URL="https://registry.npmjs.org/some-app/releases/tag/3.0.0"
before=$(curl_calls)
# Rebuild the fake curl: fail everywhere except the winning URL, which
# returns a page whose content matches the extraction (>25 chars).
cat > "$COMMAND_HARNESS_BIN/curl" <<FAKE_CURL
#!/usr/bin/env bash
output="" headers="" url=""
while (( \$# )); do
    case "\$1" in
        -o) output="\$2"; shift 2 ;;
        -D) headers="\$2"; shift 2 ;;
        https://*) url="\$1"; shift ;;
        *) shift ;;
    esac
done
{
    printf 'curl\t%s\n' "\$url"
} >> "\$COMMAND_HARNESS_LOG"
if [[ "\$url" == "$WIN_URL" ]]; then
    printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$headers"
    # fetch_url_with_retry validates kind=json: the body must be valid,
    # non-envelope JSON; the extraction greps it for the version.
    printf '{"name":"some-app","version":"3.0.0","release_notes":"Some App 3.0.0 release with plenty of detail here for extraction to succeed."}\n' > "\$output"
    exit 0
fi
exit 7
FAKE_CURL
chmod +x "$COMMAND_HARNESS_BIN/curl"
rcs=0
fetch_non_github_release_notes "some-app" "3.0.0" "$SOURCE_URL" "" >/dev/null 2>&1 || rcs=$?
assert_eq "winning chain succeeds (rc 0)" "0" "$rcs"
# The chain put negatives for failed sub-attempts? No: put/clear is
# chain-level. Verify the success cleared the key.
assert_eq "success cleared the negative entry" \
    "1" "$(http_cache_negative_get "probe some-app 3.0.0" >/dev/null 2>&1; echo $?)"

# --- 5. --fresh clears the whole namespace ------------------------------------

http_cache_negative_put "$KEY"
http_cache_reset_fresh
assert_eq "--fresh clears negative entries" \
    "1" "$(http_cache_negative_get "$KEY" >/dev/null 2>&1; echo $?)"

cp "$COMMAND_HARNESS_LOG" /tmp/tn-log.txt 2>/dev/null || true
teardown_command_harness

echo ""
printf 'Negative cache tests: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
