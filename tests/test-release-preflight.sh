#!/usr/bin/env bash
# Verify release failures occur before commit, tag, push, or GitHub release.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/brew-change-release-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

passed=0
failed=0
fixture_number=0
REPO=""
REMOTE=""
HARNESS_BIN=""
HARNESS_LOG=""
RUN_OUTPUT=""
RUN_STATUS=0

pass() { printf 'PASS: %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

assert_contains() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        pass "$description"
    else
        fail "$description (missing '$expected')"
    fi
}

assert_failed_without_mutation() {
    local description="$1" before_head="$2" before_tags="$3" before_refs="$4"
    local after_head after_tags after_refs
    after_head=$(git -C "$REPO" rev-parse HEAD)
    after_tags=$(git -C "$REPO" tag --list)
    after_refs=$(git -C "$REMOTE" for-each-ref --format='%(refname) %(objectname)' | sort)

    if [[ $RUN_STATUS -ne 0 ]]; then pass "$description exits nonzero"; else fail "$description exits nonzero"; fi
    if [[ "$after_head" == "$before_head" ]]; then pass "$description leaves HEAD unchanged"; else fail "$description leaves HEAD unchanged"; fi
    if [[ "$after_tags" == "$before_tags" ]]; then pass "$description leaves local tags unchanged"; else fail "$description leaves local tags unchanged"; fi
    if [[ "$after_refs" == "$before_refs" ]]; then pass "$description leaves remote refs unchanged"; else fail "$description leaves remote refs unchanged"; fi
    if ! grep -q '^gh[[:space:]]release[[:space:]]create' "$HARNESS_LOG"; then pass "$description creates no GitHub release"; else fail "$description creates no GitHub release"; fi
}

snapshot_state() {
    SNAPSHOT_HEAD=$(git -C "$REPO" rev-parse HEAD)
    SNAPSHOT_TAGS=$(git -C "$REPO" tag --list)
    SNAPSHOT_REFS=$(git -C "$REMOTE" for-each-ref --format='%(refname) %(objectname)' | sort)
}

