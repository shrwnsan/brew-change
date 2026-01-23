#!/usr/bin/env bash
# Release helper for brew-change
# Creates: git tag → GitHub release → shows SHA256 for homebrew-tap
# Usage: ./scripts/release.sh [version]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

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

echo "📦 Release: $CURRENT_VERSION → $NEW_VERSION"
echo ""

# Step 1: Update version in brew-change
sed -i '' "s/readonly VERSION=\"$CURRENT_VERSION\"/readonly VERSION=\"$NEW_VERSION\"/" brew-change
echo "✓ Updated brew-change version to $NEW_VERSION"

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
echo "✓ Tagged and pushed v$NEW_VERSION"

# Step 5: Create GitHub Release
echo ""
echo "Creating GitHub release..."
RELEASE_NOTES=$(git log $(git describe --tags --abbrev=0 HEAD^)..HEAD --pretty=format:"- %s" | tail -n +2)
gh release create "v$NEW_VERSION" \
  --title "v$NEW_VERSION" \
  --notes "## Changes

$RELEASE_NOTES
"
echo "✓ GitHub release created: https://github.com/shrwnsan/brew-change/releases/tag/v$NEW_VERSION"

# Step 6: Get SHA256 for homebrew-tap
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 homebrew-tap update:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SHA256=$(curl -sL "https://github.com/shrwnsan/brew-change/archive/refs/tags/v$NEW_VERSION.tar.gz" | shasum -a 256 | awk '{print $1}')

# Step 7: Update homebrew-tap formula
TAP_PATH="${TAP_PATH:-$HOME/Developer/personal/homebrew-tap}"
FORMULA_PATH="$TAP_PATH/Formula/brew-change.rb"

if [[ -d "$TAP_PATH" ]]; then
    echo ""
    echo "Updating homebrew-tap formula at $TAP_PATH..."
    cd "$TAP_PATH"

    # Update url
    sed -i '' "s|url \".*v[0-9].*\"|url \"https://github.com/shrwnsan/brew-change/archive/refs/tags/v$NEW_VERSION.tar.gz\"|" "$FORMULA_PATH"

    # Update sha256
    sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" "$FORMULA_PATH"

    # Determine commit type based on changes since last release
    cd "$SCRIPT_DIR"
    if git log $(git describe --tags --abbrev=0 HEAD^)..HEAD --pretty=format:"%s" | grep -qiE 'fix|bug'; then
        COMMIT_TYPE="fix"
    else
        COMMIT_TYPE="chore"
    fi

    # Commit and push to tap
    cd "$TAP_PATH"
    git add "$FORMULA_PATH"
    git commit -m "$COMMIT_TYPE(brew-change): bump to version $NEW_VERSION" \
        --author="github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" \
        -m ""
    git push
    echo "✓ homebrew-tap formula updated and pushed"
else
    echo "⚠ homebrew-tap not found at $TAP_PATH"
    echo "  Manual update needed:"
    cat <<EOF

Update: $FORMULA_PATH

  url "https://github.com/shrwnsan/brew-change/archive/refs/tags/v$NEW_VERSION.tar.gz"
  sha256 "$SHA256"

EOF
fi
