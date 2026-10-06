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

# --- held by a live FOREIGN PID blocks ----------------------------------------
# The blocker must be a live pid that is not ours: a lock whose pid file
# records OUR OWN pid is the badge→refresh handoff (parent pre-acquires on
# behalf of the spawned child) and must be ADOPTED, not refused.
sleep 30 >/dev/null 2>&1 &
BLOCKER=$!
mkdir -p "$REFRESH_LOCK_DIR"
printf '%s\n' "$BLOCKER" > "${REFRESH_LOCK_DIR}/pid"
_badge_now > "${REFRESH_LOCK_DIR}/started"
if refresh_lock_acquire 2>/dev/null; then
    no "acquire: live foreign PID blocks" "took over a live lock"
else
    ok "acquire: live foreign PID blocks"
fi
kill -9 "$BLOCKER" 2>/dev/null
wait "$BLOCKER" 2>/dev/null
refresh_lock_release
if [[ -d "$REFRESH_LOCK_DIR" ]]; then
    no "release: removes lock dir" "dir still present"
else
    ok "release: removes lock dir"
fi

# --- own-PID lock is adopted (badge→refresh handoff) ---------------------------
# prd-004 regression: the badge acquires the lock and writes the spawned
# child's pid into it. When the child calls refresh_lock_acquire, the pid in
# the file is its own — refusing here made every spawned refresh exit
# instantly, so refresh never ran (found live, 2026-10-06).
mkdir -p "$REFRESH_LOCK_DIR"
printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
_badge_now > "${REFRESH_LOCK_DIR}/started"
if refresh_lock_acquire; then
    ok "adopt: own-PID lock is claimed by the refresh child"
else
    no "adopt: own-PID lock is claimed by the refresh child" "child would exit without running"
fi
assert_eq "adopt: started window refreshed" \
    "$(cat "${REFRESH_LOCK_DIR}/pid")" "$$"
refresh_lock_release

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
# Foreign live holder (a sleep child, not $$ — own-pid locks are adopted).
sleep 30 >/dev/null 2>&1 &
BLOCKER2=$!
mkdir -p "$REFRESH_LOCK_DIR"
printf '%s\n' "$BLOCKER2" > "${REFRESH_LOCK_DIR}/pid"
_badge_now > "${REFRESH_LOCK_DIR}/started"
if badge_spawn_refresh "$REPO_ROOT/brew-change"; then
    ok "spawn: held lock skips silently"
else
    no "spawn: held lock skips silently" "returned failure"
fi
assert_eq "spawn: held lock untouched" "$(cat "${REFRESH_LOCK_DIR}/pid")" "$BLOCKER2"
refresh_lock_release
kill -9 "$BLOCKER2" 2>/dev/null
wait "$BLOCKER2" 2>/dev/null

# --- badge_spawn_refresh: own-PID lock is adopted for the child ------------------
export BREW_CHANGE_BADGE_NO_SPAWN=1
mkdir -p "$REFRESH_LOCK_DIR"
printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
_badge_now > "${REFRESH_LOCK_DIR}/started"
if badge_spawn_refresh "$REPO_ROOT/brew-change"; then
    ok "spawn: own-PID lock adopted (NO_SPAWN releases it)"
else
    no "spawn: own-PID lock adopted (NO_SPAWN releases it)" "returned failure"
fi
if [[ -d "$REFRESH_LOCK_DIR" ]]; then
    no "spawn: adopted lock released under NO_SPAWN" "dir still present"
else
    ok "spawn: adopted lock released under NO_SPAWN"
fi
unset BREW_CHANGE_BADGE_NO_SPAWN

# --- refresh backoff (prd-004) ------------------------------------------------
REFRESH_BACKOFF_FILE="$FIXTURES/test-backoff"
rm -f "$REFRESH_BACKOFF_FILE"

if refresh_backoff_active 2>/dev/null; then
    no "backoff: inactive when no record" "active with no file"
else
    ok "backoff: inactive when no record"
fi

_badge_now > "$REFRESH_BACKOFF_FILE"
if refresh_backoff_active; then
    ok "backoff: active within window"
else
    no "backoff: active within window" "returned inactive"
fi

BREW_CHANGE_REFRESH_BACKOFF=0
if refresh_backoff_active 2>/dev/null; then
    no "backoff: zero window expires immediately" "still active"
else
    ok "backoff: zero window expires immediately"
fi
unset BREW_CHANGE_REFRESH_BACKOFF

refresh_backoff_clear
if [[ -e "$REFRESH_BACKOFF_FILE" ]]; then
    no "backoff: clear removes record" "file still present"
else
    ok "backoff: clear removes record"
fi

# --- spawn gate under backoff ---------------------------------------------------
export BREW_CHANGE_BADGE_NO_SPAWN=1
_badge_now > "$REFRESH_BACKOFF_FILE"
rm -rf "$REFRESH_LOCK_DIR"
if badge_spawn_refresh "$REPO_ROOT/brew-change"; then
    ok "spawn: backoff skips silently"
else
    no "spawn: backoff skips silently" "returned failure"
fi
if [[ -d "$REFRESH_LOCK_DIR" ]]; then
    no "spawn: backoff never claims lock" "lock dir created"
else
    ok "spawn: backoff never claims lock"
fi
refresh_backoff_clear
unset BREW_CHANGE_BADGE_NO_SPAWN

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
