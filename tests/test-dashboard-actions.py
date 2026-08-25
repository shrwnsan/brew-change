#!/usr/bin/env python3
"""Bounded PTY tests for the dashboard action loop's real terminal readers.

Covers (per T2.5.2):
- `u` path reaches the Phase-1 exact-plan boundary: fake brew log shows the
  named `brew upgrade --dry-run` call; declining returns to the dashboard.
- A stale Enter after `r` is drained and cannot corrupt the review view.
- Inactivity timeout announces a countdown and exits 0.
- EOF (^D) exits 0.
- INT exits 130 with the terminal restored.
"""

import errno
import fcntl
import json
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
TIMEOUT = 15
BASH = shutil.which("bash") or "/bin/bash"

RECORDS = [
    {
        "package": "node",
        "display_name": "node",
        "kind": "formula",
        "installed_version": "22.6.0",
        "available_version": "25.0.0",
        "evidence_source": "github",
        "evidence_url": "https://example.com/node/releases",
        "retrieved_at": int(time.time()) - 600,
        "retrieval_status": "fresh",
        "evidence_snapshot": "excerpt: Major version transition (22 to 25)",
        "classification": "attention",
        "reasons": ["Major version transition (22 to 25)"],
        "matched_signals": ["major-version-transition"],
    },
    {
        "package": "bat",
        "display_name": "bat",
        "kind": "formula",
        "installed_version": "0.24.0",
        "available_version": "0.25.0",
        "evidence_source": "github",
        "evidence_url": "https://example.com/bat/releases",
        "retrieved_at": int(time.time()) - 600,
        "retrieval_status": "fresh",
        "evidence_snapshot": "excerpt: Release notes checked",
        "classification": "no-signal",
        "reasons": ["Release notes checked"],
        "matched_signals": [],
    },
    {
        "package": "docker",
        "display_name": "docker",
        "kind": "cask",
        "installed_version": "4.34.0",
        "available_version": "4.35.0",
        "evidence_source": "",
        "evidence_url": None,
        "retrieved_at": None,
        "retrieval_status": "unavailable",
        "evidence_snapshot": None,
        "classification": "unknown",
        "reasons": ["Release notes unavailable"],
        "matched_signals": [],
    },
]


def make_fake_brew(tmp, outdated):
    """Fake brew executable; logs every invocation, serves outdated JSON."""
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir)
    log = os.path.join(tmp, "brew.log")
    outdated_file = os.path.join(tmp, "outdated.json")
    with open(outdated_file, "w") as fh:
        json.dump(outdated, fh)
    path = os.path.join(bindir, "brew")
    with open(path, "w") as fh:
        fh.write(
            "#!/usr/bin/env bash\n"
            'echo "brew $*" >> "$FAKE_BREW_LOG"\n'
            'case "$1" in\n'
            '  outdated) cat "$FAKE_BREW_OUTDATED";;\n'
            "esac\n"
            "exit 0\n"
        )
    os.chmod(path, 0o755)
    return bindir, log, outdated_file


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


def run_scenario(body, extra_env=None, write_after_ready=None):
    """Run body in a bash PTY; returns (output, exit_status)."""
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
source "{LIB}/brew-change-utils.sh"
source "{LIB}/brew-change-interactive.sh"
source "{LIB}/brew-change-upgrade.sh"
source "{LIB}/brew-change-dashboard-ui.sh"
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
            output += read_until(master, marker, timeout=8)
            time.sleep(delay)
            os.write(master, payload)
        status = wait_while_draining(time.monotonic() + TIMEOUT)
        if status is None:
            raise AssertionError(f"scenario did not exit: {output!r}")
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


def write_records(tmp):
    records = os.path.join(tmp, "records.jsonl")
    with open(records, "w") as fh:
        for record in RECORDS:
            fh.write(json.dumps(record) + "\n")
    return records


def refresh_none():
    return (
        'test_refresh() { echo "REFRESH-CALLED" > /dev/tty; echo none; }\n'
    )


