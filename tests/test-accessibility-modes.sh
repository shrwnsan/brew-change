#!/usr/bin/env bash
# T3.3.1 — accessible output modes: cross-cutting assertions.
#
# Ratified accessibility contract (tests/fixtures/dashboard/no-color/notes.md):
# the base render/output of every view carries ZERO color and ZERO emoji, and
# text labels carry ALL classification meaning; emoji are strictly additive
# decoration that may only appear on a TTY without NO_COLOR (or with the
# explicit BREW_CHANGE_NO_EMOJI=1 opt-out). This suite pins that contract for
# the breaking-change markers (legacy -b/-u paths, selection prompt, package
# headers) and the dashboard base render.
#
# Usage: bash tests/test-accessibility-modes.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/dashboard"
BASH_BIN="${BASH:-bash}"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-breaking.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-interactive.sh"

passed=0
failed=0

pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s\n' "$1" >&2; }

WARNING_BYTES=$'⚠️'

# --- Breaking markers: text label present in every non-TTY mode ---------------

# Command substitution (piped stdout) is the base render: text label only.
marker_checks_non_tty() {
    local result
    result=$(format_breaking_indicator "true")
    [[ "$result" == "[breaking]" ]] \
        || { fail "format_breaking_indicator base is '$result', want [breaking]"; return 1; }
    result=$(NO_COLOR=1 format_breaking_indicator "true")
    [[ "$result" == "[breaking]" ]] \
        || { fail "format_breaking_indicator NO_COLOR is '$result', want [breaking]"; return 1; }
    result=$(BREW_CHANGE_NO_EMOJI=1 format_breaking_indicator "true")
    [[ "$result" == "[breaking]" ]] \
        || { fail "format_breaking_indicator no-emoji knob is '$result', want [breaking]"; return 1; }
    result=$(add_breaking_prefix "pkg" "true")
    [[ "$result" == "pkg [breaking]" ]] \
        || { fail "add_breaking_prefix base is '$result', want 'pkg [breaking]'"; return 1; }
    result=$(NO_COLOR=1 add_breaking_prefix "pkg" "true")
    [[ "$result" == "pkg [breaking]" ]] \
        || { fail "add_breaking_prefix NO_COLOR is '$result', want 'pkg [breaking]'"; return 1; }
    result=$(BREW_CHANGE_NO_EMOJI=1 add_breaking_prefix "pkg" "true")
    [[ "$result" == "pkg [breaking]" ]] \
        || { fail "add_breaking_prefix no-emoji knob is '$result', want 'pkg [breaking]'"; return 1; }
    pass "breaking marker text label present in every non-TTY mode"
}

# --- Selection-prompt marker: text-first, emoji strictly additive -------------
#
# The selection prompt is drawn to /dev/tty while its caller captures stdout
# (selected_output=$(prompt_package_selection ...)), so a `-t 1` gate would
# always suppress the overlay at the real call site. The marker is therefore
# gated by the env policy alone: the "[breaking]" label is present in every
# mode, and the glyph follows it only when NO_COLOR is unset and the explicit
# no-emoji opt-out is not set.
selection_marker_checks() {
    local result
    result=$(selection_breaking_marker)
    [[ "$result" == " [breaking] ⚠️" ]] \
        || { fail "selection marker default is '$result', want ' [breaking] ⚠️'"; return 1; }
    result=$(NO_COLOR=1 selection_breaking_marker)
    [[ "$result" == " [breaking]" ]] \
        || { fail "selection marker NO_COLOR is '$result', want ' [breaking]'"; return 1; }
    result=$(BREW_CHANGE_NO_EMOJI=1 selection_breaking_marker)
    [[ "$result" == " [breaking]" ]] \
        || { fail "selection marker no-emoji knob is '$result', want ' [breaking]'"; return 1; }
    pass "selection-prompt marker text-first, glyph additive and env-gated"
}

# --- Package header: [breaking] label, no emoji in the base render ------------

