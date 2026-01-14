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
cat <<EOF
Update: ~/Developer/personal/homebrew-tap/Formula/brew-change.rb

  url "https://github.com/shrwnsan/brew-change/archive/refs/tags/v$NEW_VERSION.tar.gz"
  sha256 "$SHA256"

EOF
