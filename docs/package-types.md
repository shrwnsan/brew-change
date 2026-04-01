# Package Type Support

brew-change intelligently detects and handles different types of packages, providing appropriate release information for each.

## GitHub Packages

Packages distributed from GitHub repositories with full release notes.

### Example: node
```bash
brew-change node
# 📦 node: 25.2.1 → 26.1.0 (5 days ago)
# 📋 Release 26.1.0
# - V8: updated 13.4.114.21
# - NODE_MODULE_VERSION: updated 135
# - deps: V8 updated to 13.4.114.21
#
# → Full Changelog: https://github.com/nodejs/node/compare/v25.2.1...v26.1.0
# 🔗 Release: https://github.com/nodejs/node/releases/tag/v26.1.0
```

### With Breaking Changes Detection
```bash
brew-change -b node
# 📦 node: 25.2.1 → 26.1.0 (5 days ago) ⚠️
# 📋 Release 26.1.0
# ## Breaking Changes
# - NODE_MODULE_VERSION: updated 135 (requires native modules recompilation)
# - deps: V8 updated to 13.4.114.21
#
# → Full Changelog: https://github.com/nodejs/node/compare/v25.2.1...v26.1.0
# 🔗 Release: https://github.com/nodejs/node/releases/tag/v26.1.0
```

### Features:
- Full release notes with commit history
- Direct links to releases and comparisons
- Contributor information and commit details
- Comprehensive changelog generation
- Breaking changes detection with ⚠️ indicator (when using `-b` flag)

## npm Registry Packages

Pure npm packages with registry information.

### Example: vercel-cli
```bash
brew-change vercel-cli
# 📦 vercel-cli: 48.10.6 → 48.10.10 (4 days ago)
# 📋 Release 48.10.10
# Release 48.10.10 published to npm registry
#
# 📋 Release: https://www.npmjs.com/package/vercel-cli/v/48.10.10
```

### Features:
- npm registry metadata
- Release dates and version information
- Direct links to npm package pages
- Support for scoped packages

## Hybrid npm+GitHub Packages

Packages distributed via npm but developed on GitHub.

### Example: gemini-cli
```bash
brew-change gemini-cli
# 📦 gemini-cli: 0.17.0 → 0.17.1 (3 days ago)
# 📋 Release 0.17.1
# - fix(patch): cherry-pick 5e218a5 (Commit#5e218a5) by @gemini-cli-robot in (PR#13625)
#
# → Full Changelog: https://github.com/google-gemini/gemini-cli/compare/v0.17.0...v0.17.1
# 🔗 Release: https://github.com/google-gemini/gemini-cli/releases/tag/v0.17.1
```

### Features:
- GitHub release notes with npm version information
- Commit history and pull request references
- Both npm and GitHub links provided
- Best of both worlds: npm distribution + GitHub development

## Third-Party Tap Packages

Support for packages from community taps with automatic tap detection.

### Example: crush (from charmbracelet/tap)
```bash
brew-change crush
# 📦 crush: 0.18.4 → 0.18.5 (4 hours ago)
# 📋 Release 0.18.5
# - 🎉 Enhanced validation output options
# - 🐛 Fixed crash on invalid JSON input
# - ⚡ Performance improvements for large datasets
#
# 🔗 Release: https://github.com/charmbracelet/crush/releases/tag/0.18.5
```

### Supported Taps:
- oven-sh/bun (Bun runtime)
- charmbracelet/tap (CLI tools)
- sst/tap (SST framework)
- Any other community tap with GitHub integration

### Features:
- Automatic tap detection and labeling
- Full GitHub integration for tap packages
- Clear indication of package source
- Seamless handling of third-party packages

## Documentation-Repository Pattern (Alpha)

Modern CLI tools with external binary distribution but GitHub documentation.

### Enable with Environment Variable:
```bash
export BREW_CHANGE_DOCS_REPO=1
```

### Example: claude-code
```bash
brew-change claude-code
# 📦 claude-code: 2.0.72 → 2.0.75 (no release date)
# 📋 Release Notes from Documentation Repository:
# ## 2.0.75
# - Fixed issue with excessive iTerm notifications
# - Improved fuzzy matching for file suggestions
# - Better handling of large file uploads
#
# → Full changelog: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
#
# 🌐 Learn more: https://github.com/anthropics/claude-code/
```

### Supported Tools:
- claude-code (Anthropic)
- Google Cloud CLI
- AWS CLI v2
- Other modern CLI tools with external distribution

### Features:
- Searches GitHub for documentation repositories
- Extracts changelogs from README/CHANGELOG files
- Provides relevant links and information
- Alpha feature - experimental but improving

## Non-GitHub Packages

Packages from other sources with homepage links.

### Example: some-package
```bash
brew-change some-package
# 📦 some-package: 1.0.0 → 1.1.0 (2 days ago)
# 🔍 Searching for release notes from downloads.example.com...
# 📋 Release Notes:
# Version 1.1.0 - Bug fixes and performance improvements
#
# 🌐 Learn more: https://downloads.example.com/releases/v1.1.0
```

### Sources Supported:
- Custom download sites
- University distributions
- Corporate software portals
- Any HTTP/HTTPS accessible source

### Features:
- Intelligent parsing of download pages
- Fallback to homepage when releases unavailable
- Best-effort release note extraction
- Useful links for more information

## Revision Support

Advanced handling of Homebrew revision numbers.

### Example: packages with revisions
```bash
brew-change some-package
# 📦 some-package: 0.61_1 → 0.62.0 (1 day ago)
# 📋 Release 0.62.0
# - Major version bump with breaking changes
# - Updated dependencies and improved performance
#
# → Full Changelog: https://github.com/example/package/compare/v0.61_1...v0.62.0
```

### Features:
- Proper handling of revision suffixes (_1, _2, etc.)
- Accurate version comparison with revisions
- Clean display of version transitions
- Support for complex version schemes

## @Version Cask Variants

Homebrew supports versioned cask variants using the `@` suffix (e.g., `claude-code` vs `claude-code@latest`). brew-change automatically detects when a user requests a base cask name that isn't installed but has a `@version` variant installed, and redirects accordingly.

### Example: claude-code@latest
```bash
# When claude-code (stable) is not installed but claude-code@latest is:
brew-change claude-code
# Note: 'claude-code' is not installed, but 'claude-code@latest' is.
# Using 'claude-code@latest' instead.
#
# 📦 claude-code@latest: 2.1.89 → latest (installed 11 hours ago)
# No new releases.

# Direct usage also works:
brew-change claude-code@latest
# 📦 claude-code@latest: 2.1.89 → latest (installed 11 hours ago)
# No new releases.
```

### Behavior:
- Passing the exact installed name (e.g., `brew-change claude-code@latest`) works as expected
- Passing the base name (e.g., `brew-change claude-code`) auto-detects the installed `@version` variant
- If the base name IS installed (e.g., `brew-change node`), no redirect occurs
- If neither the base name nor any variant is installed, the normal "not found" path runs