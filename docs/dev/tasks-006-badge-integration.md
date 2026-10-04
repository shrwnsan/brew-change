# Badge Integration Implementation Plan (tasks-006 / prd-004)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-line verdict badge printed after `brew update`/`brew upgrade` via an opt-in shell wrapper, backed by the cached export and a locked detached one-shot refresh.

**Architecture:** Three new subcommands (`badge`, `refresh`, `init`) dispatched in the main script following the existing `export` pre-parse pattern. `lib/brew-change-badge.sh` holds all new logic (pure render helpers, lock, spawn, orchestration). `refresh` reuses the existing plain `-b` evidence pipeline with stdout surfaces suppressed via a `REFRESH_MODE` flag.

**Tech Stack:** Bash 4+, jq (already hard dependencies). No new dependencies. No export schema changes.

**Spec:** `docs/dev/prd-004-badge-integration.md` — read it first. Test seam convention: `BREW_CHANGE_TEST_NOW` overrides `date +%s` (same as `lib/brew-change-utils.sh:506`); new seams `BREW_CHANGE_BADGE_FORCE` (pretend stdout is a TTY) and `BREW_CHANGE_BADGE_NO_SPAWN` (exercise lock decisions without executing a child).

**Deviation from spec, deliberate:** no `-q` flag on `refresh`. Quiet is inherent (all stdout surfaces are suppressed); accepting a dead flag is worse than not having it. Spec spawn line reads `nohup brew-change refresh -q`; we spawn `nohup brew-change refresh`. Update the prd line when flipping its Status in Task 7.

---

### Task 0: Worktree

**Files:** none (workspace setup)

- [ ] **Step 1: Verify `.worktrees` is ignored**

Run: `git check-ignore -q .worktrees && echo ignored || echo NOT-IGNORED`
Expected: `ignored`. If `NOT-IGNORED`: `echo ".worktrees/" >> .git/info/exclude` (do NOT touch tracked `.gitignore`).

- [ ] **Step 2: Create worktree + branch**

```bash
git worktree add .worktrees/feat/badge-integration -b feat/badge-integration
cd .worktrees/feat/badge-integration
```

All later paths are relative to this worktree root. Run tests from here.

---

### Task 1: Badge render helpers (pure functions) — TDD

**Files:**
- Create: `lib/brew-change-badge.sh`
- Test: `tests/test-badge-output.sh`

- [ ] **Step 1: Write the failing tests**

Create `tests/test-badge-output.sh`:

```bash
#!/usr/bin/env bash
# Tests for the badge surface (prd-004 / tasks-006).
#
# Exercises lib/brew-change-badge.sh:
# - badge_counts extracts verdict counts from the export
# - badge_render_line renders the dense one-line contract
# - badge_age_human formats relative age
# - badge_generated_epoch parses ISO-8601 UTC
# - badge_main output contract (Task 3 adds those tests to this file)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/brew-change-badge.sh
source "$REPO_ROOT/lib/brew-change-badge.sh"

FIXTURES="$SCRIPT_DIR/fixtures/badge"
mkdir -p "$FIXTURES"
FIXTURE_EXPORT="$FIXTURES/last-assessment.json"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf 'ok %d - %s\n' "$pass" "$1"
}

no() {
    fail=$((fail + 1))
    printf 'not ok %d - %s\n' "$((pass + fail))" "$1"
    shift
    printf '    %s\n' "$*" >&2
}

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        ok "$desc"
    else
        no "$desc" "got: '$got'  want: '$want'"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$desc"
    else
        no "$desc" "expected '$needle' in '$haystack'"
    fi
}

# make_export <path> <generated_at_iso> <packages_json_array>
make_export() {
    jq -n --arg ts "$2" --argjson pkgs "$3" \
        '{schema_version: 1, generated_at: $ts, packages: $pkgs}' > "$1"
}

# --- badge_counts -----------------------------------------------------------
make_export "$FIXTURE_EXPORT" "2026-10-05T12:00:00Z" '[
  {"name":"node","classification":"attention","matched_signals":["breaking-change-pattern"]},
  {"name":"python","classification":"attention","matched_signals":["major-version-transition"]},
  {"name":"wget","classification":"no-signal","matched_signals":[]},
  {"name":"gh","classification":"unknown","matched_signals":[]}
]'
assert_eq "badge_counts: counts + breaking names + classifications" \
    "$(badge_counts "$FIXTURE_EXPORT")" \
    "$(printf '4\t2\tnode,python\t1\t1')"

printf '{"schema_version":1,"generated_at":"x","packages":[{"name":"a","classification":"attention","matched_signals":["breaking-change-pattern"]}],"extra":true}' > "$FIXTURE_EXPORT"
assert_eq "badge_counts: single breaking" \
    "$(badge_counts "$FIXTURE_EXPORT")" \
    "$(printf '1\t1\ta\t0\t0')"

printf 'not json' > "$FIXTURE_EXPORT"
if badge_counts "$FIXTURE_EXPORT" >/dev/null 2>&1; then
    no "badge_counts: malformed JSON fails" "returned success"
else
    ok "badge_counts: malformed JSON fails"
fi

if badge_counts "$FIXTURES/missing.json" >/dev/null 2>&1; then
    no "badge_counts: missing file fails" "returned success"
else
    ok "badge_counts: missing file fails"
fi

# --- badge_render_line ------------------------------------------------------
assert_eq "render: all segments" \
    "$(badge_render_line 4 2 "node,python" 1 1 "2h")" \
    "brew-change: 4 updates · 2 breaking (node, python) · 1 no-signal · 1 unknown · 2h ago"

assert_eq "render: name cap at 3 then +K" \
    "$(badge_render_line 5 4 "a,b,c,d" 0 0 "3d")" \
    "brew-change: 5 updates · 4 breaking (a, b, c +1) · 3d ago"

assert_eq "render: updates + age only" \
    "$(badge_render_line 3 0 "" 0 0 "1m")" \
    "brew-change: 3 updates · 1m ago"

assert_eq "render: updates only, empty age" \
    "$(badge_render_line 3 0 "" 0 0 "")" \
    "brew-change: 3 updates"

# --- badge_age_human --------------------------------------------------------
assert_eq "age: minutes" "$(badge_age_human 1000 1900)" "16m"
assert_eq "age: zero delta is 1m" "$(badge_age_human 500 500)" "1m"
assert_eq "age: hours" "$(badge_age_human 0 7200)" "2h"
assert_eq "age: days" "$(badge_age_human 0 259200)" "3d"
assert_eq "age: clock skew clamps to 1m" "$(badge_age_human 5000 4000)" "1m"

# --- badge_generated_epoch --------------------------------------------------
WANT_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T00:00:00Z" +"%s" 2>/dev/null \
    || date -u -d "2026-01-01T00:00:00Z" +"%s")"
assert_eq "epoch: ISO-8601 Z" "$(badge_generated_epoch "2026-01-01T00:00:00Z")" "$WANT_EPOCH"

if badge_generated_epoch "not-a-date" >/dev/null 2>&1; then
    no "epoch: garbage rejected" "returned success"
else
    ok "epoch: garbage rejected"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-badge-output.sh`
