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

# Binary pin: the emitted code must reference the emitting binary by absolute
# path — a PATH lookup can resolve an older brew-change that predates the
# subcommands and misfires (v1.20.x treated unknown words as package names).
WANT_BIN="$(cd "$REPO_ROOT" && pwd)/brew-change"
assert_contains "wrapper: pins the emitting binary" "$(cat "$FIXTURES/init-bash.sh")" "__bc_bin=$WANT_BIN"
assert_contains "wrapper: badge calls go through the pin" "$(cat "$FIXTURES/init-bash.sh")" 'command "$__bc_bin" badge'

# --- argument validation -------------------------------------------------------
out="$(bash "$BREW_CHANGE" init 2>&1 >/dev/null)"
rc=$?
if [[ $rc -eq 0 ]]; then no "init: missing shell errors" "exited 0"; else ok "init: missing shell errors"; fi
assert_contains "init: missing shell message" "$out" "init requires a shell"

out="$(bash "$BREW_CHANGE" init fish 2>&1 >/dev/null)"
rc=$?
if [[ $rc -eq 0 ]]; then no "init: unsupported shell errors" "exited 0"; else ok "init: unsupported shell errors"; fi
assert_contains "init: unsupported shell message" "$out" "unsupported shell"

out="$(bash "$BREW_CHANGE" init zsh node 2>&1 >/dev/null)"
rc=$?
if [[ $rc -eq 0 ]]; then no "init: extra args error" "exited 0"; else ok "init: extra args error"; fi

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
export PATH="$BIN:$PATH"
export BC_LOG="$FIXTURES/wrapper.log"
: > "$BC_LOG"

TEST_SCRIPT="$FIXTURES/wrapper-test.sh"
{
    cat "$FIXTURES/init-bash.sh"
    # Repoint the pin at the stub so the harness observes badge calls.
    printf '__bc_bin="%s"\n' "$BIN/brew-change"
    echo 'brew update'
    echo 'printf "ec=%s\n" "$?"'
    echo 'printf "after\n"'
} > "$TEST_SCRIPT"

# set -e variant: a propagated brew failure must abort the caller (the wrapper
# returns the real status; it must not swallow it).
TEST_SCRIPT_SE="$FIXTURES/wrapper-test-se.sh"
{
    echo 'set -e'
    cat "$FIXTURES/init-bash.sh"
    printf '__bc_bin="%s"\n' "$BIN/brew-change"
    echo 'brew update'
    echo 'printf "reached-after-set-e\n"'
} > "$TEST_SCRIPT_SE"

# Run under a pty so the wrapper's >/dev/tty redirect succeeds. script(1)
# syntax differs: BSD (macOS) takes the command positionally, util-linux
# (most Linux) needs -c. Skip invocation assertions where script is absent.
WRAPPER_OUT=""
WRAPPER_SE_OUT=""
if command -v script >/dev/null 2>&1; then
    case "$(uname -s)" in
        Darwin)
            WRAPPER_OUT="$(script -q /dev/null bash "$TEST_SCRIPT" 2>/dev/null | tr -d '\r')"
            WRAPPER_SE_OUT="$(script -q /dev/null bash "$TEST_SCRIPT_SE" 2>/dev/null | tr -d '\r')"
            ;;
        *)
            WRAPPER_OUT="$(script -q -c "bash '$TEST_SCRIPT'" /dev/null 2>/dev/null | tr -d '\r')"
            WRAPPER_SE_OUT="$(script -q -c "bash '$TEST_SCRIPT_SE'" /dev/null 2>/dev/null | tr -d '\r')"
            ;;
    esac
else
    WRAPPER_OUT="$(bash "$TEST_SCRIPT" 2>/dev/null)"
    WRAPPER_SE_OUT="$(bash "$TEST_SCRIPT_SE" 2>/dev/null)"
fi

assert_contains "wrapper: failing brew exit code passes through" "$WRAPPER_OUT" "ec=7"
assert_contains "wrapper: execution continues after captured failure" "$WRAPPER_OUT" "after"
if [[ "$WRAPPER_SE_OUT" != *"reached-after-set-e"* ]]; then
    ok "wrapper: set -e aborts on propagated brew failure"
else
    no "wrapper: set -e aborts on propagated brew failure" "script continued past failing brew"
fi
assert_contains "wrapper: brew itself was called" "$(cat "$BC_LOG")" "BREW update"

if command -v script >/dev/null 2>&1 && [[ -e /dev/tty ]]; then
    assert_contains "wrapper: badge invoked after update" "$(cat "$BC_LOG")" "BADGE badge after-update"
else
    ok "wrapper: badge invocation skipped (no pty available)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
