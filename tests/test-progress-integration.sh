#!/usr/bin/env bash
# T2.4.3 integration tests: progress events flow end-to-end through the
# synthetic -u-style pipeline, in the approved T2.4.1 event contract form,
# and the T2.4.2 renderer returns before subsequent stage output is drawn.
#
# Pipeline under test (no network, no real brew):
#   assessment_record_init      -> inventory event(s)
#   process_packages_parallel   -> one evidence event per package (fake
#                                  show_package_changelog in the workers)
#   classify_upgrade_evidence   -> one classify event per package
#   render_progress             -> consumes the full stream and returns
#                                  (non-TTY: silent; PTY case: reaches the
#                                  next stage after the final frame)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"
BASH_BIN="${BASH:-bash}"

source "$SCRIPT_DIR/lib/test-utils.sh"
setup_command_harness || exit 1

export BREW_CHANGE_SUBPROCESS="true"
export BREW_CHANGE_CACHE_DIR="$COMMAND_HARNESS_ROOT/cache"
mkdir -p "$BREW_CHANGE_CACHE_DIR"

source "$LIB_DIR/brew-change-config.sh"
source "$LIB_DIR/brew-change-utils.sh"
source "$LIB_DIR/brew-change-breaking.sh"
source "$LIB_DIR/brew-change-assessment.sh"
source "$LIB_DIR/brew-change-brew.sh"
source "$LIB_DIR/brew-change-parallel.sh"
source "$LIB_DIR/brew-change-progress.sh"
source "$LIB_DIR/brew-change-upgrade.sh"

pass=0
fail=0

pass_case() {
    printf 'PASS: %s\n' "$1"
    pass=$((pass + 1))
}

fail_case() {
    printf 'FAIL: %s\n' "$1" >&2
    fail=$((fail + 1))
}

run_case() {
    local name="$1"
    shift
    if "$@"; then
        pass_case "$name"
    else
        fail_case "$name"
    fi
}

new_run_dir() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/bc-progint.XXXXXX")"
    printf '%s\n' "$dir"
}

cleanup_run_dir() {
    trash "$1" 2>/dev/null || rm -rf "$1"
}

outdated_json() { cat "$FIXTURE_DIR/outdated-mixed.json"; }

# Count events in progress.jsonl matching a jq filter.
event_count() {
    jq -r "$1" "$2/progress.jsonl" 2>/dev/null | grep -c . || true
}

# ---------------------------------------------------------------------------
# Stage 1: inventory event around assessment_record_init
# ---------------------------------------------------------------------------
test_inventory_event_emitted() {
    local run_dir
    run_dir="$(new_run_dir)"
    UPGRADE_STATUS_DIR="$run_dir" assessment_record_init "$run_dir" "$(outdated_json)"
    local n line
    n=$(event_count 'select(.stage == "inventory") | .completed' "$run_dir")
    line=$(jq -c 'select(.stage == "inventory")' "$run_dir/progress.jsonl")
    cleanup_run_dir "$run_dir"
    [[ "$n" == "1" ]] \
        && [[ "$line" == '{"stage":"inventory","completed":1,"total":1}' ]]
}

