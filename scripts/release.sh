#!/usr/bin/env bash
# Release helper for brew-change
# Creates: preflight → version bump commit → git tag → push → GitHub release → SHA256 for homebrew-tap
# Usage: ./scripts/release.sh [version]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

REQUIRED_RELEASE_TOOLS=(git gh curl shasum tar sed awk grep cut bash mktemp)
for tool in "${REQUIRED_RELEASE_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "PREFLIGHT FAIL: missing required tool: $tool" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Preflight checks — run before any mutation or publication.
# A failed preflight must create no commit, tag, push, gh release, or remote ref.
# ---------------------------------------------------------------------------

_release_preflight() {
    local new_version="$1"
    local expected_branch="${EXPECTED_RELEASE_BRANCH:-main}"
    local expected_remote="${EXPECTED_RELEASE_REMOTE:-origin}"

    # --- Clean worktree ---
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "PREFLIGHT FAIL: working tree is dirty" >&2
        git status --short >&2
        return 1
    fi

    # --- Current branch ---
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null) || {
        echo "PREFLIGHT FAIL: detached HEAD" >&2
        return 1
    }
    if [[ "$branch" != "$expected_branch" ]]; then
        echo "PREFLIGHT FAIL: on branch '$branch', expected '$expected_branch'" >&2
        return 1
    fi

    # --- Configured expected upstream ---
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || {
        echo "PREFLIGHT FAIL: branch '$branch' has no configured upstream" >&2
        return 1
    }
    if [[ "$upstream" != "${expected_remote}/${expected_branch}" ]]; then
        echo "PREFLIGHT FAIL: upstream is '$upstream', expected '${expected_remote}/${expected_branch}'" >&2
        return 1
    fi

    # --- HEAD synchronized with the remote branch (not a stale tracking ref) ---
    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git ls-remote --heads "$expected_remote" "refs/heads/${expected_branch}" | awk 'NR == 1 { print $1 }')
    if [[ -z "$remote_head" ]]; then
        echo "PREFLIGHT FAIL: cannot resolve ${expected_remote}/${expected_branch}" >&2
        return 1
    fi
    if [[ "$local_head" != "$remote_head" ]]; then
        echo "PREFLIGHT FAIL: HEAD is not synchronized with ${expected_remote}/${expected_branch}" >&2
        return 1
    fi

    # --- Strict X.Y.Z SemVer ---
    local semver_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    if ! [[ "$new_version" =~ $semver_re ]]; then
        echo "PREFLIGHT FAIL: '$new_version' is not strict X.Y.Z SemVer" >&2
        return 1
    fi

    # --- Absent local tag ---
    if git rev-parse "v${new_version}" >/dev/null 2>&1; then
        echo "PREFLIGHT FAIL: local tag v${new_version} already exists" >&2
        return 1
    fi

    # --- Absent remote tag ---
    if git ls-remote --tags "${expected_remote}" "refs/tags/v${new_version}" 2>/dev/null | grep -q "v${new_version}"; then
        echo "PREFLIGHT FAIL: remote tag v${new_version} already exists" >&2
        return 1
    fi

    # --- Successful deterministic test runner ---
    local runner="${SCRIPT_DIR}/tests/run-deterministic.sh"
    if [[ ! -x "$runner" ]]; then
        echo "PREFLIGHT FAIL: runner not found or not executable: $runner" >&2
        return 1
    fi
    "$runner" || {
        echo "PREFLIGHT FAIL: deterministic verification failed" >&2
        return 1
    }

    # --- Successful archive download for the current upstream HEAD ---
    local archive_url="https://github.com/shrwnsan/brew-change/archive/${local_head}.tar.gz"
    local tmp_archive
    tmp_archive=$(mktemp "${TMPDIR:-/tmp}/brew-change-preflight-archive.XXXXXX")
    if ! curl --fail --location --silent --show-error --output "$tmp_archive" "$archive_url"; then
        echo "PREFLIGHT FAIL: archive download failed for HEAD ${local_head}" >&2
        rm -f "$tmp_archive"
        return 1
    fi
    if [[ ! -s "$tmp_archive" ]]; then
        echo "PREFLIGHT FAIL: archive download was empty for HEAD ${local_head}" >&2
        rm -f "$tmp_archive"
        return 1
    fi
    if ! tar -tzf "$tmp_archive" >/dev/null 2>&1; then
        echo "PREFLIGHT FAIL: archive download was invalid for HEAD ${local_head}" >&2
        rm -f "$tmp_archive"
        return 1
    fi
    rm -f "$tmp_archive"

    echo "Preflight checks passed."
    return 0
}

# ---------------------------------------------------------------------------
# Version handling
# ---------------------------------------------------------------------------

