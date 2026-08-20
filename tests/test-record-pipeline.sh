#!/usr/bin/env bash
# Tests for the T2.1.2 normalized assessment record pipeline.
#
# Covers the approved record contract (docs/research-005):
#   - inventory emits one initial 16-key record per outdated package
#   - brew info two-layer caching (per-run memo, cross-run TTL, invalidation)
#   - evidence appends merge-by-package into assessment.jsonl (atomic rewrite)
#   - malformed line policy (logged, force-classified unknown, never dropped)
#   - classification delegates to classify_assessment_records
#
# Harness: fake brew from tests/lib/test-utils.sh; deterministic via
# BREW_CHANGE_TEST_NOW and explicit mtimes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"

source "$SCRIPT_DIR/lib/test-utils.sh"
setup_command_harness || exit 1

export BREW_CHANGE_SUBPROCESS="true"
export BREW_CHANGE_CACHE_DIR="$COMMAND_HARNESS_ROOT/cache"
mkdir -p "$BREW_CHANGE_CACHE_DIR"

source "$LIB_DIR/brew-change-config.sh"
source "$LIB_DIR/brew-change-utils.sh"
source "$LIB_DIR/brew-change-breaking.sh"
source "$LIB_DIR/brew-change-assessment.sh"
source "$LIB_DIR/brew-change-brew.sh"
source "$LIB_DIR/brew-change-upgrade.sh"
source "$LIB_DIR/brew-change-github.sh"
source "$LIB_DIR/brew-change-npm.sh"
source "$LIB_DIR/brew-change-non-github.sh"
source "$LIB_DIR/brew-change-display.sh"

# The launcher sets this flag after sourcing the libs; mirror it so display
# helpers that reference it under `set -u` resolve deterministically.
IDENTIFY_BREAKING="${IDENTIFY_BREAKING:-false}"

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

assert_record_field() {
    local desc="$1" file="$2" pkg="$3" filter="$4" expected="$5"
    local actual
    actual=$(grep -F "\"package\":\"$pkg\"" "$file" | head -1 | jq -r "$filter")
    assert_eq "$desc" "$expected" "$actual"
}

outdated_json() { cat "$FIXTURE_DIR/outdated-mixed.json"; }

run_dir=""
setup_run() {
    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-change-record.XXXXXX")
    export UPGRADE_STATUS_DIR="$run_dir"
}
teardown_run() {
    unset UPGRADE_STATUS_DIR
    [[ -z "$run_dir" ]] || rm -rf "$run_dir"
    run_dir=""
}

fake_brew_info() {
    configure_fake_command brew "" "" 0
    printf '%s' "$1" > "$COMMAND_HARNESS_CONFIG/brew/stdout"
}

brew_info_calls() {
    local n
    n=$(grep -c $'^brew\tinfo\t--json=v2\t' "$COMMAND_HARNESS_LOG" 2>/dev/null) || true
    printf '%s' "${n:-0}"
}

trap 'teardown_run; teardown_command_harness' EXIT

echo "======================================"
echo "Assessment Record Pipeline Tests"
echo "======================================"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 1: Inventory emits initial records ==="
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"

assert_eq "assessment.jsonl has 3 records" "3" "$(wc -l < "$run_dir/assessment.jsonl" | tr -d ' ')"
assert_record_field "node identity" "$run_dir/assessment.jsonl" node '.package' "node"
assert_record_field "node kind" "$run_dir/assessment.jsonl" node '.kind' "formula"
assert_record_field "node installed_version" "$run_dir/assessment.jsonl" node '.installed_version' "22.6.0"
assert_record_field "node available_version" "$run_dir/assessment.jsonl" node '.available_version' "22.8.0"
assert_record_field "cask token fallback" "$run_dir/assessment.jsonl" claude-code '.package' "claude-code"
assert_record_field "cask kind" "$run_dir/assessment.jsonl" claude-code '.kind' "cask"
assert_record_field "rectangle installed" "$run_dir/assessment.jsonl" rectangle '.installed_version' "0.88"
assert_record_field "evidence null pre-evidence" "$run_dir/assessment.jsonl" node '.evidence_source' "null"
assert_record_field "classification empty pre-classification" "$run_dir/assessment.jsonl" node '.classification' ''
assert_eq "all records carry full 16-key schema" "3" \
    "$(jq -c 'select((keys | length) == 16 and (.reasons|type)=="array")' "$run_dir/assessment.jsonl" | wc -l | tr -d ' ')"