def test_u_reaches_preview_and_decline_returns():
    """u -> named dry-run preview -> decline -> back to dashboard -> q exits 0."""
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        outdated = {
            "formulae": [{"name": "node"}, {"name": "bat"}],
            "casks": [{"token": "docker"}],
        }
        bindir, log, outdated_file = make_fake_brew(tmp, outdated)
        body = (
            f'export PATH="{bindir}:$PATH"\n'
            f'export FAKE_BREW_LOG="{log}"\n'
            f'export FAKE_BREW_OUTDATED="{outdated_file}"\n'
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            'export DRY_RUN_MODE=""\n'
            + refresh_none()
            + f'run_dashboard_mode "{records}" test_refresh\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[
                (b"[q] Quit (Enter = u):", b"u\n", 0.3),
                (b"dry-run", b"n\n", 0.3),
                (b"[q] Quit (Enter = u):", b"q\n", 0.3),
            ],
        )
        assert status == 0, (status, output)
        # The exact-plan boundary ran a NAMED dry-run over the no-signal set.
        assert b"Preview: brew upgrade --dry-run bat" in output, output
        with open(log) as fh:
            calls = fh.read()
        assert "upgrade --dry-run bat" in calls, calls
        # Decline: no mutation, refresh not called, dashboard re-rendered.
        # T3.4.1 O2: the declined confirmation prints "Upgrade cancelled."
        # exactly once (prompt-side only; the caller echo was removed).
        assert output.count(b"Upgrade cancelled.") == 1, output
        assert "upgrade --yes" not in calls, calls
        assert b"REFRESH-CALLED" not in output, output


def test_stale_enter_after_r_does_not_corrupt_review():
    """The Enter that submits 'r' is drained before the review line read."""
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        body = (
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            + refresh_none()
            + f'run_dashboard_mode "{records}" test_refresh\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[
                (b"[q] Quit (Enter = u):", b"r\n", 0.3),
                (b"Review packages (3):", b"bat\n", 0.3),
                (b"Evidence snapshot:", b"\n", 0.3),
                (b"Review packages (3):", b"b\n", 0.3),
                (b"[q] Quit (Enter = u):", b"q\n", 0.3),
            ],
        )
        assert status == 0, (status, output)
        # Detail rendered from the record, uncorrupted by the stale Enter.
        assert b"--- bat (2/3) ---" in output, output
        assert b"Evidence URL:     https://example.com/bat/releases" in output, output
        assert b"Retrieval status: fresh" in output, output
        assert b"Invalid input" not in output, output


