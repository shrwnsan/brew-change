#!/usr/bin/env python3
"""Bounded PTY tests for prompt input hygiene and inactivity timeout UX.

Covers:
- Stale Enter from the single-char mode prompt must not leak into the next
  line-based prompt (regression: confirmation auto-declined instantly).
- The inactivity timeout announces itself with a visible countdown instead of
  exiting silently.
"""

import errno
import fcntl
import os
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")
TIMEOUT = 10
BASH = shutil.which("bash") or "/bin/bash"


def overlay_lines(data):
    """Compose visible screen lines from a raw PTY byte stream.

    Applies terminal line-editing semantics: '\\r' returns the cursor to
    column 0 (later writes overlay earlier ones, chars beyond the new write
    survive), '\\n' starts a new line. This is what the user actually sees,
    so leftover prompt fragments are detectable even though the raw stream
    contains every redraw.
    """
    lines, cur, pos = [], bytearray(), 0
    for ch in data.decode("utf-8", "replace"):
        if ch == "\n":
            lines.append(bytes(cur))
            cur, pos = bytearray(), 0
        elif ch == "\r":
            pos = 0
        else:
            enc = ch.encode("utf-8")
            if pos < len(cur):
                cur[pos : pos + len(enc)] = enc
            else:
                cur += enc
            pos += len(enc)
    if cur:
        lines.append(bytes(cur))
    return lines


def read_until(fd, marker, timeout=TIMEOUT, sink=None):
    data = b"" if sink is None else sink
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


def run_scenario(body, extra_env=None, write_after_ready=None):
    """Run body in a bash PTY; returns (output, exit_status).

    The master must be drained continuously while waiting for exit, or the
    PTY buffer fills and the child blocks on its own writes.
    """
    master, slave = pty.openpty()
    env = {"BREW_CHANGE_SUBPROCESS": ""}
    if extra_env:
        env.update(extra_env)
    script = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    script.write(
        f'''#!/usr/bin/env bash
set -uo pipefail
export BREW_CHANGE_SUBPROCESS=""
'''
        + "".join(f"export {k}='{v}'\n" for k, v in (extra_env or {}).items())
        + f'''
source "{LIB}/brew-change-config.sh"
source "{LIB}/brew-change-interactive.sh"
echo READY > /dev/tty
kill -STOP "$$"
{body}
'''
    )
    script.close()

    def attach_controlling_terminal():
        os.environ.update(env)
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
    output = b""

    def wait_while_draining(deadline):
        """Poll for exit while keeping the PTY drained; returns status or None."""
        nonlocal output
        while time.monotonic() < deadline:
            try:
                return process.wait(timeout=0.05)
            except subprocess.TimeoutExpired:
                pass
            output += drain(master, seconds=0.05)
        return None

    try:
        output += read_until(master, b"READY")
        if b"READY" not in output:
            raise AssertionError(f"scenario never became ready: {output!r}")
        # Wait until the child has actually self-stopped before resuming it,
        # otherwise SIGCONT can arrive before the kill -STOP and be lost.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            stat = subprocess.run(
                ["ps", "-o", "stat=", "-p", str(process.pid)],
                capture_output=True,
                text=True,
            ).stdout.strip()
            if stat.startswith("T"):
                break
            time.sleep(0.02)
        else:
            raise AssertionError(f"scenario never stopped: {output!r}")
        os.kill(process.pid, signal.SIGCONT)
        for marker, payload, delay in write_after_ready or []:
            output += read_until(master, marker, timeout=5)
            time.sleep(delay)
            os.write(master, payload)
        status = wait_while_draining(time.monotonic() + TIMEOUT)
        if status is None:
            raise AssertionError(f"scenario did not exit: {output!r}")
        # Drain once more after exit: the final output bytes can still be in
        # the PTY buffer when the process is reaped.
        output += drain(master, seconds=0.5)
        return output, status
    finally:
        if process.poll() is None:
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        os.close(slave)
        os.close(master)
        os.unlink(script.name)


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


def test_stale_enter_is_drained():
    """After 'u' + Enter, no pending input may remain for the next prompt."""
    body = (
        'result=""\n'
        "prompt_upgrade_action 3 8 23 result\n"
        'printf \'RESULT=%s\\n\' "$result" > /dev/tty\n'
        'probe=""\n'
        'if IFS= read -r -t 1 probe < /dev/tty; then\n'
        '  printf \'PROBE=received\\n\' > /dev/tty\n'
        "else\n"
        '  printf \'PROBE=clean\\n\' > /dev/tty\n'
        "fi\n"
        'printf \'DONE\\n\' > /dev/tty\n'
    )
    output, status = run_scenario(
        body, write_after_ready=[(b"[q]uit?", b"u\n", 0.5)]
    )
    assert status == 0, (status, output)
    assert b"RESULT=no-signal" in output, output
    assert b"PROBE=clean" in output, (
        b"stale input leaked to the next prompt: " + output
    )


