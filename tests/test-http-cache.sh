#!/usr/bin/env bash
# Test: shared HTTP response cache boundary + evidence provenance (T3.2.1/T3.2.2)
#
# Validates the ratified evidence-cache design
# (docs/research-008-evidence-cache-resume.md):
#   - one $CACHE_DIR/http/ raw-response cache for JSON, text, and GitHub
#     (policy-aware) fetches; analysis re-runs over cached bodies
#   - endpoint-class TTLs (24h exact GitHub objects vs 1h mutable)
#   - auth partitioning (anon / token fingerprints) without token leakage
#   - lifecycle: cached-fresh -> refresh network-fresh -> failed refresh
#     cached-stale; corrupt entries fail closed
#   - request-scoped provenance metadata + run-scoped event files
#   - HTTP-only pruning (entry count + byte budget) and --fresh isolation
#
# No live network — fake-curl command harness only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-utils.sh"

export BREW_CHANGE_MAX_RETRIES=1
export BREW_CHANGE_SUBPROCESS="true"
export BREW_CHANGE_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bc-http-cache.XXXXXX")"
mkdir -p "$BREW_CHANGE_CACHE_DIR"
export BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES="${BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES:-512}"
export BREW_CHANGE_HTTP_CACHE_MAX_BYTES="${BREW_CHANGE_HTTP_CACHE_MAX_BYTES:-104857600}"

source "$SCRIPT_DIR/../lib/brew-change-config.sh"
source "$SCRIPT_DIR/../lib/brew-change-utils.sh"

TEST_NOW=1800000000
export BREW_CHANGE_TEST_NOW="$TEST_NOW"

pass=0
fail=0
EVENTS_DIR=""

note()  { printf '%s\n' "$1"; }
ok()    { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }

