#!/usr/bin/env bash
# T3.1.1 — first-run guidance for the trusted update workflow.
#
# Deterministic assertions:
#   1. --help documents the check/review/upgrade boundaries and the
#      no-account/no-setup promise, and carries no first-run hint line.
#   2. --version output carries no hint.
#   3. A piped (non-TTY) -u run under the fake brew/curl harness shows the
#      hint on NEITHER stdout NOR stderr, and keeps the plain prompt-flow
#      stdout contract ("Non-interactive mode. Upgrade skipped.", no
#      dashboard prompt).
#   4. A piped package-argument run (-u <pkg>) shows no hint either.
#   5. An interactive (PTY) -u dashboard run shows the one-line hint on
#      STDERR only — stdout stays free of it (byte purity) — and quits
#      cleanly with 'q'.
#   6. An interactive -u --plain run (TTY escape hatch) shows no hint.
#
# No network, no real Homebrew: brew/curl come from the command harness
# (tests/lib/test-utils.sh); the PTY legs follow the drive_cli_until
# conventions from tests/test-dashboard-actions.py (controlling terminal
# via TIOCSCTTY, stderr on a separate pipe, bounded select/read waits,
# kill+wait cleanup in a finally block).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BREW_CHANGE="$PROJECT_DIR/brew-change"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test-utils.sh"

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

assert_contains() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected to contain '$expected')"
        ((fail++))
    fi
}

assert_not_contains() {
    local desc="$1" unexpected="$2" actual="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((pass++))
    else
        echo -e "${RED}FAIL${NC}: $desc (should not contain '$unexpected')"
        ((fail++))
    fi
}

# The distinctive first words of the stderr hint.
HINT="New here?"

# ---------------------------------------------------------------------------
# Helper: run brew-change in harness and capture exit code + stdout + stderr
# ---------------------------------------------------------------------------
run_brew_change_harness() {
    setup_command_harness
    local stderr_file="$COMMAND_HARNESS_ROOT/bc-stderr"
    local stdout_file="$COMMAND_HARNESS_ROOT/bc-stdout"
    local exit_code=0

    "$BREW_CHANGE" "$@" >"$stdout_file" 2>"$stderr_file" || exit_code=$?

    RUN_BC_EXIT="$exit_code"
    RUN_BC_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_BC_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    teardown_command_harness
}

# ---------------------------------------------------------------------------
# Suite 1: --help documents the three boundaries
# ---------------------------------------------------------------------------
echo "======================================"
echo "First-Run Guidance Tests (T3.1.1)"
echo "======================================"
echo ""

echo "=== Suite 1: --help boundary explainer ==="
echo ""

echo "Test 1: --help documents the trusted update workflow boundaries"
run_brew_change_harness --help
assert_eq "--help exit code" "0" "$RUN_BC_EXIT"
assert_contains "--help names the workflow" "Trusted update workflow" "$RUN_BC_STDOUT"
assert_contains "--help check boundary" "Check" "$RUN_BC_STDOUT"
assert_contains "--help review boundary" "Review" "$RUN_BC_STDOUT"
assert_contains "--help upgrade boundary" "Upgrade" "$RUN_BC_STDOUT"
assert_contains "--help confirm-before-upgrade wording" "confirm the exact plan" "$RUN_BC_STDOUT"
assert_contains "--help no account or setup" "no account or setup" "$RUN_BC_STDOUT"
assert_not_contains "--help carries no hint line" "$HINT" "$RUN_BC_STDOUT"

echo ""
echo "Test 2: --version carries no hint"
run_brew_change_harness --version
assert_eq "--version exit code" "0" "$RUN_BC_EXIT"
assert_contains "--version shows version" "brew-change version" "$RUN_BC_STDOUT"
assert_not_contains "--version stdout carries no hint" "$HINT" "$RUN_BC_STDOUT"
assert_not_contains "--version stderr carries no hint" "$HINT" "$RUN_BC_STDERR"

# ---------------------------------------------------------------------------
# Suite 2: piped (non-TTY) runs never show the hint (stdout purity + no
# stderr noise; normal output is not blocked in noninteractive mode).
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: piped -u runs are unchanged ==="
echo ""

