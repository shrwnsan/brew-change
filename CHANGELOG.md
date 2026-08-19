# Changelog

All notable changes to brew-change are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- The v1.14.0 output-view transition notice (the one-release stderr line printed when the dashboard ran from the new default) has been removed as planned; `--plain` / `BREW_CHANGE_PLAIN=1` still restore the previous prompt flow.

## [1.14.0] - 2026-08-18

### Changed
- **Default view change**: interactive `brew-change -u` runs now use the dashboard by default (was the simple prompt). Use `--plain` or `BREW_CHANGE_PLAIN=1` to restore the previous view; a one-time notice is printed to stderr this release. Piped output and bare `brew-change` are unchanged.
- Dashboard rows no longer repeat their group's classification label; packages whose status is `unavailable` show no per-row token (actionable statuses like `rate-limited` still do).
- The parallel completion summary prints on a fresh line after the progress indicator clears.

### Fixed
- Hardened best-effort function tails against the launcher's error-exit mode, eliminating a class of silent exits (two instances of which previously reached users).

## [1.13.3] - 2026-08-18

### Changed
- Dashboard rows carry only what differs within a group: attention rows show matched signal tokens, no-signal rows show no reason, unknown rows show the bare retrieval status (e.g. `unavailable`). The Review detail view keeps full sentences.
- The review list is grouped like the dashboard (attention first) with continuous numbering and the same token language.

## [1.13.2] - 2026-08-18

### Fixed
- The inactivity countdown now clears the full prompt line before redrawing, removing leftover fragments at timeout.
- Packages whose upstream has no release notes now record `unavailable` evidence status (with the review URL) instead of `missing`.
- The launcher lib-resolution regression test now exercises the real code path.

### Changed
- `--dashboard` runs no longer print inline changelog dumps; use Review in the dashboard for details. Plain `-u` output is unchanged.

## [1.13.1] - 2026-08-18

### Fixed
- `-u` runs no longer exit silently after "Processing changelog..." once the cross-run brew info cache is populated: a false conditional at the end of the cache-invalidation routine returned failure, which the launcher's error-exit mode treated as fatal.

## [1.13.0] - 2026-08-18

### Added
- **Interactive dashboard (opt-in)**: `brew-change -u --dashboard` (or `BREW_CHANGE_DASHBOARD=1`) renders a compact grouped view of outdated packages — review evidence provenance per package, explicitly select packages (no-signal preselected; attention and unknown never preselected), and upgrade through the existing preview-then-confirm boundary. Ignored when output is piped.
- Normalized assessment records: pipeline stages communicate through a structured JSONL record per package; classifications come from a pure, fixture-tested engine.

### Changed
- `brew info` results are memoized per run and cached across runs (5-minute TTL with outdated-driven invalidation) — multi-package runs no longer call Homebrew redundantly and repeat runs are substantially faster.
- The `-u` flow shows a single animated progress line while evidence is gathered; workers no longer write to the terminal.

### Fixed
- Running from a repository checkout now uses the checkout's own libraries instead of a previously installed release's.

## [1.12.1] - 2026-08-17

### Fixed
- Drain the rest of the typed line after the single-key upgrade-mode prompt so a stale Enter can no longer auto-decline the final y/N confirmation.

### Changed
- The 5-minute prompt inactivity timeout now announces itself: the final 10 seconds count down and the exit states its reason instead of exiting silently. Overridable via `BREW_CHANGE_PROMPT_TIMEOUT`.

## [1.12.0] - 2026-08-17

### Changed
- **Trusted update assessment**: Replace binary safe/breaking language with attention, no-signal, and unknown. Attention and unknown packages are never bulk/default selected.
- **Upgrade execution**: Preview the exact named package plan with Homebrew, warn about dependencies/dependents, then require immediate final confirmation before passing the same package arguments to the mutation command.
- **Non-interactive behavior**: Piped runs remain deterministic and never start an upgrade.

### Added
- Deterministic command, URL-policy, signal, terminal, assessment, upgrade-flow, and release-preflight test coverage.
- Linux/macOS CI with Bash 4+, jq, and ShellCheck.
- Release preflight for clean/synchronized state, SemVer/tag/tool validation, deterministic verification, and HTTP download checks before publication.

### Fixed
- Canonical cask token handling across inventory and upgrade paths.
- Signal exit statuses, child cleanup, temporary-file cleanup, and terminal restoration.
- Evidence requests now use an exact HTTPS host policy, bounded validated redirects, and per-hop GitHub token confinement.

## [1.11.5] - 2026-07-09

### Fixed
- Clear the final spinner frame before redrawing the upgrade prompt.