def test_inactivity_timeout_counts_down_and_exits_zero():
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        body = (
            "export BREW_CHANGE_PROMPT_TIMEOUT=3\n"
            + f'run_dashboard_mode "{records}" test_refresh\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(body)
        assert status == 0, (status, output)
        assert b"Still there?" in output, output
        assert b"exiting in" in output, output
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


def test_invalid_key_reprompts_without_rerender():
    """An invalid key costs one error line + a fresh prompt, not a re-render.

    Mirrors the countdown 'now' contract: the error line must clear the full
    width of the previously drawn prompt, so no `]uit` fragment survives on
    the visible line. The dashboard summary must appear exactly once — the
    reprompt after the invalid key re-prints only the prompt line. The quit
    key is a phased follow-up write: the key drain would eat it on Linux if
    sent in the same burst as the invalid key (see drive_cli_until).
    """
    stdout, _stderr, status = drive_cli_until(
        ["-u"], b"[q] Quit", b"x\n", follow=[(b"Invalid input", b"q\n")]
    )
    assert status == 0, (status, stdout)
    lines = overlay_lines(stdout)
    invalid_lines = [line for line in lines if b"Invalid input" in line]
    assert invalid_lines, stdout
    for line in invalid_lines:
        assert b"Quit" not in line, (
            f"invalid-input line retains prompt fragments: {line!r}"
        )
    summary_count = sum(line.count(b"outdated \xc2\xb7") for line in lines)
    assert summary_count == 1, (summary_count, stdout)


def test_eof_exits_zero():
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        body = (
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            + f'run_dashboard_mode "{records}" test_refresh\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[(b"[q] Quit (Enter = u):", b"\x04", 0.3)],
        )
        assert status == 0, (status, output)


def test_int_exits_130_and_restores_terminal():
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        body = (
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            + f'run_dashboard_mode "{records}" test_refresh\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[(b"[q] Quit (Enter = u):", b"\x03", 0.3)],
        )
        assert status == 130, (status, output)


def test_int_at_prompt_boundary_exits_130():
    """^C racing the prompt->read transition must still exit 130 quickly.

    Bash's read builtin swallows a trapped signal that arrives between the
    read starting and its blocking wait; the pending INT trap then waits
    until the read's timeout expires (see the slice-cap regression:
    uncapped first slice was total_timeout - countdown_window). Writing ^C
    the instant the prompt appears lands the signal in that window, which
    used to freeze the dashboard until the slice expired (50s at a 60s
    timeout; 290s at the default) — the intermittent PTY-stall flake.
    With 1s-capped slices the deferral is bounded to ~1s, well under the
    scenario TIMEOUT, so the exit contract holds even when the race hits.
    """
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        body = (
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            + f'run_dashboard_mode "{records}" test_refresh\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[(b"[q] Quit (Enter = u):", b"\x03", 0.0)],
        )
        assert status == 130, (status, output)


def test_reader_slices_are_capped():
    """Every timed read slice the readers issue must be <= 1 second.

    Deterministic contract check for the int-exit stall fix: a read()
    function shadows the builtin inside the scenario and logs each call,
    so the slice sizes the readers actually compute are asserted without
    racing the signal. Uncapped slices deferred a swallowed Ctrl-C for
    total_timeout - countdown_window seconds (290s at the default 300s).
    """
    import re

    with tempfile.TemporaryDirectory() as tmp:
        calls = os.path.join(tmp, "read-calls")
        body = (
            # Shadow the read builtin: log args (restore IFS so $* keeps
            # word separation), then fail like an EOF read.
            "read() { local IFS=' '; printf '%s\\n' \"$*\" >> "
            f'"{calls}"; return 1; }}\n'
            'probe=""\n'
            "_dashboard_read_key probe\n"
            "_dashboard_read_line probe\n"
            'printf "READCALLS-BEGIN\\n" > /dev/tty\n'
            f'cat "{calls}" > /dev/tty\n'
            'printf "\\nREADCALLS-END\\n" > /dev/tty\n'
        )
        output, status = run_scenario(body)
        assert status == 0, (status, output)
        assert b"READCALLS-BEGIN" in output, output
        log = output.split(b"READCALLS-BEGIN\r\n", 1)[1].split(b"READCALLS-END", 1)[0]
        timed = [line for line in log.splitlines() if b"-t " in line]
        assert timed, output
        for line in timed:
            m = re.search(rb"-t (\d+)", line)
            assert m, f"unparseable read call: {line!r}"
            assert int(m.group(1)) <= 1, f"uncapped read slice: {line!r}"


# --- T2.6.2 default flip: full-CLI dispatch under a PTY ----------------------
#
# Runs the real ./brew-change -u with fake brew/curl on PATH, stdout on a
# controlling PTY (so the TTY gate opens), stderr on a separate pipe (so
# each stream can be asserted independently — the v1.14.0 transition
# notice must stay gone from both). The dashboard/prompt readers use
# /dev/tty, which is the PTY via TIOCSCTTY.

NOTICE = b"brew-change: output view changed in v1.14.0"
# The dashboard legend/prompt line (rendered for any classification mix);
# the plain prompt flow instead prints "Select upgrade mode:".
DASH_PROMPT = b"[s] Select packages"
PLAIN_PROMPT = b"Select upgrade mode:"


def drive_cli_until(args, marker, payload, extra_env=None, follow=None):
    """Run the CLI in a PTY, wait for marker, write payload, wait for exit.

    follow: optional [(marker, payload), ...] — each payload is written only
    after its marker appears. Multi-key scenarios need this: the key reader's
    post-key line drain keeps whatever follows the key on macOS bash but the
    trailing newline is discarded on Linux, so a follow-up key written in the
    same burst is consumed by the drain on Linux and never reaches the prompt.
    Waiting for the reprompt marker proves the drain has finished on both.
    """
    # Implemented on top of run_cli_pty's building blocks but with input.
    tmp = tempfile.mkdtemp()
    try:
        outdated = {"formulae": [{"name": "bat"}], "casks": []}
        bindir, log, outdated_file = make_fake_brew(tmp, outdated)
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
            # keep the full-CLI scenarios fast and hermetic.
            "BREW_CHANGE_MAX_RETRIES": "1",
            "BREW_CHANGE_CACHE_DIR": os.path.join(tmp, "cache"),
            "FAKE_BREW_LOG": log,
            "FAKE_BREW_OUTDATED": outdated_file,
        }
        env.update(extra_env or {})

        def attach_controlling_terminal():
            os.environ.clear()
            os.environ.update(env)
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [BASH, os.path.join(ROOT, "brew-change")] + args,
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
            stdout += read_until(master, marker, timeout=TIMEOUT)
            assert marker in stdout, f"marker never appeared: {stdout!r}"
            time.sleep(0.3)
            os.write(master, payload)
            for follow_marker, follow_payload in follow or []:
                stdout += read_until(master, follow_marker, timeout=TIMEOUT)
                assert follow_marker in stdout, (
                    f"follow marker never appeared: {stdout!r}"
                )
                time.sleep(0.3)
                os.write(master, follow_payload)
            deadline = time.monotonic() + TIMEOUT
            while time.monotonic() < deadline:
                try:
                    returncode = process.wait(timeout=0.05)
                except subprocess.TimeoutExpired:
                    pass
                else:
                    status = returncode
                    break
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
        return stdout, stderr, status
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_default_flip_dispatches_dashboard():
    """TTY -u with no view flags: dashboard runs and the transition notice stays gone."""
    stdout, stderr, status = drive_cli_until(["-u"], DASH_PROMPT, b"q\n")
    assert status == 0, (status, stdout, stderr)
    assert DASH_PROMPT in stdout, stdout
    assert PLAIN_PROMPT not in stdout, stdout
    assert NOTICE not in stdout and NOTICE not in stderr, (stdout, stderr)


