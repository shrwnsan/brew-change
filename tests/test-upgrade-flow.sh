#!/usr/bin/env bash
# Tests for upgrade flow integrity (Task 5).
# Validates:
#   upgrade_action_from_response: u->no-signal, c->choose, q->cancel, invalid->invalid
#   prompt_upgrade_action: invalid reprompts, q/EOF/timeout cancel
#   run_upgrade_with_preview: preview + confirm -> execute_upgrade (single mutation path)
#   execute_upgrade: single entry point, receives package array
#   preview_upgrade_packages: dry-run with HOMEBREW_NO_AUTO_UPDATE=1
#   DRY_RUN_MODE: runs real brew upgrade --dry-run, no mutation
#   Decline/preview failure/EOF/timeout: no --yes in log
#   Exact log for node+rectangle: 2 lines (dry-run then --yes)
#   Preview and mutation receive byte-identical package argv
#   Env assertions: HOMEBREW_NO_AUTO_UPDATE=1 on both calls, NO_INSTALL_CLEANUP on mutation
#   No argument-free upgrade execution (empty packages = no-op)
#
# Harness: Uses the fail-closed fake brew and optional environment capture from
# tests/lib/test-utils.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/homebrew"
PROJECT_DIR="$SCRIPT_DIR/.."
BREW_CHANGE="$PROJECT_DIR/brew-change"

# Source shared test utilities
source "$SCRIPT_DIR/lib/test-utils.sh"

# Source production libs (suppress subprocess traps)
export BREW_CHANGE_SUBPROCESS="true"
source "$LIB_DIR/brew-change-config.sh"
source "$LIB_DIR/brew-change-utils.sh"
source "$LIB_DIR/brew-change-brew.sh"
source "$LIB_DIR/brew-change-upgrade.sh"
source "$LIB_DIR/brew-change-display.sh"
source "$LIB_DIR/brew-change-interactive.sh"

# ---------------------------------------------------------------------------
# Minimal assertion harness
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Suite 1: upgrade_action_from_response vocabulary
# ---------------------------------------------------------------------------
echo "======================================"
echo "Upgrade Flow Tests"
echo "======================================"
echo ""

echo "=== Suite 1: Action Vocabulary ==="
echo ""

echo "Test 1: 'u' maps to no-signal"
assert_eq "u -> no-signal" "no-signal" "$(upgrade_action_from_response "u" 2)"

echo ""
echo "Test 2: 'upgrade' maps to no-signal"
assert_eq "upgrade -> no-signal" "no-signal" "$(upgrade_action_from_response "upgrade" 2)"

echo ""
echo "Test 3: 'c' maps to choose"
assert_eq "c -> choose" "choose" "$(upgrade_action_from_response "c" 5)"

echo ""
echo "Test 4: 'choose' maps to choose"
assert_eq "choose -> choose" "choose" "$(upgrade_action_from_response "choose" 5)"

echo ""
echo "Test 5: 'q' maps to cancel"
assert_eq "q -> cancel" "cancel" "$(upgrade_action_from_response "q" 5)"

echo ""
echo "Test 6: 'quit' maps to cancel"
assert_eq "quit -> cancel" "cancel" "$(upgrade_action_from_response "quit" 5)"

echo ""
echo "Test 7: empty input with no-signal count > 0 maps to no-signal"
assert_eq "empty -> no-signal (count=2)" "no-signal" "$(upgrade_action_from_response "" 2)"

echo ""
echo "Test 8: empty input with no-signal count 0 maps to cancel"
assert_eq "empty -> cancel (count=0)" "cancel" "$(upgrade_action_from_response "" 0)"

echo ""
echo "Test 9: unrecognized input maps to invalid"
assert_eq "x -> invalid" "invalid" "$(upgrade_action_from_response "x" 5)"
assert_eq "a -> invalid" "invalid" "$(upgrade_action_from_response "a" 5)"
assert_eq "s -> invalid" "invalid" "$(upgrade_action_from_response "s" 5)"
assert_eq "all -> invalid" "invalid" "$(upgrade_action_from_response "all" 5)"
assert_eq "y -> invalid" "invalid" "$(upgrade_action_from_response "y" 5)"