Expected: source failure — `lib/brew-change-badge.sh: No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/brew-change-badge.sh`:

```bash
#!/usr/bin/env bash
# Badge + shell-integration surface (prd-004 / tasks-006).
#
# The badge is a first-party consumer of the assessment export
# (~/.brew-change/last-assessment.json). It renders one terminal line from
# cached data and never runs the assessment pipeline itself; refreshes are
# spawned as detached one-shot runs guarded by a lock (prd-004 Approach A).
# Contract: the badge may never fail the caller's shell — every path exits
# 0 and error paths are silent.

# Default staleness threshold for the badge (seconds), used when
# BREW_CHANGE_BADGE_MAX_AGE is unset.
BADGE_DEFAULT_MAX_AGE=86400
# Breaking names shown before collapsing to "+K" (prd-004 output contract).
BADGE_NAME_CAP=3
# Lock directory for the detached one-shot refresh.
REFRESH_LOCK_DIR="${HOME}/.brew-change/.refresh.lock"
# A lock older than this (seconds) is abandoned even if its PID looks alive
# (recycled-PID guard).
REFRESH_LOCK_MAX_AGE=1800

# ---------------------------------------------------------------------------
# _badge_now — epoch seconds; BREW_CHANGE_TEST_NOW overrides (test seam,
# same convention as _http_cache_now in brew-change-utils.sh).
# ---------------------------------------------------------------------------
_badge_now() { printf '%s\n' "${BREW_CHANGE_TEST_NOW:-$(date +%s)}"; }

# ---------------------------------------------------------------------------
# badge_counts <export_file>
#
# Prints verdict counts as one TAB-separated line:
#   updates <TAB> breaking <TAB> breaking_names_csv <TAB> nosignal <TAB> unknown
#
# updates = all packages (every export row was outdated at assessment time).
# breaking = rows whose matched_signals include "breaking-change-pattern"
# (signal names: lib/brew-change-assessment.sh; the other current signal is
# "major-version-transition").
#
# Prints nothing and returns 1 when the file is unreadable or not valid JSON.
# ---------------------------------------------------------------------------
badge_counts() {
    local file="$1"
    [[ -r "$file" ]] || return 1
    jq -r '
        (.packages // []) as $pkgs
        | ([ $pkgs[] | select((.matched_signals // []) | index("breaking-change-pattern")) ]) as $brk
        | [ ($pkgs | length),
            ($brk | length),
            ([ $brk[].name ] | join(",")),
            ([ $pkgs[] | select(.classification == "no-signal") ] | length),
            ([ $pkgs[] | select(.classification == "unknown") ] | length)
          ]
        | @tsv' "$file" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# badge_render_line <updates> <breaking> <names_csv> <nosignal> <unknown> <age>
#
# Renders the badge line without any state suffix. Segments beyond "N
# updates" print only when non-empty (prd-004 output contract).
# ---------------------------------------------------------------------------
badge_render_line() {
    local updates="$1" breaking="$2" names_csv="$3" nosignal="$4" unknown="$5" age="$6"
    local line="brew-change: ${updates} updates"
    if (( breaking > 0 )); then
        local -a names=() shown=()
        IFS=',' read -r -a names <<< "$names_csv"
        local i
        for (( i = 0; i < ${#names[@]} && i < BADGE_NAME_CAP; i++ )); do
            shown+=("${names[$i]}")
        done
        local label
        label="$(printf '%s, ' "${shown[@]}")"
        label="${label%, }"
        if (( ${#names[@]} > BADGE_NAME_CAP )); then
            label="${label} +$(( ${#names[@]} - BADGE_NAME_CAP ))"
        fi
        line+=" · ${breaking} breaking (${label})"
    fi
    if (( nosignal > 0 )); then line+=" · ${nosignal} no-signal"; fi
    if (( unknown > 0 )); then line+=" · ${unknown} unknown"; fi
    if [[ -n "$age" ]]; then line+=" · ${age} ago"; fi
    printf '%s' "$line"
}

# ---------------------------------------------------------------------------
# badge_age_human <generated_epoch> <now_epoch>
#
# Prints "16m" / "3h" / "2d". Sub-hour deltas round up to 1m; negative deltas
# (clock skew) clamp to 1m. Non-numeric input prints an empty string.
# ---------------------------------------------------------------------------
badge_age_human() {
    local gen="$1" now="$2"
    [[ "$gen" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
    local delta=$(( now - gen ))
    if (( delta < 60 )); then delta=60; fi
    if (( delta < 3600 )); then
        printf '%dm' $(( delta / 60 ))
    elif (( delta < 172800 )); then
        printf '%dh' $(( delta / 3600 ))
    else
        printf '%dd' $(( delta / 86400 ))
    fi
}

# ---------------------------------------------------------------------------
# badge_generated_epoch <iso8601_utc_timestamp>
#
# Parses "2026-10-05T12:34:56Z" to epoch seconds. BSD date first, then GNU.
# Returns 1 when unparseable (badge_main treats that as a non-event).
# ---------------------------------------------------------------------------
badge_generated_epoch() {
    local ts="$1" epoch=""
    epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +"%s" 2>/dev/null)" \
        || epoch="$(date -u -d "$ts" +"%s" 2>/dev/null)" \
        || epoch=""
    [[ -n "$epoch" ]] || return 1
    printf '%s' "$epoch"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-badge-output.sh`
