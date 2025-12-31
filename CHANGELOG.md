# Changelog

All notable changes to brew-change are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.3] - 2025-12-31

### Fixed
- Visual separation in verbose mode by adding blank line before package output
- Improves readability when using `-a`/`--all` or `-b`/`--identify-breaking` flags
- Each package output now has a preceding newline for better visual distinction

## [1.5.2] - 2025-12-31

### Fixed
- **Generic tap pattern handling**: Packages from taps using the "user/tap" format (e.g., shrwnsan/tap) are now properly detected
- Homebrew stores these taps as "user/homebrew-tap" but the code was only removing the slash, resulting in incorrect path resolution
- Added generic pattern match to handle all */tap taps correctly
- **Up-to-date message clarity**: Split generic message into two distinct cases
  - Show "Already up to date at version X" when package is current
  - Show "Version information unavailable" when versions are actually missing

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
| 1.5.3 | 2025-12-31 | 1 fix | UX improvement for verbose mode output formatting |
| 1.5.2 | 2025-12-31 | 2 fixes | Generic tap pattern handling, up-to-date message clarity |
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