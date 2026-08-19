#!/usr/bin/env bash
# Locale-export regression for the brew-change launcher (PTY stall, part 1).
#
# The launcher runs `set -euo pipefail` and used to decide its UTF-8 locale
# export with `locale -a 2>/dev/null | grep -q "^en_US.UTF-8"`. grep -q exits
# on the first match while `locale -a` keeps writing, so the producer dies of
# SIGPIPE (141) and pipefail marks the pipeline failed — the if-test was
# false on every macOS run and the export was silently skipped. With no
# ambient UTF-8 locale exported, the dashboard renderer's per-render locale
# resolution re-assigned LC_ALL on every helper call, whose setlocale(3) path
# (Homebrew bash + libintl -> CoreFoundation) is an intermittent bash
# segfault vector under load — the T2.6.2 full-CLI PTY stall.
#
# This suite extracts the launcher's locale-export construct verbatim and
# exercises it under a stubbed `locale -a`, so the checks are deterministic
# on every platform (no dependence on the host's locale list) and fail on
# the old pipe-based construct: the stub emits its match first and then far
# more output than a pipe can buffer, which is exactly the condition that
# made `locale -a | grep -q` die of SIGPIPE on macOS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
LAUNCHER="$ROOT_DIR/brew-change"

pass=0
fail=0

note() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bail() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

# The launcher's construct, byte-verbatim: the `_available_locales` capture
# through `unset _available_locales`. A refactor that moves or renames it
# must update this extraction — failing loudly beats silently testing a
# paraphrase. The construct must not feed grep through a pipe at all.
construct="$(sed -n '/^_available_locales=/,/^unset _available_locales$/p' "$LAUNCHER")"
# No line of the construct may feed grep through a pipe (`| grep` on one
# line — `|| true` is fine); that is the SIGPIPE-under-pipefail shape.
pipe_grep_lines="$(printf '%s\n' "$construct" | grep -cE '\|.*grep|grep.*\|')"
if [[ -n $construct && $construct == *"export LC_ALL="* && $pipe_grep_lines -eq 0 ]]; then
    note "launcher locale-export construct extracted (no grep pipes)"
else
    bail "could not extract pipe-free locale-export construct from launcher ($pipe_grep_lines piped-grep lines)"
    printf '\nlocale export: %d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

# Stub `locale`: `locale -a` prints $1 (if any) followed by enough filler to
# overflow a pipe buffer (64 KiB) many times over, so any consumer that
# stops reading early (grep -q) deterministically SIGPIPEs the producer.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
stub="$work/bin/locale"

make_stub() { # match-line ('' for none) / exit-status
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [[ "${1:-}" == "-a" ]]; then\n'
        if [[ -n $1 ]]; then
            printf '    printf "%%s\\n" "%s"\n' "$1"
        fi
        # The || exit makes the producer's death disposition-independent:
        # with SIGPIPE at default the shell dies of signal 141 on the write;
        # process runners that ignore SIGPIPE (CI spawns shells with SIG_IGN
        # inherited — it cannot be reset in a non-interactive shell) instead
        # get a failed printf (EPIPE) and this explicit nonzero exit. Either
        # way pipefail marks the pipeline failed once grep -q stops reading.
        printf '    for i in $(seq 1 20000); do printf "xx_XX.ISO8859-1 %%06d\\n" "$i" || exit 142; done\n'
        printf '    exit %s\n' "$2"
        printf 'fi\n'
        printf 'exit %s\n' "$2"
    } > "$stub"
    chmod +x "$stub"
}

# Run the extracted construct (verbatim, in a scratch script) under the
# stubbed PATH, with pipefail and a scrubbed environment, and print
# "<LC_ALL>|<LANG>|<_available_locales leak>" on stdout.
run_construct() {
    {
        printf 'set -euo pipefail\n'
        printf '%s\n' "$construct"
        printf 'printf "%%s|%%s|%%s" "${LC_ALL:-}" "${LANG:-}" "${_available_locales:-NONE}"\n'
    } > "$work/run.sh"
    env -i PATH="$work/bin:/usr/bin:/bin" bash "$work/run.sh"
}

# --- The export must actually happen under pipefail --------------------------

make_stub "en_US.UTF-8" 0
out="$(run_construct)"; rc=$?
if [[ $rc -eq 0 && $out == "en_US.UTF-8|en_US.UTF-8|NONE" ]]; then
    note "en_US.UTF-8 available: LC_ALL/LANG exported, no variable leak"
else
    bail "en_US.UTF-8 available but construct yielded '$out' (rc=$rc)"
fi

make_stub "C.UTF-8" 0
out="$(run_construct)"; rc=$?
if [[ $rc -eq 0 && $out == "C.UTF-8|C.UTF-8|NONE" ]]; then
    note "C.UTF-8-only system: LC_ALL/LANG exported"
else
    bail "C.UTF-8-only system but construct yielded '$out' (rc=$rc)"
fi

# --- Absent / failing `locale -a`: no export, and errexit must survive -------

make_stub "" 0
out="$(run_construct)"; rc=$?
if [[ $rc -eq 0 && $out == "||NONE" ]]; then
    note "no UTF-8 locale available: nothing exported, construct survives"
else
    bail "no-UTF-8 case yielded '$out' (rc=$rc) — must export nothing and survive"
fi

make_stub "" 1
out="$(run_construct)"; rc=$?
if [[ $rc -eq 0 && $out == "||NONE" ]]; then
    note "failing locale -a: nothing exported, construct survives"
else
    bail "failing locale -a yielded '$out' (rc=$rc) — must export nothing and survive"
fi

# --- The bug class itself: grep -q against a still-writing producer ----------

# The same stub must defeat the OLD pipe construct under pipefail: the
# producer is guaranteed to still be writing (>64 KiB pending) when grep -q
# exits on its first match, so `locale -a | grep -q` fails (SIGPIPE death or
# the stub's EPIPE exit) and the export is skipped. Any nonzero rc is a valid
# defeat — the pinned mechanism is "early-exiting reader fails the producer
# under pipefail", not a specific signal number. If this ever "passes" with
# EXPORTED, grep stopped early-exiting and this suite's stub no longer pins
# the mechanism.
make_stub "en_US.UTF-8" 0
old_out="$(env -i PATH="$work/bin:/usr/bin:/bin" bash -c '
    set -euo pipefail
    if locale -a 2>/dev/null | grep -q "^en_US.UTF-8"; then
        printf "EXPORTED"
    else
        printf "SKIPPED(rc=%s)" "$?"
    fi
')"; old_rc=$?
if [[ $old_rc -eq 0 && $old_out =~ ^SKIPPED\(rc=1[0-9][0-9]\)$ ]]; then
    note "old pipe construct still skips the export (producer failed under pipefail) with this stub"
else
    bail "stub no longer defeats the old pipe construct (got '$old_out', rc=$old_rc); grow the filler"
fi

printf '\nlocale export: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
