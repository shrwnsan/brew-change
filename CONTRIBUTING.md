# Contributing to brew-change

We welcome contributions! This guide will help you get started.

## Development Setup

### Prerequisites
- macOS with Homebrew installed
- bash 4.0+ for modern shell features
- jq and curl (install with `brew install jq curl`)
- shellcheck for linting (`brew install shellcheck`)

### Clone and Setup
```bash
# Clone the repository
git clone https://github.com/shrwnsan/brew-change.git
cd brew-change

# Make the main script executable
chmod +x brew-change

# Run a quick test
./brew-change --help
```

## Running Tests

### Deterministic gate
```bash
# Same fixture-backed suites used by CI and release preflight
./tests/run-deterministic.sh
```

These tests fake Homebrew and HTTP behavior. They do not perform a real upgrade. Use `./tests/test-brew-change-local.sh` only for optional host/network troubleshooting.

### Shell Script Linting
```bash
# Blocking baseline across the repository
shellcheck --severity=error brew-change lib/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh

# Default severity for each modified script
shellcheck path/to/changed-script.sh
```

Pre-existing warning/style findings outside the release gate are currently baselined; ShellCheck errors are not. Do not add a broad suppression. Explain any narrow inline suppression.

## Code Style

### Shell Script Guidelines
- Use 2 spaces for indentation
- Prefer `[[ ]]` over `[ ]` for conditionals
- Use `local` for function variables
- Quote variables: `"$VAR"` not `$VAR`
- Use `printf` over `echo` for complex output

### Function Naming
- Prefix functions with module name: `github_*`, `npm_*`, `brew_*`
- Use snake_case for function names
- Keep functions under 50 lines when possible

### Error Handling
- Always check command exit codes
- Provide meaningful error messages
- Use `set -e -o pipefail` in scripts
- Clean up resources in trap handlers

## Adding New Features

### Adding Package Types
1. Create new module: `lib/brew-change-newtype.sh`
2. Implement detection function: `detect_newtype_package()`
3. Implement fetch function: `fetch_newtype_info()`
4. Update `brew-change-utils.sh` for type detection
5. Add tests in the testing section

### Adding Breaking Change Patterns
The breaking changes detection system (`lib/brew-change-breaking.sh`) uses pattern matching to identify potential breaking changes in release notes. To add new patterns:

1. Edit `lib/brew-change-breaking.sh`
2. Add new pattern to the `breaking_patterns` array in `detect_breaking_changes()`:
   ```bash
   local breaking_patterns=(
       # ... existing patterns ...
       "your new pattern here"    # Add descriptive comment
   )
   ```
3. Run tests: `./tests/test-breaking-changes.sh --ci`
4. Add test case to `tests/test-breaking-changes.sh` if appropriate

**Pattern Guidelines**:
- Use lowercase for case-insensitive matching
- Include common variations (e.g., "removed:" and "removed ")
- Test against real-world release notes
- Consider false positives when adding broad patterns

### Adding Configuration Options
1. Add to `lib/brew-change-config.sh`
2. Update configuration loading in main script
3. Document in `docs/configuration.md`
4. Add environment variable to README quick reference

### Adding New Commands
1. Update argument parsing in main script
2. Implement command handler function
3. Update help text
4. Add to testing matrix

## Submitting Changes

### Commit Guidelines
- Use conventional commits: `feat:`, `fix:`, `docs:`, etc.
- Keep commits focused on single changes
- Write clear commit messages
- Test your changes before submitting

### Pull Request Process
1. Fork the repository
2. Create a feature branch: `git checkout -b feature/new-feature`
3. Make your changes and test thoroughly
4. Run `./tests/run-deterministic.sh` and ShellCheck on all modified scripts
5. Submit a pull request with clear description
6. Link any relevant issues

### Testing Checklist
- [ ] Script runs without errors
- [ ] Help text is updated
- [ ] New features are tested
- [ ] Existing functionality still works
- [ ] The deterministic runner passes
- [ ] ShellCheck reports no errors repository-wide and no new findings in modified scripts
- [ ] Documentation is updated

## Project Structure

```
brew-change/
├── brew-change                   # Main entry point
├── CONTRIBUTING.md              # This file
├── LICENSE                      # MIT License
├── README.md                    # Main documentation
├── CHANGELOG.md                 # Version history
├── docs/                        # Additional documentation
│   ├── architecture.md          # Architecture overview
│   ├── configuration.md         # Configuration guide
│   └── technical-documentation.md  # Technical details
├── tests/                       # Test suite
│   ├── run-deterministic.sh     # CI/release fixture-backed gate
│   ├── test-upgrade-flow.sh     # Preview/confirm/mutate invariants
│   ├── test-url-policy.sh       # Evidence destination policy
│   ├── test-release-preflight.sh # Publication failure invariants
│   ├── test-brew-change-local.sh # Optional live/local menu
│   └── lib/
│       └── test-utils.sh        # Test utilities
└── lib/                         # Library modules
    ├── brew-change-config.sh    # Configuration
    ├── brew-change-utils.sh     # Utilities
    ├── brew-change-breaking.sh  # Breaking changes detection
    ├── brew-change-github.sh    # GitHub integration
    ├── brew-change-npm.sh       # npm integration
    ├── brew-change-brew.sh      # Homebrew integration
    ├── brew-change-non-github.sh # Non-GitHub handling
    ├── brew-change-display.sh   # Output formatting
    └── brew-change-parallel.sh  # Parallel processing
```

Docker test infrastructure was removed in v1.5.4 and is not part of the current development workflow.

## Release process

Maintainers run `./scripts/release.sh [X.Y.Z]` from a clean, synchronized `main` branch. The script validates strict SemVer, local/remote tag availability, required tools, the deterministic gate, and an HTTP archive download before creating a version commit or publishing anything. On success it retains the existing behavior of pushing the version commit and tag, creating the GitHub release, and optionally updating the tap checkout at `$TAP_PATH`.

Publication spans Git and GitHub and cannot be transactional. If a failure occurs after preflight, inspect which of the commit, tag, GitHub release, and tap update exist before retrying. Repair or remove only the incomplete remote object, restore `main` to a consistent release commit, then rerun after the underlying failure is fixed. Never blindly rerun the script after a partial publication.

## Bug Reports

When reporting bugs, please include:
- macOS version
- Homebrew version
- bash version (`bash --version`)
- Exact command used
- Full error output
- Environment variables if any

## Feature Requests

Feature requests should include:
- Clear description of the feature
- Use case and motivation
- Proposed implementation approach
- Examples of how it would work

## Development Tips

### Debug Mode
```bash
export BREW_CHANGE_DEBUG=1
./brew-change [command]
```

### Testing Specific Scenarios
```bash
# Test with single package
BREW_CHANGE_JOBS=1 ./brew-change package-name

# Test cache behavior
rm -rf ~/.cache/brew-change/*
./brew-change -a

# Test network failure simulation
export BREW_CHANGE_TIMEOUT=1
./brew-change package-name
```

### Performance Profiling
```bash
# Time the full operation
time ./brew-change -a

# Debug mode shows timing per operation
export BREW_CHANGE_DEBUG=1
./brew-change -a | grep "time:"
```

## Community

- Feel free to ask questions in issues
- Share feature ideas and improvements
- Help other users with their questions
- Contribute to documentation

Thank you for contributing to brew-change! 🎉
