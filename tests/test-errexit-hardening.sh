#!/usr/bin/env bash
# Regression harness for errexit hardening (preventive audit).
#
# The launcher runs `set -euo pipefail`. Two shipped silent-exit bugs came from
# a false `[[ ... ]] && cmd` / `(( ... )) && cmd` as a function's LAST
# statement: the function returns 1 as a side effect of normal control flow
# and errexit kills the whole run.
#
# This suite sources every lib module under `set -euo pipefail` and calls the
# audited best-effort ("never fails") functions with representative benign
# inputs, asserting survival. Any nonzero exit from the audited functions is a
# regression of the v1.13.0 bug class.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

pass=0
fail=0

note() { printf 'PASS: %s\n' "$1"; }

# Each case runs in its own subshell with `set -euo pipefail` active, mimics
# the launcher environment, and must reach the trailing `survived` marker.
run_case() {
    local desc="$1"
    local body="$2"
    if bash -c "
        set -euo pipefail
        export BREW_CHANGE_CACHE_DIR=\"\$(mktemp -d)\"
        for m in '$LIB_DIR'/*.sh; do source \"\$m\"; done
        $body
        echo survived
    " 2>/dev/null | grep -qx survived; then
        note "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s (run aborted under set -e)\n' "$desc" >&2
        fail=$((fail + 1))
    fi
}

# --- fixed tails: previously returned 1 on benign control flow -------------

# Text shorter than the last drawn width is the *common* countdown case
# (numbers shrink toward zero); the old `(( len > width )) && width=...` tail
# returned 1 whenever it did not grow.
run_case "countdown note with shrinking text does not trip errexit" '
    dashboard_last_line_width=100
    _dashboard_countdown_note "5  "
    _dashboard_countdown_note "now\n"
'

# Trap flags stay false whenever an EXIT trap was already installed
# (`trap -p EXIT` non-empty), so restore must not return 1.
run_case "prompt trap restore with no installed EXIT trap does not trip errexit" '
    prompt_previous_int_trap=""
    prompt_previous_term_trap=""
    _restore_prompt_traps
'

run_case "progress trap restore with no installed EXIT trap does not trip errexit" '
    progress_previous_int_trap=""
    progress_previous_term_trap=""
    _restore_progress_traps
'

# --- best-effort tails guarded by `|| true`: must stay survivable -----------

run_case "cosmetic /dev/tty writers survive without a tty" '
    _dashboard_say "no tty here"
    _dashboard_note "%s\n" "no tty here"
'

run_case "stale temp cleanup on empty cache dir survives" '
    cleanup_stale_temp_files
'

run_case "outdated json fetch tolerates missing brew" '
    PATH="/nonexistent" _dashboard_fetch_outdated_json >/dev/null
'

# --- predicate tails: nonzero return IS the contract, verify no errexit ----

run_case "predicate functions callable as plain statements (status consumed)" '
    if _assessment_is_dotted_numeric "1.2"; then :; else :; fi
    if is_major_version_transition "3" "4"; then :; else :; fi
    if _changelog_stdout_enabled; then :; else :; fi
    if is_interactive_mode; then :; else :; fi
'

printf '\nerrexit hardening: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
