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

# Export last assessment for external tools (e.g., brew-usage)
brew-change export

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

A few pointers into the docs — the README stays lean on purpose:

- **The trusted update workflow** — upgrade behavior, the `-b` verdict, first-run behavior, dashboard defaults, evidence caching & re-entry, accessibility modes: [docs/trusted-update.md](docs/trusted-update.md)
- **Assessment export** — the versioned JSON feed for external tools (brew-usage): [docs/assessment-export.md](docs/assessment-export.md)
- **Configuration** — every environment variable in one reference: [docs/configuration.md](docs/configuration.md)

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

- **v1.20.0**: Negative probe cache — immediate re-runs skip concluded no-notes probe chains (10-minute memo)
- **v1.19.0**: SELECT arrow-key navigation with stage-all (`a`); single action line; Enter no longer silently quits when nothing is preselected; subtractive post-upgrade refresh (no more full re-probe after upgrading)
- **v1.18.x**: `-b` verdict summary (attention split into breaking changes and major transitions, all-clear that never claims safe); pattern-precision fixes; npm→GitHub notes fallback; assessment export in CI
- **v1.15.0–v1.17.0**: Trusted-update workflow waves — first-run guidance, plain-language remediation, accessibility modes, evidence cache & re-entry, `brew-change export`

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