Expected: all `ok`, `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/brew-change-badge.sh tests/test-badge-output.sh
git commit -m "feat(badge): render helpers for the update badge surface

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Refresh lock — TDD

**Files:**
- Modify: `lib/brew-change-badge.sh` (append)
- Test: `tests/test-refresh-lock.sh` (create)

- [ ] **Step 1: Write the failing tests**

Create `tests/test-refresh-lock.sh`:

```bash
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
[[ -d "$REFRESH_LOCK_DIR" ]] && no "release: removes lock dir" "dir still present" || ok "release: removes lock dir"

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
[[ -d "$REFRESH_LOCK_DIR" ]] && no "spawn: NO_SPAWN releases lock" "dir still present" || ok "spawn: NO_SPAWN releases lock"

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-refresh-lock.sh`
Expected: `refresh_lock_acquire: command not found` (or equivalent) — failures.

- [ ] **Step 3: Write the minimal implementation**

Append to `lib/brew-change-badge.sh`:

```bash
# ---------------------------------------------------------------------------
# refresh_lock_acquire
#
# Atomically claims the refresh lock. Returns 0 when acquired (fresh or taken
# over from an abandoned lock), 1 when a live refresh plausibly holds it.
#
# Takeover cases: readable PID that is dead, or a lock older than
# REFRESH_LOCK_MAX_AGE. A missing/unreadable pid file does NOT take over —
# the creator may be between mkdir and its pid write (conservative skip).
#
# The pid file normally records the spawned refresh child (badge writes it
# after spawn, see badge_spawn_refresh); refresh_lock_acquire itself records
# the caller so plain acquire-and-hold tests are meaningful.
# ---------------------------------------------------------------------------
refresh_lock_acquire() {
    if mkdir "$REFRESH_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
        _badge_now > "${REFRESH_LOCK_DIR}/started"
        return 0
    fi
    local lpid lstart age=0
    lpid="$(cat "${REFRESH_LOCK_DIR}/pid" 2>/dev/null || true)"
    lstart="$(cat "${REFRESH_LOCK_DIR}/started" 2>/dev/null || true)"
    [[ "$lstart" =~ ^[0-9]+$ ]] && age=$(( $(_badge_now) - lstart ))
    if [[ -z "$lpid" ]]; then
        return 1
    fi
    if (( age >= REFRESH_LOCK_MAX_AGE )); then
        refresh_lock_release
    elif kill -0 "$lpid" 2>/dev/null; then
        return 1
    else
        refresh_lock_release
    fi
    mkdir "$REFRESH_LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" > "${REFRESH_LOCK_DIR}/pid"
    _badge_now > "${REFRESH_LOCK_DIR}/started"
    return 0
}

