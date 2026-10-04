#!/usr/bin/env bash
# Tests for the refresh lock + spawn decision (prd-004 / tasks-006).
#
# Lock protocol: atomic mkdir; pid + started files; live PID blocks; dead PID
# or >REFRESH_LOCK_MAX_AGE takeover; missing pid file blocks (conservative —
# the creator may not have written it yet).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/brew-change-badge.sh
source "$REPO_ROOT/lib/brew-change-badge.sh"

FIXTURES="$SCRIPT_DIR/fixtures/badge"
mkdir -p "$FIXTURES"
REFRESH_LOCK_DIR="$FIXTURES/test-refresh.lock"

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

# dead_pid: spawn and kill a child for a deterministically dead PID.
dead_pid() {
    sleep 30 >/dev/null 2>&1 &
    local dp=$!
    kill -9 "$dp" 2>/dev/null
    wait "$dp" 2>/dev/null
    printf '%s' "$dp"
}

rm -rf "$REFRESH_LOCK_DIR"

# --- acquire on clean state -------------------------------------------------
if refresh_lock_acquire; then
    ok "acquire: succeeds when unlocked"
else
    no "acquire: succeeds when unlocked" "returned failure"
fi
assert_eq "acquire: pid file records caller" "$(cat "${REFRESH_LOCK_DIR}/pid")" "$$"

# --- held by live PID blocks ------------------------------------------------
if refresh_lock_acquire 2>/dev/null; then
    no "acquire: live PID blocks" "took over a live lock"
else
    ok "acquire: live PID blocks"
fi
refresh_lock_release
if [[ -d "$REFRESH_LOCK_DIR" ]]; then
    no "release: removes lock dir" "dir still present"
else
    ok "release: removes lock dir"
fi

# --- dead PID takeover -------------------------------------------------------
DP="$(dead_pid)"
mkdir -p "$REFRESH_LOCK_DIR"
printf '%s\n' "$DP" > "${REFRESH_LOCK_DIR}/pid"
_badge_now > "${REFRESH_LOCK_DIR}/started"
if refresh_lock_acquire; then
    ok "takeover: dead PID lock reclaimed"
else
    no "takeover: dead PID lock reclaimed" "returned failure"
fi
assert_eq "takeover: lock now records new owner" "$(cat "${REFRESH_LOCK_DIR}/pid")" "$$"
refresh_lock_release

# --- expired lock takeover ----------------------------------------------------
mkdir -p "$REFRESH_LOCK_DIR"
printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
echo $(( $(date +%s) - REFRESH_LOCK_MAX_AGE - 100 )) > "${REFRESH_LOCK_DIR}/started"
if refresh_lock_acquire; then
    ok "takeover: expired lock reclaimed"
else
    no "takeover: expired lock reclaimed" "returned failure"
fi
refresh_lock_release

# --- missing pid file blocks (conservative) -----------------------------------
mkdir -p "$REFRESH_LOCK_DIR"
if refresh_lock_acquire 2>/dev/null; then
    no "acquire: missing pid file blocks" "took over an uninitialized lock"
else
    ok "acquire: missing pid file blocks"
fi
refresh_lock_release

# --- badge_spawn_refresh: NO_SPAWN seam leaves no lock -------------------------
export BREW_CHANGE_BADGE_NO_SPAWN=1
if badge_spawn_refresh "$REPO_ROOT/brew-change"; then
    ok "spawn: NO_SPAWN returns 0"
else
    no "spawn: NO_SPAWN returns 0" "returned failure"
fi
if [[ -d "$REFRESH_LOCK_DIR" ]]; then
    no "spawn: NO_SPAWN releases lock" "dir still present"
else
    ok "spawn: NO_SPAWN releases lock"
fi

# --- badge_spawn_refresh: held lock skips ---------------------------------------
mkdir -p "$REFRESH_LOCK_DIR"
printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
_badge_now > "${REFRESH_LOCK_DIR}/started"
if badge_spawn_refresh "$REPO_ROOT/brew-change"; then
    ok "spawn: held lock skips silently"
else
    no "spawn: held lock skips silently" "returned failure"
fi
assert_eq "spawn: held lock untouched" "$(cat "${REFRESH_LOCK_DIR}/pid")" "$$"
refresh_lock_release
unset BREW_CHANGE_BADGE_NO_SPAWN

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