echo ""
echo "Test 9b: EOF and timeout cancel instead of selecting the Enter default"
assert_eq "failed read with no-signal packages -> cancel" "cancel" \
    "$(upgrade_action_from_read "false" "" 5)"
assert_eq "successful empty Enter -> no-signal" "no-signal" \
    "$(upgrade_action_from_read "true" "" 5)"

# ---------------------------------------------------------------------------
# Suite 2: execute_upgrade is the single mutation entry point
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 2: execute_upgrade single mutation entry ==="
echo ""

echo "Test 10: execute_upgrade receives package array, not mode+string"
setup_command_harness
configure_harness_env_capture HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
configure_fake_command brew "" "" 0

OUTPUT=$(execute_upgrade "node" "rectangle" 2>&1) || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
assert_eq "brew upgrade --yes in log" \
    $'brew\tupgrade\t--yes\tnode\trectangle' "$BREW_LOG"

# Check env assertions
ENV_LOG=$(cat "$COMMAND_HARNESS_ENV_LOG" 2>/dev/null || true)
assert_contains "HOMEBREW_NO_AUTO_UPDATE=1 on mutation" "HOMEBREW_NO_AUTO_UPDATE=1" "$ENV_LOG"
assert_contains "HOMEBREW_NO_INSTALL_CLEANUP=1 on mutation" "HOMEBREW_NO_INSTALL_CLEANUP=1" "$ENV_LOG"

teardown_command_harness

echo ""
echo "Test 11: execute_upgrade with no packages is a no-op"
setup_command_harness
configure_fake_command brew "" "" 0

OUTPUT=$(execute_upgrade 2>&1) || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
assert_eq "no brew calls for empty package list" "" "$BREW_LOG"
assert_contains "no packages message" "No packages" "$OUTPUT"

teardown_command_harness

# ---------------------------------------------------------------------------
# Suite 3: preview_upgrade_packages calls dry-run with env vars
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 3: Preview dry-run ==="
echo ""

echo "Test 12: preview_upgrade_packages calls brew upgrade --dry-run"
setup_command_harness
configure_harness_env_capture HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
configure_fake_command brew "" "" 0

printf '==> Upgrading node\n  22.6.0 -> 22.8.0\n' > "$COMMAND_HARNESS_CONFIG/brew/stdout"

OUTPUT=$(preview_upgrade_packages "node" "rectangle" 2>&1) || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
ENV_LOG=$(cat "$COMMAND_HARNESS_ENV_LOG" 2>/dev/null || true)

assert_contains "dry-run call present" $'brew\tupgrade\t--dry-run\tnode\trectangle' "$BREW_LOG"
assert_not_contains "no mutation call in preview" "brew	upgrade	--yes" "$BREW_LOG"
assert_contains "HOMEBREW_NO_AUTO_UPDATE=1 on dry-run" "HOMEBREW_NO_AUTO_UPDATE=1" "$ENV_LOG"
assert_contains "dependency warning present" "dependencies" "$OUTPUT"

teardown_command_harness

# ---------------------------------------------------------------------------
# Suite 4: run_upgrade_with_preview: preview then mutation on confirm
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 4: Preview-Confirm-Mutate Flow ==="
echo ""

echo "Test 13: decline -> no mutation"
setup_command_harness
configure_harness_env_capture HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
configure_fake_command brew "" "" 0

printf '==> Upgrading node\n  22.6.0 -> 22.8.0\n' > "$COMMAND_HARNESS_CONFIG/brew/stdout"

# Mock the final confirmation boundary to decline
prompt_upgrade_confirmation() { return 1; }

NO_SIGNAL_PKGS=("node" "rectangle")
ATTENTION_PKGS=()
UNKNOWN_PKGS=()