# Get current version
CURRENT_VERSION=$(grep '^readonly VERSION=' brew-change | cut -d'"' -f2)

# Determine new version
if [[ -n "${1:-}" ]]; then
    NEW_VERSION="$1"
else
    IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
    patch=$((patch + 1))
    NEW_VERSION="$major.$minor.$patch"
fi

echo "Release: $CURRENT_VERSION -> $NEW_VERSION"
echo ""

# Run preflight before any mutation
_release_preflight "$NEW_VERSION"

# Step 1: Update version in brew-change
sed -i.bak "s/readonly VERSION=\"$CURRENT_VERSION\"/readonly VERSION=\"$NEW_VERSION\"/" brew-change && rm -f brew-change.bak
echo "Updated brew-change version to $NEW_VERSION"

# Step 2: Commit version bump
echo ""
git add brew-change
git commit -m "chore(release): bump version to $NEW_VERSION"

# Step 3: Push to remote
echo ""
git push

# Step 4: Create and push tag
echo ""
git tag "v$NEW_VERSION"
git push origin "v$NEW_VERSION"
echo "Tagged and pushed v$NEW_VERSION"

# Step 5: Create GitHub Release
echo ""
echo "Creating GitHub release..."
PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || git rev-list --max-parents=0 HEAD)
RELEASE_NOTES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" | tail -n +2)
gh release create "v$NEW_VERSION" \
  --title "v$NEW_VERSION" \
  --notes "## Changes

$RELEASE_NOTES
"
echo "GitHub release created: https://github.com/shrwnsan/brew-change/releases/tag/v$NEW_VERSION"

# Step 6: Get SHA256 for homebrew-tap (use curl --fail --location, hash only successful download)
echo ""
echo "=============================================="
echo "homebrew-tap update:"
echo "=============================================="
ARCHIVE_URL="https://github.com/shrwnsan/brew-change/archive/refs/tags/v${NEW_VERSION}.tar.gz"
TMP_ARCHIVE=$(mktemp "${TMPDIR:-/tmp}/brew-change-release-archive.XXXXXX")
cleanup_release_archive() {
    [[ -z "${TMP_ARCHIVE:-}" ]] || rm -f "$TMP_ARCHIVE"
}
trap cleanup_release_archive EXIT
if curl --fail --location --silent --show-error --output "$TMP_ARCHIVE" "$ARCHIVE_URL" \
    && tar -tzf "$TMP_ARCHIVE" >/dev/null 2>&1; then
    SHA256=$(shasum -a 256 "$TMP_ARCHIVE" | awk '{print $1}')
    rm -f "$TMP_ARCHIVE"
    TMP_ARCHIVE=""
else
    echo "ERROR: archive download failed for v${NEW_VERSION}" >&2
    exit 1
fi

# Step 7: Update homebrew-tap formula
TAP_PATH="${TAP_PATH:-$HOME/Developer/personal/homebrew-tap}"
FORMULA_PATH="$TAP_PATH/Formula/brew-change.rb"

if [[ -d "$TAP_PATH" && -f "$FORMULA_PATH" ]]; then
    echo ""
    echo "Updating homebrew-tap formula at $TAP_PATH..."

    # Portable sed in-place: works on macOS and Linux
    sed -i.bak "s|url \".*v[0-9].*\"|url \"https://github.com/shrwnsan/brew-change/archive/refs/tags/v$NEW_VERSION.tar.gz\"|" "$FORMULA_PATH" && rm -f "$FORMULA_PATH.bak"
    sed -i.bak "s/sha256 \".*\"/sha256 \"$SHA256\"/" "$FORMULA_PATH" && rm -f "$FORMULA_PATH.bak"

    # Determine commit type based on changes since last release
    cd "$SCRIPT_DIR"
    PREV_TAG_CHECK=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || git rev-list --max-parents=0 HEAD)
    if git log "${PREV_TAG_CHECK}..HEAD" --pretty=format:"%s" | grep -qiE 'fix|bug'; then
        COMMIT_TYPE="fix"
    else
        COMMIT_TYPE="chore"
    fi

    # Commit and push to tap
    cd "$TAP_PATH"
    git add "$FORMULA_PATH"
    git commit -m "$COMMIT_TYPE(brew-change): bump to version $NEW_VERSION" \
        --author="github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"
    if git push; then
        echo "homebrew-tap formula updated and pushed"
    else
        echo "Failed to push homebrew-tap update"
        exit 1
    fi
else
    echo "homebrew-tap not found at $TAP_PATH"
    echo "  Manual update needed:"
    cat <<EOF

Update: $FORMULA_PATH

  url "https://github.com/shrwnsan/brew-change/archive/refs/tags/v$NEW_VERSION.tar.gz"
  sha256 "$SHA256"

EOF
fi
