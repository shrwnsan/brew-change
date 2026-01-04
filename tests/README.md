# brew-change Testing Suite

This directory contains testing tools for the `brew-change` utility, supporting both local development testing and CI/CD automation.

## 📁 Directory Structure

```
tests/
├── README.md                           # This file
├── lib/
│   └── test-utils.sh                   # Shared test utilities and assertions
├── test-breaking-changes.sh            # Breaking changes detection tests (24 tests)
└── test-brew-change-local.sh           # Local testing menu (macOS/Linux) + CI mode
```

## 🚀 Quick Start

### Local Testing (Recommended for Development)
```bash
# Run interactive menu on your host system
./tests/test-brew-change-local.sh
```

### CI/Automated Testing (Non-Interactive)
```bash
# Run comprehensive test suite in CI mode
./tests/test-brew-change-local.sh --ci

# Run breaking changes detection tests
./tests/test-breaking-changes.sh --ci
```

CI mode features:
- ✅ **Non-interactive**: No prompts or user input required
- ✅ **Structured output**: `[PASS]`/`[FAIL]`/`[INFO]` format
- ✅ **Exit codes**: Returns 0 on success, non-zero on failure
- ✅ **Summary report**: Test statistics at the end
- ✅ **CI-friendly**: Perfect for GitHub Actions, GitLab CI, etc.

## 🔧 Testing Options

### Local Testing (`test-brew-change-local.sh`)
- ✅ **Environment**: Your macOS/Linux system with Homebrew tap installation
- ✅ **Speed**: Fast, no container overhead
- ✅ **Real-world**: Tests your actual tap installation
- ✅ **Convenience**: Immediate feedback

**Features:**
- 🧪 Run all functionality tests
- 📦 Test individual packages
- ⚡ Performance benchmarking
- 🌐 Network connectivity tests
- 🔍 Debug mode testing
- 📊 Configuration validation

## 📋 Test Coverage

### Functionality Tests
- ✅ Help command and usage
- ✅ Invalid package handling
- ✅ Simple and verbose listing
- ✅ Single package processing
- ✅ Multiple package handling
- ✅ Breaking changes detection (24 tests)

### Performance Tests
- ⏱️ Execution timing
- 📈 System resource usage
- 💾 Memory utilization
- 🔄 Parallel processing efficiency

### Integration Tests
- 🌐 Network connectivity
- 📦 Package type detection
- 🔧 API endpoint validation
- 🏥 Environment health checks

### Breaking Changes Detection Tests
The `test-breaking-changes.sh` suite provides comprehensive testing for breaking changes pattern detection:

- ✅ Pattern matching (40+ breaking change keywords)
- ✅ Case-insensitive detection
- ✅ Markdown header recognition
- ✅ False positive prevention
- ✅ Multi-line release notes
- ✅ Empty input handling
- ✅ Emoji indicator formatting

Run with: `./tests/test-breaking-changes.sh --ci`

### Debug Tools
- 🔍 Detailed error reporting
- 📊 Resource monitoring
- 🛠️ Configuration validation
- 🧪 Interactive troubleshooting

## 🚀 Usage Examples

### Local Development Workflow
```bash
# Quick function test
./tests/test-brew-change-local.sh

# Test specific package
./brew-change node

# Performance test
time ./brew-change -a
```

### Advanced Usage
```bash
# Run in CI mode (non-interactive)
./tests/test-brew-change-local.sh --ci

# Enable debug output
BREW_CHANGE_DEBUG=1 ./tests/test-brew-change-local.sh --ci

# Test breaking changes detection
./tests/test-breaking-changes.sh --ci
```

## 📊 Results and Logging

### Local Testing
- Results shown directly in terminal
- Debug output available with `BREW_CHANGE_DEBUG=1`
- Logs printed to console
- CI mode provides structured `[PASS]`/`[FAIL]` output

## 🔧 Configuration

### Environment Variables
```bash
# Enable debug output
export BREW_CHANGE_DEBUG=1

# Set parallel job limit
export BREW_CHANGE_JOBS=4

# Configure retry attempts
export BREW_CHANGE_MAX_RETRIES=2
```

## 📦 Shared Test Utilities

The `lib/test-utils.sh` library provides reusable testing functions used across all test scripts.

