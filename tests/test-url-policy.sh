#!/usr/bin/env bash
# Test: Enforce the evidence URL boundary (Task 7)
#
# Validates that all runtime HTTP requests are subject to a single URL policy
# function. Covers allowed hosts, rejected patterns, redirect safety, and
# authentication confinement.
#
# No live network — uses the command-harness fake-curl fixture system.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

export BREW_CHANGE_MAX_RETRIES=1
export BREW_CHANGE_SUBPROCESS="true"
source "$SCRIPT_DIR/../lib/brew-change-config.sh"
source "$SCRIPT_DIR/../lib/brew-change-utils.sh"
source "$SCRIPT_DIR/../lib/brew-change-non-github.sh"
source "$SCRIPT_DIR/../lib/brew-change-upgrade.sh"

pass=0
fail=0

assert_ok()   { local d="$1"; if validate_url "$2" >/dev/null 2>&1; then pass=$((pass+1)); printf 'PASS: %s\n' "$d"; else fail=$((fail+1)); printf 'FAIL: %s (rejected %s)\n' "$d" "$2"; fi; }
assert_reject() { local d="$1"; if validate_url "$2" >/dev/null 2>&1; then fail=$((fail+1)); printf 'FAIL: %s (accepted %s)\n' "$d" "$2"; else pass=$((pass+1)); printf 'PASS: %s\n' "$d"; fi; }

echo "=== URL Policy Tests ==="
echo ""

# -----------------------------------------------------------------------
# 1. Allowed first-party evidence hosts
# -----------------------------------------------------------------------
echo "--- 1. Allowed first-party hosts ---"

assert_ok  "api.github.com"                  "https://api.github.com/repos/owner/repo/releases/tags/v1"
assert_ok  "api.github.com path variant"    "https://api.github.com/rate_limit"
assert_ok  "github.com"                     "https://github.com/owner/repo/releases"
assert_ok  "github.com path variant"        "https://github.com/owner/repo"
assert_ok  "raw.githubusercontent.com"      "https://raw.githubusercontent.com/owner/repo/main/CHANGELOG.md"
assert_ok  "formulae.brew.sh"               "https://formulae.brew.sh/api/formula/node.json"
assert_ok  "formulae.brew.sh cask"           "https://formulae.brew.sh/api/cask/rectangle.json"
assert_ok  "registry.npmjs.org"              "https://registry.npmjs.org/package-name"
assert_ok  "query without path"              "https://api.github.com?per_page=1"
assert_ok  "fragment without path"           "https://github.com#releases"

echo ""

# -----------------------------------------------------------------------
# 2. Reject arbitrary public hosts
# -----------------------------------------------------------------------
echo "--- 2. Reject arbitrary public hosts ---"

assert_reject "arbitrary example.com"        "https://example.com"
assert_reject "arbitrary evil.com"           "https://evil.com/path"
assert_reject "arbitrary random.org"         "https://random.org/api"
assert_reject "subdomain of allowed"         "https://sub.api.github.com"
assert_reject "suffix trick on github"       "https://notgithub.com"
assert_reject "suffix trick on brew"          "https://notformulae.brew.sh"

echo ""

# -----------------------------------------------------------------------
# 3. Reject localhost, private IPs, link-local
# -----------------------------------------------------------------------
echo "--- 3. Reject localhost and private addresses ---"

assert_reject "localhost"                     "https://localhost/api"
assert_reject "localhost with port"           "https://localhost:443/api"
assert_reject "non-default HTTPS port"        "https://api.github.com:22/api"
assert_reject "127.0.0.1"                   "https://127.0.0.1/api"
assert_reject "127.0.0.1 port"              "https://127.0.0.1:8080/api"
assert_reject "loopback IPv6"                "https://[::1]/api"
assert_reject "10.x private"                 "https://10.0.0.1/api"
assert_reject "172.16 private"               "https://172.16.0.1/api"
assert_reject "192.168 private"              "https://192.168.1.1/api"
assert_reject "169.254 link-local"           "https://169.254.1.1/api"
assert_reject "fc00 IPv6 ULA"               "https://[fc00::1]/api"
assert_reject "fe80 IPv6 link-local"        "https://[fe80::1]/api"

echo ""

# -----------------------------------------------------------------------
# 4. Reject non-HTTPS schemes and dangerous schemes
# -----------------------------------------------------------------------
echo "--- 4. Reject non-HTTPS and dangerous schemes ---"

assert_reject "HTTP (not HTTPS)"             "http://api.github.com/repos/test"
assert_reject "ftp scheme"                   "ftp://files.example.com/package.tar.gz"
assert_reject "file scheme"                  "file:///etc/passwd"
assert_reject "data scheme"                  "data:text/html,<script>alert(1)</script>"
assert_reject "javascript scheme"            "javascript:alert(1)"
assert_reject "empty URL"                    ""

