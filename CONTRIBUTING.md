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

### Manual Testing
```bash
# Test basic functionality
./brew-change

# Test specific package types
./brew-change node              # GitHub package
./brew-change gemini-cli        # Hybrid package
./brew-change claude-code       # Non-GitHub package
./brew-change crush             # Third-party tap package

# Test parallel processing
./brew-change -a

# Performance testing
time ./brew-change -a
```

### Shell Script Linting
```bash
# Check all shell scripts
shellcheck brew-change lib/*.sh

# Check specific file
shellcheck lib/brew-change-github.sh
```

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
4. Run shellcheck on all modified files
5. Submit a pull request with clear description
6. Link any relevant issues

### Testing Checklist
- [ ] Script runs without errors
- [ ] Help text is updated
- [ ] New features are tested
- [ ] Existing functionality still works
- [ ] shellcheck passes on all files
- [ ] Documentation is updated

## Project Structure

```
brew-change/
├── brew-change              # Main entry point
├── CONTRIBUTING.md         # This file
├── LICENSE                 # MIT License
├── README.md               # Main documentation
├── CHANGELOG.md            # Version history
└── lib/                    # Library modules
    ├── brew-change-config.sh      # Configuration
    ├── brew-change-utils.sh       # Utilities
    ├── brew-change-github.sh      # GitHub integration
    ├── brew-change-npm.sh         # npm integration
    ├── brew-change-brew.sh        # Homebrew integration
    ├── brew-change-non-github.sh  # Non-GitHub handling
    ├── brew-change-display.sh     # Output formatting
    └── brew-change-parallel.sh    # Parallel processing
```

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