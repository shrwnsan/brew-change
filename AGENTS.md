# AGENTS.md

<!-- Project Overview -->
brew-change is a Homebrew utility that displays changelog information for outdated packages with enhanced features like parallel processing, GitHub API integration, and support for multiple package types.

<!-- Development Environment -->
## Development Environment

- **Language**: Bash (Shell Script)
- **Platform**: macOS and Linux (with Homebrew)
- **Testing**: Both local and Docker-based testing environments
- **Dependencies**: bash, curl, jq, git, homebrew

## Setup Commands

```bash
# Clone and set up
git clone https://github.com/shrwnsan/brew-change.git
cd brew-change

# Make executable
chmod +x brew-change

# Test locally
./brew-change --help

# Run comprehensive tests
./tests/test-brew-change-local.sh
```

## Testing

### Local Testing
```bash
# Quick validation
./tests/test-brew-change-local.sh

# Run specific test
./tests/test-brew-change-local.sh
# Choose option 11 for comprehensive test suite
```

### Docker Testing
```bash
# Full Docker test suite
./tests/test-brew-change-docker.sh

# Interactive menu for specific tests
./tests/test-brew-change-docker.sh
# Choose option 3 for interactive menu
```

## Code Style

- **Shell Compatibility**: POSIX bash with modern features
- **Modular Architecture**: Functions separated into library files in `lib/`
- **Error Handling**: Use `set -euo pipefail` for robust error handling
- **Documentation**: Comments for complex logic, especially for API interactions

## Project Structure

```
brew-change/
├── brew-change                    # Main entry point and CLI interface
├── scripts/
│   └── release.sh                # Release automation helper
└── lib/
    ├── brew-change-config.sh    # Configuration constants and environment variables
    ├── brew-change-utils.sh     # Core utility functions (URL validation, caching, etc.)
    ├── brew-change-github.sh    # GitHub API integration and release note fetching
    ├── brew-change-npm.sh       # npm registry integration for Node.js packages
    ├── brew-change-brew.sh      # Homebrew integration and package detection
    ├── brew-change-non-github.sh # Non-GitHub package fallback handling
    ├── brew-change-display.sh   # Output formatting and display logic
    └── brew-change-parallel.sh  # Parallel processing with race condition prevention
```

## Key Features to Understand

1. **Package Type Detection**: Automatically determines if packages are from GitHub, npm, or other sources
2. **Parallel Processing**: Uses background processes with proper synchronization
3. **API Rate Limiting**: Respects GitHub API limits with configurable delays
4. **Fallback Handling**: Graceful degradation when APIs are unavailable
5. **Caching**: Intelligent caching to reduce API calls

## Security Considerations

- **Input Sanitization**: All package names and URLs are validated
- **Network Timeouts**: Configurable timeouts for all network requests
- **No Arbitrary Execution**: Avoids eval/exec with user input
- **API Rate Limits**: Built-in protection against API abuse

## Performance Guidelines

- Use parallel processing for multiple packages (`-a` flag)
- Respect API rate limits between requests
- Cache responses where appropriate
- Handle network failures gracefully with retries

## AI Attribution

This project uses AI assistance for development following best practices:

### Code Contributions
Code generated with AI assistance includes attribution:
```
Co-Authored-By: Claude <noreply@anthropic.com>
```

### GitHub Interactions
AI-generated content includes attribution:
```
🤖 Generated with [Claude Code](https://claude.ai/code) - [MODEL_NAME]
```

### Human Oversight
- All contributions are reviewed and approved by human maintainer
- Architectural decisions are made by project maintainer (shrwnsan)
- Code quality and security are verified before merging

## When Making Changes

1. **Test Locally**: Always run `./tests/test-brew-change-local.sh`
2. **Docker Test**: Use `./tests/test-brew-change-docker.sh` for isolated testing
3. **Check Dependencies**: Ensure all required tools are available
4. **Verify Compatibility**: Test on both macOS and Linux if possible
5. **Update Docs**: Keep documentation aligned with code changes

## Release Process

Releases are managed through the release helper script:

```bash
./scripts/release.sh [version]
```

The script automates:
- Version bumping in brew-change
- Git commit and push
- Tag creation and push
- GitHub release creation with auto-generated notes
- SHA256 generation for homebrew-tap
- Automatic update of homebrew-tap formula (if `$TAP_PATH` exists)

The homebrew-tap formula update happens at `~/Developer/personal/homebrew-tap` by default (configurable via `TAP_PATH` env var). The commit type (`fix` vs `chore`) is determined by scanning commit messages since the last release.

If no version is specified, the patch version is automatically incremented.

## Common Gotchas

- brew-change must be executable (`chmod +x brew-change`)
- Homebrew must be installed and in PATH
- jq is required for JSON processing
- GitHub API may require authentication for high usage
- Some packages may not have release notes available

## Tools Used

### Claude Code
- **Provider**: Anthropic
- **Usage**: Code development, documentation, architectural planning
- **Contribution Areas**:
  - Auto-discovery system implementation
  - Performance optimization and caching
  - Documentation and roadmap creation
  - Code review and security analysis

## Attribution Method

### Code Contributions
Code generated with AI assistance includes attribution in commit messages following conventional commit format:
```
type(scope): description

Implementation details...

Co-Authored-By: Claude <noreply@anthropic.com>
```

### GitHub Interactions
Issues, pull requests, and discussions generated with AI assistance include:
```
🤖 Generated with [Claude Code](https://claude.ai/code) - [MODEL_NAME]
```

## Transparency

This project embraces AI-assisted development while maintaining:
- Human oversight and architectural direction
- Code review and quality assurance
- Clear attribution of AI-generated content
- Adherence to open source licensing requirements

## Human Authorship

The project maintainer (shrwnsan) retains:
- Final decision-making on all contributions
- Architectural direction and strategy
- Code review and approval authority
- Responsibility for project outcomes

---

*This attribution follows emerging best practices for AI-assisted open source development, ensuring transparency while maintaining project integrity.*

*Last Updated: 2025-12-21*