echo ""
echo "Test: unclassified initial records classify to unknown via engine"
classify_upgrade_evidence "$run_dir" node rectangle claude-code
unknown_list="$(printf '%s ' "${UNKNOWN_PKGS[@]}")"; unknown_list="${unknown_list% }"
assert_eq "all three packages UNKNOWN without evidence" "node rectangle claude-code" "$unknown_list"
assert_eq "counts sum to inventory" "3" "$(( ${#ATTENTION_PKGS[@]} + ${#NO_SIGNAL_PKGS[@]} + ${#UNKNOWN_PKGS[@]} ))"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: brew info memoization (single fetch per run) ==="
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"
fake_brew_info '{"formulae":[{"name":"node","versions":{"stable":"22.8.0"}}],"casks":[]}'

get_brew_info node >/dev/null
get_brew_info node >/dev/null
get_brew_info node >/dev/null
assert_eq "brew info fetched at most once for 3 lookups" "1" "$(brew_info_calls)"

echo ""
echo "Test: per-run memo file exists and satisfies later subshells"
assert_eq "memo file written" "yes" "$([[ -f "$run_dir/brew-info/$(printf '%s' node | jq -sRr '@uri')".json ]] && echo yes || echo no)"
memo_before=$(brew_info_calls)
( get_brew_info node >/dev/null )
assert_eq "subshell lookup hits memo (no new fetch)" "$memo_before" "$(brew_info_calls)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: Cross-run cache TTL ==="
: > "$COMMAND_HARNESS_LOG"
setup_run
cache_file="$BREW_CHANGE_CACHE_DIR/brew-info/$(printf '%s' git | jq -sRr '@uri').json"
mkdir -p "$(dirname "$cache_file")"
printf '%s' '{"formulae":[{"name":"git","versions":{"stable":"2.50.0"}}],"casks":[]}' > "$cache_file"
# Fresh: mtime = now
fake_brew_info '{"formulae":[{"name":"git","versions":{"stable":"99.0.0"}}],"casks":[]}'
result=$(get_brew_info git)
assert_eq "TTL hit within 300s" "2.50.0" "$(printf '%s' "$result" | jq -r '.formulae[0].versions.stable')"
assert_eq "TTL hit performs no fetch" "0" "$(brew_info_calls)"

echo ""
echo "Test: TTL expiry refetches"
touch -t "$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-10 minutes' +%Y%m%d%H%M.%S)" "$cache_file"
# Probe layer 3 from a fresh run dir: the earlier hit in this run correctly
# wrote the per-run memo (fetch-at-most-once-per-run contract), and that memo
# would serve the memoized payload without consulting the now-expired
# cross-run entry.
setup_run
result=$(get_brew_info git)
assert_eq "expired entry refetched" "99.0.0" "$(printf '%s' "$result" | jq -r '.formulae[0].versions.stable')"
assert_eq "expired entry caused one fetch" "1" "$(brew_info_calls)"

echo ""
echo "Test: outdated version invalidates cached entry"
cache_file_node="$BREW_CHANGE_CACHE_DIR/brew-info/$(printf '%s' node | jq -sRr '@uri').json"
printf '%s' '{"formulae":[{"name":"node","versions":{"stable":"22.7.0"}}],"casks":[]}' > "$cache_file_node"
touch "$cache_file_node"
fake_brew_info '{"formulae":[{"name":"node","versions":{"stable":"22.8.0"}}],"casks":[]}'
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"   # outdated says 22.8.0 > cached 22.7.0
result=$(get_brew_info node)
assert_eq "stale-vs-outdated cache invalidated" "22.8.0" "$(printf '%s' "$result" | jq -r '.formulae[0].versions.stable')"