def test_confirmation_not_auto_declined_by_stale_enter():
    """u+Enter must not instantly decline the follow-up y/N confirmation."""
    body = (
        'result=""\n'
        "prompt_upgrade_action 3 8 23 result\n"
        "if prompt_for_confirmation_with_timeout 'Proceed? (y/N): ' 5 "
        "< /dev/tty; then\n"
        '  printf \'CONFIRMED=1\\n\' > /dev/tty\n'
        "else\n"
        '  printf \'CONFIRMED=0\\n\' > /dev/tty\n'
        "fi\n"
    )
    output, status = run_scenario(
        body,
        write_after_ready=[
            (b"[q]uit?", b"u\n", 0.5),
            # y arrives only after the confirmation prompt is visible; a
            # stale Enter would have declined it before y ever arrives.
            (b"Proceed?", b"y\n", 0.5),
        ],
    )
    assert b"CONFIRMED=1" in output, (
        f"confirmation was declined without user input (status={status}): "
    ).encode() + output


def test_inactivity_countdown_announces_timeout():
    """Timeout must show a countdown and state the exit reason, not exit silently."""
    body = (
        'result=""\n'
        "prompt_upgrade_action 3 8 23 result\n"
        'printf \'RESULT=%s\\n\' "$result" > /dev/tty\n'
    )
    output, status = run_scenario(
        body,
        extra_env={"BREW_CHANGE_PROMPT_TIMEOUT": "3"},
    )
    assert b"RESULT=cancel" in output, (status, output)
    assert b"Still there?" in output, output
    assert b"exiting in" in output, output
    assert b"now" in output, output
    assert b"inactivity timeout" in output, output
    # The final "now" redraw must clear the full width of the previously
    # drawn prompt line; no prompt tail may survive on the visible line.
    now_lines = [
        line for line in overlay_lines(output) if b"exiting in... now" in line
    ]
    assert now_lines, output
    for line in now_lines:
        assert b"]uit" not in line, (
            f"countdown 'now' line retains prompt fragments: {line!r}"
        )


def test_int_at_prompt_boundary_exits_130():
    """^C racing the prompt->read transition must still exit 130 quickly.

    Same regression as the dashboard int-boundary probe: bash's read
    builtin can swallow a trapped signal arriving between the read
    starting and its blocking wait, deferring the INT trap until the
    read slice expires. Writing ^C the instant the prompt appears lands
    in that window; with 1s-capped read slices the exit is bounded to
    ~1s instead of freezing for the whole first slice (50s at a 60s
    timeout, 290s at the default).
    """
    body = (
        'result=""\n'
        "prompt_upgrade_action 3 8 23 result\n"
        'printf \'RESULT=%s\\n\' "$result" > /dev/tty\n'
    )
    output, status = run_scenario(
        body,
        extra_env={"BREW_CHANGE_PROMPT_TIMEOUT": "60"},
        write_after_ready=[(b"[q]uit?", b"\x03", 0.0)],
    )
    assert status == 130, (status, output)


def test_reader_slices_are_capped():
    """Every timed read slice prompt_upgrade_action issues must be <= 1s.

    Deterministic contract check: a read() function shadows the builtin
    inside the scenario and logs each call, asserting the slice sizes
    without racing the signal. Uncapped slices deferred a swallowed
    Ctrl-C for total_timeout - countdown_window seconds.
    """
    import re

    tmp = tempfile.mkdtemp()
    try:
        calls = os.path.join(tmp, "read-calls")
        body = (
            "read() { local IFS=' '; printf '%s\\n' \"$*\" >> "
            f'"{calls}"; return 1; }}\n'
            'result=""\n'
            "prompt_upgrade_action 3 8 23 result\n"
            'printf \'RESULT=%s\\n\' "$result" > /dev/tty\n'
            'printf "READCALLS-BEGIN\\n" > /dev/tty\n'
            f'cat "{calls}" > /dev/tty\n'
            'printf "\\nREADCALLS-END\\n" > /dev/tty\n'
        )
        output, status = run_scenario(
            body, extra_env={"BREW_CHANGE_PROMPT_TIMEOUT": "60"}
        )
        assert status == 0, (status, output)
        assert b"RESULT=cancel" in output, output
        assert b"READCALLS-BEGIN" in output, output
        log = output.split(b"READCALLS-BEGIN\r\n", 1)[1].split(b"READCALLS-END", 1)[0]
        timed = [line for line in log.splitlines() if b"-t " in line]
        assert timed, output
        for line in timed:
            m = re.search(rb"-t (\d+)", line)
            assert m, f"unparseable read call: {line!r}"
            assert int(m.group(1)) <= 1, f"uncapped read slice: {line!r}"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    tests = [
        test_stale_enter_is_drained,
        test_confirmation_not_auto_declined_by_stale_enter,
        test_inactivity_countdown_announces_timeout,
        test_int_at_prompt_boundary_exits_130,
        test_reader_slices_are_capped,
    ]
    failures = 0
    for test in tests:
        try:
            test()
            print(f"PASS: {test.__name__}", flush=True)
        except Exception as exc:
            failures += 1
            print(f"FAIL: {test.__name__}: {exc}", flush=True)
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
