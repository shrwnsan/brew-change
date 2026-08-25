#!/usr/bin/env bash
# T2.5.2 — dashboard action-state machine conformance (research-007 §1).
#
# Deterministic state×input coverage: the terminal readers
# (_dashboard_read_key/_dashboard_read_line) are overridden with scripted
# queues so every DASHBOARD/REVIEW/SELECT/UPGRADE outcome is exercised
# without a TTY; execution goes through a recording override of
# run_upgrade_with_preview (the sole boundary). The real readers' terminal
# hygiene (stty/signals/timeout/stale Enter) is covered by the PTY suite
# this script invokes last (tests/test-dashboard-actions.py).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-dashboard-ui.sh"

FIXTURE="$SCRIPT_DIR/fixtures/dashboard/mixed/input.jsonl"

passed=0
failed=0
pass() { passed=$(( passed + 1 )); }
fail() { failed=$(( failed + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Small deterministic record set: attention (node, postgresql@16),
# no-signal (bat, curl), unknown (docker) — in that record order.
RECORDS="$TMPDIR_TEST/records.jsonl"
jq -c 'select(.package == "node" or .package == "postgresql@16"
             or .package == "bat" or .package == "curl"
             or .package == "docker")' "$FIXTURE" > "$RECORDS"
ALL_UNKNOWN="$TMPDIR_TEST/all-unknown.jsonl"
jq -c 'select(.classification == "unknown")' "$FIXTURE" > "$ALL_UNKNOWN"

# Expected canonical sets (record order).
NS_SET="bat curl"
ALL_SET="node postgresql@16 bat curl docker"

# ---------------------------------------------------------------------------
# Test-time reader overrides: scripted queues; exhausted queue = EOF.
# ---------------------------------------------------------------------------
KEY_QUEUE=()
KEY_I=0
_dashboard_read_key() { # varname
    local __var="$1"
    if (( KEY_I >= ${#KEY_QUEUE[@]} )); then
        return 1
    fi
    printf -v "$__var" '%s' "${KEY_QUEUE[$KEY_I]}"
    KEY_I=$(( KEY_I + 1 ))
    return 0
}

LINE_QUEUE=()
LINE_I=0
_dashboard_read_line() { # varname
    local __var="$1"
    if (( LINE_I >= ${#LINE_QUEUE[@]} )); then
        return 1
    fi
    printf -v "$__var" '%s' "${LINE_QUEUE[$LINE_I]}"
    LINE_I=$(( LINE_I + 1 ))
    return 0
}

# SELECT raw-action translation: scripted line entries replay as their
# characters (CHR) followed by CONFIRM (Enter resolving the buffer) —
# exactly what a user typing the entry would produce in raw mode. The
# tokens UP/DOWN/TOGGLE/BS/CLEAR map to the arrow-navigation actions with
# no Enter appended. Exhausted queue = EOF, same contract as above.
SELECT_PENDING=""
_dashboard_select_read_action() { # varname
    local __var="$1"
    if [[ -n "$SELECT_PENDING" ]]; then
        case "$SELECT_PENDING" in
            UP|DOWN|TOGGLE|BS|CLEAR)
                printf -v "$__var" '%s' "$SELECT_PENDING"
                SELECT_PENDING=""
                return 0
                ;;
        esac
        if [[ "$SELECT_PENDING" == $'\n' ]]; then
            SELECT_PENDING=""
            printf -v "$__var" 'CONFIRM'
            return 0
        fi
        printf -v "$__var" 'CHR:%s' "${SELECT_PENDING:0:1}"
        SELECT_PENDING="${SELECT_PENDING:1}"
        return 0
    fi
    if (( LINE_I >= ${#LINE_QUEUE[@]} )); then
        return 1
    fi
    local entry="${LINE_QUEUE[$LINE_I]}"
    LINE_I=$(( LINE_I + 1 ))
    case "$entry" in
        UP|DOWN|TOGGLE|BS|CLEAR)
            printf -v "$__var" '%s' "$entry"
            return 0
            ;;
        "")
            printf -v "$__var" 'CONFIRM'
            return 0
            ;;
        type1:*)
            # Partial typing: chars with NO trailing Enter — lets a
            # scenario interrupt a half-typed buffer mid-word.
            SELECT_PENDING="${entry#type1:}"
            printf -v "$__var" 'CHR:%s' "${SELECT_PENDING:0:1}"
            SELECT_PENDING="${SELECT_PENDING:1}"
            return 0
            ;;
        *)
            SELECT_PENDING="$entry"$'\n'
            printf -v "$__var" 'CHR:%s' "${SELECT_PENDING:0:1}"
            SELECT_PENDING="${SELECT_PENDING:1}"
            return 0
            ;;
    esac
}

# Route cosmetic /dev/tty messages to stdout so assertions can see them.
_dashboard_say() { echo "$1"; }
# shellcheck disable=SC2059 # format passthrough mirrors the module helper
_dashboard_note() { printf "$@"; }

# Execution-boundary recorder.
UPGRADE_CALLS="$TMPDIR_TEST/upgrade-calls"
run_upgrade_with_preview() {
    printf '%s\n' "$*" >> "$UPGRADE_CALLS"
    return "${UPGRADE_RC:-0}"
}

# Inventory fetch recorder (also flags any refetch from REVIEW).
FETCH_LOG="$TMPDIR_TEST/fetch-log"
FETCH_JSON="{}"
_dashboard_fetch_outdated_json() {
    echo "fetch" >> "$FETCH_LOG"
    echo "$FETCH_JSON"
}

REFRESH_LOG="$TMPDIR_TEST/refresh-log"
test_refresh() {
    echo "refresh" >> "$REFRESH_LOG"
    echo "none"
}

# Drive run_dashboard_mode in a subshell (it always exits) and capture
# stdout+exit status: drive <records> <expected_status>
drive() {
    local rec="$1"; local expect_status="$2"
    KEY_I=0 LINE_I=0
    : > "$UPGRADE_CALLS"; : > "$FETCH_LOG"; : > "$REFRESH_LOG"
    OUT="$( run_dashboard_mode "$rec" test_refresh 2>&1 )"
    STATUS=$?
    if [[ "$STATUS" != "$expect_status" ]]; then
        fail "drive($rec): exit $STATUS, expected $expect_status
$OUT"
        return 1
    fi
    return 0
}

upgrade_args() { tr '\n' ' ' < "$UPGRADE_CALLS" | sed 's/ $//'; }

# --- DASHBOARD -------------------------------------------------------------

# q -> exit 0, no mutation
KEY_QUEUE=(q)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"Dashboard closed."* ]] \
    && [[ ! -s "$UPGRADE_CALLS" ]] \
    && pass || fail "DASHBOARD q: exit 0, closed, no upgrade call"

# EOF (empty queue) -> exit 0
KEY_QUEUE=()
drive "$RECORDS" 0 && [[ ! -s "$UPGRADE_CALLS" ]] \
    && pass || fail "DASHBOARD EOF: exit 0, no upgrade call"

# invalid -> hint, then a prompt-only reprompt: the dashboard summary must
# appear exactly once (no full re-render for the invalid key); then q
KEY_QUEUE=(x q)
drive "$RECORDS" 0 && [[ "$OUT" == *"Invalid input 'x'. Type r/s/u/q"* ]] \
    && [[ "$(grep -c '5 outdated · 2 attention · 2 no-signal · 1 unknown' <<< "$OUT")" -eq 1 ]] \
    && pass || fail "DASHBOARD invalid: hint then prompt-only reprompt"

# r -> REVIEW list (grouped, continuous numbering, differential tokens);
# b -> back; q -> exit 0
EXPECTED_REVIEW_LIST="Review packages (5):

Needs attention (2)
   1) node — major-version-transition
   2) postgresql@16 — breaking-change-note

No risk signal found (2)
   3) bat
   4) curl