echo ""

# -----------------------------------------------------------------------
# 5. Reject userinfo in URL
# -----------------------------------------------------------------------
echo "--- 5. Reject userinfo ---"

assert_reject "userinfo in URL"              "https://user:pass@api.github.com/repos/test"
assert_reject " userinfo in URL"             "https://user@api.github.com/repos/test"

echo ""

# -----------------------------------------------------------------------
# 6. Reject encoded CR/LF injection
# -----------------------------------------------------------------------
echo "--- 6. Reject encoded CR/LF ---"

assert_reject "encoded CR %0d"               "https://api.github.com/repos/test%0dextra"
assert_reject "encoded LF %0a"               "https://api.github.com/repos/test%0aextra"
assert_reject "encoded CRLF %0d%0a"         "https://api.github.com/repos/test%0d%0aextra"
assert_reject "double-encoded %250d"         "https://api.github.com/repos/test%250d"
assert_reject "uppercase %0D%0A"             "https://api.github.com/repos/test%0D%0A"

echo ""

# -----------------------------------------------------------------------
# 7. fetch_url_with_retry_text also uses the same validator
# -----------------------------------------------------------------------
echo "--- 7. Text helper uses same policy ---"

setup_command_harness

# Configure fake curl to always succeed (returns empty, status 0)
configure_fake_command curl "" "" 0

# fetch_url_with_retry_text must reject the same patterns
result=$(fetch_url_with_retry_text "https://evil.com/path" 2>&1) || true
if [[ "$result" == *"not allowed"* || "$result" == *"not Allowed"* ]]; then
    echo "PASS: fetch_url_with_retry_text rejects evil.com"
    pass=$((pass+1))
else
    echo "FAIL: fetch_url_with_retry_text accepted evil.com: $result"
    fail=$((fail+1))
fi

result=$(fetch_url_with_retry_text "http://api.github.com/test" 2>&1) || true
if [[ "$result" == *"not allowed"* || "$result" == *"Only HTTPS"* ]]; then
    echo "PASS: fetch_url_with_retry_text rejects HTTP to allowed host"
    pass=$((pass+1))
else
    echo "FAIL: fetch_url_with_retry_text accepted HTTP to allowed host: $result"
    fail=$((fail+1))
fi

result=$(fetch_url_with_retry_text "file:///etc/passwd" 2>&1) || true
if [[ "$result" == *"not allowed"* || "$result" == *"Only HTTPS"* ]]; then
    echo "PASS: fetch_url_with_retry_text rejects file:// scheme"
    pass=$((pass+1))
else
    echo "FAIL: fetch_url_with_retry_text accepted file:// scheme"
    fail=$((fail+1))
fi

teardown_command_harness

echo ""

# -----------------------------------------------------------------------
# 8. Redirect safety: allowed -> allowed OK, allowed -> disallowed blocked
# -----------------------------------------------------------------------
echo "--- 8. Redirect safety (fake-curl) ---"

setup_command_harness

