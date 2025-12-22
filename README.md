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
- **Rich Release Info**: Full changelogs, commit history, and helpful links
- **Revision Support**: Advanced handling of Homebrew revision numbers
- **Performance Optimized**: 75% faster than original with intelligent caching

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

- **v1.4.1**: Homebrew installation path detection, --version flag support
- **v1.4.0**: Auto-discovery system for documentation repositories, revision number support
- **v1.3.0**: Fixed parallel processing race conditions, npm+GitHub hybrid support
- **v1.2.0**: Added npm registry integration
- **v1.1.0**: Implemented parallel processing
- **v1.0.0**: Initial release with basic GitHub integration

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