Unknown (1)
   5) docker — rate-limited

[b]ack · [q]uit · package number or name for detail"
KEY_QUEUE=(r q)
LINE_QUEUE=(b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"$EXPECTED_REVIEW_LIST"* ]] \
    && pass || fail "DASHBOARD r: grouped review list renders, b returns"

# Single group only: all-unknown records show only the Unknown header
KEY_QUEUE=(r q)
LINE_QUEUE=(b)
drive "$ALL_UNKNOWN" 0 \
    && [[ "$OUT" == *"Review packages"* ]] \
    && [[ "$OUT" != *"Needs attention ("* ]] \
    && [[ "$OUT" != *"No risk signal found ("* ]] \
    && [[ "$OUT" == *"Unknown ("* ]] \
    && pass || fail "REVIEW single group: empty groups omitted"

# Numbering stays unambiguous across groups: index 3 (first no-signal row)
# resolves to bat, index 5 (first unknown row) resolves to docker
KEY_QUEUE=(r q)
LINE_QUEUE=('3' '' b)
drive "$RECORDS" 0 && [[ "$OUT" == *"--- bat (3/5) ---"* ]] \
    && pass || fail "REVIEW continuous numbering: 3 -> bat"
KEY_QUEUE=(r q)
LINE_QUEUE=('5' '' b)
drive "$RECORDS" 0 && [[ "$OUT" == *"--- docker (5/5) ---"* ]] \
    && pass || fail "REVIEW continuous numbering: 5 -> docker"

# Attention fallback: no matched_signals -> compact first reason as the token
NO_SIGNALS_RECORDS="$TMPDIR_TEST/no-signals.jsonl"
jq -c 'select(.package == "node") | .matched_signals = []' "$RECORDS" \
    > "$NO_SIGNALS_RECORDS"