cat > "$COMMAND_HARNESS_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
output="" headers="" url=""
{
    printf 'curl'
    for arg in "$@"; do printf '\t%s' "$arg"; done
    printf '\n'
} >> "$COMMAND_HARNESS_LOG"
while (( $# )); do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        -D) headers="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    https://api.github.com/start-allowed)
        printf 'HTTP/1.1 302 Found\r\nLocation: https://github.com/final\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/start-blocked)
        printf 'HTTP/1.1 302 Found\r\nLocation: https://evil.com/stolen\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/start-auth)
        printf 'HTTP/1.1 302 Found\r\nLocation: https://github.com/final\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/start-root)
        printf 'HTTP/1.1 302 Found\r\nLocation: /final-root\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/final-root)
        printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
        printf 'root-relative' > "$output"
        ;;
    https://api.github.com/path/start-relative)
        printf 'HTTP/1.1 302 Found\r\nLocation: next\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/path/next)
        printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
        printf 'path-relative' > "$output"
        ;;
    https://api.github.com/start-scheme-relative)
        printf 'HTTP/1.1 302 Found\r\nLocation: //github.com/final\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/start-http)
        printf 'HTTP/1.1 302 Found\r\nLocation: http://api.github.com/insecure\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/loop-a)
        printf 'HTTP/1.1 302 Found\r\nLocation: /loop-b\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://api.github.com/loop-b)
        printf 'HTTP/1.1 302 Found\r\nLocation: /loop-a\r\n\r\n' > "$headers"
        : > "$output"
        ;;
    https://github.com/final)
        printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
        printf 'release notes' > "$output"
        ;;
    *) exit 125 ;;
esac
FAKE_CURL
chmod +x "$COMMAND_HARNESS_BIN/curl"

: > "$COMMAND_HARNESS_LOG"
redirect_result=$(fetch_url_with_retry_text "https://api.github.com/start-allowed" 2>/dev/null)
if [[ "$redirect_result" == "release notes" ]] && [[ $(wc -l < "$COMMAND_HARNESS_LOG" | tr -d ' ') -eq 2 ]]; then
    echo "PASS: allowed redirect is followed exactly once"
    pass=$((pass+1))
else
    echo "FAIL: allowed redirect result='$redirect_result'"
    fail=$((fail+1))
fi

: > "$COMMAND_HARNESS_LOG"
if fetch_url_with_retry_text "https://api.github.com/start-blocked" >/dev/null 2>&1; then
    echo "FAIL: disallowed redirect was followed"
    fail=$((fail+1))
elif [[ $(wc -l < "$COMMAND_HARNESS_LOG" | tr -d ' ') -eq 1 ]]; then
    echo "PASS: allowed-to-disallowed redirect is blocked before second request"
    pass=$((pass+1))
else
    echo "FAIL: disallowed redirect made an unexpected request"
    fail=$((fail+1))
fi

: > "$COMMAND_HARNESS_LOG"
auth_result=$(fetch_url_policy_aware "https://api.github.com/start-auth" "secret-token" 2>/dev/null)
if [[ "$auth_result" == "release notes" ]] \
    && sed -n '1p' "$COMMAND_HARNESS_LOG" | grep -q $'\tAuthorization: token secret-token' \
    && ! sed -n '2p' "$COMMAND_HARNESS_LOG" | grep -q 'Authorization:'; then
    echo "PASS: authorization is stripped on redirect away from api.github.com"
    pass=$((pass+1))
else
    echo "FAIL: authorization confinement across redirect"
    fail=$((fail+1))
fi

: > "$COMMAND_HARNESS_LOG"
root_result=$(fetch_url_with_retry_text "https://api.github.com/start-root" 2>/dev/null)
relative_result=$(fetch_url_with_retry_text "https://api.github.com/path/start-relative" 2>/dev/null)
scheme_relative_result=$(fetch_url_with_retry_text "https://api.github.com/start-scheme-relative" 2>/dev/null)
if [[ "$root_result" == "root-relative" && "$relative_result" == "path-relative" && "$scheme_relative_result" == "release notes" ]]; then
    echo "PASS: root, path, and scheme-relative redirects resolve correctly"
    pass=$((pass+1))
else
    echo "FAIL: relative redirect resolution"
    fail=$((fail+1))
fi

: > "$COMMAND_HARNESS_LOG"
if fetch_url_with_retry_text "https://api.github.com/start-http" >/dev/null 2>&1; then
    echo "FAIL: HTTP redirect was followed"
    fail=$((fail+1))
elif [[ $(wc -l < "$COMMAND_HARNESS_LOG" | tr -d ' ') -eq 1 ]]; then
    echo "PASS: HTTP redirect is blocked before the second request"
    pass=$((pass+1))
else
    echo "FAIL: HTTP redirect made an unexpected request"
    fail=$((fail+1))
fi

: > "$COMMAND_HARNESS_LOG"
if fetch_url_with_retry_text "https://api.github.com/loop-a" >/dev/null 2>&1; then
    echo "FAIL: redirect loop unexpectedly succeeded"
    fail=$((fail+1))
elif [[ $(wc -l < "$COMMAND_HARNESS_LOG" | tr -d ' ') -eq 3 ]]; then
    echo "PASS: redirect loop stops after the bounded hop count"
    pass=$((pass+1))
else
    echo "FAIL: redirect loop request count was not bounded at three"
    fail=$((fail+1))
fi

teardown_command_harness

echo ""

# -----------------------------------------------------------------------
# 9. No --location in fetch helpers (manual redirect following only)
# -----------------------------------------------------------------------
echo "--- 9. No auto-follow redirects ---"

# Grep the production code for --location usage in fetch helpers (exclude comments)
code_only=$(grep '\-\-location' "$SCRIPT_DIR/../lib/brew-change-utils.sh" 2>/dev/null | grep -cv '^\s*#')
[[ -z "$code_only" ]] && code_only=0
if [[ "$code_only" -eq 0 ]]; then
    echo "PASS: No --location in brew-change-utils.sh"
    pass=$((pass+1))
else
    echo "FAIL: Found $code_only --location occurrences in brew-change-utils.sh"
    fail=$((fail+1))
fi

echo ""

# -----------------------------------------------------------------------
# 10. Auth tokens only sent to api.github.com (no raw bypass curl)
# -----------------------------------------------------------------------
echo "--- 10. Auth token confinement ---"

# Verify no raw curl+Authorization bypass calls remain in github.sh (exclude comments)
raw_auth_curl=$(grep 'curl.*Authorization.*token' "$SCRIPT_DIR/../lib/brew-change-github.sh" 2>/dev/null | grep -cv '^\s*#')
[[ -z "$raw_auth_curl" ]] && raw_auth_curl=0
if [[ "$raw_auth_curl" -eq 0 ]]; then
    echo "PASS: No raw curl+Authorization calls in github.sh (all go through policy path)"
    pass=$((pass+1))
else
    echo "FAIL: Found $raw_auth_curl raw curl+Authorization calls in github.sh"
    fail=$((fail+1))
fi

echo ""

# -----------------------------------------------------------------------
# 11. Call-site inventory: lock expected production fetch paths
# -----------------------------------------------------------------------
echo "--- 11. Call-site inventory ---"

# The only direct runtime curl calls are the single-hop policy transport and
# the fixed, validated connectivity probe. Any new direct call requires review.
direct_curl_count=$(awk '
    /^[[:space:]]*#/ { next }
    /command[[:space:]]+-v[[:space:]]+curl/ { next }
    /(^|[;&|[:space:]])curl([[:space:]]|$)/ { count++ }
    END { print count + 0 }
' "$SCRIPT_DIR/../brew-change" "$SCRIPT_DIR"/../lib/*.sh)
transport_count=$(grep -F -c 'curl "${curl_args[@]}" 2>/dev/null || status=$?' "$SCRIPT_DIR/../lib/brew-change-utils.sh")
connectivity_count=$(grep -F -c 'if curl -s --max-time 3 --connect-timeout 2 "$url" >/dev/null 2>&1; then' "$SCRIPT_DIR/../lib/brew-change-utils.sh")
if [[ "$direct_curl_count" -eq 2 && "$transport_count" -eq 1 && "$connectivity_count" -eq 1 ]]; then
    echo "PASS: Direct curl inventory matches the two reviewed policy paths"
    pass=$((pass+1))
else
    echo "FAIL: Direct curl inventory changed (total=$direct_curl_count transport=$transport_count connectivity=$connectivity_count)"
    fail=$((fail+1))
fi

echo ""

# -----------------------------------------------------------------------
# 12. Unsupported sources fail closed (unknown classification)
# -----------------------------------------------------------------------
echo "--- 12. Unsupported source fail-closed ---"

# validate_url rejects arbitrary domains, so code paths using it will fail
# and return unknown classification. Verify by checking the generic pattern
# URL construction is rejected:
assert_ok "supported sourceforge"            "https://sourceforge.net/projects/test/files"
assert_ok "supported crabnebula"             "https://crabnebula.app/packages/test"
assert_ok "supported factory.ai"             "https://factory.ai/packages/test"
assert_reject "generic constructed URL"      "https://some-domain.com/package/releases/tag/v1"

setup_command_harness
configure_fake_command curl "" "" 125
configure_fake_command brew "" "" 1
: > "$COMMAND_HARNESS_LOG"

unsupported_fetch_succeeded=false
if fetch_non_github_release_notes "some-app" "2.0.0" "https://unsupported.example/downloads/some-app.tar.gz" "" >/dev/null 2>&1; then
    unsupported_fetch_succeeded=true
fi
review_output=$(show_non_github_fallback "some-app" "https://unsupported.example/downloads/some-app.tar.gz")
unsupported_status_dir=$(mktemp -d "${TMPDIR:-/tmp}/bc-url-policy-status.XXXXXX")
classify_upgrade_evidence "$unsupported_status_dir" "some-app"

if [[ "$unsupported_fetch_succeeded" == "false" ]] \
    && [[ " ${UNKNOWN_PKGS[*]} " == *" some-app "* ]] \
    && [[ "$review_output" == *"https://unsupported.example/"* ]] \
    && ! grep -q '^curl' "$COMMAND_HARNESS_LOG"; then
    echo "PASS: unsupported source is unknown with a review URL and no network request"
    pass=$((pass+1))
else
    echo "FAIL: unsupported source did not fail closed with unknown status and review URL"
    fail=$((fail+1))
fi

rm -rf "$unsupported_status_dir"
teardown_command_harness

echo ""

# -----------------------------------------------------------------------
# 13. DNS rebinding limitation documented
# -----------------------------------------------------------------------
echo "--- 13. DNS rebinding caveat ---"

if grep -qi "dns rebinding" "$SCRIPT_DIR/../lib/brew-change-utils.sh" 2>/dev/null; then
    echo "PASS: DNS rebinding limitation is documented in brew-change-utils.sh"
    pass=$((pass+1))
else
    echo "FAIL: DNS rebinding limitation not documented"
    fail=$((fail+1))
fi

echo ""

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "=== Results ==="
total=$((pass + fail))
printf 'Total: %d  Passed: %d  Failed: %d\n' "$total" "$pass" "$fail"

if [[ $fail -gt 0 ]]; then
    exit 1
else
    printf 'All URL policy tests passed!\n'
    exit 0
fi
