#!/usr/bin/env bash
# Progress animation must never leak terminal control sequences into piped output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_outdated_package_tokens() {
    printf 'alpha\tformula\nbeta\tformula\n'
}

show_package_changelog() {
    printf 'changelog for %s\n' "$1"
}

# shellcheck source=../lib/brew-change-parallel.sh
source "$PROJECT_DIR/lib/brew-change-parallel.sh"

# Override production resource detection after sourcing it so a busy CI runner
# cannot add an unrelated high-load warning to this output-focused test.
adjust_jobs_for_resources() {
    printf '%s\n' "$1"
}

stderr_file=$(mktemp "${TMPDIR:-/tmp}/brew-change-progress.XXXXXX")
trap 'rm -f "$stderr_file"' EXIT

process_packages_parallel '{}' 2 >/dev/null 2>"$stderr_file"

[[ ! -s "$stderr_file" ]] || fail "non-TTY stderr received progress output"

printf 'PASS: parallel progress is TTY-only\n'
