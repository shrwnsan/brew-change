#!/usr/bin/env python3
"""Bounded PTY tests for prompt terminal restoration and signal handling."""

import errno
import fcntl
import os
import pty
import select
import signal
import shutil
import subprocess
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")
TIMEOUT = 8
BASH = shutil.which("bash") or "/bin/bash"


def stty_state(fd):
    result = subprocess.run(
        ["stty", "-g"], stdin=fd, capture_output=True, text=True, timeout=2
    )
    if result.returncode:
        raise AssertionError(result.stderr.strip())
    return result.stdout.strip()


def stable_stty_state(state):
    """Ignore macOS PTY's transient PENDIN bit; compare every stable field."""
    fields = state.split(":")
    for index, field in enumerate(fields):
        if field.startswith("lflag="):
            value = int(field.split("=", 1)[1], 16) & ~0x20000000
            fields[index] = "lflag=%x" % value
    return ":".join(fields)


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


def scenario(action, expected_status, expected_result=None):
    master, slave = pty.openpty()
    script = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    invocation = "prompt_upgrade_action 0 2 2"
    if expected_result is not None:
        invocation = (
            'result=""\nprompt_upgrade_action 0 2 2 result\n'
            'printf \'RESULT=%s\\n\' "$result" > /dev/tty'
        )
    script.write(
        f'''#!/usr/bin/env bash
set -uo pipefail
export BREW_CHANGE_SUBPROCESS=""
source "{LIB}/brew-change-config.sh"
source "{LIB}/brew-change-interactive.sh"
echo READY > /dev/tty
kill -STOP "$$"
{invocation}
'''
    )
    script.close()

    def attach_controlling_terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [BASH, script.name],
        stdin=subprocess.PIPE if action == "eof" else slave,
        stdout=slave,
        stderr=slave,
        pass_fds=(slave,),
        preexec_fn=attach_controlling_terminal,
    )
    try:
        output = read_until(master, b"READY")
        if b"READY" not in output:
            raise AssertionError(f"prompt never became ready: {output!r}")
        initial = stty_state(master)
        os.kill(process.pid, signal.SIGCONT)
        output += read_until(master, b"[q]uit?", timeout=2)
        time.sleep(0.1)

        if action == "eof":
            process.stdin.close()
        elif isinstance(action, int):
            os.kill(process.pid, action)
        else:
            os.write(master, action)

        if expected_result is not None:
            output += read_until(master, b"RESULT=", timeout=2)
        else:
            time.sleep(0.3)
        try:
            status = process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
            raise AssertionError("prompt process did not exit within timeout")
        final = stty_state(master)

        assert status == expected_status, (status, output.decode(errors="replace"))
        assert stable_stty_state(final) == stable_stty_state(initial), (
            f"terminal changed: {initial!r} -> {final!r}; output={output!r}"
        )
        if expected_result is not None:
            assert f"RESULT={expected_result}".encode() in output, output
    finally:
        if process.stdin and not process.stdin.closed:
            process.stdin.close()
        os.close(slave)
        if master >= 0:
            os.close(master)
        os.unlink(script.name)


def prompt_signal_handler_scenario(signal_name, expected_status):
    """Prompt signal cleanup restores terminal state and chains the handler."""
    master, slave = pty.openpty()
    script = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    script.write(
        f'''#!/usr/bin/env bash
set -uo pipefail
export BREW_CHANGE_SUBPROCESS=""
source "{LIB}/brew-change-config.sh"
source "{LIB}/brew-change-interactive.sh"
echo READY > /dev/tty
kill -STOP "$$"
prompt_stty_state="$(stty -g < /dev/tty)"
register_terminal_state "$prompt_stty_state"
stty -echo < /dev/tty
sleep 300 &
spinner_pid=$!
register_pid "$spinner_pid"
previous_trap="$(trap -p {signal_name})"
_handle_prompt_signal {expected_status} "$previous_trap"
'''
    )
    script.close()

    def attach_controlling_terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [BASH, script.name],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        pass_fds=(slave,),
        preexec_fn=attach_controlling_terminal,
    )
    try:
        output = read_until(master, b"READY")
        if b"READY" not in output:
            raise AssertionError(f"handler never became ready: {output!r}")
        initial = stty_state(master)
        os.kill(process.pid, signal.SIGCONT)
        status = process.wait(timeout=TIMEOUT)
        final = stty_state(master)

        assert status == expected_status, status
        assert stable_stty_state(final) == stable_stty_state(initial), (
            f"terminal changed: {initial!r} -> {final!r}"
        )
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        os.close(slave)
        os.close(master)
        os.unlink(script.name)


def main():
    cases = [
        (b"u", 0, "no-signal", "success"),
        (b"\n", 0, "no-signal", "Enter default"),
        (b"q", 0, "cancel", "quit"),
        ("eof", 0, "cancel", "EOF"),
    ]
    failures = 0
    for action, status, result, name in cases:
        try:
            scenario(action, status, result)
            print(f"PASS: {name} restores terminal state", flush=True)
        except Exception as exc:
            failures += 1
            print(f"FAIL: {name}: {exc}", flush=True)

    for signal_name, status in (("INT", 130), ("TERM", 143)):
        try:
            prompt_signal_handler_scenario(signal_name, status)
            print(
                f"PASS: {signal_name} prompt handler restores terminal state",
                flush=True,
            )
        except Exception as exc:
            failures += 1
            print(f"FAIL: {signal_name} prompt handler: {exc}", flush=True)
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