echo ""
echo "Test: same-version cache is kept"
cache_file_rect="$BREW_CHANGE_CACHE_DIR/brew-info/$(printf '%s' rectangle | jq -sRr '@uri').json"
printf '%s' '{"formulae":[],"casks":[{"token":"rectangle","version":"0.92"}]}' > "$cache_file_rect"
touch "$cache_file_rect"
: > "$COMMAND_HARNESS_LOG"
result=$(get_brew_info rectangle)
assert_eq "matching cache still used" "0.92" "$(printf '%s' "$result" | jq -r '.casks[0].version')"
assert_eq "no refetch for matching cache" "0" "$(brew_info_calls)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3b: warm cross-run cache + fresh run dir writes the memo ==="
# Regression (v1.14.3 field report): on a cross-run cache HIT the memo write
# ran before any fetch had created <run_dir>/brew-info, so the redirection
# failed with "No such file or directory" on stderr for every warm package
# until the first cache MISS fetched. Reproduce exactly that state: a fresh
# empty run dir (no brew-info subdir, no inventory yet), a cache file whose
# mtime is inside the TTL, and no prior lookup of the package in this shell.
setup_run
warm_pkg="htop"
warm_enc=$(record_encode_name "$warm_pkg")
warm_cache="$BREW_CHANGE_CACHE_DIR/brew-info/$warm_enc.json"
mkdir -p "$(dirname "$warm_cache")"
printf '%s' '{"formulae":[{"name":"htop","versions":{"stable":"3.4.0"}}],"casks":[]}' > "$warm_cache"
touch "$warm_cache"   # mtime = now, inside the 300s TTL
: > "$COMMAND_HARNESS_LOG"
warm_err="$(mktemp "${TMPDIR:-/tmp}/brew-change-warm-stderr.XXXXXX")"

result=$(get_brew_info "$warm_pkg" 2>"$warm_err")

assert_eq "warm cache hit returns cached data" "3.4.0" \
    "$(printf '%s' "$result" | jq -r '.formulae[0].versions.stable')"
assert_eq "warm cache hit performs no fetch" "0" "$(brew_info_calls)"
assert_eq "warm cache hit is silent on stderr" "no" \
    "$([[ -s "$warm_err" ]] && echo yes || echo no)"
assert_eq "warm cache hit creates the per-run memo file" "yes" \
    "$([[ -f "$run_dir/brew-info/$warm_enc.json" ]] && echo yes || echo no)"
assert_eq "per-run memo holds the cached payload" "3.4.0" \
    "$(jq -r '.formulae[0].versions.stable' "$run_dir/brew-info/$warm_enc.json" 2>/dev/null)"
rm -f "$warm_err"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 4: Evidence merge round-trip ==="
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"
unicode_pkg="pkg-ünïcode-🍺"
snapshot=$'## Changes\n- BREAKING: removed legacy flag\n- "quoted" \ttab and unicode 🎁'

append_assessment_evidence "$unicode_pkg" "github" "https://github.com/ex/rel" "1723900000" "fresh" "$snapshot"
append_assessment_evidence "node" "github" "https://github.com/node/node/releases/tag/v22.8.0" "1723900000" "fresh" $'## Changes\n- bug fixes'
consolidate_assessment_records "$run_dir"

# unicode package was not in inventory; merge adds it as a record
merged=$(grep -F '"package":"pkg-ünïcode-🍺"' "$run_dir/assessment.jsonl" | head -1)
assert_eq "unicode snapshot round-trips byte-exact" "$snapshot" "$(printf '%s' "$merged" | jq -r '.evidence_snapshot')"
assert_eq "unicode URL preserved" "https://github.com/ex/rel" "$(printf '%s' "$merged" | jq -r '.evidence_url')"
assert_eq "retrieved_at numeric" "1723900000" "$(printf '%s' "$merged" | jq -r '.retrieved_at')"
assert_record_field "node evidence merged into existing record" "$run_dir/assessment.jsonl" node '.retrieval_status' "fresh"
assert_record_field "node identity preserved after merge" "$run_dir/assessment.jsonl" node '.available_version' "22.8.0"
assert_eq "merge keeps one record per known package" "1" "$(grep -cF '"package":"node"' "$run_dir/assessment.jsonl")"
assert_eq "merged stream stays strict 16-key" "4" \
    "$(jq -c 'select((keys | length) == 16)' "$run_dir/assessment.jsonl" | wc -l | tr -d ' ')"