KEY_QUEUE=(r q)
LINE_QUEUE=(b)
drive "$NO_SIGNALS_RECORDS" 0 \
    && [[ "$OUT" == *"1) node — major version transition"* ]] \
    && pass || fail "REVIEW attention fallback: compact first reason token"

# Unknown "unavailable" status token is suppressed in the review list too
# (same rule as the dashboard's Unknown group); the row carries no suffix.
UNAVAIL_RECORDS="$TMPDIR_TEST/unavail.jsonl"
jq -c 'if .classification == "unknown" then .retrieval_status = "unavailable"
        else . end' "$RECORDS" > "$UNAVAIL_RECORDS"
KEY_QUEUE=(r q)
LINE_QUEUE=(b)
drive "$UNAVAIL_RECORDS" 0 \
    && grep -q '^ *5) docker$' <<< "$OUT" \
    && [[ "$OUT" != *'docker — unavailable'* ]] \
    && pass || fail "REVIEW unknown unavailable: token suppressed"

# Very long differential tokens are printed in full (no truncation)
LONG_TOKEN_RECORDS="$TMPDIR_TEST/long-token.jsonl"
LONG_REASON='an extremely long release-note reason sentence that keeps going and going far beyond any normal terminal width'
jq -c --arg r "$LONG_REASON" \
    'select(.package == "node") | .matched_signals = [] | .reasons = [$r]' \
    "$RECORDS" > "$LONG_TOKEN_RECORDS"
KEY_QUEUE=(r q)
LINE_QUEUE=(b)
drive "$LONG_TOKEN_RECORDS" 0 \
    && [[ "$OUT" == *"1) node — $LONG_REASON"* ]] \
    && pass || fail "REVIEW long token: printed in full"

# Quoted/backslash-heavy record strings must keep their row tokens: the
# record used to ride through @tsv, which doubles backslashes, so `\"`
# truncated the JSON at the first quote in release-note text — jq parse
# errors leaked into the drawn list and affected rows silently lost their
# tokens (fallback reason here; unknown status token below).
HOSTILE_RECORDS="$TMPDIR_TEST/hostile.jsonl"
jq -c --arg snap 'release notes with "quoted" text, path C:\Users\karma and 1.2.3 versions' \
    --arg reason 'Major "breaking" change (1.2.3 -> 2.0.0), see C:\path' \
    'if .package == "node" then
        .matched_signals = [] | .reasons = [$reason] | .evidence_snapshot = $snap
     else . end' "$RECORDS" > "$HOSTILE_RECORDS"
KEY_QUEUE=(r q)
LINE_QUEUE=(b)
drive "$HOSTILE_RECORDS" 0 \
    && [[ "$OUT" == *'1) node — major "breaking" change (1.2.3 -> 2.0.0), see C:\path'* ]] \
    && [[ "$OUT" == *'5) docker — rate-limited'* ]] \
    && [[ "$OUT" != *'parse error'* ]] \
    && [[ "$OUT" != *'jq: error'* ]] \
    && pass || fail "REVIEW hostile strings: tokens kept, no jq stderr leak"

# Detail browsing: n/p walk the grouped order and number/name jump without
# round-tripping through the list; Enter/b returns to the list.
KEY_QUEUE=(r q)
LINE_QUEUE=('1' 'n' 'n' 'p' '' b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"--- node (1/5) ---"* ]] \
    && [[ "$OUT" == *"--- postgresql@16 (2/5) ---"* ]] \
    && [[ "$OUT" == *"--- bat (3/5) ---"* ]] \
    && [[ "$OUT" != *"--- curl"* ]] \
    && [[ "$(grep -c 'Review packages (5):' <<< "$OUT")" -eq 2 ]] \
    && pass || fail "REVIEW browse: n/p walk order, Enter returns to list"

KEY_QUEUE=(r q)
LINE_QUEUE=('1' 'docker' '' b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"--- docker (5/5) ---"* ]] \
    && pass || fail "REVIEW browse: number/name jump from detail"

KEY_QUEUE=(r q)
LINE_QUEUE=('1' 'p' '5' 'n' '' b)
drive "$RECORDS" 0 \
    && [[ "$(grep -c 'No previous package.' <<< "$OUT")" -eq 1 ]] \
    && [[ "$(grep -c 'No next package.' <<< "$OUT")" -eq 1 ]] \
    && pass || fail "REVIEW browse: n/p clamp at both ends"

# u -> UPGRADE with the exact no-signal set; inventory unchanged -> decline
# path: no refresh, records kept, dashboard re-rendered; then q
KEY_QUEUE=(u q)
FETCH_JSON='{"formulae":[{"name":"bat"},{"name":"curl"},{"name":"node"},{"name":"postgresql@16"},{"name":"docker"}],"casks":[]}'
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "$NS_SET" ]] \
    && [[ ! -s "$REFRESH_LOG" ]] \
    && [[ "$(grep -c 'Needs attention' <<< "$OUT")" -ge 1 ]] \
    && [[ "$OUT" == *'[r] Review · [s] Select · [u] Upgrade no-signal ('* ]] \
    && pass || fail "DASHBOARD u: no-signal set only, no refresh on unchanged inventory"