## [1.11.4] - 2026-07-09

### Fixed
- Run prompt animation in a background subshell so blocking input does not freeze it.

## [1.11.3] - 2026-07-08

### Fixed
- Move terminal setup out of the spinner poll loop.

## [1.11.2] - 2026-07-08

### Fixed
- Simplify prompt text and correct prompt variable scoping.

## [1.11.1] - 2026-07-08

### Fixed
- Add a discoverable quit action and improve Enter-default handling.

## [1.11.0] - 2026-07-08

### Added
- Make `-u` interactive by default and add `-n` / `--dry-run` preview mode.

### Removed
- Remove the `BREW_CHANGE_UPGRADE_INTERACTIVE` opt-in environment variable.

## [1.10.0–1.10.1] - 2026-07-07

### Changed
- Improve interactive upgrade UX and pass `--yes` to the Homebrew upgrade command.

## [1.9.0–1.9.2] - 2026-07-03

### Changed
- Remove interactive prompt timeouts, redundant confirmation, and noisy prompt formatting.

## [1.8.0–1.8.8] - 2026-06-28 to 2026-07-03

### Added
- Add selective interactive upgrades with `-u`.

### Fixed
- Harden `/dev/tty` prompt input, cancellation, and spinner timing through the 1.8 patch series.

## [1.7.0] - 2026-04-02

### Changed
- Apply eleven post-refactor code-review corrections.

## [1.6.0] - 2026-04-02

### Added
- Accept multiple positional package arguments.

## [1.5.5] - 2026-01-04

### Fixed
- **Cask detection**: Use `.token` field instead of `.name` for cask identification
- Fixes casks not being detected due to Homebrew JSON API v2 using different field types
- Cask `.name` is an array while `.token` is the install name string

## [1.5.4] - 2026-01-04

### Added
- **Clear status display**: Show `[not installed]` for uninstalled packages instead of `unknown`
- Makes package status immediately clear to users when querying uninstalled packages

### Fixed
- **Output formatting**: Removed inconsistent blank lines in package output
- Cleaner, more consistent visual presentation across all package queries

### Changed
- Removed Docker test infrastructure (simplified test setup)

## [1.5.3] - 2025-12-31

### Fixed
- Visual separation in verbose mode by adding blank line before package output
- Improves readability when using `-a`/`--all` or `-b`/`--identify-breaking` flags
- Each package output now has a preceding newline for better visual distinction

## [1.5.2] - 2025-12-31

### Fixed
- **Up-to-date message clarity**: Split generic message into two distinct cases
  - Show "Already up to date at version X" when package is current
  - Show "Version information unavailable" when versions are actually missing

## [1.5.1] - 2025-12-31

### Fixed
- **Generic tap pattern handling**: Packages from taps using the "user/tap" format (e.g., shrwnsan/tap) are now properly detected
- Homebrew stores these taps as "user/homebrew-tap" but the code was only removing the slash, resulting in incorrect path resolution
- Added generic pattern match to handle all */tap taps correctly

## [1.5.0] - 2025-12-31

### Added
- **Breaking Changes Detection**: New `-b` / `--identify-breaking` flag to highlight packages with breaking changes
  - Detects common patterns: "BREAKING", "deprecated", "removed", "incompatible", "not backward compatible"
  - Shows ⚠️ emoji indicator next to packages with breaking changes
  - Comprehensive test suite with 24 test cases covering various release note formats
- Comprehensive documentation with examples and architecture overview
- Performance benchmarks and optimization details
- Docker testing environment design (planned)

### Changed
- Improved error messages and user feedback
- Enhanced debugging capabilities with environment variables

## [1.4.1] - 2025-12-22

### Fixed
- **Critical**: Homebrew installation path detection for lib files
- Script now properly locates library files when installed via brew install
- Maintains backward compatibility for local script usage

### Added
- Support for `--version` flag to display version information
- Enhanced help text with version flag documentation

## [1.3.0] - 2025-11-26

### Fixed
- **Major**: Parallel processing race conditions that caused content mixing between packages
- **Major**: npm scoped package extraction for packages like `@google/gemini-cli`
- **Major**: URL validation to allow @ symbols in npm URLs while maintaining security
- **Critical**: Incorrect hardcoded GitHub repository mapping for claude-code
- **Performance**: 13 packages now process in ~51 seconds vs 2+ minutes before
- **Display**: Added proper package separators and eliminated output bleeding

### Added
- Hybrid package support for npm+GitHub packages
- Intelligent fallback from npm to GitHub when homepage points to GitHub
- Enhanced security validation for npm scoped packages
- Proper temporary file handling for parallel processing

