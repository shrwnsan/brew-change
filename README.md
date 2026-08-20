# brew-change

Make informed updates - see what changed in your Homebrew packages

## 🚀 Quick Start

```bash
# Show simple outdated list (like brew outdated)
brew-change

# Show outdated packages with version information
brew-change -v

# Show detailed changelog for specific package
brew-change node

# Show detailed changelogs for all outdated packages in parallel
brew-change -a

# Show changelogs with interactive upgrade prompt
brew-change -u

# Preview the no-signal package plan without executing it
brew-change -u --dry-run

# Highlight packages with breaking changes (-b implies -a)
brew-change -b

# Show version information
brew-change --version

# Show help
brew-change --help
```

## 🎯 Who This Is For

- **Developers** who want to understand package changes before updating
- **DevOps Engineers** managing production dependencies
- **Security-Conscious Users** checking for vulnerability fixes
- **Power Users** who like knowing what's changing in their tools
- **Curious Learners** exploring how their tools evolve

## ✨ Key Features

- **Smart Package Detection**: GitHub, npm, third-party taps, hybrid packages, and more
- **Parallel Processing**: Handles multiple packages simultaneously (45-50s for 13 packages)
- **Honest Update Assessment**: Separates packages into attention, no-signal, and unknown instead of claiming an update is safe
- **Preview Before Mutation**: Shows Homebrew's `upgrade --dry-run` output, warns about dependency/dependent effects, and asks for final confirmation
- **TTY-Aware Progress**: Animates interactive work while keeping piped output deterministic
- **Breaking Changes Detection**: Highlights packages with breaking-change evidence using `-b`
- **Rich Release Info**: Full changelogs, commit history, and helpful links
- **Revision Support**: Advanced handling of Homebrew revision numbers
- **Performance Optimized**: 75% faster than original with intelligent caching

### Upgrade behavior

`brew-change -u` defaults only to packages whose fresh release evidence produced no risk signal. Packages marked **attention** or **unknown** are never bulk-selected. Before any upgrade, brew-change previews the exact named package list with Homebrew, then asks for immediate confirmation. Homebrew can still act on dependencies or dependents shown in that preview.

In a pipe or other non-interactive environment, brew-change prints guidance and never starts an upgrade.

### First run

On an interactive `brew-change -u` run you will see a one-line hint on stderr: brew-change checks your outdated packages, shows what changed for each (`r` review), and only upgrades what you explicitly confirm — nothing runs until you approve the exact plan. No account or configuration is needed, and quitting (`q`) changes nothing. The hint is never printed in pipes or scripts, and it is not stored anywhere.

### Changed defaults (v1.14.0)

`brew-change -u` on a terminal now runs the interactive dashboard by default instead of the plain prompt flow: review each package's evidence provenance read-only (`r`), stage an explicit per-package selection (`s`), upgrade the no-signal set (`u`/Enter), or quit (`q`).

```bash
brew-change -u          # dashboard is now the default on a terminal
brew-change -u --plain  # previous prompt flow (or BREW_CHANGE_PLAIN=1)
```

Escape hatches, in precedence order (`--plain` flag > `BREW_CHANGE_PLAIN=1` environment variable > default dashboard):

- `--plain` (or `BREW_CHANGE_PLAIN=1`, e.g. in an rc file) restores the previous prompt flow.
- `--dashboard` and `BREW_CHANGE_DASHBOARD=1`, the pre-v1.14.0 opt-ins, are accepted as documented no-ops.

Piped or redirected runs are unchanged: plain deterministic output, no prompts, no upgrades, and the view flags do not switch views.

### Accessibility

Output meaning never depends on color or emoji: text labels (like `[breaking]` and the dashboard group headers) always carry the full classification, and any emoji is strictly additive decoration on a terminal. The base render — piped output, `NO_COLOR=1`, screen readers, copy-paste — is identical by construction.