# Enter == u when the no-signal set is non-empty
KEY_QUEUE=($'\n' q)
drive "$RECORDS" 0 && [[ "$(upgrade_args)" == "$NS_SET" ]] \
    && pass || fail "DASHBOARD Enter: upgrades no-signal set"

# Enter with an empty no-signal set -> quit semantics (exit 0)
KEY_QUEUE=($'\n')
drive "$ALL_UNKNOWN" 0 \
    && [[ "$OUT" == *"Dashboard closed."* ]] \
    && [[ ! -s "$UPGRADE_CALLS" ]] \
    && pass || fail "DASHBOARD Enter (no no-signal): exit 0, no upgrade"

# u with an empty no-signal set -> hint, no execution
KEY_QUEUE=(u q)
drive "$ALL_UNKNOWN" 0 \
    && [[ "$OUT" == *"No no-signal packages to upgrade"* ]] \
    && [[ ! -s "$UPGRADE_CALLS" ]] \
    && pass || fail "DASHBOARD u (no no-signal): hint, no execution"

# UPGRADE completion (named set no longer outdated) -> refresh -> empty
# dashboard -> "No outdated packages." -> exit 0
KEY_QUEUE=(u)
FETCH_JSON='{"formulae":[],"casks":[]}'
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "$NS_SET" ]] \
    && [[ -s "$REFRESH_LOG" ]] \
    && [[ "$OUT" == *"No outdated packages."* ]] \
    && pass || fail "UPGRADE completion: refresh called, empty dashboard, exit 0"

# UPGRADE preview failure -> back to dashboard, plan discarded, no refresh
KEY_QUEUE=(u q)
UPGRADE_RC=1
drive "$RECORDS" 0 \
    && [[ ! -s "$REFRESH_LOG" ]] \
    && [[ "$OUT" == *"[q] Quit"* ]] \
    && pass || fail "UPGRADE failure: returns to dashboard, no refresh"
UPGRADE_RC=0

# --- REVIEW -----------------------------------------------------------------

# Detail by index: read-only fields from the record; file unchanged; no fetch
RECORDS_HASH_BEFORE=$(shasum "$RECORDS" | cut -d' ' -f1)
KEY_QUEUE=(r q)
LINE_QUEUE=(1 '' b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"--- node (1/5) ---"* ]] \
    && [[ "$OUT" == *"Evidence source:  github"* ]] \
    && [[ "$OUT" == *"Evidence URL:     https://example.com/node/releases"* ]] \
    && [[ "$OUT" == *"Retrieval status: fresh"* ]] \
    && [[ "$OUT" == *"Reason:           Major version transition (22 to 25)"* ]] \
    && [[ "$OUT" == *"Evidence snapshot:"* ]] \
    && [[ "$OUT" == *"retrieved"* ]] \
    && [[ ! -s "$FETCH_LOG" ]] \
    && [[ "$(shasum "$RECORDS" | cut -d' ' -f1)" == "$RECORDS_HASH_BEFORE" ]] \
    && pass || fail "REVIEW detail by index: record-driven, read-only, no refetch"

# Detail by name with a punctuated canonical token; URL omitted when null
KEY_QUEUE=(r q)
LINE_QUEUE=('postgresql@16' '' b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"--- postgresql@16 (2/5) ---"* ]] \
    && [[ "$OUT" == *"Evidence URL"* ]] \
    && pass || fail "REVIEW detail by name: canonical token with punctuation"
KEY_QUEUE=(r q)
LINE_QUEUE=('docker' '' b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"--- docker (5/5) ---"* ]] \
    && [[ "$OUT" == *"Retrieval status: rate-limited"* ]] \
    && [[ "$OUT" != *"Evidence URL:"* ]] \
    && [[ "$OUT" == *"Freshness:        not recorded"* ]] \
    && pass || fail "REVIEW detail unknown: URL omitted, null freshness"

# Invalid review input -> hint; the review list must NOT be reprinted for
# the invalid line (prompt-only reprompt)
KEY_QUEUE=(r q)
LINE_QUEUE=(nope b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"Invalid input 'nope'"* ]] \
    && [[ "$(grep -c 'Review packages (5):' <<< "$OUT")" -eq 1 ]] \
    && pass || fail "REVIEW invalid: hint, prompt-only reprompt"

# q inside REVIEW -> exit 0
KEY_QUEUE=(r)
LINE_QUEUE=(q)
drive "$RECORDS" 0 && [[ "$OUT" == *"Dashboard closed."* ]] \
    && pass || fail "REVIEW q: exit 0"

