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

# invalid -> hint, reprompt; then q
KEY_QUEUE=(x q)
drive "$RECORDS" 0 && [[ "$OUT" == *"Invalid input 'x'. Type r/s/u/q"* ]] \
    && pass || fail "DASHBOARD invalid: hint then reprompt"

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
drive "$RECORDS" 0 && [[ "$OUT" == *"--- bat ---"* ]] \
    && pass || fail "REVIEW continuous numbering: 3 -> bat"
KEY_QUEUE=(r q)
LINE_QUEUE=('5' '' b)
drive "$RECORDS" 0 && [[ "$OUT" == *"--- docker ---"* ]] \
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

# u -> UPGRADE with the exact no-signal set; inventory unchanged -> decline
# path: no refresh, records kept, dashboard re-rendered; then q
KEY_QUEUE=(u q)
FETCH_JSON='{"formulae":[{"name":"bat"},{"name":"curl"},{"name":"node"},{"name":"postgresql@16"},{"name":"docker"}],"casks":[]}'
drive "$RECORDS" 0 \
    && [[ "$(upgrade_args)" == "$NS_SET" ]] \
    && [[ ! -s "$REFRESH_LOG" ]] \
    && [[ "$(grep -c 'Needs attention' <<< "$OUT")" -ge 1 ]] \
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
    && [[ "$OUT" == *"[q]uit"* ]] \
    && pass || fail "UPGRADE failure: returns to dashboard, no refresh"
UPGRADE_RC=0

# --- REVIEW -----------------------------------------------------------------

# Detail by index: read-only fields from the record; file unchanged; no fetch
RECORDS_HASH_BEFORE=$(shasum "$RECORDS" | cut -d' ' -f1)
KEY_QUEUE=(r q)
LINE_QUEUE=(1 '' b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"--- node ---"* ]] \
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
    && [[ "$OUT" == *"--- postgresql@16 ---"* ]] \
    && [[ "$OUT" == *"Evidence URL"* ]] \
    && pass || fail "REVIEW detail by name: canonical token with punctuation"
KEY_QUEUE=(r q)
LINE_QUEUE=('docker' '' b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"--- docker ---"* ]] \
    && [[ "$OUT" == *"Retrieval status: rate-limited"* ]] \
    && [[ "$OUT" != *"Evidence URL:"* ]] \
    && [[ "$OUT" == *"Freshness:        retrieved unknown"* ]] \
    && pass || fail "REVIEW detail unknown: URL omitted, null freshness"

# Invalid review input -> hint, reprompt
KEY_QUEUE=(r q)
LINE_QUEUE=(nope b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"Invalid input 'nope'"* ]] \
    && pass || fail "REVIEW invalid: hint, reprompt"

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

# Invalid select input -> hint
KEY_QUEUE=(s q)
LINE_QUEUE=(zz b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"Invalid input 'zz'"* ]] \
    && pass || fail "SELECT invalid: hint, reprompt"

# Preselection markers render ([x] no-signal, [ ] attention/unknown)
KEY_QUEUE=(s q)
LINE_QUEUE=(b)
drive "$RECORDS" 0 \
    && [[ "$OUT" == *"[x]  3) bat — No risk signal"* ]] \
    && [[ "$OUT" == *"[ ]  1) node — Needs attention"* ]] \
    && [[ "$OUT" == *"[ ]  5) docker — Unknown"* ]] \
    && pass || fail "SELECT render: preselection markers"

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
# deterministic prompt-flow output, no dashboard, no notice — with or
# without the view flags.
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
        && "$_FLIP_STDOUT" != *"[s] Select packages"* \
        && "$_FLIP_STDERR" != *"output view changed"* ]] \
        && pass || fail "piped -u default: plain output, no dashboard, no notice"

    _flip_piped_run -u --plain
    [[ "$_FLIP_EXIT" == "0" \
        && "$_FLIP_STDOUT" == *"Non-interactive mode. Upgrade skipped."* \
        && "$_FLIP_STDERR" != *"output view changed"* ]] \
        && pass || fail "piped -u --plain: plain output, no notice"

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
        && "$_FLIP_STDOUT" != *"[s] Select packages"* \
        && "$_FLIP_STDERR" != *"output view changed"* ]] \
        && pass || fail "piped -u with BREW_CHANGE_DASHBOARD=1: flag ignored, no notice"
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

printf '\ndashboard actions: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