echo ""
echo "Test: classification consumes merged records (delegation)"
classify_upgrade_evidence "$run_dir" node rectangle claude-code "$unicode_pkg"
no_signal_list="$(printf '%s ' "${NO_SIGNAL_PKGS[@]}")"; no_signal_list="${no_signal_list% }"
assert_eq "node fresh no-signal -> NO_SIGNAL" "node" "$no_signal_list"
attention_list="$(printf '%s ' "${ATTENTION_PKGS[@]}")"; attention_list="${attention_list% }"
assert_eq "unicode BREAKING snapshot -> ATTENTION" "$unicode_pkg" "$attention_list"
assert_record_field "assessment.jsonl rewritten with classification" "$run_dir/assessment.jsonl" node '.classification' "no-signal"
assert_record_field "attention reasons recorded" "$run_dir/assessment.jsonl" "$unicode_pkg" '.matched_signals[0]' "breaking-change-pattern"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 5: Malformed line policy ==="
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"
printf '%s\n' '{"package":"broken-pkg","retrieval_status":"fresh"' >> "$run_dir/evidence.jsonl"   # truncated JSON
printf 'not json at all\n' >> "$run_dir/evidence.jsonl"
consolidate_assessment_records "$run_dir" 2>/dev/null
assert_eq "malformed evidence lines are not dropped silently" "5" "$(wc -l < "$run_dir/assessment.jsonl" | tr -d ' ')"
malformed_count=$(jq -r 'select(.retrieval_status == "malformed") | .package' "$run_dir/assessment.jsonl" | wc -l | tr -d ' ')
assert_eq "malformed lines force unknown records" "2" "$malformed_count"

echo ""
echo "Test: malformed record in assessment stream classifies unknown"
printf '%s\n' 'garbage line {' >> "$run_dir/assessment.jsonl"
classify_upgrade_evidence "$run_dir" 2>/dev/null
assert_eq "malformed lines dedup to one record per package after classification" "4" "$(wc -l < "$run_dir/assessment.jsonl" | tr -d ' ')"
bad_classification=$(grep -F '"retrieval_status":"malformed"' "$run_dir/assessment.jsonl" | head -1 | jq -r '.classification')
assert_eq "malformed record classified unknown" "unknown" "$bad_classification"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 6: Progress events ==="
setup_run
: > "$run_dir/progress.jsonl"
append_progress_event "evidence" 1 3 "node"
append_progress_event "evidence" 2 3 "git"
event=$(tail -1 "$run_dir/progress.jsonl")
assert_eq "progress event schema" '{"stage":"evidence","completed":2,"total":3,"package":"git"}' "$event"
unset_progress=$(UPGRADE_STATUS_DIR= append_progress_event "evidence" 1 3 "x" 2>/dev/null; echo $?)
assert_eq "progress event no-ops without run dir" "0" "$unset_progress"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 7: no-notes terminal paths record unavailable, not missing ==="
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"

# Non-GitHub package whose evidence search runs but finds nothing.
wget_info='{"name":"wget","homepage":"https://www.gnu.org/software/wget/","urls":{"stable":{"url":"https://ftp.gnu.org/gnu/wget/wget-1.25.tar.gz"}},"versions":{"stable":"1.25"}}'
fake_brew_info "{\"formulae\":[$wget_info],\"casks\":[]}"
fetch_non_github_release_notes() { return 1; }

no_notes_output=$(show_package_changelog_full "wget" "1.24" "1.25" "$wget_info" 2>/dev/null)

assert_eq "no-notes output announces the search" "yes" \
    "$(printf '%s' "$no_notes_output" | grep -qF 'Searching for release notes' && echo yes || echo no)"
assert_eq "no-notes output shows the terminal marker" "yes" \
    "$(printf '%s' "$no_notes_output" | grep -qF 'No release notes available' && echo yes || echo no)"

consolidate_assessment_records "$run_dir"
classify_upgrade_evidence "$run_dir" >/dev/null 2>&1
wget_record=$(grep -F '"package":"wget"' "$run_dir/assessment.jsonl" | head -1)
assert_eq "no-notes package has a consolidated record" "yes" \
    "$([[ -n "$wget_record" ]] && echo yes || echo no)"