run_upgrade_with_preview "node" "rectangle" 2>&1 || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
assert_contains "dry-run call present" $'brew\tupgrade\t--dry-run\tnode\trectangle' "$BREW_LOG"
assert_not_contains "no mutation call on decline" "brew	upgrade	--yes" "$BREW_LOG"

teardown_command_harness

echo ""
echo "Test 14: confirm -> mutation follows preview"
setup_command_harness
configure_harness_env_capture HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
configure_fake_command brew "" "" 0

printf '==> Upgrading node\n  22.6.0 -> 22.8.0\n==> Upgrading rectangle\n  0.88 -> 0.92\n' > "$COMMAND_HARNESS_CONFIG/brew/stdout"

# Mock the final confirmation boundary to accept
prompt_upgrade_confirmation() { return 0; }

NO_SIGNAL_PKGS=("node" "rectangle")
ATTENTION_PKGS=()
UNKNOWN_PKGS=()

run_upgrade_with_preview "node" "rectangle" 2>&1 || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
ENV_LOG=$(cat "$COMMAND_HARNESS_ENV_LOG" 2>/dev/null || true)

# Exact log: 2 lines only - dry-run then --yes
EXPECTED_LOG=$'brew\tupgrade\t--dry-run\tnode\trectangle\nbrew\tupgrade\t--yes\tnode\trectangle'
assert_eq "exact 2-line log for node+rectangle" "$EXPECTED_LOG" "$BREW_LOG"

# Env assertions
EXPECTED_ENV_LOG=$'HOMEBREW_NO_AUTO_UPDATE=1\nHOMEBREW_NO_INSTALL_CLEANUP=\n---ENV-SEP---\nHOMEBREW_NO_AUTO_UPDATE=1\nHOMEBREW_NO_INSTALL_CLEANUP=1\n---ENV-SEP---'
assert_eq "preview and mutation environments" "$EXPECTED_ENV_LOG" "$ENV_LOG"

teardown_command_harness

echo ""
echo "Test 15: preview and mutation receive byte-identical package argv"
# (Already proven by Test 14: dry-run and --yes both have node\trectangle)

echo ""
echo "Test 16: preview failure prevents mutation"
setup_command_harness
configure_harness_env_capture HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
printf 'Error: dry run failed\n' > "$COMMAND_HARNESS_ROOT/brew-stderr.txt"
configure_fake_command brew "" "$COMMAND_HARNESS_ROOT/brew-stderr.txt" 1

# Even if confirmation would accept, it must not run after preview failure
prompt_upgrade_confirmation() { return 0; }

NO_SIGNAL_PKGS=("node")
ATTENTION_PKGS=()
UNKNOWN_PKGS=()

run_upgrade_with_preview "node" 2>&1 || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
assert_contains "dry-run attempted" $'brew\tupgrade\t--dry-run\tnode' "$BREW_LOG"
assert_not_contains "no mutation after dry-run failure" "brew	upgrade	--yes" "$BREW_LOG"

teardown_command_harness

# ---------------------------------------------------------------------------
# Suite 5: run_upgrade_prompt with DRY_RUN_MODE
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 5: --dry-run Upgrade Mode ==="
echo ""

echo "Test 17: DRY_RUN_MODE runs real brew upgrade --dry-run on no-signal packages"
setup_command_harness
configure_harness_env_capture HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
configure_fake_command brew "" "" 0

printf '==> Upgrading node\n  22.6.0 -> 22.8.0\n==> Upgrading rectangle\n  0.88 -> 0.92\n' > "$COMMAND_HARNESS_CONFIG/brew/stdout"

export DRY_RUN_MODE="true"
NO_SIGNAL_PKGS=("node" "rectangle")
ATTENTION_PKGS=()
UNKNOWN_PKGS=()

OUTDATED_JSON=$(cat "$FIXTURE_DIR/outdated-mixed.json")
OUTPUT=$(run_upgrade_prompt "$OUTDATED_JSON" 2>&1) || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
ENV_LOG=$(cat "$COMMAND_HARNESS_ENV_LOG" 2>/dev/null || true)