### Performance
- **Speed**: 75% improvement in processing time for multiple packages
- **Memory**: Reduced memory usage through better process management
- **Network**: Optimized API calls with intelligent caching

### Changed
- Refactored parallel processing logic for race condition prevention
- Improved npm registry integration with better error handling
- Enhanced package type detection for hybrid scenarios

## [1.2.0] - 2025-11-25

### Added
- npm registry integration for Node.js packages
- Support for scoped npm packages (@namespace/package)
- Enhanced release date extraction from npm metadata
- Fallback mechanisms for npm packages without GitHub repositories

### Fixed
- npm package name extraction for complex URL patterns
- Version comparison logic for npm packages
- Display formatting for npm-specific information

## [1.1.0] - 2025-11-24

### Added
- Parallel processing support for multiple packages
- System resource monitoring and adaptive job limiting
- Temporary file management for clean output separation
- Progress indicators for long-running operations

### Performance
- Parallel job execution with configurable limits
- Intelligent load-based job adjustment
- Memory usage optimization for large package sets

## [1.0.0] - 2025-11-23

### Added
- Initial release with core functionality
- GitHub API integration for release notes
- Homebrew package detection and version comparison
- Multiple package type support (GitHub, non-GitHub)
- Basic error handling and fallback mechanisms
- Command-line interface with help system

### Features
- Smart repository extraction from package URLs
- Release notes formatting and display
- Version information with relative dates
- Homepage fallback for non-GitHub packages
- Configurable retry logic for network requests

---

## Version Statistics

| Version | Release Date | Changes | Key Features |
|---------|---------------|---------|--------------|
| 1.5.4 | 2026-01-04 | 1 addition, 1 fix, 1 change | Clear status display for uninstalled packages |
| 1.5.3 | 2025-12-31 | 1 fix | UX improvement for verbose mode output formatting |
| 1.5.2 | 2025-12-31 | 1 fix | Up-to-date message clarity |
| 1.5.1 | 2025-12-31 | 1 fix | Generic tap pattern handling for */tap taps |
| 1.5.0 | 2025-12-31 | 1 addition, 2 changes | Breaking changes detection with -b flag |
| 1.4.1 | 2025-12-22 | 1 fix, 2 additions | Homebrew installation path detection, --version flag |
| 1.3.0 | 2025-11-26 | 8 fixes, 5 additions, 3 changes | Parallel processing, npm+GitHub hybrid support |
| 1.2.0 | 2025-11-25 | 4 additions, 3 fixes | npm registry integration |
| 1.1.0 | 2025-11-24 | 4 additions, 1 performance improvement | Parallel processing |
| 1.0.0 | 2025-11-23 | Initial release | Core functionality |

## Migration Guide

### From 1.2.x to 1.3.x
- No breaking changes
- Performance improvements are automatic
- Enhanced error handling may show different messages for edge cases

### From 1.1.x to 1.2.x
- npm package detection is now automatic
- No configuration required for scoped packages

### From 1.0.x to 1.1.x
- Parallel processing is enabled by default
- Use `BREW_CHANGE_JOBS` environment variable to control concurrency

## Technical Debt

### Future Improvements
- [ ] Add local caching for GitHub API responses
- [ ] Implement configuration file support
- [ ] Add machine-readable output formats (JSON)
- [ ] Enhance npm package metadata extraction
- [ ] Add more package manager support (pip, cargo, etc.)

### Known Limitations
- Requires internet connection for release notes
- GitHub API rate limits may affect large-scale usage
- Some package URLs may not be automatically detected
- Non-GitHub release notes extraction is limited

## Performance Benchmarks

### Version 1.3.0
- **13 packages**: 51.3 seconds (parallel)
- **Single package**: 3.9 seconds average
- **Memory usage**: ~15MB peak
- **Success rate**: 100% (13/13 packages)

### Version 1.2.x
- **13 packages**: 65+ seconds (sequential)
- **Single package**: 5.2 seconds average
- **Memory usage**: ~8MB peak
- **Success rate**: 85% (11/13 packages)

### Version 1.0.x
- **13 packages**: 120+ seconds (with timeouts)
- **Single package**: 9.1 seconds average
- **Memory usage**: ~12MB peak
- **Success rate**: 70% (9/13 packages)

## Security Notes

### Fixed Vulnerabilities
- **URL injection**: Prevented malicious URL patterns in version 1.3.0
- **Command injection**: Enhanced input sanitization in version 1.2.0
- **Race conditions**: Eliminated process interference in version 1.3.0

### Security Best Practices
- All URLs are validated before processing
- User inputs are sanitized and escaped
- Network requests have configurable timeouts
- No arbitrary code execution in any context