# EOF inside REVIEW (line queue exhausted) -> exit 0
KEY_QUEUE=(r)
LINE_QUEUE=()
drive "$RECORDS" 0 && [[ ! -s "$UPGRADE_CALLS" ]] \
    && pass || fail "REVIEW EOF: exit 0"

# --- SELECT -----------------------------------------------------------------

# Defaults: exactly the no-signal tokens, never attention/unknown
DEFAULTS="$(_dashboard_default_selected_pkgs "$RECORDS" | tr '\n' ' ' | sed 's/ $//')"
if [[ "$DEFAULTS" == "$NS_SET" ]]; then
    pass
else
    fail "SELECT defaults: got '$DEFAULTS', expected '$NS_SET'"
fi

# Toggle + Enter -> UPGRADE with the exact staged canonical tokens
# (defaults bat+curl; add node and docker by index, drop bat by name)
KEY_QUEUE=(s q)
LINE_QUEUE=('1' '5' 'bat' '')
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "node curl docker" ]] \
    && pass || fail "SELECT toggle: staged set passed to the boundary exactly"

# b discards the staged selection; later u uses only the no-signal set
KEY_QUEUE=(s u q)
LINE_QUEUE=('1' b)
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "$NS_SET" ]] \
    && pass || fail "SELECT b: staged selection discarded"

# Empty staged set + Enter -> guard hint, no execution
KEY_QUEUE=(s q)
LINE_QUEUE=('3' '4' '')
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"Nothing selected."* ]] \
    && [[ ! -s "$UPGRADE_CALLS" ]] \
    && pass || fail "SELECT empty confirm: guarded, no execution"

# q inside SELECT -> exit 0
KEY_QUEUE=(s)
LINE_QUEUE=(q)
drive "$RECORDS" 0 && [[ "$OUT" == *"Dashboard closed."* ]] \
    && pass || fail "SELECT q: exit 0"

# EOF inside SELECT -> exit 0
KEY_QUEUE=(s)
LINE_QUEUE=()
drive "$RECORDS" 0 && [[ ! -s "$UPGRADE_CALLS" ]] \
    && pass || fail "SELECT EOF: exit 0"

# Invalid select input -> hint; the checkbox list must NOT be reprinted for
# the invalid line (prompt-only reprompt)
KEY_QUEUE=(s q)
LINE_QUEUE=(zz b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"Invalid input 'zz'"* ]] \
    && [[ "$(grep -c 'Select packages (no-signal preselected' <<< "$OUT")" -eq 1 ]] \
    && pass || fail "SELECT invalid: hint, prompt-only reprompt"

# Preselection markers render ([x] no-signal, [ ] attention/unknown)
KEY_QUEUE=(s q)
LINE_QUEUE=(b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"[x]  3) bat — No risk signal"* ]] \
    && [[ "$OUT" == *"[ ]  1) node — Needs attention"* ]] \
    && [[ "$OUT" == *"[ ]  5) docker — Unknown"* ]] \
    && pass || fail "SELECT render: preselection markers"

# --- SELECT arrow navigation ------------------------------------------------
# Cursor starts on row 1; DOWN×2 lands on bat (row 3), space unstages it,
# Enter confirms the remaining default set (curl).
KEY_QUEUE=(s q)
LINE_QUEUE=(DOWN DOWN TOGGLE '')
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "curl" ]] \
    && pass || fail "SELECT arrows: DOWN×2 + space unstages bat; Enter confirms curl"

# UP clamps at row 1; space stages the cursor row (node) on top of defaults.
KEY_QUEUE=(s q)
LINE_QUEUE=(UP TOGGLE '')
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "node bat curl" ]] \
    && pass || fail "SELECT arrows: UP clamps at row 1, space stages node"

# The text cursor marker renders on the cursor row (text-first, no color).
KEY_QUEUE=(s q)
LINE_QUEUE=(DOWN b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"> [ ]  2) postgresql@16 — Needs attention"* ]] \
    && pass || fail "SELECT arrows: cursor marker on row 2"

# Arrow movement clears any half-typed buffer (movement is structural).
KEY_QUEUE=(s q)
LINE_QUEUE=('type1:1' DOWN TOGGLE '')
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "postgresql@16 bat curl" ]] \
    && pass || fail "SELECT arrows: movement clears half-typed buffer"

# A name starting with b/q still types: buffer takes precedence over the
# back/quit shortcut (which only fires on an empty buffer).
KEY_QUEUE=(s q)
LINE_QUEUE=('bat' '')
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "curl" ]] \
    && pass || fail "SELECT: name entry 'bat' not mistaken for back"

# --- Full-set sanity: every record token is reachable in SELECT -----------
FULL="$(_dashboard_all_pkgs "$RECORDS" | tr '\n' ' ' | sed 's/ $//')"
if [[ "$FULL" == "$ALL_SET" ]]; then
    pass
else
    fail "record tokens: got '$FULL', expected '$ALL_SET'"
fi