new_fixture() {
    fixture_number=$((fixture_number + 1))
    local fixture="$TEST_ROOT/$fixture_number"
    local seed="$fixture/seed"
    REMOTE="$fixture/remote.git"
    REPO="$fixture/repo"
    HARNESS_BIN="$fixture/bin"
    HARNESS_LOG="$fixture/commands.log"

    mkdir -p "$seed/scripts" "$seed/tests" "$HARNESS_BIN"
    git init --bare --quiet "$REMOTE"
    git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
    git init --quiet -b main "$seed"
    git -C "$seed" config user.name "Release Test"
    git -C "$seed" config user.email "release-test@example.invalid"

    printf '#!/usr/bin/env bash\nreadonly VERSION="1.0.0"\n' > "$seed/brew-change"
    cp "$PROJECT_DIR/scripts/release.sh" "$seed/scripts/release.sh"
    cat > "$seed/tests/run-deterministic.sh" <<'RUNNER'
#!/usr/bin/env bash
exit "${FAKE_VERIFY_STATUS:-0}"
RUNNER
    chmod +x "$seed/brew-change" "$seed/scripts/release.sh" "$seed/tests/run-deterministic.sh"
    git -C "$seed" add .
    git -C "$seed" commit --quiet -m "fixture"
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push --quiet -u origin main
    git clone --quiet "$REMOTE" "$REPO"
    git -C "$REPO" config user.name "Release Test"
    git -C "$REPO" config user.email "release-test@example.invalid"

    : > "$HARNESS_LOG"
    cat > "$HARNESS_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf 'gh' >> "$RELEASE_TEST_COMMAND_LOG"
printf '\t%s' "$@" >> "$RELEASE_TEST_COMMAND_LOG"
printf '\n' >> "$RELEASE_TEST_COMMAND_LOG"
exit 0
FAKE_GH
    cat > "$HARNESS_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf 'curl' >> "$RELEASE_TEST_COMMAND_LOG"
printf '\t%s' "$@" >> "$RELEASE_TEST_COMMAND_LOG"
printf '\n' >> "$RELEASE_TEST_COMMAND_LOG"
output=""
while (( $# )); do
    case "$1" in
        --output) output="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -z "$output" ]] || printf 'fixture archive' > "$output"
exit "${FAKE_CURL_STATUS:-0}"
FAKE_CURL
    chmod +x "$HARNESS_BIN/gh" "$HARNESS_BIN/curl"
}

run_release() {
    local version="$1"
    RUN_STATUS=0
    RUN_OUTPUT=$(cd "$REPO" && \
        RELEASE_TEST_COMMAND_LOG="$HARNESS_LOG" \
        PATH="$HARNESS_BIN:$PATH" \
        bash scripts/release.sh "$version" 2>&1) || RUN_STATUS=$?
}

echo "=== Release Preflight Tests ==="

new_fixture
printf '\ndirty\n' >> "$REPO/brew-change"
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "dirty tree" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "dirty tree explains failure" "working tree is dirty" "$RUN_OUTPUT"

new_fixture
git -C "$REPO" checkout --quiet -b feature/test
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "wrong branch" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "wrong branch explains failure" "expected 'main'" "$RUN_OUTPUT"

new_fixture
git -C "$REPO" branch --unset-upstream
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "missing upstream" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "missing upstream explains failure" "upstream" "$RUN_OUTPUT"

new_fixture
printf '\nahead\n' >> "$REPO/brew-change"
git -C "$REPO" add brew-change
git -C "$REPO" commit --quiet -m "ahead"
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "ahead branch" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "ahead branch explains failure" "not synchronized" "$RUN_OUTPUT"

new_fixture
behind_clone="$TEST_ROOT/behind-seed"
git clone --quiet "$REMOTE" "$behind_clone"
git -C "$behind_clone" config user.name "Release Test"
git -C "$behind_clone" config user.email "release-test@example.invalid"
printf '\nbehind\n' >> "$behind_clone/brew-change"
git -C "$behind_clone" add brew-change
git -C "$behind_clone" commit --quiet -m "behind"
git -C "$behind_clone" push --quiet origin main
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "behind branch" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "behind branch explains failure" "not synchronized" "$RUN_OUTPUT"

for invalid_version in "v1.1.0" "1.1" "1.1.0-beta" "01.1.0"; do
    new_fixture
    snapshot_state
    run_release "$invalid_version"
    assert_failed_without_mutation "invalid version $invalid_version" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
    assert_contains "invalid version explains failure" "SemVer" "$RUN_OUTPUT"
done

new_fixture
git -C "$REPO" tag v1.1.0
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "existing local tag" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "local tag explains failure" "local tag" "$RUN_OUTPUT"

new_fixture
git -C "$REPO" tag v1.1.0
git -C "$REPO" push --quiet origin v1.1.0
git -C "$REPO" tag --delete v1.1.0 >/dev/null
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "existing remote tag" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "remote tag explains failure" "remote tag" "$RUN_OUTPUT"

new_fixture
missing_bin="$TEST_ROOT/missing-bin"
mkdir -p "$missing_bin"
for tool in bash dirname git curl shasum tar sed awk grep cut mktemp; do
    tool_path=$(command -v "$tool")
    ln -s "$tool_path" "$missing_bin/$tool"
done
snapshot_state
RUN_STATUS=0
RUN_OUTPUT=$(cd "$REPO" && PATH="$missing_bin" "$missing_bin/bash" scripts/release.sh 1.1.0 2>&1) || RUN_STATUS=$?
assert_failed_without_mutation "missing gh" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "missing tool explains failure" "missing required tool: gh" "$RUN_OUTPUT"

new_fixture
snapshot_state
FAKE_VERIFY_STATUS=1 run_release "1.1.0"
assert_failed_without_mutation "failed verification" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "verification explains failure" "deterministic verification failed" "$RUN_OUTPUT"

new_fixture
snapshot_state
run_release "1.1.0"
assert_failed_without_mutation "invalid archive" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "invalid archive explains failure" "archive download was invalid" "$RUN_OUTPUT"

new_fixture
snapshot_state
FAKE_CURL_STATUS=22 run_release "1.1.0"
assert_failed_without_mutation "HTTP failure" "$SNAPSHOT_HEAD" "$SNAPSHOT_TAGS" "$SNAPSHOT_REFS"
assert_contains "HTTP failure explains failure" "archive download failed" "$RUN_OUTPUT"
curl_argv=$(grep '^curl' "$HARNESS_LOG" || true)
assert_contains "HTTP preflight uses curl --fail" $'\t--fail' "$curl_argv"
assert_contains "HTTP preflight uses curl --location" $'\t--location' "$curl_argv"

printf '\nRelease preflight assertions: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