echo "Test 3: piped -u shows the hint on neither stream, stdout contract kept"
setup_command_harness
configure_fake_command brew "$FIXTURE_DIR/outdated-mixed.json" "" 0
configure_fake_command curl "" "" 0
export BREW_CHANGE_TEST_NOW=1800000000
stderr_file="$COMMAND_HARNESS_ROOT/bc-stderr"
stdout_file="$COMMAND_HARNESS_ROOT/bc-stdout"
exit_code=0
"$BREW_CHANGE" -u >"$stdout_file" 2>"$stderr_file" || exit_code=$?
piped_stdout="$(cat "$stdout_file" 2>/dev/null || true)"
piped_stderr="$(cat "$stderr_file" 2>/dev/null || true)"
piped_log="$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)"
unset BREW_CHANGE_TEST_NOW
teardown_command_harness

assert_eq "piped -u exit code" "0" "$exit_code"
assert_contains "piped -u reached Homebrew inventory" $'brew\toutdated\t--json=v2' "$piped_log"
assert_contains "piped -u stdout contract unchanged" "Non-interactive mode. Upgrade skipped." "$piped_stdout"
assert_not_contains "piped -u no dashboard prompt" "[s] Select packages" "$piped_stdout"
assert_not_contains "piped -u hint not on stdout" "$HINT" "$piped_stdout"
assert_not_contains "piped -u hint not on stderr" "$HINT" "$piped_stderr"

echo ""
echo "Test 4: piped package-argument run (-u <pkg>) shows no hint"
setup_command_harness
configure_fake_command brew "$FIXTURE_DIR/outdated-mixed.json" "" 0
configure_fake_command curl "" "" 0
stderr_file="$COMMAND_HARNESS_ROOT/bc-stderr"
stdout_file="$COMMAND_HARNESS_ROOT/bc-stdout"
exit_code=0
"$BREW_CHANGE" -u no-such-package >"$stdout_file" 2>"$stderr_file" || exit_code=$?
pkg_stdout="$(cat "$stdout_file" 2>/dev/null || true)"
pkg_stderr="$(cat "$stderr_file" 2>/dev/null || true)"
teardown_command_harness

assert_contains "package run takes the detail path" "no-such-package" "$pkg_stdout$pkg_stderr"
assert_not_contains "package run hint not on stdout" "$HINT" "$pkg_stdout"
assert_not_contains "package run hint not on stderr" "$HINT" "$pkg_stderr"

# ---------------------------------------------------------------------------
# Suite 3: interactive (PTY) runs — the TTY gate is genuinely asserted by
# driving the real CLI under a controlling terminal (pattern lifted from
# tests/test-dashboard-actions.py drive_cli_until) with the fake-brew/curl
# environment. stderr is a separate pipe so the hint's stream is provable.
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: interactive PTY runs ==="
echo ""

