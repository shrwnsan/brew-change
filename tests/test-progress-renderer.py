#!/usr/bin/env python3
"""Bounded PTY tests for the T2.4.2 progress renderer.

Covers:
- Animation appears on a TTY and the final frame is cleared before return.
- No animation when stdout is not a TTY or BREW_CHANGE_PARALLEL_MODE=true.
- stty state is restored across normal exit, INT, and TERM.
- Redraw rate is bounded (~150ms) under rapid event streams.
"""

import errno
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib")
TIMEOUT = 15
BASH = shutil.which("bash") or "/bin/bash"

FRAMES_RE = re.compile(rb"\d+/\d+")


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


def drain(fd, seconds=0.05):
    data = b""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], seconds)
        if not ready:
            break
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


def read_until(fd, marker, timeout=TIMEOUT, sink=b""):
    data = sink
    deadline = time.monotonic() + timeout
    while marker not in data and time.monotonic() < deadline:
        data += drain(fd, 0.05)
    return data


def run_scenario(body, extra_env=None, signal_after=None, stdout_pipe=False):
    """Run body in a bash PTY; returns (output, exit_status).

    The master is drained continuously while waiting for exit, or the PTY
    buffer fills and the child blocks on its own writes. The child self-stops
    (SIGSTOP) after READY and is only resumed once the stop state is observed
    via ps, so a SIGCONT cannot be lost.
    """
    master, slave = pty.openpty()
    env = {"BREW_CHANGE_SUBPROCESS": ""}
    env.update(extra_env or {})
    script = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    script.write(
        f'''#!/usr/bin/env bash
set -uo pipefail
'''
        + "".join(f"export {k}='{v}'\n" for k, v in env.items())
        + f'''
source "{LIB}/brew-change-config.sh"
source "{LIB}/brew-change-progress.sh"
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
        stdout=subprocess.PIPE if stdout_pipe else slave,
        stderr=slave,
        pass_fds=(slave,),
        preexec_fn=attach_controlling_terminal,
    )
    output = b""
    piped_stdout = b""
    try:
        output += read_until(master, b"READY")
        if b"READY" not in output:
            raise AssertionError(f"scenario never became ready: {output!r}")
        initial = stty_state(master)
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

        if signal_after is not None:
            sig, delay = signal_after
            output += read_until(master, b"/", timeout=3)
            time.sleep(delay)
            os.kill(process.pid, sig)

        status = None
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            try:
                status = process.wait(timeout=0.05)
                break
            except subprocess.TimeoutExpired:
                pass
            output += drain(master, 0.05)
            if stdout_pipe:
                piped_stdout += drain(process.stdout.fileno(), 0.01)
        if status is None:
            process.kill()
            process.wait(timeout=2)
            raise AssertionError(f"scenario did not exit: {output!r}")
        # Drain once more after exit: the final output bytes can still be
        # in the PTY buffer when the process is reaped.
        output += drain(master, 0.3)
        final = stty_state(master)
        return output, piped_stdout, status, initial, final
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        os.close(slave)
        os.close(master)
        os.unlink(script.name)


def temp_run_dir():
    import tempfile as _tf

    run_dir = _tf.mkdtemp(prefix="bc-progress-pty.")
    return run_dir


def writer_snippet(run_dir, count, total, delay, stage="evidence"):
    lines = []
    for i in range(1, count + 1):
        pkg = f"pkg{i}"
        lines.append(
            f'echo \'{{"stage":"{stage}","completed":{i},"total":{total},"package":"{pkg}"}}\''
            f' >> "{run_dir}/progress.jsonl"; sleep {delay}'
        )
    # Pre-create the file so the renderer does not exit before the first
    # event lands (missing file is a documented no-op return).
    # Ensure the renderer can observe completion when count < total.
    return (
        f': > "{run_dir}/progress.jsonl"\n'
        + "(\n" + "\n".join(lines) + "\n) &\nwriter_pid=$!\n"
    )


def test_animation_and_final_clear():
    run_dir = temp_run_dir()
    body = (
        writer_snippet(run_dir, 20, 20, 0.1)
        + f'render_progress "{run_dir}"\n'
        + "wait \"$writer_pid\"\n"
        + 'printf \'DONE\\n\' > /dev/tty\n'
        + "printf 'AFTER\\n' > /dev/tty\n"
    )
    output, _, status, initial, final = run_scenario(body)
    shutil.rmtree(run_dir, ignore_errors=True)
    frames = FRAMES_RE.findall(output)
    assert status == 0, (status, output)
    assert frames, f"no animation frames on tty: {output!r}"
    assert b"evidence" in output, output
    # Final frame cleared: the clear sequence precedes DONE at column start.
    assert b"20/20" in output, output
    assert re.search(rb"\r +\rDONE", output), (
        f"final frame not cleared before returning: {output[-300:]!r}"
    )
    assert stable_stty_state(final) == stable_stty_state(initial), (
        f"terminal changed: {initial!r} -> {final!r}"
    )


def test_no_animation_when_piped():
    run_dir = temp_run_dir()
    body = (
        writer_snippet(run_dir, 5, 5, 0.05)
        + f'render_progress "{run_dir}"\n'
        + "wait \"$writer_pid\"\n"
        + 'printf \'DONE\\n\' > /dev/tty\n'
    )
    output, piped, status, initial, final = run_scenario(body, stdout_pipe=True)
    shutil.rmtree(run_dir, ignore_errors=True)
    assert status == 0, (status, output)
    assert b"DONE" in output, output
    # No frames on the tty and nothing on piped stdout.
    assert not FRAMES_RE.search(output), output
    assert b"\r" not in piped and piped == b"", piped
    assert stable_stty_state(final) == stable_stty_state(initial)


def test_no_animation_in_parallel_mode():
    run_dir = temp_run_dir()
    body = (
        writer_snippet(run_dir, 5, 5, 0.05)
        + f'render_progress "{run_dir}"\n'
        + "wait \"$writer_pid\"\n"
        + 'printf \'DONE\\n\' > /dev/tty\n'
    )
    output, _, status, _, _ = run_scenario(
        body, extra_env={"BREW_CHANGE_PARALLEL_MODE": "true"}
    )
    shutil.rmtree(run_dir, ignore_errors=True)
    assert status == 0, (status, output)
    assert b"DONE" in output, output
    assert not FRAMES_RE.search(output), output


def test_stty_restored_on_int():
    run_dir = temp_run_dir()
    # total=100 with only 10 events keeps the renderer alive for the signal.
    body = writer_snippet(run_dir, 10, 100, 0.3) + f'render_progress "{run_dir}"\n'
    output, _, status, initial, final = run_scenario(
        body, signal_after=(signal.SIGINT, 0.2)
    )
    shutil.rmtree(run_dir, ignore_errors=True)
    assert status == 130, (status, output)
    assert frames_present(output), output
    assert stable_stty_state(final) == stable_stty_state(initial), (
        f"terminal changed after INT: {initial!r} -> {final!r}"
    )


def test_stty_restored_on_term():
    run_dir = temp_run_dir()
    body = writer_snippet(run_dir, 10, 100, 0.3) + f'render_progress "{run_dir}"\n'
    output, _, status, initial, final = run_scenario(
        body, signal_after=(signal.SIGTERM, 0.2)
    )
    shutil.rmtree(run_dir, ignore_errors=True)
    assert status == 143, (status, output)
    assert frames_present(output), output
    assert stable_stty_state(final) == stable_stty_state(initial), (
        f"terminal changed after TERM: {initial!r} -> {final!r}"
    )


def frames_present(output):
    return bool(FRAMES_RE.search(output))


def test_redraw_bounded():
    run_dir = temp_run_dir()
    # 200 events at 10ms cadence (~2-3.5s wall clock depending on the
    # scheduler). Without renderer-owned rate limiting every event would
    # produce a frame (~200); at one frame per >=150ms the observed count
    # must stay far below the event count.
    body = (
        writer_snippet(run_dir, 200, 200, 0.01)
        + f'render_progress "{run_dir}"\n'
        + "wait \"$writer_pid\"\n"
        + 'printf \'DONE\\n\' > /dev/tty\n'
    )
    started = time.monotonic()
    output, _, status, _, _ = run_scenario(body)
    duration_s = time.monotonic() - started
    shutil.rmtree(run_dir, ignore_errors=True)
    frames = FRAMES_RE.findall(output)
    assert status == 0, (status, output)
    assert len(frames) > 1, f"animation never redrew: {output!r}"
    # Cap derived from measured wall clock: at the 150ms floor the frame
    # count is bounded by duration, not by the event count (~200). A small
    # allowance covers scheduler jitter on loaded CI runners.
    cap = int(duration_s * 1000 / 150) + 10
    assert len(frames) <= cap, (
        f"redraw not bounded: {len(frames)} frames over {duration_s:.1f}s "
        f"(cap {cap} at a 150ms floor; unbounded would be ~200): "
        f"{frames!r}"
    )


def test_static_progress_mode():
    """T3.3.1: BREW_CHANGE_STATIC_PROGRESS=1 replaces animation on a TTY.

    The static line is a plain "stage n/N" (no braille spinner glyph), each
    drawn frame corresponds to a count change (never a timer tick), the final
    frame is fully cleared, and terminal state is restored.
    """
    run_dir = temp_run_dir()
    body = (
        writer_snippet(run_dir, 12, 12, 0.08)
        + f'render_progress "{run_dir}"\n'
        + "wait \"$writer_pid\"\n"
        + 'printf \'DONE\\n\' > /dev/tty\n'
    )
    output, _, status, initial, final = run_scenario(
        body, extra_env={"BREW_CHANGE_STATIC_PROGRESS": "1"}
    )
    shutil.rmtree(run_dir, ignore_errors=True)
    frames = FRAMES_RE.findall(output)
    assert status == 0, (status, output)
    assert frames, f"no static progress frames on tty: {output!r}"
    assert b"evidence" in output, output
    # Plain static line: no braille spinner glyph anywhere.
    for glyph in "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏":
        assert glyph.encode() not in output, output
    # Static frames are drawn only when the count changes: at most one frame
    # per event (12), never per 150ms timer tick for the whole run duration.
    assert len(frames) <= 12 + 2, (
        f"static mode redrew {len(frames)} frames for 12 events "
        f"(must change only when the count changes): {frames!r}"
    )
    # Final frame cleared before the following output, like the animated mode.
    assert re.search(rb"\r +\rDONE", output), (
        f"final static frame not cleared before returning: {output[-300:]!r}"
    )
    assert stable_stty_state(final) == stable_stty_state(initial), (
        f"terminal changed: {initial!r} -> {final!r}"
    )


def main():
    tests = [
        test_animation_and_final_clear,
        test_no_animation_when_piped,
        test_no_animation_in_parallel_mode,
        test_stty_restored_on_int,
        test_stty_restored_on_term,
        test_redraw_bounded,
        test_static_progress_mode,
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