# Should have the dry-run call only, no --yes mutation
assert_contains "dry-run call present" $'brew\tupgrade\t--dry-run\tnode\trectangle' "$BREW_LOG"
assert_not_contains "no mutation in dry-run mode" "brew	upgrade	--yes" "$BREW_LOG"
assert_contains "HOMEBREW_NO_AUTO_UPDATE=1 on dry-run" "HOMEBREW_NO_AUTO_UPDATE=1" "$ENV_LOG"
assert_not_contains "no NO_INSTALL_CLEANUP in dry-run" "HOMEBREW_NO_INSTALL_CLEANUP=1" "$ENV_LOG"

unset DRY_RUN_MODE
teardown_command_harness

echo ""
echo "Test 18: DRY_RUN_MODE with no no-signal packages does not call brew"
setup_command_harness
configure_harness_env_capture HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
configure_fake_command brew "" "" 0

export DRY_RUN_MODE="true"
NO_SIGNAL_PKGS=()
ATTENTION_PKGS=("node")
UNKNOWN_PKGS=("rectangle")

OUTPUT=$(run_upgrade_prompt "$OUTDATED_JSON" 2>&1) || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
assert_eq "no brew calls when no no-signal packages" "" "$BREW_LOG"
assert_contains "no no-signal message" "No no-signal packages" "$OUTPUT"

unset DRY_RUN_MODE
teardown_command_harness

# ---------------------------------------------------------------------------
# Suite 6: No argument-free upgrade execution
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 6: No Argument-Free Execution ==="
echo ""

echo "Test 19: run_upgrade_with_preview with no packages is a no-op"
setup_command_harness
configure_fake_command brew "" "" 0

OUTPUT=$(run_upgrade_with_preview 2>&1) || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
assert_eq "no brew calls for empty packages" "" "$BREW_LOG"
assert_contains "no packages message" "No packages" "$OUTPUT"

teardown_command_harness

# ---------------------------------------------------------------------------
# Suite 7: Non-interactive mode in run_upgrade_prompt
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 7: Non-interactive mode ==="
echo ""

echo "Test 20: non-interactive mode prints suggestion, no brew upgrade calls"
setup_command_harness
configure_fake_command brew "" "" 0

NO_SIGNAL_PKGS=("node" "rectangle")
ATTENTION_PKGS=()
UNKNOWN_PKGS=()

# Override is_interactive_mode to return non-interactive
is_interactive_mode() { return 1; }

OUTPUT=$(run_upgrade_prompt "$OUTDATED_JSON" 2>&1) || true

BREW_LOG=$(cat "$COMMAND_HARNESS_LOG" 2>/dev/null || true)
assert_eq "no brew upgrade calls in non-interactive" "" "$BREW_LOG"
assert_contains "non-interactive message" "Non-interactive" "$OUTPUT"

# Restore original
is_interactive_mode() { [[ -t 0 ]]; }

teardown_command_harness

# ---------------------------------------------------------------------------
# Suite 8: Dependency warning on preview
# ---------------------------------------------------------------------------
echo ""
echo "=== Suite 8: Dependency Warning ==="
echo ""

echo "Test 21: preview_upgrade_packages shows dependency warning"
setup_command_harness
configure_fake_command brew "" "" 0

printf '==> Upgrading node\n  22.6.0 -> 22.8.0\n' > "$COMMAND_HARNESS_CONFIG/brew/stdout"

NO_SIGNAL_PKGS=("node")
ATTENTION_PKGS=()
UNKNOWN_PKGS=()

OUTPUT=$(preview_upgrade_packages "node" 2>&1) || true

assert_contains "preview shows dependency warning" "dependencies" "$OUTPUT" || \
assert_contains "preview shows dependent warning" "dependents" "$OUTPUT" || {
    echo -e "${RED}FAIL${NC}: preview output should warn about dependencies or dependents"
    ((fail++))
}

teardown_command_harness

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