# pty_drive <mode> <cli-args...>
#   mode "dashboard": wait for the dashboard prompt marker
#   mode "plain":     wait for the plain prompt-flow marker
# Sets PTY_DRIVER_RC, PTY_OUTPUT (EXIT= / MARKER_SEEN= / HINT_STDERR= /
# HINT_STDOUT= facts), PTY_DRIVER_ERR.
pty_drive() {
    local mode="$1"; shift
    local err_file rc=0
    err_file="$(mktemp)"
    PTY_OUTPUT="$(python3 - "$BREW_CHANGE" "$mode" "$@" 2>"$err_file" <<'PYEOF'
import errno
import fcntl
import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time

TIMEOUT = 15
BASH = shutil.which("bash") or "/bin/bash"
HINT = b"New here?"
MARKERS = {
    "dashboard": b"[s] Select packages",
    "plain": b"Select upgrade mode:",
}


def read_until(fd, marker, timeout=TIMEOUT):
    data = b""
    deadline = time.monotonic() + timeout
    while marker not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        data += chunk
    return data


def drain(fd, seconds=0.5):
    data = b""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    return data


def main():
    cli = os.path.abspath(sys.argv[1])
    mode = sys.argv[2]
    args = sys.argv[3:]
    marker = MARKERS[mode]
    tmp = tempfile.mkdtemp()
    try:
        outdated = {"formulae": [{"name": "bat"}], "casks": []}
        bindir = os.path.join(tmp, "bin")
        os.makedirs(bindir)
        log = os.path.join(tmp, "brew.log")
        outdated_file = os.path.join(tmp, "outdated.json")
        with open(outdated_file, "w") as fh:
            json.dump(outdated, fh)
        brew = os.path.join(bindir, "brew")
        with open(brew, "w") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                'echo "brew $*" >> "$FAKE_BREW_LOG"\n'
                'case "$1" in\n'
                '  outdated) cat "$FAKE_BREW_OUTDATED";;\n'
                "esac\n"
                "exit 0\n"
            )
        os.chmod(brew, 0o755)
        curl = os.path.join(bindir, "curl")
        with open(curl, "w") as fh:
            fh.write("#!/usr/bin/env bash\nexit 0\n")
        os.chmod(curl, 0o755)

        master, slave = pty.openpty()
        stderr_r, stderr_w = os.pipe()
        env = {
            "PATH": bindir + os.pathsep + os.environ.get("PATH", ""),
            "HOME": tmp,
            "BREW_CHANGE_PROMPT_TIMEOUT": "60",
            "BREW_CHANGE_TEST_NOW": str(int(time.time())),
            # One fetch attempt (no retry backoff) and an isolated cache
            # keep the full-CLI scenario fast and hermetic.
            "BREW_CHANGE_MAX_RETRIES": "1",
            "BREW_CHANGE_CACHE_DIR": os.path.join(tmp, "cache"),
            "FAKE_BREW_LOG": log,
            "FAKE_BREW_OUTDATED": outdated_file,
        }

        def attach_controlling_terminal():
            os.environ.clear()
            os.environ.update(env)
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [BASH, cli] + args,
            stdin=slave,
            stdout=slave,
            stderr=stderr_w,
            pass_fds=(slave, stderr_w),
            preexec_fn=attach_controlling_terminal,
        )
        os.close(stderr_w)
        stdout = b""
        status = None
        try:
            stdout += read_until(master, marker)
            assert marker in stdout, f"marker never appeared: {stdout!r}"
            time.sleep(0.3)
            os.write(master, b"q\n")
            deadline = time.monotonic() + TIMEOUT
            while time.monotonic() < deadline:
                try:
                    status = process.wait(timeout=0.05)
                    break
                except subprocess.TimeoutExpired:
                    pass
                stdout += drain(master, seconds=0.05)
            if status is None:
                raise AssertionError(f"CLI did not exit after input: {stdout!r}")
            stdout += drain(master, seconds=0.5)
        finally:
            if process.poll() is None:
                process.kill()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            os.close(slave)
            os.close(master)
        stderr = b""
        while True:
            chunk = os.read(stderr_r, 4096)
            if not chunk:
                break
            stderr += chunk
        os.close(stderr_r)
        print(f"EXIT={status}")
        print(f"MARKER_SEEN={'yes' if marker in stdout else 'no'}")
        print(f"HINT_STDERR={'yes' if HINT in stderr else 'no'}")
        print(f"HINT_STDOUT={'yes' if HINT in stdout else 'no'}")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
PYEOF
    )" || rc=$?
    PTY_DRIVER_RC="$rc"
    PTY_DRIVER_ERR="$(cat "$err_file" 2>/dev/null || true)"
    rm -f "$err_file"
}

pty_fact() { sed -n "s/^$1=//p" <<< "$PTY_OUTPUT"; }

echo "Test 5: interactive -u (PTY) shows the hint on stderr only, quits with q"
pty_drive dashboard -u
if [[ "$PTY_DRIVER_RC" != "0" ]]; then
    echo -e "${RED}FAIL${NC}: PTY -u driver error: $PTY_DRIVER_ERR"
    ((fail++))
else
    assert_eq "PTY -u exit code" "0" "$(pty_fact EXIT)"
    assert_eq "PTY -u dashboard rendered" "yes" "$(pty_fact MARKER_SEEN)"
    assert_eq "PTY -u hint on stderr" "yes" "$(pty_fact HINT_STDERR)"
    assert_eq "PTY -u hint not on stdout" "no" "$(pty_fact HINT_STDOUT)"
fi

echo ""
echo "Test 6: interactive -u --plain (PTY) shows no hint"
pty_drive plain -u --plain
if [[ "$PTY_DRIVER_RC" != "0" ]]; then
    echo -e "${RED}FAIL${NC}: PTY --plain driver error: $PTY_DRIVER_ERR"
    ((fail++))
else
    assert_eq "PTY --plain exit code" "0" "$(pty_fact EXIT)"
    assert_eq "PTY --plain prompt flow rendered" "yes" "$(pty_fact MARKER_SEEN)"
    assert_eq "PTY --plain hint not on stderr" "no" "$(pty_fact HINT_STDERR)"
    assert_eq "PTY --plain hint not on stdout" "no" "$(pty_fact HINT_STDOUT)"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
echo ""
echo "======================================"
echo "Test Results Summary"
echo "======================================"
echo "Total tests:  $((pass + fail))"
echo "Passed:       $pass"
echo "Failed:       $fail"
echo ""

if [[ $fail -gt 0 ]]; then
    exit 1
fi
