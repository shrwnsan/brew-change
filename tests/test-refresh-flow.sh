#!/usr/bin/env bash
# Tests for the `refresh` subcommand (prd-004 / tasks-006).
#
# Runs the real CLI against a fake `brew` on PATH with an empty outdated set:
# - exits 0, prints nothing, writes a fresh empty export, releases the lock
# - logs the completion to refresh.log
# - takes no arguments
# - skips silently when the lock is held

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BREW_CHANGE="$REPO_ROOT/brew-change"
source "$SCRIPT_DIR/lib/test-utils.sh"

FIXTURES="$SCRIPT_DIR/fixtures/badge"
mkdir -p "$FIXTURES"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok %d - %s\n' "$pass" "$1"; }
no() {
    fail=$((fail + 1))
    printf 'not ok %d - %s\n' "$((pass + fail))" "$1"
    shift
    printf '    %s\n' "$*" >&2
}
assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then ok "$desc"; else no "$desc" "got: '$got'  want: '$want'"; fi
}

# Fake brew: zero outdated formulae and casks.
SHIM="$FIXTURES/shim"
rm -rf "$SHIM"
mkdir -p "$SHIM"
cat > "$SHIM/brew" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    outdated)
        if [[ "${2:-}" == "--json=v2" ]]; then
            printf '{"formulae":[],"casks":[]}\n'
        else
            printf ''
        fi
        ;;
    --prefix) printf '/opt/homebrew\n' ;;
    --repository) printf '/opt/homebrew\n' ;;
    *) printf '' ;;
esac
EOF
chmod +x "$SHIM/brew"

R_HOME="$FIXTURES/refresh-home"
rm -rf "$R_HOME"
mkdir -p "$R_HOME"

run_refresh() {
    HOME="$R_HOME" PATH="$SHIM:$PATH" \
        bash "$BREW_CHANGE" refresh 2>"$FIXTURES/refresh-err.txt"
}

out="$(run_refresh)"; rc=$?
assert_eq "refresh: exits 0 on empty outdated" "$rc" "0"
assert_eq "refresh: stdout silent" "$out" ""
if [[ -s "$FIXTURES/refresh-err.txt" ]]; then
    no "refresh: stderr silent" "$(cat "$FIXTURES/refresh-err.txt")"
else
    ok "refresh: stderr silent"
fi

if [[ -f "$R_HOME/.brew-change/last-assessment.json" ]]; then
    ok "refresh: export written"
else
    no "refresh: export written" "file missing"
fi
exp_pkgs="$(jq -r '.packages | length' "$R_HOME/.brew-change/last-assessment.json" 2>/dev/null || echo ERR)"
assert_eq "refresh: export has zero packages" "$exp_pkgs" "0"
exp_schema="$(jq -r '.schema_version' "$R_HOME/.brew-change/last-assessment.json" 2>/dev/null || echo ERR)"
assert_eq "refresh: export schema_version 1" "$exp_schema" "1"

if [[ -d "$R_HOME/.brew-change/.refresh.lock" ]]; then
    no "refresh: lock released" "lock dir still present"
else
    ok "refresh: lock released"
fi

assert_contains_log() {
    local desc="$1" needle="$2"
    if grep -q "$needle" "$R_HOME/.brew-change/refresh.log" 2>/dev/null; then
        ok "$desc"
    else
        no "$desc" "expected '$needle' in refresh.log"
    fi
}
assert_contains_log "refresh: completion logged" "refresh rc=0"

# --- argument validation --------------------------------------------------
rc=0
HOME="$R_HOME" PATH="$SHIM:$PATH" bash "$BREW_CHANGE" refresh node >/dev/null 2>&1 || rc=$?
assert_eq "refresh: rejects arguments" "$rc" "1"

# --- held lock: skip silently -------------------------------------------------
mkdir -p "$R_HOME/.brew-change/.refresh.lock"
printf '%s\n' "$$" > "$R_HOME/.brew-change/.refresh.lock/pid"
date +%s > "$R_HOME/.brew-change/.refresh.lock/started"
out="$(HOME="$R_HOME" PATH="$SHIM:$PATH" bash "$BREW_CHANGE" refresh 2>/dev/null)"; rc=$?
assert_eq "refresh: held lock exits 0" "$rc" "0"
assert_eq "refresh: held lock silent" "$out" ""
assert_eq "refresh: held lock untouched" "$(cat "$R_HOME/.brew-change/.refresh.lock/pid")" "$$"
rm -rf "$R_HOME/.brew-change/.refresh.lock"

# --- degraded refresh keeps a healthy export (prd-004) -------------------------
# Full integration: one outdated package, every curl probe fails instantly.
# MAX_RETRIES=1 removes retry sleeps and a single package means a single
# batch, so no rate-limit sleep fires — the whole doomed evidence pass runs
# in well under a second. The records come back failed/unavailable only
# (the degraded signature), so the guard must keep the healthy export,
# exit 2, and start the backoff.
DEG_HOME="$FIXTURES/degraded-home"
rm -rf "$DEG_HOME"
mkdir -p "$DEG_HOME/.brew-change"
jq -n '{schema_version:1,generated_at:"2026-10-04T00:00:00Z",packages:[{name:"node",display_name:"node",kind:"formula",installed_version:"22.6.0",available_version:"22.8.0",classification:"attention",matched_signals:["major-version-transition"],retrieval_status:"fresh"}]}' \
    > "$DEG_HOME/.brew-change/last-assessment.json"
cp "$DEG_HOME/.brew-change/last-assessment.json" "$FIXTURES/degraded-export-was.json"

setup_command_harness
configure_fake_command brew "$FIXTURES/outdated-one.json" "" 0
configure_fake_command curl "" "" 1
export BREW_CHANGE_MAX_RETRIES=1
export API_RATE_LIMIT_DELAY=0
rc=0
HOME="$DEG_HOME" bash "$BREW_CHANGE" refresh >/dev/null 2>"$FIXTURES/degraded-err.txt" || rc=$?
unset BREW_CHANGE_MAX_RETRIES API_RATE_LIMIT_DELAY
teardown_command_harness

assert_eq "degraded: exits 2 (kept old export)" "$rc" "2"
if cmp -s "$FIXTURES/degraded-export-was.json" "$DEG_HOME/.brew-change/last-assessment.json"; then
    ok "degraded: healthy export untouched"
else
    no "degraded: healthy export untouched" "export was overwritten"
fi
if grep -q "refresh rc=2" "$DEG_HOME/.brew-change/refresh.log" 2>/dev/null; then
    ok "degraded: completion logged with rc=2"
else
    no "degraded: completion logged with rc=2" "missing from refresh.log"
fi
if [[ -e "$DEG_HOME/.brew-change/.refresh-backoff" ]]; then
    ok "degraded: backoff started"
else
    no "degraded: backoff started" "no backoff record"
fi
if [[ -d "$DEG_HOME/.brew-change/.refresh.lock" ]]; then
    no "degraded: lock released" "lock dir still present"
else
    ok "degraded: lock released"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