def test_plain_flag_selects_prompt_flow():
    """TTY -u --plain: previous prompt flow."""
    stdout, stderr, status = drive_cli_until(["-u", "--plain"], PLAIN_PROMPT, b"q\n")
    assert status == 0, (status, stdout, stderr)
    assert PLAIN_PROMPT in stdout, stdout
    assert DASH_PROMPT not in stdout, stdout


def test_plain_env_selects_prompt_flow():
    """TTY -u with BREW_CHANGE_PLAIN=1: prompt flow."""
    stdout, stderr, status = drive_cli_until(
        ["-u"], PLAIN_PROMPT, b"q\n", extra_env={"BREW_CHANGE_PLAIN": "1"}
    )
    assert status == 0, (status, stdout, stderr)
    assert PLAIN_PROMPT in stdout, stdout
    assert DASH_PROMPT not in stdout, stdout


def test_explicit_dashboard_flag_dispatches_dashboard():
    """TTY -u --dashboard: dashboard runs (flag now a no-op)."""
    stdout, stderr, status = drive_cli_until(["-u", "--dashboard"], DASH_PROMPT, b"q\n")
    assert status == 0, (status, stdout, stderr)
    assert DASH_PROMPT in stdout, stdout


def test_cache_banner_is_tty_only_and_stdout_pure():
    """T3.2.2: run-scoped cache events become one TTY banner, never stdout."""
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        events = os.path.join(tmp, "http-cache-events")
        os.makedirs(events)
        now = int(time.time())
        with open(os.path.join(events, "e1.1.%d" % (now - 3600)), "w") as fh:
            fh.write("%d cached-fresh\n" % (now - 3600))
        with open(os.path.join(events, "e2.2.%d" % (now - 60)), "w") as fh:
            fh.write("%d cached-fresh\n" % (now - 60))
        captured = os.path.join(tmp, "out.txt")
        body = (
            f'export BREW_CHANGE_HTTP_CACHE_EVENTS="{events}"\n'
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            + refresh_none()
            + f'run_dashboard_mode "{records}" test_refresh > "{captured}"\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[
                (b"Reusing 2 cached responses", b"q\n", 0.3),
            ],
        )
        assert status == 0, (status, output)
        assert b"Reusing 2 cached responses" in output, output
        assert b"Use --fresh to re-probe" in output, output
        with open(captured, "rb") as fh:
            captured_bytes = fh.read()
        assert b"Reusing" not in captured_bytes, captured_bytes
        assert b"--fresh" not in captured_bytes, captured_bytes