# --- Dashboard quiet-changelogs: inline per-package dump suppression -------
# When brew-change dispatches dashboard mode it exports
# BREW_CHANGE_CHANGELOG_OUTPUT=0 before evidence gathering; the inline
# changelog dump (the "📦 pkg: ..." blocks) must disappear from stdout while
# evidence recording stays intact. Default (unset) and explicit =1 keep the
# dump for plain -u and all non-dashboard modes.
printf '\n--- dashboard quiet changelog dump ---\n'
_quiet_dump_run() { # mode (quiet|loud|default); echoes the changelog stdout
    local mode="$1"
    local dir="$TMPDIR_TEST/quiet-$mode"
    mkdir -p "$dir"
    rm -f "$dir/evidence.jsonl" "$dir/progress.jsonl"
    (
        export BREW_CHANGE_SUBPROCESS=true
        export UPGRADE_STATUS_DIR="$dir"
        export IDENTIFY_BREAKING=true
        case "$mode" in
            quiet) export BREW_CHANGE_CHANGELOG_OUTPUT=0 ;;
            loud) export BREW_CHANGE_CHANGELOG_OUTPUT=1 ;;
            default) unset BREW_CHANGE_CHANGELOG_OUTPUT ;;
        esac
        # shellcheck disable=SC1091
        source "$ROOT_DIR/lib/brew-change-config.sh"
        source "$ROOT_DIR/lib/brew-change-utils.sh"
        source "$ROOT_DIR/lib/brew-change-breaking.sh"
        source "$ROOT_DIR/lib/brew-change-assessment.sh"
        source "$ROOT_DIR/lib/brew-change-github.sh"
        source "$ROOT_DIR/lib/brew-change-npm.sh"
        source "$ROOT_DIR/lib/brew-change-brew.sh"
        source "$ROOT_DIR/lib/brew-change-non-github.sh"
        source "$ROOT_DIR/lib/brew-change-display.sh"
        # Deterministic GitHub release stub: no network, fixed snapshot.
        fetch_github_release() {
            printf '{"tag_name":"v2.0.0","published_at":"2026-08-01T00:00:00Z","html_url":"https://github.com/example/demo/releases/tag/v2.0.0","body":"## Changes\\n- quiet dump guard"}'
        }
        show_package_changelog_full "demo" "1.0.0" "2.0.0" \
            '{"homepage":"https://github.com/example/demo","urls":{"stable":{"url":"https://github.com/example/demo/archive/v2.0.0.tar.gz"}}}'
    )
}
_quiet_evidence_rows() { # mode; prints evidence.jsonl rows for "demo"
    jq -c 'select(.package == "demo")' \
        "$TMPDIR_TEST/quiet-$1/evidence.jsonl" 2>/dev/null || true
}

QUIET_OUT=$(_quiet_dump_run quiet)
if [[ "$QUIET_OUT" != *"📦"* && "$QUIET_OUT" != *"Release:"* ]]; then
    pass
else
    fail "quiet flag: stdout still carries the changelog dump"
fi
if grep -q '"retrieval_status":"fresh"' <(_quiet_evidence_rows quiet) \
    && _quiet_evidence_rows quiet | grep -q 'quiet dump guard'; then
    pass
else
    fail "quiet flag: evidence recording missing/empty"
fi

LOUD_OUT=$(_quiet_dump_run loud)
if [[ "$LOUD_OUT" == *"📦 demo:"* && "$LOUD_OUT" == *"Release: https://github.com/example/demo/releases/tag/v2.0.0"* ]]; then
    pass
else
    fail "explicit =1: changelog dump missing"
fi
if grep -q '"retrieval_status":"fresh"' <(_quiet_evidence_rows loud); then
    pass
else
    fail "explicit =1: evidence recording missing"
fi

DEFAULT_OUT=$(_quiet_dump_run default)
if [[ "$DEFAULT_OUT" == *"📦 demo:"* ]]; then
    pass
else
    fail "default (unset): changelog dump missing"
fi
if grep -q '"retrieval_status":"fresh"' <(_quiet_evidence_rows default); then
    pass
else
    fail "default (unset): evidence recording missing"
fi