assert_eq "no-notes retrieval_status is unavailable (search ran, found nothing)" "unavailable" \
    "$(printf '%s' "$wget_record" | jq -r '.retrieval_status')"
assert_eq "no-notes evidence_url preserves the review URL" "https://www.gnu.org/software/wget/" \
    "$(printf '%s' "$wget_record" | jq -r '.evidence_url')"
assert_eq "no-notes classification stays unknown" "unknown" \
    "$(printf '%s' "$wget_record" | jq -r '.classification')"
assert_eq "no-notes reason names unavailable, not missing" "evidence retrieval status: unavailable" \
    "$(printf '%s' "$wget_record" | jq -r '.reasons[] | select(startswith("evidence retrieval status"))')"
assert_eq "no timestamped evidence exists for no-notes" "null" \
    "$(printf '%s' "$wget_record" | jq -r '.retrieved_at')"

echo ""
echo "=== Suite 8: process_release_notes no-notes path records unavailable ==="
setup_run

# Exercise the shared utils.sh branch directly (empty release JSON + non-GitHub
# source). Callers historically supplied $homepage only via dynamic scoping,
# so seed one to mirror that calling convention; the fix must not depend on it.
homepage="https://www.example.com/home"
fetch_non_github_release_notes() { return 1; }
show_non_github_fallback() { echo "STUB fallback for: $1"; }

process_release_notes "nostalgia" "2.1" "" "https://example.com/pkg" "" >/dev/null 2>&1

nostalgia_row=$(grep -F '"package":"nostalgia"' "$run_dir/evidence.jsonl" 2>/dev/null | head -1)
assert_eq "utils no-notes branch writes an evidence row" "yes" \
    "$([[ -n "$nostalgia_row" ]] && echo yes || echo no)"
assert_eq "utils no-notes retrieval_status is unavailable" "unavailable" \
    "$(printf '%s' "$nostalgia_row" | jq -r '.retrieval_status // empty')"
assert_eq "utils no-notes source is the source domain" "example.com" \
    "$(printf '%s' "$nostalgia_row" | jq -r '.evidence_source // empty')"
assert_eq "utils no-notes url falls back to domain (no homepage in scope)" "https://example.com" \
    "$(printf '%s' "$nostalgia_row" | jq -r '.evidence_url // empty')"

echo ""
echo "Test: plain flow (no run dir) still no-ops and succeeds"
unset_homepage_rc=$(UPGRADE_STATUS_DIR= homepage= process_release_notes "nostalgia" "2.1" "" "https://example.com/pkg" "" >/dev/null 2>&1; echo $?)
assert_eq "no run dir: process_release_notes succeeds without evidence writes" "0" "$unset_homepage_rc"
assert_eq "no run dir: no stray evidence.jsonl in cwd" "no" \
    "$([[ -f "$PWD/evidence.jsonl" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------

echo "Test: cache invalidation survives set -e with a current cache"
# Regression: a false [[ ]] && rm at function tail returned 1, and the
# launcher's set -euo pipefail killed the whole run silently once the
# cross-run cache was populated.
CURRENT_JSON='{"formulae":[{"name":"git","current_version":"2.50.0"}],"casks":[]}'
mkdir -p "$BREW_CHANGE_CACHE_DIR/brew-info"
cur_enc=$(record_encode_name "git")
printf '%s' '{"formulae":[{"name":"git","versions":{"stable":"2.50.0"}}],"casks":[]}' \
    > "$BREW_CHANGE_CACHE_DIR/brew-info/$cur_enc.json"
(
    set -e
    _invalidate_stale_brew_info_cache "$CURRENT_JSON"
)
assert_eq "invalidation returns 0 under set -e" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 9: evidence provenance truthfulness (T3.2.1/T3.2.2) ==="
# A cached serve must not be stamped as newly retrieved: the record keeps
# the original retrieval epoch and a cached-fresh status, and no network
# request happens (research-008 Decision 3).