def test_quit_with_staged_selection_prints_reentry_hint():
    """T3.2.2 (research-008 Decision 2): quitting after staging a selection
    (and declining the exact-plan confirmation) prints the quit-time
    re-entry hint; quitting without a staged selection stays quiet."""
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        outdated = {
            "formulae": [{"name": "node"}, {"name": "bat"}],
            "casks": [{"token": "docker"}],
        }
        bindir, log, outdated_file = make_fake_brew(tmp, outdated)
        body = (
            f'export PATH="{bindir}:$PATH"\n'
            f'export FAKE_BREW_LOG="{log}"\n'
            f'export FAKE_BREW_OUTDATED="{outdated_file}"\n'
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            'export DRY_RUN_MODE=""\n'
            + refresh_none()
            + f'run_dashboard_mode "{records}" test_refresh\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[
                (b"[q] Quit (Enter = u):", b"s\n", 0.3),
                (b"Select: ", b"node\n", 0.3),
                (b"staged.", b"\n", 0.3),
                (b"dry-run", b"n\n", 0.3),
                (b"[q] Quit (Enter = u):", b"q\n", 0.3),
            ],
        )
        assert status == 0, (status, output)
        assert (
            b"Review discarded. Re-run 'brew-change -u' "
            b"\xe2\x80\x94 cached evidence will be reused where available."
        ) in output, output
        assert b"Dashboard closed." in output, output

    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        body = (
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            + refresh_none()
            + f'run_dashboard_mode "{records}" test_refresh\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[
                (b"[q] Quit (Enter = u):", b"q\n", 0.3),
            ],
        )
        assert status == 0, (status, output)
        assert b"Review discarded" not in output, output


def test_select_arrow_navigation_raw_mode():
    """Arrow keys navigate the SELECT list in raw mode: space stages the
    cursor row (node, row 1), Down moves to bat (row 2), space unstages
    it, Enter confirms — the exact-plan preview then names node only."""
    with tempfile.TemporaryDirectory() as tmp:
        records = write_records(tmp)
        outdated = {
            "formulae": [{"name": "node"}, {"name": "bat"}],
            "casks": [{"token": "docker"}],
        }
        bindir, log, outdated_file = make_fake_brew(tmp, outdated)
        body = (
            f'export PATH="{bindir}:$PATH"\n'
            f'export FAKE_BREW_LOG="{log}"\n'
            f'export FAKE_BREW_OUTDATED="{outdated_file}"\n'
            "export BREW_CHANGE_PROMPT_TIMEOUT=60\n"
            'export DRY_RUN_MODE=""\n'
            + refresh_none()
            + f'run_dashboard_mode "{records}" test_refresh\n'
            'printf "EXIT=%s\\n" "$?" > /dev/tty\n'
        )
        output, status = run_scenario(
            body,
            write_after_ready=[
                (b"[q] Quit (Enter = u):", b"s\n", 0.3),
                # One burst: space (stage node at cursor 1), Down arrow,
                # space (unstage bat at cursor 2), Enter (confirm).
                (b"Select: ", b" \x1b[B \n", 0.4),
                (b"dry-run", b"n\n", 0.3),
                (b"[q] Quit (Enter = u):", b"q\n", 0.3),
            ],
        )
        assert status == 0, (status, output)
        # Text cursor marker rendered on the visited rows (raw mode, no
        # echo — everything on screen is app-drawn).
        assert b"> [ ]  1) node" in output, output
        assert b"> [x]  2) bat" in output, output
        # The confirmed staged set is exactly node (bat unstaged).
        assert b"Preview: brew upgrade --dry-run node" in output, output
        assert b"Dashboard closed." in output, output


def main():
    tests = [
        test_u_reaches_preview_and_decline_returns,
        test_stale_enter_after_r_does_not_corrupt_review,
        test_inactivity_timeout_counts_down_and_exits_zero,
        test_invalid_key_reprompts_without_rerender,
        test_eof_exits_zero,
        test_int_exits_130_and_restores_terminal,
        test_int_at_prompt_boundary_exits_130,
        test_reader_slices_are_capped,
        test_default_flip_dispatches_dashboard,
        test_plain_flag_selects_prompt_flow,
        test_plain_env_selects_prompt_flow,
        test_explicit_dashboard_flag_dispatches_dashboard,
        test_cache_banner_is_tty_only_and_stdout_pure,
        test_quit_with_staged_selection_prints_reentry_hint,
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