# ---------------------------------------------------------------------------
# refresh_lock_release — idempotent.
# ---------------------------------------------------------------------------
refresh_lock_release() {
    rm -rf "$REFRESH_LOCK_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# badge_self_path <raw_path>
#
# Resolves the main script to an absolute executable path for re-invoking
# refresh. Returns 1 when the path is not a usable executable.
# ---------------------------------------------------------------------------
badge_self_path() {
    local raw="$1"
    [[ -n "$raw" ]] || return 1
    local dir base abs
    dir="$(cd "$(dirname "$raw")" 2>/dev/null && pwd)" || return 1
    base="$(basename "$raw")"
    abs="${dir}/${base}"
    [[ -x "$abs" ]] || return 1
    printf '%s' "$abs"
}

# ---------------------------------------------------------------------------
# badge_spawn_refresh <script_path>
#
# Claims the lock, spawns `brew-change refresh` detached, records the child's
# PID in the lock, and leaves the lock in place — the refresh run releases it
# when it exits. Held lock → skip silently (a refresh is already pending).
#
# BREW_CHANGE_BADGE_NO_SPAWN=1 exercises the lock decision without executing
# the child (test seam; the lock is released immediately in that case).
# ---------------------------------------------------------------------------
badge_spawn_refresh() {
    refresh_lock_acquire || return 0
    if [[ "${BREW_CHANGE_BADGE_NO_SPAWN:-0}" == "1" ]]; then
        refresh_lock_release
        return 0
    fi
    local self
    self="$(badge_self_path "$1")" || { refresh_lock_release; return 0; }
    nohup "$self" refresh >/dev/null 2>&1 </dev/null &
    local child=$!
    printf '%s\n' "$child" > "${REFRESH_LOCK_DIR}/pid"
    disown "$child" 2>/dev/null || true
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-refresh-lock.sh`
Expected: all `ok`, `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/brew-change-badge.sh tests/test-refresh-lock.sh
git commit -m "feat(badge): refresh lock with dead-PID and expiry takeover

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: badge_main orchestration — TDD

**Files:**
- Modify: `lib/brew-change-badge.sh` (append)
- Test: `tests/test-badge-output.sh` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-badge-output.sh` (before the final `printf`/`[[ ]]` summary lines):

```bash
# --- badge_main --------------------------------------------------------------
# Re-point the lock + export at fixture paths (the lib derived them from the
# real HOME at source time, exactly like tests/test-assessment-export.sh).
REFRESH_LOCK_DIR="$FIXTURES/badge-main.lock"
export ASSESSMENT_EXPORT_FILE="$FIXTURE_EXPORT"
export BREW_CHANGE_BADGE_FORCE=1       # tests run without a TTY on stdout
export BREW_CHANGE_BADGE_NO_SPAWN=1
ts_now="2026-10-05T12:00:00Z"
export BREW_CHANGE_TEST_NOW="$(badge_generated_epoch "$ts_now")"

# fresh export: line only, no suffix
make_export "$FIXTURE_EXPORT" "$ts_now" \
    '[{"name":"node","classification":"attention","matched_signals":["breaking-change-pattern"]}]'
assert_eq "badge_main: fresh line" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: 1 updates · 1 breaking (node) · 1m ago"

# zero packages: still a valid fresh line
make_export "$FIXTURE_EXPORT" "$ts_now" '[]'
assert_eq "badge_main: zero updates" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: 0 updates · 1m ago"

# stale export (36h old > 24h default): refreshing suffix
make_export "$FIXTURE_EXPORT" "2026-10-04T00:00:00Z" \
    '[{"name":"node","classification":"unknown","matched_signals":[]}]'
out="$(badge_main after-update "$REPO_ROOT/brew-change")"
assert_contains "badge_main: stale suffix" "$out" "· refreshing…"
assert_contains "badge_main: stale age" "$out" "36h ago"

# upgrade trigger: always updating suffix, even when fresh
make_export "$FIXTURE_EXPORT" "$ts_now" '[]'
assert_contains "badge_main: upgrade suffix" \
    "$(badge_main after-upgrade "$REPO_ROOT/brew-change")" "· assessment updating…"

# custom max age: 3600 makes the 36h-old export stale, and 129600 makes it fresh
make_export "$FIXTURE_EXPORT" "2026-10-04T00:00:00Z" '[]'
BREW_CHANGE_BADGE_MAX_AGE=3600 assert_contains "badge_main: BREW_CHANGE_BADGE_MAX_AGE shortens freshness" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" "· refreshing…"
BREW_CHANGE_BADGE_MAX_AGE=129600 assert_not_contains "badge_main: BREW_CHANGE_BADGE_MAX_AGE extends freshness" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" "refreshing"

# garbage max age: falls back to default, never crashes
BREW_CHANGE_BADGE_MAX_AGE=notanumber assert_eq "badge_main: garbage max age falls back to default" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: 0 updates · 36h ago · refreshing…"

# missing export: setup hint
export ASSESSMENT_EXPORT_FILE="$FIXTURES/does-not-exist.json"
assert_eq "badge_main: missing → hint" \
    "$(badge_main after-update "$REPO_ROOT/brew-change")" \
    "brew-change: no assessment yet — run brew-change -b"

# malformed export: silence (non-event contract)
printf 'not json' > "$FIXTURE_EXPORT"
export ASSESSMENT_EXPORT_FILE="$FIXTURE_EXPORT"
assert_eq "badge_main: malformed → silence" "$(badge_main after-update x)" ""

# future schema: silence
jq -n '{schema_version: 99, generated_at: "2026-10-05T12:00:00Z", packages: []}' > "$FIXTURE_EXPORT"
assert_eq "badge_main: future schema → silence" "$(badge_main after-update x)" ""

# unparsable generated_at: silence
jq -n '{schema_version: 1, generated_at: "garbage", packages: []}' > "$FIXTURE_EXPORT"
assert_eq "badge_main: bad generated_at → silence" "$(badge_main after-update x)" ""

# disable beats force
make_export "$FIXTURE_EXPORT" "$ts_now" '[]'
export BREW_CHANGE_BADGE_DISABLE=1
assert_eq "badge_main: disable beats force" "$(badge_main after-update x)" ""
unset BREW_CHANGE_BADGE_DISABLE

# piped stdout (force off): silence
unset BREW_CHANGE_BADGE_FORCE
assert_eq "badge_main: piped stdout is silent" "$(badge_main after-update x)" ""
export BREW_CHANGE_BADGE_FORCE=1
unset BREW_CHANGE_BADGE_NO_SPAWN BREW_CHANGE_TEST_NOW
```

Also add `assert_not_contains` next to the existing helpers (top of file):

```bash
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$desc"
    else
        no "$desc" "did not expect '$needle' in '$haystack'"
    fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-badge-output.sh`
Expected: `badge_main: command not found` — the new assertions fail.

- [ ] **Step 3: Write the minimal implementation**

Append to `lib/brew-change-badge.sh`:

```bash
# ---------------------------------------------------------------------------
# badge_main <after-update|after-upgrade> <script_path>
#
# Entry from the main script's badge subcommand. Output contract (prd-004):
# - always exits 0; every error path is silent
# - silent when stdout is not a TTY (BREW_CHANGE_BADGE_FORCE=1 overrides —
#   test seam) or when BREW_CHANGE_BADGE_DISABLE=1
# - missing export: one-line setup hint
# - unparsable JSON, unsupported schema_version, or unparsable generated_at:
#   silence (non-event, per the export consumer contract in
#   docs/assessment-export.md)
# - fresh (age < BREW_CHANGE_BADGE_MAX_AGE, default BADGE_DEFAULT_MAX_AGE):
#   the rendered line only
# - stale after-update: line + " · refreshing…" + spawn refresh
# - after-upgrade: line + " · assessment updating…" + always spawn refresh
#   (the outdated set provably changed)
# ---------------------------------------------------------------------------
badge_main() {
    local trigger="$1" script_path="$2"
    if [[ "${BREW_CHANGE_BADGE_DISABLE:-0}" == "1" ]]; then return 0; fi
    if [[ ! -t 1 && "${BREW_CHANGE_BADGE_FORCE:-0}" != "1" ]]; then return 0; fi

    if [[ ! -r "${ASSESSMENT_EXPORT_FILE:-}" ]]; then
        printf '%s\n' "brew-change: no assessment yet — run brew-change -b"
        return 0
    fi
    jq -e 'type == "object" and (.schema_version == 1)' "${ASSESSMENT_EXPORT_FILE}" >/dev/null 2>&1 \
        || return 0

    local counts gen_epoch now age line suffix="" spawn=0
    counts="$(badge_counts "${ASSESSMENT_EXPORT_FILE}")" || return 0
    gen_epoch="$(badge_generated_epoch \
        "$(jq -r '.generated_at // empty' "${ASSESSMENT_EXPORT_FILE}")")" || return 0
    now="$(_badge_now)"
    age="$(badge_age_human "$gen_epoch" "$now")"
    # $counts is five TAB-separated fields; unquoted expansion is the split.
    line="$(badge_render_line $counts "$age")"

    if [[ "$trigger" == "after-upgrade" ]]; then
        suffix=" · assessment updating…"
        spawn=1
    else
        local max_age="${BREW_CHANGE_BADGE_MAX_AGE:-$BADGE_DEFAULT_MAX_AGE}"
        # Non-numeric garbage must fall back to the default, never reach the
        # arithmetic below (set -u turns unset arithmetic names into errors).
        [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=$BADGE_DEFAULT_MAX_AGE
        if (( now >= gen_epoch + max_age )); then
            suffix=" · refreshing…"
            spawn=1
        fi
    fi

    printf '%s%s\n' "$line" "$suffix"
    if (( spawn == 1 )); then
        badge_spawn_refresh "$script_path"
    fi
    return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-badge-output.sh && bash tests/test-refresh-lock.sh`
Expected: all `ok`, `0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/brew-change-badge.sh tests/test-badge-output.sh
git commit -m "feat(badge): badge_main orchestration with staleness and trigger contract

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: `init` subcommand — TDD

**Files:**
- Modify: `brew-change` (pre-parse block, lines ~83-155)
- Test: `tests/test-badge-init.sh` (create)

- [ ] **Step 1: Write the failing tests**

Create `tests/test-badge-init.sh`:

```bash
#!/usr/bin/env bash
# Tests for the `init` subcommand (prd-004 / tasks-006).
#
# - init zsh / init bash emit syntax-valid wrapper code
# - the wrapper passes a failing brew's exit status through
# - the wrapper invokes `brew-change badge after-update` after `brew update`
# - argument validation: missing shell, unsupported shell, extra args

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BREW_CHANGE="$REPO_ROOT/brew-change"

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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"; else no "$desc" "expected '$needle' in '$haystack'"; fi
}

# --- syntax validity ----------------------------------------------------------
bash "$BREW_CHANGE" init zsh > "$FIXTURES/init-zsh.sh" || no "init zsh: exits 0" "non-zero"
bash "$BREW_CHANGE" init bash > "$FIXTURES/init-bash.sh" || no "init bash: exits 0" "non-zero"

if bash -n "$FIXTURES/init-zsh.sh" 2>/dev/null; then ok "init zsh: bash -n clean"; else no "init zsh: bash -n clean" "syntax error"; fi
if bash -n "$FIXTURES/init-bash.sh" 2>/dev/null; then ok "init bash: bash -n clean"; else no "init bash: bash -n clean" "syntax error"; fi
if command -v zsh >/dev/null 2>&1; then
    if zsh -n "$FIXTURES/init-zsh.sh" 2>/dev/null; then ok "init zsh: zsh -n clean"; else no "init zsh: zsh -n clean" "syntax error"; fi
else
    ok "init zsh: zsh -n skipped (zsh not installed)"
fi

assert_contains "wrapper: passes brew through" "$(cat "$FIXTURES/init-bash.sh")" 'command brew "$@"'
assert_contains "wrapper: returns brew status" "$(cat "$FIXTURES/init-bash.sh")" 'return $__bc_ec'
assert_contains "wrapper: update trigger" "$(cat "$FIXTURES/init-bash.sh")" 'badge after-update'
assert_contains "wrapper: upgrade trigger" "$(cat "$FIXTURES/init-bash.sh")" 'badge after-upgrade'

# --- argument validation -------------------------------------------------------
out="$(bash "$BREW_CHANGE" init 2>&1 >/dev/null)"
if [[ $? -eq 0 ]]; then no "init: missing shell errors" "exited 0"; else ok "init: missing shell errors"; fi
assert_contains "init: missing shell message" "$out" "init requires a shell"

out="$(bash "$BREW_CHANGE" init fish 2>&1 >/dev/null)"
if [[ $? -eq 0 ]]; then no "init: unsupported shell errors" "exited 0"; else ok "init: unsupported shell errors"; fi
assert_contains "init: unsupported shell message" "$out" "unsupported shell"

out="$(bash "$BREW_CHANGE" init zsh node 2>&1 >/dev/null)"
if [[ $? -eq 0 ]]; then no "init: extra args error" "exited 0"; else ok "init: extra args error"; fi

# --- wrapper behavior: exit-code passthrough + badge invocation -----------------
BIN="$FIXTURES/bin"
mkdir -p "$BIN"
cat > "$BIN/brew" << 'EOF'
#!/usr/bin/env bash
# Fake brew: records the call, then fails like a real failure would.
printf 'BREW %s\n' "$*" >> "${BC_LOG}"
exit 7
EOF
cat > "$BIN/brew-change" << 'EOF'
#!/usr/bin/env bash
printf 'BADGE %s\n' "$*" >> "${BC_LOG}"
exit 0
EOF
chmod +x "$BIN/brew" "$BIN/brew-change"
export BC_LOG="$FIXTURES/wrapper.log"
: > "$BC_LOG"

TEST_SCRIPT="$FIXTURES/wrapper-test.sh"
{
    echo 'set -e'
    cat "$FIXTURES/init-bash.sh"
    echo 'brew update'
    echo 'printf "ec=%s\n" "$?"'
} > "$TEST_SCRIPT"

# Run under a pty so the wrapper's >/dev/tty redirect succeeds (macOS script;
# skip invocation assertions where script/pty is unavailable).
WRAPPER_OUT=""
if command -v script >/dev/null 2>&1; then
    WRAPPER_OUT="$(script -q /dev/null bash "$TEST_SCRIPT" 2>/dev/null | tr -d '\r')"
else
    WRAPPER_OUT="$(bash "$TEST_SCRIPT" 2>/dev/null)"
fi

assert_contains "wrapper: failing brew exit code passes through" "$WRAPPER_OUT" "ec=7"
assert_contains "wrapper: brew itself was called" "$(cat "$BC_LOG")" "BREW update"

if command -v script >/dev/null 2>&1 && [[ -e /dev/tty ]]; then
    assert_contains "wrapper: badge invoked after update" "$(cat "$BC_LOG")" "BADGE badge after-update"
else
    ok "wrapper: badge invocation skipped (no pty available)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-badge-init.sh`
Expected: failures — `init` is currently an unknown option / missing-shell tests fail.

- [ ] **Step 3: Write the minimal implementation**

In `brew-change`, make three edits.

Edit 1 — pre-parse state (after `_PRE_PARSE_HAS_EXPORT="false"` at line ~85):

```bash
_PRE_PARSE_HAS_BADGE="false"
_PRE_PARSE_BADGE_TRIGGER=""
_PRE_PARSE_HAS_INIT="false"
_PRE_PARSE_INIT_SHELL=""
_PRE_PARSE_HAS_REFRESH="false"
```

Edit 2 — pre-parse case (add before `*)` at line ~122):

```bash
        badge)
            _PRE_PARSE_HAS_BADGE="true"
            ;;
        after-update|after-upgrade)
            # Trigger positionally following `badge`; validated below.
            _PRE_PARSE_BADGE_TRIGGER="$_arg"
            ;;
        init)
            _PRE_PARSE_HAS_INIT="true"
            ;;
        refresh)
            _PRE_PARSE_HAS_REFRESH="true"
            ;;
```

And extend the existing `*)` case to:

```bash
        *)
            if [[ "$_PRE_PARSE_HAS_INIT" == "true" ]]; then
                if [[ -z "$_PRE_PARSE_INIT_SHELL" ]]; then
                    _PRE_PARSE_INIT_SHELL="$_arg"
                else
                    echo "Error: init takes exactly one shell argument (zsh or bash)" >&2
                    exit 1
                fi
            elif [[ "$_PRE_PARSE_HAS_BADGE" == "true" && -n "$_PRE_PARSE_BADGE_TRIGGER" ]]; then
                echo "Error: badge takes exactly one trigger (after-update or after-upgrade)" >&2
                exit 1
            else
                # A package argument gathers changelog evidence too.
                _PRE_PARSE_HAS_EVIDENCE_MODE="true"
            fi
            ;;
```

Edit 3 — argument validation + init handler (insert after the `--fresh` validation loop, before `unset _arg` at line ~155):

```bash
# prd-004 subcommand validation
if [[ "$_PRE_PARSE_HAS_BADGE" == "true" && -z "$_PRE_PARSE_BADGE_TRIGGER" ]]; then
    echo "Error: badge requires a trigger: after-update or after-upgrade" >&2
    echo "Example: brew-change badge after-update" >&2
    exit 1
fi
if [[ "$_PRE_PARSE_HAS_REFRESH" == "true" ]]; then
    for _arg in "${ORIGINAL_ARGS[@]}"; do
        if [[ "$_arg" != "refresh" ]]; then
            echo "Error: refresh takes no arguments" >&2
            exit 1
        fi
    done
fi

# prd-004: `init` emits the shell wrapper and exits before any library
# sourcing — it stays dependency-free and instant. It never writes rc files;
# the user opts in with: eval "$(brew-change init zsh)"
if [[ "$_PRE_PARSE_HAS_INIT" == "true" ]]; then
    case "${_PRE_PARSE_INIT_SHELL:-}" in
        zsh|bash) ;;
        "")
            echo "Error: init requires a shell: zsh or bash" >&2
            exit 1
            ;;
        *)
            echo "Error: unsupported shell: $_PRE_PARSE_INIT_SHELL (use zsh or bash)" >&2
            exit 1
            ;;
    esac
    cat << 'EOF'
# brew-change badge integration (opt-in; see docs/badge-integration.md)
# Define this after any other brew function/alias — it takes precedence.
brew() {
    local __bc_ec=0
    command brew "$@" || __bc_ec=$?
    case "${1:-}" in
        update)  command brew-change badge after-update  >/dev/tty 2>&1 || true ;;
        upgrade) command brew-change badge after-upgrade >/dev/tty 2>&1 || true ;;
    esac
    return $__bc_ec
}
EOF
    exit 0
fi

unset _arg
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-badge-init.sh && bash tests/test-cli-validation.sh`
Expected: badge-init all `ok`; cli-validation still green (no regressions in option handling).

- [ ] **Step 5: Commit**

```bash
git add brew-change tests/test-badge-init.sh
git commit -m "feat(badge): init subcommand emitting the shell wrapper

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: `badge` subcommand dispatch — TDD

**Files:**
- Modify: `brew-change` (source block ~lines 203-218, badge handler)
- Test: `tests/test-badge-output.sh` (append CLI-level tests)

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-badge-output.sh` (before the summary lines):

```bash
# --- badge subcommand via the CLI ---------------------------------------------
CLI_HOME="$FIXTURES/cli-home"
rm -rf "$CLI_HOME"
mkdir -p "$CLI_HOME/.brew-change"
make_export "$CLI_HOME/.brew-change/last-assessment.json" "2026-10-05T12:00:00Z" \
    '[{"name":"node","classification":"attention","matched_signals":["breaking-change-pattern"]}]'

CLI_RUN="$(cd "$REPO_ROOT" && pwd)/brew-change"
ts_cli="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cli_out="$(HOME="$CLI_HOME" BREW_CHANGE_BADGE_FORCE=1 BREW_CHANGE_BADGE_NO_SPAWN=1 \
    BREW_CHANGE_TEST_NOW="$(badge_generated_epoch "$ts_cli")" \
    bash "$CLI_RUN" badge after-update 2>/dev/null)"
assert_eq "CLI badge: fresh line" "$cli_out" "brew-change: 1 updates · 1 breaking (node) · 1m ago"

cli_out="$(HOME="$CLI_HOME" bash "$CLI_RUN" badge after-update 2>/dev/null)"
assert_eq "CLI badge: piped stdout silent" "$cli_out" ""

cli_err="$(HOME="$CLI_HOME" bash "$CLI_RUN" badge 2>&1 >/dev/null)"
cli_rc=0; HOME="$CLI_HOME" bash "$CLI_RUN" badge >/dev/null 2>&1 || cli_rc=$?
assert_eq "CLI badge: missing trigger exits 1" "$cli_rc" "1"
assert_contains "CLI badge: missing trigger message" "$cli_err" "badge requires a trigger"

# badge must not regress the export subcommand
exp_out="$(HOME="$CLI_HOME" bash "$CLI_RUN" export 2>/dev/null | jq -r '.schema_version')"
assert_eq "CLI badge: export subcommand still works" "$exp_out" "1"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-badge-output.sh`
Expected: `CLI badge: fresh line` fails — `badge` is currently an unknown option.

- [ ] **Step 3: Write the minimal implementation**

In `brew-change`, replace the source block (lines 203-218) with a staged version — badge exits before the heavy pipeline sources:

```bash
	# Stage 1 (prd-004): minimal libs for the badge subcommand, which must
	# stay fast — it runs after every wrapped brew update/upgrade.
	source "$LIB_DIR/brew-change-config.sh"
	source "$LIB_DIR/brew-change-utils.sh"
	source "$LIB_DIR/brew-change-export.sh"
	source "$LIB_DIR/brew-change-badge.sh"

	# Handle badge command (prd-004). Always exits 0; see badge_main.
	if [[ "$_PRE_PARSE_HAS_BADGE" == "true" ]]; then
	    badge_main "$_PRE_PARSE_BADGE_TRIGGER" "$0"
	    exit 0
	fi

	source "$LIB_DIR/brew-change-interactive.sh"
	source "$LIB_DIR/brew-change-breaking.sh"
	source "$LIB_DIR/brew-change-assessment.sh"
	source "$LIB_DIR/brew-change-github.sh"
	source "$LIB_DIR/brew-change-npm.sh"
	source "$LIB_DIR/brew-change-brew.sh"
	source "$LIB_DIR/brew-change-non-github.sh"
	source "$LIB_DIR/brew-change-display.sh"
	source "$LIB_DIR/brew-change-verdict.sh"
	source "$LIB_DIR/brew-change-parallel.sh"
	source "$LIB_DIR/brew-change-progress.sh"
	source "$LIB_DIR/brew-change-upgrade.sh"
	source "$LIB_DIR/brew-change-dashboard-ui.sh"
```

(The old `source "$LIB_DIR/brew-change-export.sh"` line is replaced by the stage-1 block; everything else keeps its order.)

Note: the badge path exits before `verify_dependencies` — deliberate (badge needs only jq, and badge_main already degrades silently when jq is missing, since `badge_counts`/`jq -e` failures return early).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-badge-output.sh && bash tests/test-badge-init.sh`
Expected: all `ok`, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add brew-change tests/test-badge-output.sh
git commit -m "feat(badge): badge subcommand via staged library sourcing

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: `refresh` subcommand — TDD

**Files:**
- Modify: `brew-change` (handler after line ~233; flow guards at lines ~497-522, ~662-688; zero-outdated sites at lines 468, 474)
- Modify: `lib/brew-change-badge.sh` (append `finish_refresh_empty_export`)
- Test: `tests/test-refresh-flow.sh` (create)

- [ ] **Step 1: Write the failing tests**

Create `tests/test-refresh-flow.sh`:

```bash
#!/usr/bin/env bash
# Tests for the `refresh` subcommand (prd-004 / tasks-006).
#
# Runs the real CLI against a fake `brew` on PATH with an empty outdated set:
# - exits 0, prints nothing, writes a fresh empty export, releases the lock
# - takes no arguments
# - skips silently when the lock is held

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BREW_CHANGE="$REPO_ROOT/brew-change"

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
    HOME="$R_HOME" PATH="$SHIM:$PATH" BREW_CHANGE_TEST_NOW="$(date +%s)" \
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

assert_contains "refresh: completion logged" "$(cat "$R_HOME/.brew-change/refresh.log" 2>/dev/null)" "refresh rc=0"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-refresh-flow.sh`
Expected: failures — `refresh` is currently an unknown option.

- [ ] **Step 3: Write the minimal implementation**

Edit 1 — append to `lib/brew-change-badge.sh`:

```bash
# ---------------------------------------------------------------------------
# finish_refresh_empty_export
#
# prd-004: a refresh that finds zero outdated packages still writes a fresh,
# empty export (so the badge can say "0 updates" with a new timestamp). The
# EXIT trap installed by the refresh handler owns lock release and the
# refresh.log entry for every exit path, including this one. No-op for every
# non-refresh invocation.
# ---------------------------------------------------------------------------
finish_refresh_empty_export() {
    [[ "${REFRESH_MODE:-}" == "true" ]] || return 0
    local empty_records
    empty_records="$(mktemp -t brew-change-empty.XXXXXX)" || exit 0
    write_assessment_export "$empty_records" || true
    rm -f "$empty_records"
    exit 0
}
```

Edit 2 — in `brew-change`, insert the refresh handler after `init_github_auth`/`export GITHUB_AUTH_TOKEN` (lines ~232-233) and before the "Full argument parsing" comment:

```bash
# Handle refresh command (prd-004): a headless -b-equivalent run that
# refreshes the export with no interactive surface. Badge spawns it detached
# under the refresh lock; the lock is held for the whole run. Piped-contract
# rules already keep the pipeline plain and non-prompting; REFRESH_MODE
# additionally suppresses every stdout surface. One EXIT trap owns the two
# always-required finish steps — lock release and the refresh.log entry —
# for every exit path (success, empty-outdated, hard failure).
if [[ "$_PRE_PARSE_HAS_REFRESH" == "true" ]]; then
    REFRESH_MODE="true"
    IDENTIFY_BREAKING="true"
    SHOW_ALL="true"
    export BREW_CHANGE_CHANGELOG_OUTPUT=0
    BREW_CHANGE_DEFER_SUMMARY=1
    if ! refresh_lock_acquire; then
        # Another refresh is pending/running: nothing to do, no trap yet.
        exit 0
    fi
    __bc_refresh_log="${BREW_CHANGE_REFRESH_LOG:-${HOME}/.brew-change/refresh.log}"
    __bc_refresh_finish() {
        local __rc=$?
        printf 'refresh rc=%s %s\n' "$__rc" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            >> "$__bc_refresh_log" 2>/dev/null || true
        # Size-capped log: keep the most recent 100 lines.
        tail -n 100 "$__bc_refresh_log" 2>/dev/null > "${__bc_refresh_log}.tmp" \
            && mv "${__bc_refresh_log}.tmp" "$__bc_refresh_log" 2>/dev/null || true
        refresh_lock_release
        trap - EXIT
    }
    trap __bc_refresh_finish EXIT
fi
```

Note the handler position: AFTER `init_github_auth` (refresh workers need the exported token) and BEFORE full argument parsing (which would re-derive `SHOW_ALL`/`IDENTIFY_BREAKING` — refresh sets them after that parse instead). Concretely: place this block immediately before the `# ------` + `Full argument parsing` comment at line ~235, and change nothing in the parse loop.

Edit 3 — suppress the interactive preamble in the `SHOW_ALL` branch. Wrap the block from `# First show the outdated packages list like brew outdated -v` (line ~497) through the blank `echo ""` just before `# Process packages in parallel` (line ~522) in:

```bash
        if [[ "$REFRESH_MODE" != "true" ]]; then
            # First show the outdated packages list like brew outdated -v
            echo "Outdated packages:"
            brew outdated -v

            # Ask for confirmation before showing detailed changelogs
            # Skip for upgrade mode (-u) or single package — auto-proceed
            echo ""
            if [[ $total_packages -eq 1 ]] || [[ "$UPGRADE_MODE" == "true" ]]; then
                echo ""
                echo "Processing changelog for $total_packages outdated package(s)..."
            else
                # Check if running interactively
                if is_interactive_mode; then
                    if ! prompt_for_confirmation "Found $total_packages outdated packages. Would you like to see detailed changelog information? (y/N) "; then
                        echo "Run 'brew upgrade' to upgrade all packages, or 'brew upgrade <package>' for individual packages."
                        exit 0
                    fi
                else
                    # Non-interactive mode (piped input): proceed without confirmation
                    echo "Found $total_packages outdated packages. Processing..."
                fi
            fi
            echo ""
        fi
```

Edit 4 — belt-and-braces summary suppression just before `process_packages_parallel` (line ~625):

```bash
        if [[ "$REFRESH_MODE" == "true" ]]; then
            BREW_CHANGE_DEFER_SUMMARY=1
        fi
        process_packages_parallel "$outdated_packages" "$PARALLEL_JOBS"
```

Edit 5 — zero-outdated sites (lines 468 and 474). Prepend the helper call to each `echo "No outdated packages found."; exit 0` pair:

```bash
                    finish_refresh_empty_export
                    echo "No outdated packages found."
                    exit 0
```

Edit 6 — the plain `-b` tail (line ~662): guard the verdict print, keep classify + export, release the lock, guard the hint. Replace:

```bash
                if classify_upgrade_evidence "$UPGRADE_STATUS_DIR" "${inventory_tokens[@]+"${inventory_tokens[@]}"}"; then
                    # Write assessment export for external consumers (tasks-005)
                    write_assessment_export "$UPGRADE_STATUS_DIR/assessment.jsonl" || true

                    verdict_block=$(render_verdict_summary "$UPGRADE_STATUS_DIR/assessment.jsonl")
                    if [[ -n "$verdict_block" ]]; then
                        printf '\n%s\n\n' "$verdict_block"
                    fi
                else
                    echo "Warning: verdict summary unavailable for this run" >&2
                fi
            fi
            echo "Run 'brew upgrade' to upgrade all packages, or 'brew upgrade <package>' for individual packages."
```

with:

```bash
                if classify_upgrade_evidence "$UPGRADE_STATUS_DIR" "${inventory_tokens[@]+"${inventory_tokens[@]}"}"; then
                    # Write assessment export for external consumers (tasks-005)
                    write_assessment_export "$UPGRADE_STATUS_DIR/assessment.jsonl" || true

                    if [[ "$REFRESH_MODE" != "true" ]]; then
                        verdict_block=$(render_verdict_summary "$UPGRADE_STATUS_DIR/assessment.jsonl")
                        if [[ -n "$verdict_block" ]]; then
                            printf '\n%s\n\n' "$verdict_block"
                        fi
                    fi
                else
                    echo "Warning: verdict summary unavailable for this run" >&2
                fi
            fi
            if [[ "$REFRESH_MODE" != "true" ]]; then
                echo "Run 'brew upgrade' to upgrade all packages, or 'brew upgrade <package>' for individual packages."
            fi
```

(Lock release at this tail is intentionally absent — the EXIT trap from Edit 2 owns it, including hard-failure exits.)

(The `if [[ "$IDENTIFY_BREAKING" == "true" && -n "${UPGRADE_STATUS_DIR:-}" ]]` condition wrapping this block is unchanged — refresh sets `IDENTIFY_BREAKING=true` and the status-dir block at line ~563 creates the dir for exactly this shape.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-refresh-flow.sh`
Expected: all `ok`, `0 failed`.

If `refresh: export written` fails on the empty path: check `finish_refresh_empty_export` placement — both zero-outdated exits (lines 468, 474) must call it before their `echo`/`exit 0`.

- [ ] **Step 5: Run the whole badge family + regressions**

Run: `bash tests/test-badge-output.sh && bash tests/test-refresh-lock.sh && bash tests/test-badge-init.sh && bash tests/test-refresh-flow.sh && bash tests/test-cli-validation.sh && bash tests/test-assessment-export.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add brew-change lib/brew-change-badge.sh tests/test-refresh-flow.sh
git commit -m "feat(badge): refresh subcommand — headless export refresh under lock

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Suite registration + help text + docs

**Files:**
- Modify: `tests/run-deterministic.sh`
- Modify: `brew-change` (usage text, Commands section + examples)
- Create: `docs/badge-integration.md`
- Modify: `docs/configuration.md`, `README.md`, `CHANGELOG.md`, `docs/dev/prd-004-badge-integration.md`

- [ ] **Step 1: Register the three new suites**

In `tests/run-deterministic.sh`, next to the `assessment export` line:

```bash
run_suite "badge output" bash "$SCRIPT_DIR/test-badge-output.sh"
run_suite "refresh lock" bash "$SCRIPT_DIR/test-refresh-lock.sh"
run_suite "badge init" bash "$SCRIPT_DIR/test-badge-init.sh"
run_suite "refresh flow" bash "$SCRIPT_DIR/test-refresh-flow.sh"
```

- [ ] **Step 2: Update usage text**

In `usage()` (brew-change, Commands section):

```
Commands:
  export               Print the last assessment export to stdout
  badge                Print a one-line verdict from the last assessment
                        (called by the shell wrapper; see `init`)
  refresh              Headless re-run that refreshes the assessment export
  init                 Emit the shell wrapper: init zsh | init bash
```

And in Examples:

```
  eval "$(brew-change init zsh)"  # opt in: badge after brew update/upgrade
```

- [ ] **Step 3: Write docs/badge-integration.md**

```markdown
# Badge Integration

One-line verdict highlights after `brew update` / `brew upgrade`, via an
opt-in shell wrapper. Homebrew has no hook or plugin mechanism for augmenting
core commands (verified against Homebrew source, 2026-10 — see
[dev/prd-004](dev/prd-004-badge-integration.md)), so brew-change ships the
wrapper pattern instead: a `brew()` shell function that runs the real brew,
prints the badge from cached assessment data, and returns brew's exact exit
status.

## Install (opt-in)

```zsh
# zsh — add to ~/.zshrc
eval "$(brew-change init zsh)"

# bash — add to ~/.bashrc
eval "$(brew-change init bash)"
```

Nothing is written to your rc files by brew-change itself. Place the line
after any other `brew` function or alias you define — the wrapper takes
precedence.

Uninstall: delete the `eval` line from your rc.

## What you see

    brew-change: 5 updates · 2 breaking (node, python) · 1 no-signal · 2h ago

- Counts come from the last assessment export (`~/.brew-change/last-assessment.json`)
  — the badge is instant and never touches the network.
- After `brew update` with a stale assessment (> 24h): `· refreshing…` — a
  headless `brew-change refresh` runs in the background (lock-protected, so
  parallel brew sessions never stack refreshes).
- After `brew upgrade`: `· assessment updating…` — always refreshed, because
  the outdated set provably changed.
- No assessment yet: `brew-change: no assessment yet — run brew-change -b`.
- The badge never prints in pipes or scripts (its own stdout-TTY check), and
  never changes brew's exit status.

## Wrapper semantics

    brew() {
        local __bc_ec=0
        command brew "$@" || __bc_ec=$?      # real brew runs unchanged
        case "${1:-}" in
            update)  command brew-change badge after-update  >/dev/tty 2>&1 || true ;;
            upgrade) command brew-change badge after-upgrade >/dev/tty 2>&1 || true ;;
        esac
        return $__bc_ec                       # brew's status passes through
    }

Only explicit `brew update` / `brew upgrade` invocations trigger the badge —
Homebrew's internal auto-update before install/upgrade is untouched.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BREW_CHANGE_BADGE_MAX_AGE` | `86400` | Seconds after `generated_at` before the assessment counts as stale and refreshes |
| `BREW_CHANGE_BADGE_DISABLE` | unset | `1` → badge is a silent no-op (escape hatch without editing rc) |

## Refresh internals

`brew-change refresh` is the headless engine: it re-runs the assessment
pipeline with all prompts resolved to `unknown`, no dashboard, no changelog
output, and writes the export. It is a public entry point — a future
LaunchAgent/cron integration calls the same command (prd-004 Approach B door
left open). State: `~/.brew-change/.refresh.lock/` (atomic mkdir; live-PID
skip; dead-PID or 30-min takeover).
```

- [ ] **Step 4: Update docs/configuration.md**

Add two rows to the environment-variable table (match existing table format):

```
| `BREW_CHANGE_BADGE_MAX_AGE` | `86400` | Badge: seconds after `generated_at` before the assessment counts as stale |
| `BREW_CHANGE_BADGE_DISABLE` | unset | Badge: `1` makes the update badge a silent no-op |
```

And a one-line pointer: badge details live in [badge-integration.md](badge-integration.md).

- [ ] **Step 5: Update README.md + CHANGELOG.md**

README quick-start, after the existing examples:

```markdown
# Opt in: one-line verdict badge after `brew update` / `brew upgrade`
eval "$(brew-change init zsh)"   # or: init bash
```

CHANGELOG, under `## [Unreleased]`:

```markdown
### Added
- Badge integration (opt-in): `eval "$(brew-change init zsh)"` defines a `brew`
  wrapper that prints a one-line verdict from the cached assessment after every
  `brew update`/`brew upgrade` — counts, breaking packages, assessment age —
  while passing brew's exit status through untouched. Stale assessments refresh
  in the background via the new headless `brew-change refresh` command
  (lock-protected, one-shot; also the future entry point for a LaunchAgent).
  See docs/badge-integration.md.
```

- [ ] **Step 6: Flip prd-004 status + record the -q deviation**

In `docs/dev/prd-004-badge-integration.md`:
- Status → `Implemented via tasks-006, 2026-10-05`
- In the `refresh` bullet, change "Quiet by default (`-q` semantics)" to "Quiet by default (no `-q` flag — quiet is inherent; deviation recorded in tasks-006)".

- [ ] **Step 7: Run the full deterministic suite**

Run: `bash tests/run-deterministic.sh`
Expected: every suite green, including the four new ones.

- [ ] **Step 8: Commit**

```bash
git add tests/run-deterministic.sh brew-change docs/badge-integration.md docs/configuration.md README.md CHANGELOG.md docs/dev/prd-004-badge-integration.md
git commit -m "docs(badge): badge integration guide, config entries, suite registration

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Verification + handoff

- [ ] **Step 1: Full deterministic suite from the worktree**

Run: `bash tests/run-deterministic.sh`
Expected: all green.

- [ ] **Step 2: Manual smoke (real shell, real brew)**

```bash
./brew-change init zsh | zsh -n && echo "init ok"
HOME=$PWD/tests/fixtures/badge/cli-home BREW_CHANGE_BADGE_FORCE=1 BREW_CHANGE_BADGE_NO_SPAWN=1 ./brew-change badge after-update
```
Expected: `init ok` + the badge line from the fixture export.

- [ ] **Step 3: Report**

Summarize: tests added/passed, deviations (no `-q`), files touched. Do NOT push, merge, or bump VERSION — release bumps are separate `chore(release)` commits and push/merge need an explicit ask.