test_no_inventory_event_without_status_dir() {
    local run_dir
    run_dir="$(new_run_dir)"
    UPGRADE_STATUS_DIR="" assessment_record_init "$run_dir" "$(outdated_json)"
    local n=0
    [[ -e "$run_dir/progress.jsonl" ]] && n=$(wc -l < "$run_dir/progress.jsonl")
    cleanup_run_dir "$run_dir"
    [[ "$n" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Stage 2: evidence events from process_packages_parallel
# ---------------------------------------------------------------------------
test_evidence_events_per_package() {
    local run_dir
    run_dir="$(new_run_dir)"
    export UPGRADE_STATUS_DIR="$run_dir"

    # Fake worker payload: no network, small deterministic delay.
    show_package_changelog() {
        sleep 0.05
        printf 'changelog for %s\n' "$1"
    }
    adjust_jobs_for_resources() { printf '%s\n' "$1"; }
    rate_limit_delay() { :; }

    process_packages_parallel "$(outdated_json)" 4 > /dev/null

    local total n seq_ok total_ok labels_ok
    total=$(event_count 'select(.stage == "evidence") | .total' "$run_dir")
    n=$(event_count 'select(.stage == "evidence") | .completed' "$run_dir")
    # completed ordinals are exactly 1..N (monotonic, ends at total)
    seq_ok=$(jq -s '[.[].completed] == [1,2,3]' \
        < <(jq -c 'select(.stage == "evidence")' "$run_dir/progress.jsonl") >/dev/null \
        && echo ok || echo no)
    total_ok=$(jq -s 'all(.[]; .total == 3)' \
        < <(jq -c 'select(.stage == "evidence")' "$run_dir/progress.jsonl") >/dev/null \
        && echo ok || echo no)
    # package labels are exactly the inventory token set
    labels_ok=$(jq -s '([.[].package] | sort) == (["node", "rectangle", "claude-code"] | sort)' \
        < <(jq -c 'select(.stage == "evidence")' "$run_dir/progress.jsonl") >/dev/null \
        && echo ok || echo no)

    cleanup_run_dir "$run_dir"
    unset UPGRADE_STATUS_DIR
    [[ "$n" == "3" && "$total" == "3" ]] \
        && [[ "$seq_ok" == "ok" && "$total_ok" == "ok" && "$labels_ok" == "ok" ]]
}

# ---------------------------------------------------------------------------
# Stage 3: classify events from classify_upgrade_evidence
# ---------------------------------------------------------------------------
test_classify_events_per_package() {
    local run_dir
    run_dir="$(new_run_dir)"
    export UPGRADE_STATUS_DIR="$run_dir"

    assessment_record_init "$run_dir" "$(outdated_json)"
    append_assessment_evidence "node" "github" "https://example.com/node" \
        "1700000000" "ok" "snapshot" || true
    classify_upgrade_evidence "$run_dir" node rectangle claude-code > /dev/null

    local n seq_ok labels_ok
    n=$(event_count 'select(.stage == "classify") | .completed' "$run_dir")
    seq_ok=$(jq -s '[.[].completed] == [1,2,3]' \
        < <(jq -c 'select(.stage == "classify")' "$run_dir/progress.jsonl") >/dev/null \
        && echo ok || echo no)
    labels_ok=$(jq -s '([.[].package] | sort) == (["node", "rectangle", "claude-code"] | sort)' \
        < <(jq -c 'select(.stage == "classify")' "$run_dir/progress.jsonl") >/dev/null \
        && echo ok || echo no)

    cleanup_run_dir "$run_dir"
    unset UPGRADE_STATUS_DIR
    [[ "$n" == "3" && "$seq_ok" == "ok" && "$labels_ok" == "ok" ]]
}

# ---------------------------------------------------------------------------
# Renderer: full completed -u-style stream, must return before the next
# stage's output is drawn (non-TTY, silent consumption).
# ---------------------------------------------------------------------------
test_renderer_returns_before_subsequent_output() {
    local run_dir
    run_dir="$(new_run_dir)"
    {
        echo '{"stage":"inventory","completed":1,"total":1}'
        echo '{"stage":"evidence","completed":1,"total":3,"package":"node"}'
        echo '{"stage":"evidence","completed":2,"total":3,"package":"rectangle"}'
        echo '{"stage":"evidence","completed":3,"total":3,"package":"claude-code"}'
        echo '{"stage":"classify","completed":1,"total":3,"package":"node"}'
        echo '{"stage":"classify","completed":2,"total":3,"package":"rectangle"}'
        echo '{"stage":"classify","completed":3,"total":3,"package":"claude-code"}'
    } > "$run_dir/progress.jsonl"

    local out status
    set +e
    out=$(BREW_CHANGE_PROGRESS_DUMP=1 \
        BREW_CHANGE_PROGRESS_IDLE_US=60000 \
        BREW_CHANGE_PROGRESS_STALL_US=60000 \
        "$BASH_BIN" -c '
            set -u
            source "$1/brew-change-progress.sh"
            render_progress "$2" </dev/null
            echo NEXT_STAGE_OUTPUT
        ' _ "$LIB_DIR" "$run_dir" 2>&1)
    status=$?
    set -e

    cleanup_run_dir "$run_dir"
    [[ $status -eq 0 ]] \
        && [[ "$out" == *"STAGE=classify COUNT=3 TOTAL=3"* ]] \
        && [[ "$out" == *"NEXT_STAGE_OUTPUT"* ]] \
        && [[ "$out" == *"$(
            printf 'STAGE=classify COUNT=3 TOTAL=3\nNEXT_STAGE_OUTPUT')"* ]]
}

# ---------------------------------------------------------------------------
# Renderer termination: no other spinner/animation code may exist in the
# worker/parent path (contract rule 1).
# ---------------------------------------------------------------------------
test_no_terminal_writes_in_parallel_path() {
    local offenders
    offenders=$(grep -n '\\r\|\[K\|⠋' "$LIB_DIR/brew-change-parallel.sh" || true)
    [[ -z "$offenders" ]]
}

# ---------------------------------------------------------------------------
# Completion summary deferral: with the renderer active the summary must be
# handed back (PARALLEL_PENDING_SUMMARY), not printed inline where it would
# collide with the live spinner frame; without the defer flag the historical
# inline echo is preserved (non-TTY / renderer-less runs unchanged).
# ---------------------------------------------------------------------------
test_deferred_completion_summary() {
    local run_dir out pending out_file
    run_dir="$(new_run_dir)"
    export UPGRADE_STATUS_DIR="$run_dir"

    show_package_changelog() {
        sleep 0.05
        printf 'changelog for %s\n' "$1"
    }
    adjust_jobs_for_resources() { printf '%s\n' "$1"; }
    rate_limit_delay() { :; }

    PARALLEL_PENDING_SUMMARY=""
    # No command substitution: the pending summary is handed back via the
    # shell global, so the call must run in this shell (stdout to a file).
    local out_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/bc-progint-out.XXXXXX")"
    BREW_CHANGE_DEFER_SUMMARY=1 \
        process_packages_parallel "$(outdated_json)" 4 > "$out_file" 2>/dev/null
    pending="$PARALLEL_PENDING_SUMMARY"
    PARALLEL_PENDING_SUMMARY=""
    out="$(cat "$out_file")"
    rm -f "$out_file"

    cleanup_run_dir "$run_dir"
    unset UPGRADE_STATUS_DIR
    [[ "$out" != *"Completed processing"* ]] \
        && [[ "$pending" == "Completed processing 3 packages in "*s ]]
}

test_inline_completion_summary_without_defer() {
    local run_dir out out_file
    run_dir="$(new_run_dir)"
    export UPGRADE_STATUS_DIR="$run_dir"

    show_package_changelog() {
        sleep 0.05
        printf 'changelog for %s\n' "$1"
    }
    adjust_jobs_for_resources() { printf '%s\n' "$1"; }
    rate_limit_delay() { :; }

    out_file="$(mktemp "${TMPDIR:-/tmp}/bc-progint-out.XXXXXX")"
    process_packages_parallel "$(outdated_json)" 4 > "$out_file" 2>/dev/null
    out="$(cat "$out_file")"
    rm -f "$out_file"

    cleanup_run_dir "$run_dir"
    unset UPGRADE_STATUS_DIR
    [[ "$out" == *"Completed processing 3 packages in "*s ]]
}

run_case "inventory event emitted around assessment_record_init" test_inventory_event_emitted
run_case "no inventory event without UPGRADE_STATUS_DIR" test_no_inventory_event_without_status_dir
run_case "evidence events per package from parallel workers" test_evidence_events_per_package
run_case "classify events per package from classification" test_classify_events_per_package
run_case "renderer returns before subsequent stage output" test_renderer_returns_before_subsequent_output
run_case "no terminal writes in the parallel processing path" test_no_terminal_writes_in_parallel_path
run_case "deferred completion summary handed back, not printed" test_deferred_completion_summary
run_case "inline completion summary without defer flag" test_inline_completion_summary_without_defer

# ---------------------------------------------------------------------------
# PTY: a completed -u-style flow animates and still reaches its next stage.
# ---------------------------------------------------------------------------
printf '\n--- progress integration PTY ---\n'
if python3 - "$LIB_DIR" <<'PYEOF'
import errno
import os
import pty
import select
import shutil
import sys
import tempfile
import time

LIB = sys.argv[1]
TIMEOUT = 20
BASH = shutil.which("bash") or "/bin/bash"

run_dir = tempfile.mkdtemp(prefix="bc-progint-pty.")
script = f"""
set -u
source '{LIB}/brew-change-progress.sh'
(
  echo '{{"stage":"inventory","completed":1,"total":1}}' >> progress.jsonl
  sleep 0.3
  for i in 1 2 3; do
    echo "{{\\"stage\\":\\"evidence\\",\\"completed\\":$i,\\"total\\":3,\\"package\\":\\"pkg$i\\"}}" >> progress.jsonl
    sleep 0.3
  done
  for i in 1 2 3; do
    echo "{{\\"stage\\":\\"classify\\",\\"completed\\":$i,\\"total\\":3,\\"package\\":\\"pkg$i\\"}}" >> progress.jsonl
    sleep 0.2
  done
) &
writer=$!
render_progress .
wait "$writer"
echo NEXT_STAGE_REACHED
"""

try:
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(run_dir)
        os.execv(BASH, [BASH, "-c", script])

    data = b""
    deadline = time.monotonic() + TIMEOUT
    while b"NEXT_STAGE_REACHED" not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
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
    _, status = os.waitpid(pid, 0)
    code = os.waitpid_status_to_exitcode(status) if hasattr(os, "waitpid_status_to_exitcode") \
        else (status >> 8)
finally:
    shutil.rmtree(run_dir, ignore_errors=True)

assert b"NEXT_STAGE_REACHED" in data, "flow did not reach its next stage"
# No spinner frame may be drawn after the next-stage marker: the renderer
# cleared its final frame before returning.
tail = data.split(b"NEXT_STAGE_REACHED", 1)[1]
spin = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".encode()
assert not any(c in tail for c in spin), "frame drawn after next-stage output"
assert code == 0, f"non-zero exit: {code}"
sys.exit(0)
PYEOF
then
    pass_case "PTY: completed -u-style flow reaches next stage after renderer"
else
    fail_case "PTY: completed -u-style flow reaches next stage after renderer"
fi

# ---------------------------------------------------------------------------
# PTY: with the renderer running the brew-change stop sequence (sentinel +
# bounded wait + kill + clear-line), the completion summary printed after
# the stop never shares a rendered line with a spinner frame.
# ---------------------------------------------------------------------------
printf '\n--- completion summary vs renderer PTY ---\n'
if python3 - "$LIB_DIR" <<'PYEOF'
import errno
import os
import pty
import select
import shutil
import sys
import tempfile
import time

LIB = sys.argv[1]
TIMEOUT = 20
BASH = shutil.which("bash") or "/bin/bash"

run_dir = tempfile.mkdtemp(prefix="bc-progint-sum-pty.")
# Mirrors brew-change: renderer loop until sentinel, then bounded wait +
# kill backstop + clear-line, then the deferred completion summary.
script = f"""
set -u
source '{LIB}/brew-change-progress.sh'
(
  echo '{{"stage":"inventory","completed":1,"total":1}}' >> progress.jsonl
  sleep 0.3
  for i in 1 2 3; do
    echo "{{\\"stage\\":\\"evidence\\",\\"completed\\":$i,\\"total\\":3,\\"package\\":\\"pkg$i\\"}}" >> progress.jsonl
    sleep 0.3
  done
  # Keep the renderer from satisfying its idle contract on its own: the
  # caller-side sentinel stop below must be what terminates it.
  for i in 1 2; do
    echo "{{\\"stage\\":\\"classify\\",\\"completed\\":$i,\\"total\\":3,\\"package\\":\\"pkg$i\\"}}" >> progress.jsonl
    sleep 0.3
  done
) &
writer=$!
(
  while [[ ! -f .progress_done ]] && kill -0 "$writer" 2>/dev/null; do
    render_progress .
    sleep 0.1
  done
) &
renderer=$!
wait "$writer"
: > .progress_done
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "$renderer" 2>/dev/null || break
  sleep 0.1
done
kill "$renderer" 2>/dev/null || true
wait "$renderer" 2>/dev/null || true
if declare -F _progress_clear_line >/dev/null 2>&1; then
  _progress_clear_line > /dev/tty 2>/dev/null || true
fi
echo 'Completed processing 3 packages in 1s'
echo NEXT_STAGE_REACHED
"""

try:
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(run_dir)
        os.execv(BASH, [BASH, "-c", script])

    data = b""
    deadline = time.monotonic() + TIMEOUT
    while b"NEXT_STAGE_REACHED" not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
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
    _, status = os.waitpid(pid, 0)
    code = os.waitpid_status_to_exitcode(status) if hasattr(os, "waitpid_status_to_exitcode") \
        else (status >> 8)
finally:
    shutil.rmtree(run_dir, ignore_errors=True)

assert b"NEXT_STAGE_REACHED" in data, "flow did not reach its next stage"
assert b"Completed processing 3 packages" in data, "summary missing"

# CR-overlay sense: the summary occupies a rendered line only up to the
# previous carriage return / newline. No spinner frame glyph may precede
# the summary on that same rendered segment.
marker = b"Completed processing 3 packages"
idx = data.find(marker)
assert idx >= 0
line_start = max(data.rfind(b"\r", 0, idx), data.rfind(b"\n", 0, idx)) + 1
segment = data[line_start:idx]
spin = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".encode()
assert not any(c in segment for c in spin), \
    f"summary shares a line with a spinner frame: {segment!r}"
assert code == 0, f"non-zero exit: {code}"
sys.exit(0)
PYEOF
then
    pass_case "PTY: completion summary starts on a fresh line after renderer stop"
else
    fail_case "PTY: completion summary starts on a fresh line after renderer stop"
fi

printf '\nProgress integration suites: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