# --- T2.6.2 default flip: piped full-CLI runs are unchanged -----------------
# Non-TTY runs ignore the view entirely (research-004 §3.1): plain
# deterministic prompt-flow output, no dashboard — with or without the
# view flags.
printf '\n--- default flip: piped full-CLI runs ---\n'
FLIP_HARNESS_OK=1
if [[ -f "$ROOT_DIR/tests/lib/test-utils.sh" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/tests/lib/test-utils.sh"
    _flip_piped_run() { # args...; sets _FLIP_STDOUT/_FLIP_STDERR/_FLIP_EXIT
        setup_command_harness
        configure_fake_command brew \
            "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json" "" 0
        configure_fake_command curl "" "" 0
        export BREW_CHANGE_TEST_NOW=1800000000
        local out_file="$COMMAND_HARNESS_ROOT/out"
        local err_file="$COMMAND_HARNESS_ROOT/err"
        local ec=0
        "$ROOT_DIR/brew-change" "$@" >"$out_file" 2>"$err_file" || ec=$?
        _FLIP_STDOUT="$(cat "$out_file")"
        _FLIP_STDERR="$(cat "$err_file")"
        _FLIP_EXIT="$ec"
        unset BREW_CHANGE_TEST_NOW
        teardown_command_harness
    }

    _flip_piped_run -u
    [[ "$_FLIP_EXIT" == "0" \
        && "$_FLIP_STDOUT" == *"Non-interactive mode. Upgrade skipped."* \
        && "$_FLIP_STDOUT" != *"[s] Select packages"* ]] \
        && pass || fail "piped -u default: plain output, no dashboard"

    _flip_piped_run -u --plain
    [[ "$_FLIP_EXIT" == "0" \
        && "$_FLIP_STDOUT" == *"Non-interactive mode. Upgrade skipped."* ]] \
        && pass || fail "piped -u --plain: plain output"

    # Explicit former opt-in env, piped: still ignored in favor of plain.
    setup_command_harness
    configure_fake_command brew \
        "$SCRIPT_DIR/fixtures/homebrew/outdated-mixed.json" "" 0
    configure_fake_command curl "" "" 0
    export BREW_CHANGE_TEST_NOW=1800000000
    ec=0
    BREW_CHANGE_DASHBOARD=1 "$ROOT_DIR/brew-change" -u \
        >"$COMMAND_HARNESS_ROOT/out" 2>"$COMMAND_HARNESS_ROOT/err" || ec=$?
    _FLIP_STDOUT="$(cat "$COMMAND_HARNESS_ROOT/out")"
    _FLIP_STDERR="$(cat "$COMMAND_HARNESS_ROOT/err")"
    unset BREW_CHANGE_TEST_NOW
    teardown_command_harness
    [[ "$ec" == "0" \
        && "$_FLIP_STDOUT" == *"Non-interactive mode. Upgrade skipped."* \
        && "$_FLIP_STDOUT" != *"[s] Select packages"* ]] \
        && pass || fail "piped -u with BREW_CHANGE_DASHBOARD=1: flag ignored"
else
    fail "test-utils.sh missing for piped flip checks"
fi

# --- Terminal hygiene (PTY): real readers, stty/signals/countdown ----------
printf '\n--- dashboard action PTY suite ---\n'
if python3 "$SCRIPT_DIR/test-dashboard-actions.py"; then
    pass
else
    fail "dashboard action PTY suite"
fi

# --- UPGRADE refresh: the REAL dashboard_refresh_records under capture ----
# The refresh runs inside a command substitution in _dashboard_upgrade_state,
# so its stdout contract is strict: ONLY the new records path (or "none").
# Worker-phase chatter, the deferred completion summary, and any renderer
# cosmetics must stay off the captured stream — a polluted path makes the
# post-capture `jq -s length` fail into a wrong "No outdated packages." exit.
printf '\n--- refresh stdout purity + progress state reset ---\n'
REFRESH_DIR="$TMPDIR_TEST/refresh"
REFRESH_STATUS="$REFRESH_DIR/status"
mkdir -p "$REFRESH_STATUS"
PROBE_LOG="$REFRESH_DIR/probe.log"
SAY_LOG="$REFRESH_DIR/say.log"
CAPTURE_FILE="$REFRESH_DIR/captured.out"
: > "$SAY_LOG"

(
    # Real pipeline primitives (assessment_record_init resets
    # assessment.jsonl and emits the inventory event); CACHE_DIR points
    # somewhere nonexistent so cross-run cache invalidation stays a no-op.
    export CACHE_DIR="$REFRESH_DIR/no-cache"
    # shellcheck disable=SC1091
    source "$ROOT_DIR/lib/brew-change-brew.sh"
    # shellcheck disable=SC1091
    source "$ROOT_DIR/lib/brew-change-progress.sh"
    export UPGRADE_STATUS_DIR="$REFRESH_STATUS"

    # State as the launcher leaves it after the initial pass: stop
    # sentinel present, first-pass progress events, classified records.
    : > "$REFRESH_STATUS/.progress_done"
    printf '%s\n' \
        '{"stage":"inventory","completed":1,"total":1}' \
        '{"stage":"evidence","completed":1,"total":5,"package":"node"}' \
        '{"stage":"evidence","completed":2,"total":5,"package":"jq"}' \
        > "$REFRESH_STATUS/progress.jsonl"
    jq -c 'select(.package == "node")' "$FIXTURE" \
        > "$REFRESH_STATUS/assessment.jsonl"

    # Post-upgrade inventory: bat and curl remain outdated.
    _dashboard_fetch_outdated_json() {
        printf '{"formulae":[{"name":"bat","installed_versions":["0.24"],"current_version":"0.25"},{"name":"curl","installed_versions":["8.0"],"current_version":"8.1"}],"casks":[]}'
    }

    # Worker-phase stub: echoes the historical banner chatter straight to
    # stdout (the pollution source) and appends the per-package evidence
    # events in the T2.4.1 contract form, like the real workers do; hands
    # the completion summary back via the deferred-summary global.
    process_packages_parallel() {
        echo "Processing 2 packages in parallel (max 4 jobs)..."
        echo ""
        local _pkg _n=0
        for _pkg in bat curl; do
            _n=$((_n + 1))
            printf '{"stage":"evidence","completed":%d,"total":2,"package":"%s"}\n' \
                "$_n" "$_pkg" >> "$UPGRADE_STATUS_DIR/progress.jsonl"
        done
        PARALLEL_PENDING_SUMMARY="Completed processing 2 packages in 1s"
        return 0
    }

    # Classify stub: rewrites assessment.jsonl with the post-upgrade
    # records and appends the classify events (contract form).
    classify_upgrade_evidence() {
        jq -c 'select(.package == "bat" or .package == "curl")' "$FIXTURE" \
            > "$UPGRADE_STATUS_DIR/assessment.jsonl"
        printf '%s\n' \
            '{"stage":"classify","completed":1,"total":2,"package":"bat"}' \
            '{"stage":"classify","completed":2,"total":2,"package":"curl"}' \
            >> "$UPGRADE_STATUS_DIR/progress.jsonl"
        return 0
    }

    # Cosmetic /dev/tty messages land in a log, never on the capture.
    _dashboard_say() { printf '%s\n' "$1" >> "$SAY_LOG"; }

    # Production captures the refresh via a command substitution; the file
    # redirect is equivalent for the stream while keeping this subshell the
    # same shell the deferred-summary global lives in.
    dashboard_refresh_records > "$CAPTURE_FILE"
    refresh_rc=$?
    printf 'RC=%s\nCLEARED=%s\n' "$refresh_rc" \
        "${PARALLEL_PENDING_SUMMARY-UNSET}" > "$PROBE_LOG"
)
REFRESH_OUT="$(cat "$CAPTURE_FILE")"

EXPECTED_REFRESH_PATH="$REFRESH_STATUS/assessment.jsonl"

# Captured stdout is EXACTLY the records path: no banner, no blank line,
# no summary, no trailing newline.
[[ "$REFRESH_OUT" == "$EXPECTED_REFRESH_PATH" ]] \
    && pass || fail "refresh capture: got '$REFRESH_OUT', expected exactly '$EXPECTED_REFRESH_PATH'"

# The post-capture jq check from _dashboard_upgrade_state must succeed on
# the result (this is the check the pollution used to break).
REFRESH_LEN=$(jq -s 'length' "$REFRESH_OUT" 2>/dev/null || echo 0)
[[ "$REFRESH_LEN" == "2" ]] \
    && pass || fail "refresh capture: jq record count got '$REFRESH_LEN', expected 2"

# First-pass progress events were reset: no stale total=5 rows remain.
STALE_EVENTS=$(grep -c '"total":5' "$REFRESH_STATUS/progress.jsonl" || true)
[[ "$STALE_EVENTS" == "0" ]] \
    && pass || fail "refresh progress reset: $STALE_EVENTS stale first-pass events remain"

# Fresh event census: one inventory, two evidence, two classify.
_event_count() { jq -s --arg s "$1" '[.[] | select(.stage == $s)] | length' \
    "$REFRESH_STATUS/progress.jsonl" 2>/dev/null || echo 0; }
[[ "$(_event_count inventory)" == "1" && "$(_event_count evidence)" == "2" \
    && "$(_event_count classify)" == "2" ]] \
    && pass || fail "refresh events: inventory=$(_event_count inventory) evidence=$(_event_count evidence) classify=$(_event_count classify), expected 1/2/2"

# Records were re-derived from the post-upgrade inventory only.
REFRESH_PKGS=$(jq -r '.package' "$REFRESH_STATUS/assessment.jsonl" 2>/dev/null \
    | paste -sd' ' -)
[[ "$REFRESH_PKGS" == "bat curl" ]] \
    && pass || fail "refresh records: got '$REFRESH_PKGS', expected 'bat curl'"

# The deferred completion summary went to the terminal path (never the
# capture) and was cleared afterwards; the refresh itself succeeded.
grep -q '^Completed processing 2 packages in 1s$' "$SAY_LOG" \
    && pass || fail "refresh summary: deferred summary not flushed to the terminal path"
grep -q '^RC=0$' "$PROBE_LOG" && grep -q '^CLEARED=$' "$PROBE_LOG" \
    && pass || fail "refresh summary: rc/deferred-summary clear failed ($(cat "$PROBE_LOG" 2>/dev/null | tr '\n' ' '))"

printf '\ndashboard actions: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