header_marker_checks() {
    local out
    out=$(IDENTIFY_BREAKING=true create_package_header "node" "22.6.0" "25.0.0" \
        "3 days ago" '{}' "true")
    [[ "$out" == *"[breaking]"* ]] \
        || { fail "package header lacks the [breaking] text label: '$out'"; return 1; }
    [[ "$out" != *"$WARNING_BYTES"* ]] \
        || { fail "package header carries emoji in the base render: '$out'"; return 1; }
    out=$(IDENTIFY_BREAKING=true NO_COLOR=1 create_package_header "node" \
        "22.6.0" "25.0.0" "3 days ago" '{}' "true")
    [[ "$out" == *"[breaking]"* && "$out" != *"$WARNING_BYTES"* ]] \
        || { fail "NO_COLOR package header not text-only: '$out'"; return 1; }
    out=$(IDENTIFY_BREAKING=true BREW_CHANGE_NO_EMOJI=1 create_package_header \
        "node" "22.6.0" "25.0.0" "3 days ago" '{}' "true")
    [[ "$out" == *"[breaking]"* && "$out" != *"$WARNING_BYTES"* ]] \
        || { fail "no-emoji-knob package header not text-only: '$out'"; return 1; }
    # Without breaking evidence there is no marker at all.
    out=$(IDENTIFY_BREAKING=true create_package_header "node" "22.6.0" "25.0.0" \
        "3 days ago" '{}' "false")
    [[ "$out" != *"[breaking]"* && "$out" != *"$WARNING_BYTES"* ]] \
        || { fail "non-breaking package header carries a breaking marker: '$out'"; return 1; }
    pass "package header breaking marker is text-first"
}

# --- Emoji is additive on a real TTY (python3 PTY) ----------------------------
#
# The overlay must appear ONLY when stdout is a TTY, NO_COLOR is unset, and
# BREW_CHANGE_NO_EMOJI is not 1 — and even then the text label stays primary
# (the glyph follows it).

emoji_overlay_checks() {
    local out
    out=$(python3 - "$ROOT_DIR/lib/brew-change-breaking.sh" 2>&1 <<'PYEOF'
import pty, os, sys, select

lib = sys.argv[1]

def run_in_pty(env_extra, body):
    master, slave = pty.openpty()
    env = dict(os.environ)
    env.update(env_extra)
    script = f"""#!/usr/bin/env bash
source "{lib}"
{body}
"""
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write(script)
        name = f.name
    pid = os.fork()
    if pid == 0:
        os.setsid()
        import fcntl, termios
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
        if slave > 2:
            os.close(slave)
        os.close(master)
        os.execve("/usr/bin/env", ["/usr/bin/env", "bash", name], env)
    os.close(slave)
    data = b""
    while True:
        r, _, _ = select.select([master], [], [], 10)
        if not r:
            break
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    os.waitpid(pid, 0)
    os.unlink(name)
    os.close(master)
    return data

want = "[breaking] \u26a0\ufe0f".encode()
label = b"[breaking]"
ok = True

# TTY + color allowed: text label first, glyph strictly additive.
out = run_in_pty({}, "format_breaking_indicator true")
if label not in out:
    print(f"TTY-default: missing [breaking] label: {out!r}"); ok = False
if want not in out:
    print(f"TTY-default: additive glyph missing after label: {out!r}"); ok = False

# TTY + NO_COLOR: text label only.
out = run_in_pty({"NO_COLOR": "1"}, "format_breaking_indicator true")
if label not in out or b"\xe2\x9a\xa0" in out:
    print(f"TTY-NO_COLOR: expected text-only marker: {out!r}"); ok = False

# TTY + explicit no-emoji knob: text label only.
out = run_in_pty({"BREW_CHANGE_NO_EMOJI": "1"}, "format_breaking_indicator true")
if label not in out or b"\xe2\x9a\xa0" in out:
    print(f"TTY-no-emoji-knob: expected text-only marker: {out!r}"); ok = False

sys.exit(0 if ok else 1)
PYEOF
    )
    local status=$?
    if [[ $status -eq 0 && -z "$out" ]]; then
        pass "emoji overlay is additive on a TTY and gated by NO_COLOR/knob"
    else
        fail "emoji overlay PTY checks failed (status $status): $out"
    fi
}

# --- Dashboard base render stays byte-stable under accessibility knobs --------

dashboard_invariance_checks() {
    local expected="$FIXTURE_DIR/mixed/expected.txt"
    if NO_COLOR=1 render_dashboard_records "$FIXTURE_DIR/mixed/input.jsonl" 80 \
        | cmp -s - "$expected"; then
        pass "NO_COLOR=1 dashboard render byte-identical to base"
    else
        fail "NO_COLOR=1 dashboard render differs from base"
    fi
    if NO_COLOR=1 BREW_CHANGE_NO_EMOJI=1 render_dashboard_records \
        "$FIXTURE_DIR/mixed/input.jsonl" 80 | cmp -s - "$expected"; then
        pass "no-color+no-emoji dashboard render byte-identical to base"
    else
        fail "no-color+no-emoji dashboard render differs from base"
    fi
}

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/brew-change-dashboard.sh"

marker_checks_non_tty
selection_marker_checks
header_marker_checks
emoji_overlay_checks
dashboard_invariance_checks

printf '\nAccessibility modes: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