### Key Features
- **Command detection**: Automatically finds `brew-change` command
- **Assertions**: Validate command success, failures, and output
- **Test tracking**: Count passed/failed tests automatically
- **Mode awareness**: Adapts output for interactive vs CI mode
- **Exit codes**: Proper return codes for CI integration

### Common Functions

#### Command Detection
```bash
# Automatically find brew-change command
brew_change_cmd=$(get_brew_change_cmd)
```

#### Assertions
```bash
# Assert command succeeds
assert_command_success "Test name" $brew_change_cmd --help

# Assert command fails
assert_command_fails "Invalid option" $brew_change_cmd --invalid

# Assert output contains string
assert_command_output_contains "Version check" "version" $brew_change_cmd --version

# Assert output doesn't contain string
assert_command_output_not_contains "No errors" "error" $brew_change_cmd
```

#### Logging
```bash
log_info "Informational message"
log_success "Success message"
log_error "Error message"
log_warning "Warning message"
```

#### Test Results
```bash
# Record test results
log_test_result "Test name" "pass"
log_test_result "Another test" "fail" "Optional message"

# Print summary at end
print_test_summary

# Get appropriate exit code
get_test_exit_code
```

### Adding New Tests

To add new tests using the shared utilities:

```bash
test_my_feature() {
    local brew_change_cmd="$1"

    log_info "Testing my feature..."

    # Use assertions
    assert_command_success "Feature flag" $brew_change_cmd --my-feature

    # Or manual testing
    run_command_capture_output $brew_change_cmd --complex
    if [[ $COMMAND_EXIT_CODE -eq 0 ]]; then
        log_test_result "Complex test" "pass"
    else
        log_test_result "Complex test" "fail" "Exit: $COMMAND_EXIT_CODE"
    fi
}

# Call from comprehensive_test_suite()
comprehensive_test_suite() {
    # ... existing tests ...
    test_my_feature "$brew_change_cmd"
}
```

## 🐛 Troubleshooting

### Local Testing Issues
```bash
# Check permissions
chmod +x tests/test-brew-change-local.sh

# Verify brew-change installation
which brew-change
./brew-change --help

# Check dependencies
which jq curl git
```

### Common Problems
- **Permission denied**: `chmod +x tests/*.sh`
- **brew-change not found**: Ensure tap is installed via `brew tap shrwnsan/tap && brew install brew-change`
- **Network issues**: Check internet connectivity for API calls

### Known Limitations
- **macOS timeout command**: The `timeout` command is not available on macOS by default (requires `brew install coreutils`). Parallel processing tests will skip timeout protection on macOS. This is documented behavior - tests will still run, just without the timeout safeguard.

## 🔄 Continuous Integration

### GitHub Actions Example
```yaml
name: brew-change Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install from tap
        run: |
          brew tap shrwnsan/tap
          brew install brew-change

      - name: Run test suite in CI mode
        run: ./tests/test-brew-change-local.sh --ci

      - name: Run breaking changes tests
        run: ./tests/test-breaking-changes.sh --ci
```

### Linux CI Example
```yaml
name: brew-change Tests (Linux)

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Set up Homebrew
        run: |
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
          echo '/home/linuxbrew/.linuxbrew/bin' >> $GITHUB_PATH

      - name: Install from tap
        run: brew tap shrwnsan/tap && brew install brew-change

      - name: Run test suite in CI mode
        run: ./tests/test-brew-change-local.sh --ci
```

## 📈 Performance Benchmarks

### Expected Performance
| Environment | Single Package | 13 Packages | Memory Usage |
|-------------|----------------|--------------|--------------|
| **Local (macOS)** | 2-4 seconds | 45-55 seconds | 15-25MB |
| **Local (Linux)** | 3-5 seconds | 50-60 seconds | 20-30MB |

## 🤝 Contributing

When adding new tests:
1. Update the appropriate test suite (local or breaking changes)
2. Use shared utilities from `lib/test-utils.sh`
3. Add documentation for new test scenarios
4. Update this README with new coverage areas

## 📄 License

These testing tools follow the same license as the brew-change utility.

---

**Last Updated**: 2026-01-04
**Version**: 1.5.3
**Compatibility**: macOS 10.15+, Linux with Homebrew