```bash
export NO_COLOR=1                      # no-color convention: also suppresses decorative emoji
export BREW_CHANGE_NO_EMOJI=1          # explicit no-emoji opt-out (labels unchanged)
export BREW_CHANGE_STATIC_PROGRESS=1   # plain "stage n/N" progress line, no spinner animation
```

`BREW_CHANGE_STATIC_PROGRESS=1` keeps the progress lifecycle (TTY-only drawing, cleared line before the dashboard, restored terminal state) but replaces the animated spinner with a static line that updates only when the count changes.

## 📦 Installation

### Quick Install
```bash
# Install directly via Homebrew tap (dependencies included)
brew install shrwnsan/tap/brew-change

# Verify installation
brew-change --version
```

### Dependencies
- **Homebrew**: Core package manager
- **jq**: JSON parsing and processing
- **curl**: HTTP requests with retry logic
- **bash**: Version 4.0+ for modern shell features

### Platform Support

brew-change works seamlessly across all platforms where Homebrew is available:

| Platform | Homebrew Path | Status |
|----------|---------------|--------|
| **macOS (Intel)** | `/usr/local/bin/brew` | ✅ Fully supported |
| **macOS (Apple Silicon)** | `/opt/homebrew/bin/brew` | ✅ Fully supported |
| **Linux** | Detected with `brew --prefix` | ✅ Fully supported |
| **WSL (Windows Subsystem for Linux)** | Detected with `brew --prefix` | ✅ Fully supported |

The script automatically detects the correct library path using `brew --prefix`, ensuring compatibility across all Homebrew installations.

## 🎯 Package Types

brew-change intelligently handles different package sources:
- **GitHub packages**: Full release notes with commit history
- **npm packages**: Registry information with release dates
- **Hybrid packages**: npm distribution + GitHub development
- **Third-party taps**: Community tap support (charmbracelet, oven-sh/bun)
- **Modern CLI tools**: Documentation-repository pattern (alpha)

→ **See detailed package type examples**: [Package Types Documentation](docs/package-types.md)
→ **Full documentation index**: [All Documentation](docs/README.md)

## 🐛 Troubleshooting

**"Package not found" errors**
```bash
brew info package-name    # Check if package exists
brew search package-name  # Search for similar packages
```

**Slow performance**
```bash
brew-change -a            # Auto-adjusts if system is busy
export BREW_CHANGE_JOBS=2 # Reduce parallel jobs manually
```

**Network timeouts**
```bash
curl -I https://api.github.com  # Check connectivity
```

**Clear cache**
```bash
rm -rf ~/.cache/brew-change/*
```

## 📈 Recent Updates

- **Unreleased trusted-update foundation**: Honest three-state assessments, canonical cask identities, exact package previews, final confirmation, deterministic tests, signal-safe terminal cleanup, and a strict evidence URL policy
- **v1.11.0–v1.11.5**: Made `-u` interactive by default, added `--dry-run`, and refined prompt/spinner behavior
- **v1.10.0–v1.10.1**: Improved interactive upgrade UX and ensured Homebrew receives `--yes`
- **v1.9.0–v1.9.2**: Removed prompt timeouts and simplified prompt formatting
- **v1.8.0–v1.8.8**: Added selective upgrades and iteratively hardened `/dev/tty` prompt handling and animation
- **v1.7.0**: Applied the post-refactor code-review fixes
- **v1.6.0**: Added positional multi-package support

→ **Full changelog**: [CHANGELOG.md](CHANGELOG.md)

## 🔗 Related Projects

- [Homebrew](https://brew.sh/) - The missing package manager for macOS
- [jq](https://stedolan.github.io/jq/) - Command-line JSON processor
- [GitHub CLI](https://cli.github.com/) - Official GitHub command-line tool

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

**Looking for more?**
- [📚 All Documentation](docs/README.md) | [🎯 Quick Start](#-quick-start) | [Testing Suite](tests/README.md) | [Contributing](CONTRIBUTING.md)