assert_eq() { # desc expected actual
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert_contains() { # desc needle haystack
    if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1 (missing '$2' in '$3')"; fi
}
assert_not_contains() { # desc needle haystack
    if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1 (unexpected '$2' in '$3')"; fi
}
assert_file_absent() { if [[ ! -e "$2" ]]; then ok "$1"; else bad "$1 ($2 exists)"; fi; }
assert_file_present() { if [[ -e "$2" ]]; then ok "$1"; else bad "$1 ($2 missing)"; fi; }

http_dir() { printf '%s/http' "$BREW_CHANGE_CACHE_DIR"; }

# Configure fake curl to answer 200 with $1 as the body.
fake_curl_ok() {
    local body_file="$1"
    configure_fake_command curl "$body_file" "" 0
    printf '200\n' > "$COMMAND_HARNESS_CONFIG/curl/http-status" 2>/dev/null || true
}

fake_curl_fail() {
    configure_fake_command curl "" "" 22
}

curl_invocations() {
    [[ -f "$COMMAND_HARNESS_LOG" ]] || { echo 0; return; }
    grep -c $'^curl\t' "$COMMAND_HARNESS_LOG" || true
}

meta_field() { # meta_file field
    jq -r --arg f "$2" '.[$f] // empty' "$1" 2>/dev/null || echo ""
}

setup() {
    setup_command_harness
    # Each scenario starts from an empty HTTP cache: entry files from a
    # previous section must not leak partition counts or body searches.
    rm -rf "$(http_dir)" 2>/dev/null || true
    EVENTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bc-cache-events.XXXXXX")"
    export BREW_CHANGE_HTTP_CACHE_EVENTS="$EVENTS_DIR"
}

teardown() {
    teardown_command_harness
    rm -rf "$EVENTS_DIR"
    unset BREW_CHANGE_HTTP_CACHE_EVENTS
    EVENTS_DIR=""
}

# ---------------------------------------------------------------------------
echo "=== 1. JSON responses are cached under \$CACHE_DIR/http/ ==="
setup
body_file="$(mktemp)"; printf '{"tag_name":"v1","body":"notes"}' > "$body_file"
meta1="$(mktemp)"; rm -f "$meta1"
fake_curl_ok "$body_file"
out="$(fetch_url_with_retry "https://api.github.com/repos/o/r/releases" "$meta1" 2>/dev/null)"
rc=$?
assert_eq "JSON fetch succeeds" "0" "$rc"
assert_contains "JSON body returned" '"tag_name":"v1"' "$out"
assert_file_present "entry created under http/ namespace" "$(http_dir)"
assert_eq "meta provenance network-fresh" "network-fresh" "$(meta_field "$meta1" provenance)"
assert_eq "meta retrieved_at is numeric epoch" "$TEST_NOW" "$(meta_field "$meta1" retrieved_at)"
n_before=$(curl_invocations)
assert_eq "one network fetch so far" "1" "$n_before"

# Second call must be served from cache without touching curl.
fake_curl_fail
meta2="$(mktemp)"; rm -f "$meta2"
out2="$(fetch_url_with_retry "https://api.github.com/repos/o/r/releases" "$meta2" 2>/dev/null)"
assert_eq "cached serve succeeds despite dead network" "0" "$?"
assert_contains "cached body identical" '"tag_name":"v1"' "$out2"
assert_eq "meta provenance cached-fresh" "cached-fresh" "$(meta_field "$meta2" provenance)"
assert_eq "no additional curl invocation" "$n_before" "$(curl_invocations)"
assert_eq "one cache event emitted" "1" "$(find "$EVENTS_DIR" -type f | wc -l | tr -d ' ')"
teardown

# ---------------------------------------------------------------------------
echo "=== 2. Text responses are cached (nonempty body only) ==="
setup
text_file="$(mktemp)"; printf 'line one\nline two\n' > "$text_file"
metaT="$(mktemp)"; rm -f "$metaT"
fake_curl_ok "$text_file"
outT="$(fetch_url_with_retry_text "https://raw.githubusercontent.com/o/r/main/CHANGELOG.md" "$metaT" 2>/dev/null)"
assert_eq "text fetch succeeds" "0" "$?"
assert_contains "text body returned" "line two" "$outT"
assert_eq "text meta network-fresh" "network-fresh" "$(meta_field "$metaT" provenance)"
fake_curl_fail
outT2="$(fetch_url_with_retry_text "https://raw.githubusercontent.com/o/r/main/CHANGELOG.md" "" 2>/dev/null)"
assert_eq "text cached serve (no meta arg)" "0" "$?"
assert_contains "text cached body" "line two" "$outT2"
assert_eq "text cache event (hits only)" "1" "$(find "$EVENTS_DIR" -type f | wc -l | tr -d ' ')"

# Empty body must not be cached (and the fetch itself fails closed).
empty_file="$(mktemp)"; : > "$empty_file"
fake_curl_ok "$empty_file"
fetch_url_with_retry_text "https://raw.githubusercontent.com/o/r/main/EMPTY.md" >/dev/null 2>&1
empty_rc=$?
assert_eq "empty text body not cached (fetch fails closed)" "1" "$empty_rc"
teardown

# ---------------------------------------------------------------------------
echo "=== 3. Auth partitioning without token leakage ==="
setup
gh_file="$(mktemp)"; printf '{"sha":"abc"}' > "$gh_file"
fake_curl_ok "$gh_file"
m1="$(mktemp)"; rm -f "$m1"; m2="$(mktemp)"; rm -f "$m2"; m3="$(mktemp)"; rm -f "$m3"
fetch_url_policy_aware "https://api.github.com/repos/o/r/git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "tokENSECRET-one" "$m1" >/dev/null 2>&1
fetch_url_policy_aware "https://api.github.com/repos/o/r/git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "tokENSECRET-two" "$m2" >/dev/null 2>&1
fetch_url_policy_aware "https://api.github.com/repos/o/r/git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "$m3" >/dev/null 2>&1
entries=$(find "$(http_dir)" -type f -name '*.cache' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "three distinct partition entries" "3" "$entries"
leak=$(grep -rl "tokENSECRET" "$BREW_CHANGE_CACHE_DIR" 2>/dev/null | head -1)
if [[ -z "$leak" ]]; then ok "no token material written anywhere in cache"; else bad "token material leaked to $leak"; fi
# Same token re-served from its own partition (network dead).
fake_curl_fail
m1b="$(mktemp)"; rm -f "$m1b"
fetch_url_policy_aware "https://api.github.com/repos/o/r/git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "tokENSECRET-one" "$m1b" >/dev/null 2>&1
assert_eq "token partition cache hit" "cached-fresh" "$(meta_field "$m1b" provenance)"
teardown

# ---------------------------------------------------------------------------
echo "=== 4. Endpoint-class TTLs ==="
setup
rel_file="$(mktemp)"; printf '{"sha":"deadbeef"}' > "$rel_file"
# Exact tag endpoint, retrieved 2h ago -> still fresh (24h class).
metaE="$(mktemp)"; rm -f "$metaE"
fake_curl_ok "$rel_file"
fetch_url_with_retry "https://api.github.com/repos/o/r/releases/tags/v9.9.9" "$metaE" >/dev/null 2>&1
# Age the stored entry header to now-7200 without touching mtime.
entry=$(find "$(http_dir)" -name '*.cache' | head -1)
# Rewrite ONLY the metadata header line of an entry (the body may itself be
# a JSON array, which jq must not touch).
age_header() { # file seconds-ago
    local header
    header=$(head -n 1 "$1")
    header=$(jq -c --argjson r "$((TEST_NOW - $2))" '.retrieved_at = $r' <<<"$header") || return 1
    tail -n +2 "$1" > "$1.body"
    printf '%s\n' "$header" | cat - "$1.body" > "$1.new"
    mv "$1.new" "$1" && rm -f "$1.body"
}
age_header "$entry" 7200
fake_curl_fail
mE="$(mktemp)"; rm -f "$mE"
fetch_url_with_retry "https://api.github.com/repos/o/r/releases/tags/v9.9.9" "$mE" >/dev/null 2>&1
assert_eq "exact tag endpoint 24h TTL (2h old still cached-fresh)" "cached-fresh" "$(meta_field "$mE" provenance)"
assert_eq "meta age_seconds ~7200" "7200" "$(meta_field "$mE" age_seconds)"
# Mutable collection endpoint, 2h old -> expired -> refresh (network live).
coll_file="$(mktemp)"; printf '[{"tag_name":"v2"}]' > "$coll_file"
metaC="$(mktemp)"; rm -f "$metaC"
fake_curl_ok "$coll_file"
fetch_url_with_retry "https://api.github.com/repos/o/r/releases" "$metaC" >/dev/null 2>&1
entryC=""
for f in "$(http_dir)"/*.cache; do
    [[ "$(tail -n +2 "$f")" == *'[{"tag_name":"v2"}]'* ]] && entryC="$f" && break
done
[[ -n "$entryC" ]] || bad "collection entry not found for TTL test"
age_header "$entryC" 7200
new_coll="$(mktemp)"; printf '[{"tag_name":"v3"}]' > "$new_coll"
fake_curl_ok "$new_coll"
mC="$(mktemp)"; rm -f "$mC"
outC="$(fetch_url_with_retry "https://api.github.com/repos/o/r/releases" "$mC" 2>/dev/null)"
assert_eq "mutable endpoint 1h TTL (2h old refreshes)" "network-fresh" "$(meta_field "$mC" provenance)"
assert_contains "refreshed body served" '"v3"' "$outC"
assert_not_contains "old body gone" '"v1"' "$outC"
teardown

# ---------------------------------------------------------------------------
echo "=== 5. Lifecycle: stale fallback, corrupt fails closed ==="
setup
st_file="$(mktemp)"; printf '{"a":1}' > "$st_file"
fake_curl_ok "$st_file"
fetch_url_with_retry "https://registry.npmjs.org/mypkg" >/dev/null 2>&1
entryS=$(for f in "$(http_dir)"/*.cache; do [[ "$(tail -n +2 "$f")" == *'"a":1'* ]] && echo "$f" && break; done)
age_file() { # file seconds-ago — same header-only rewrite as age_header
    local header
    header=$(head -n 1 "$1")
    header=$(jq -c --argjson r "$((TEST_NOW - $2))" '.retrieved_at = $r' <<<"$header") || return 1
    tail -n +2 "$1" > "$1.body"
    printf '%s\n' "$header" | cat - "$1.body" > "$1.new"
    mv "$1.new" "$1" && rm -f "$1.body"
}
age_file "$entryS" 7200
fake_curl_fail
mS="$(mktemp)"; rm -f "$mS"
outS="$(fetch_url_with_retry "https://registry.npmjs.org/mypkg" "$mS" 2>/dev/null)"
assert_eq "failed refresh falls back to validated stale" "0" "$?"
assert_eq "stale provenance recorded" "cached-stale" "$(meta_field "$mS" provenance)"
assert_contains "stale body served" '"a":1' "$outS"

# Corrupt header + dead network -> fail closed, entry deleted.
printf 'this is not json\n{"a":1}\n' > "$entryS"
mX="$(mktemp)"; rm -f "$mX"
fetch_url_with_retry "https://registry.npmjs.org/mypkg" "$mX" >/dev/null 2>&1
assert_eq "corrupt entry fails closed with dead network" "1" "$?"
assert_file_absent "corrupt entry deleted" "$entryS"
teardown

# ---------------------------------------------------------------------------
echo "=== 6. Parallel event accounting ==="
setup
par_file="$(mktemp)"; printf '{"p":1}' > "$par_file"
fake_curl_ok "$par_file"
fetch_url_with_retry "https://api.github.com/repos/o/r/releases" >/dev/null 2>&1
fake_curl_fail
(
    fetch_url_with_retry "https://api.github.com/repos/o/r/releases" >/dev/null 2>&1 &
    fetch_url_with_retry "https://api.github.com/repos/o/r/releases" >/dev/null 2>&1 &
    fetch_url_with_retry "https://api.github.com/repos/o/r/releases" >/dev/null 2>&1 &
    wait
)
assert_eq "three subshell hits -> three event files" "3" "$(find "$EVENTS_DIR" -type f | wc -l | tr -d ' ')"
summary="$(http_cache_hit_summary)"
assert_contains "summary counts 3 hits" "count=3" "$summary"
assert_contains "summary reports oldest age" "oldest_age=" "$summary"
teardown

# ---------------------------------------------------------------------------
echo "=== 7. Pruning: entry-count and byte budgets, HTTP namespace only ==="
export BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES=5
export BREW_CHANGE_HTTP_CACHE_MAX_BYTES=4096
mkdir -p "$(http_dir)"
i=0
while (( i < 8 )); do
    printf '{"retrieved_at":%d,"ttl":3600,"kind":"json"}\n{"n":%d}\n' "$((TEST_NOW - 1000 + i))" "$i" \
        > "$(http_dir)/entry-$i.cache"
    i=$((i + 1))
done
# Unrelated state that pruning must never touch.
printf 'legacy\n' > "$BREW_CHANGE_CACHE_DIR/abc123.json"
mkdir -p "$BREW_CHANGE_CACHE_DIR/brew-info"
printf 'x' > "$BREW_CHANGE_CACHE_DIR/brew-info/node.formula.json"
printf 'y' > "$BREW_CHANGE_CACHE_DIR/github-patterns.json"
http_cache_prune
remaining=$(find "$(http_dir)" -name '*.cache' | wc -l | tr -d ' ')
assert_eq "entry budget enforced" "5" "$remaining"
if find "$(http_dir)" -name '*.cache' | grep -q 'entry-0.cache'; then bad "oldest entry survived prune"; else ok "oldest entries pruned first"; fi
assert_file_present "legacy flat cache untouched" "$BREW_CHANGE_CACHE_DIR/abc123.json"
assert_file_present "brew-info cache untouched" "$BREW_CHANGE_CACHE_DIR/brew-info/node.formula.json"
assert_file_present "github-patterns.json untouched" "$BREW_CHANGE_CACHE_DIR/github-patterns.json"
# Byte budget: two entries exceeding 4096 total bytes.
export BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES=512
printf '{"retrieved_at":%d,"ttl":3600,"kind":"text"}\n%s\n' "$((TEST_NOW - 50))" "$(head -c 2500 /dev/zero | tr '\0' 'a')" > "$(http_dir)/big-old.cache"
printf '{"retrieved_at":%d,"ttl":3600,"kind":"text"}\n%s\n' "$TEST_NOW" "$(head -c 2500 /dev/zero | tr '\0' 'b')" > "$(http_dir)/big-new.cache"
http_cache_prune
if [[ -e "$(http_dir)/big-old.cache" ]]; then bad "byte budget did not evict oldest big entry"; else ok "byte budget evicts oldest big entry"; fi
assert_file_present "newest big entry kept while within count budget" "$(http_dir)/big-new.cache"
unset BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES BREW_CHANGE_HTTP_CACHE_MAX_BYTES
export BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES="${BREW_CHANGE_HTTP_CACHE_MAX_ENTRIES:-512}"

# ---------------------------------------------------------------------------
echo "=== 8. --fresh isolation helper ==="
setup
fresh_file="$(mktemp)"; printf '{"f":1}' > "$fresh_file"
fake_curl_ok "$fresh_file"
fetch_url_with_retry "https://api.github.com/repos/o/r/releases" >/dev/null 2>&1
assert_file_present "http cache populated before fresh reset" "$(http_dir)"
http_cache_reset_fresh
assert_file_present "http dir recreated empty" "$(http_dir)"
assert_eq "http namespace now empty" "0" "$(find "$(http_dir)" -type f | wc -l | tr -d ' ')"
assert_file_present "legacy flat cache survives --fresh" "$BREW_CHANGE_CACHE_DIR/abc123.json"
assert_file_present "brew-info cache survives --fresh" "$BREW_CHANGE_CACHE_DIR/brew-info/node.formula.json"
assert_file_present "github-patterns.json survives --fresh" "$BREW_CHANGE_CACHE_DIR/github-patterns.json"
teardown

# ---------------------------------------------------------------------------
printf '\nHTTP cache tests: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