node_info='{"name":"node","homepage":"https://github.com/node/node","urls":{"stable":{"url":"https://nodejs.org/dist/node-v22.8.0.tar.gz"}},"versions":{"stable":"22.8.0"}}'
node_release='{"tag_name":"v22.8.0","published_at":"2026-08-01T00:00:00Z","html_url":"https://github.com/node/node/releases/tag/v22.8.0","body":"## Changes\n- bug fixes and performance work"}'

install_dispatching_curl() { # status body  — URL-aware fake curl for the GitHub tag endpoint
    local status="$1" body="$2"
    cat > "$COMMAND_HARNESS_BIN/curl" <<FAKE_CURL
#!/usr/bin/env bash
output="" headers="" write_out="" url=""
{
    printf 'curl'
    for arg in "\$@"; do printf '\t%s' "\$arg"; done
    printf '\n'
} >> "\$COMMAND_HARNESS_LOG"
while (( \$# )); do
    case "\$1" in
        -o) output="\$2"; shift 2 ;;
        -D) headers="\$2"; shift 2 ;;
        -w) write_out="\$2"; shift 2 ;;
        https://*) url="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$url" in
    https://api.github.com/repos/node/node/releases/tags/*)
        printf 'HTTP/1.1 $status OK\r\n\r\n' > "\$headers"
        printf '%s' '$body' > "\$output"
        [[ -n "\$write_out" ]] && printf '${status}'
        exit 0
        ;;
esac
exit 125
FAKE_CURL
    chmod +x "$COMMAND_HARNESS_BIN/curl"
}

T1=$((1800000000))
T2=$((T1 + 600))

# First run: network fetch, provenance network-fresh.
export BREW_CHANGE_TEST_NOW="$T1"
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"
fake_brew_info "{\"formulae\":[$node_info],\"casks\":[]}"
install_dispatching_curl 200 "$node_release"
: > "$COMMAND_HARNESS_LOG"
show_package_changelog_full "node" "22.6.0" "22.8.0" "$node_info" >/dev/null 2>&1
consolidate_assessment_records "$run_dir"
node_row=$(grep -F '"package":"node"' "$run_dir/assessment.jsonl" | head -1)
assert_eq "network run records retrieval_status fresh" "fresh" \
    "$(printf '%s' "$node_row" | jq -r '.retrieval_status')"
assert_eq "network run records the fetch epoch" "$T1" \
    "$(printf '%s' "$node_row" | jq -r '.retrieved_at')"
assert_eq "network run hit the endpoint once" "1" \
    "$(grep -c 'releases/tags' "$COMMAND_HARNESS_LOG" || true)"
teardown_run

# Second run ten minutes later, network dead: cached serve must keep the
# ORIGINAL epoch and tell the truth about reuse.
export BREW_CHANGE_TEST_NOW="$T2"
setup_run
assessment_record_init "$run_dir" "$(outdated_json)"
fake_brew_info "{\"formulae\":[$node_info],\"casks\":[]}"
install_dispatching_curl 503 '{"message":"Service Unavailable"}'
: > "$COMMAND_HARNESS_LOG"
show_package_changelog_full "node" "22.6.0" "22.8.0" "$node_info" >/dev/null 2>&1
consolidate_assessment_records "$run_dir"
classify_upgrade_evidence "$run_dir" >/dev/null 2>&1
node_row2=$(grep -F '"package":"node"' "$run_dir/assessment.jsonl" | head -1)
assert_eq "cached run records cached-fresh, not fresh" "cached-fresh" \
    "$(printf '%s' "$node_row2" | jq -r '.retrieval_status')"
assert_eq "cached run keeps the original retrieval epoch" "$T1" \
    "$(printf '%s' "$node_row2" | jq -r '.retrieved_at')"
assert_eq "cached run performs no network request" "0" \
    "$(grep -c 'releases/tags' "$COMMAND_HARNESS_LOG" || true)"
assert_eq "cached adequate evidence still classifies no-signal" "no-signal" \
    "$(printf '%s' "$node_row2" | jq -r '.classification')"
teardown_run
unset BREW_CHANGE_TEST_NOW

echo ""
echo "======================================"
echo "Record Pipeline Results: $pass passed, $fail failed"
echo "======================================"
[[ $fail -eq 0 ]]
