#!/usr/bin/env bash
# Run the fixture-backed test suites used by CI and release preflight.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
passed=0
failed=0

run_suite() {
    local name="$1"
    shift

    printf '\n--- %s ---\n' "$name"
    if "$@"; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n' "$name" >&2
        failed=$((failed + 1))
    fi
}

run_suite "shell command harness" bash "$SCRIPT_DIR/test-command-harness.sh"
run_suite "CLI validation" bash "$SCRIPT_DIR/test-cli-validation.sh"
run_suite "breaking-change detection" bash "$SCRIPT_DIR/test-breaking-changes.sh" --ci
run_suite "refactor regressions" bash "$SCRIPT_DIR/test-refactor-fixes.sh"
run_suite "cask JSON parsing" bash "$SCRIPT_DIR/test-cask-json-parsing.sh"
run_suite "variant resolution" bash "$SCRIPT_DIR/test-variant-resolution.sh"
run_suite "upgrade assessment" bash "$SCRIPT_DIR/test-upgrade-assessment.sh"
run_suite "upgrade flow" bash "$SCRIPT_DIR/test-upgrade-flow.sh"
run_suite "parallel progress" bash "$SCRIPT_DIR/test-parallel-progress.sh"
run_suite "signal cleanup" bash "$SCRIPT_DIR/test-signal-cleanup.sh"
run_suite "assessment engine" bash "$SCRIPT_DIR/test-assessment-engine.sh"
run_suite "record pipeline" bash "$SCRIPT_DIR/test-record-pipeline.sh"
run_suite "terminal restoration" python3 "$SCRIPT_DIR/test-terminal-restoration.py"
run_suite "prompt behavior" python3 "$SCRIPT_DIR/test-prompt-behavior.py"
run_suite "URL policy" bash "$SCRIPT_DIR/test-url-policy.sh"
run_suite "HTTP cache" bash "$SCRIPT_DIR/test-http-cache.sh"
run_suite "release preflight" bash "$SCRIPT_DIR/test-release-preflight.sh"
run_suite "progress renderer" bash "$SCRIPT_DIR/test-progress-renderer.sh"
run_suite "progress integration" bash "$SCRIPT_DIR/test-progress-integration.sh"
run_suite "dashboard fixtures" bash "$SCRIPT_DIR/test-dashboard-fixtures.sh"
run_suite "dashboard renderer" bash "$SCRIPT_DIR/test-dashboard-render.sh"
run_suite "dashboard actions" bash "$SCRIPT_DIR/test-dashboard-actions.sh"
run_suite "locale export" bash "$SCRIPT_DIR/test-locale-export.sh"
run_suite "errexit hardening" bash "$SCRIPT_DIR/test-errexit-hardening.sh"
run_suite "first-run guidance" bash "$SCRIPT_DIR/test-first-run-guidance.sh"
run_suite "remediation wording" bash "$SCRIPT_DIR/test-remediation-wording.sh"
run_suite "accessibility modes" bash "$SCRIPT_DIR/test-accessibility-modes.sh"
run_suite "b verdict summary" bash "$SCRIPT_DIR/test-b-verdict-summary.sh"
run_suite "npm-github fallback" bash "$SCRIPT_DIR/test-npm-github-fallback.sh"
run_suite "assessment export" bash "$SCRIPT_DIR/test-assessment-export.sh"

printf '\nDeterministic suites: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
