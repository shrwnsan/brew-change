# brew-change Testing Suite

This directory contains comprehensive testing tools for the `brew-change` utility, supporting both local development testing and sandboxed Docker testing.

## 📁 Directory Structure

```
tests/
├── README.md                           # This file
├── lib/
│   └── test-utils.sh                   # Shared test utilities and assertions
├── test-breaking-changes.sh            # Breaking changes detection tests (24 tests)
├── test-brew-change-local.sh           # Local testing menu (macOS/Linux) + CI mode
├── test-brew-change-docker.sh          # Docker testing menu (sandboxed)
├── docker/                             # Docker environment
│   ├── Dockerfile.test-ubuntu          # Ubuntu 24.04 optimized testing environment
│   ├── test-brew-change.sh             # Automated test suite
│   ├── docker-compose.brew-change.yml  # Multi-scenario testing
│   └── README.md                       # Docker-specific documentation
└── results/                            # Test output directory (created automatically)
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

### Docker Testing (Sandboxed Environment)
```bash
# Run Docker testing menu
./tests/test-brew-change-docker.sh
```

## 🔧 Testing Options

### Local Testing (`test-brew-change-local.sh`)
- ✅ **Environment**: Your macOS/Linux system
- ✅ **Speed**: Fast, no container overhead
- ✅ **Real-world**: Tests your actual installation
- ✅ **Convenience**: Immediate feedback

**Features:**
- 🧪 Run all functionality tests
- 📦 Test individual packages
- ⚡ Performance benchmarking
- 🌐 Network connectivity tests
- 🔍 Debug mode testing
- 📊 Configuration validation

### Docker Testing (`test-brew-change-docker.sh`)
- ✅ **Environment**: Optimized Debian Slim container with Homebrew
- ✅ **Isolation**: No interference with host system
- ✅ **Consistency**: Reproducible test environment
- ✅ **Cross-platform**: Same environment everywhere
- ✅ **Performance**: Fast builds (~7 minutes vs 30+ minutes previously)
- ✅ **Size**: Optimized image size (~216.5MB vs ~500MB previously)
- ✅ **Packages**: Lightweight testing packages (jq, yq, tree, htop, openssl@3.5)

**Features:**
- 🐳 Build and manage Docker images
- 🎮 Interactive menu in container
- 📊 Performance benchmarking
- 🧹 Docker environment cleanup
- 🔍 Debug shell access
- 📋 View test results

## 🎯 When to Use Each

### Use Local Testing When:
- 🛠️ **Developing new features**
- 🔧 **Debugging specific issues**
- ⚡ **Need quick feedback**
- 🎯 **Testing your actual setup**

### Use Docker Testing When:
- 🧪 **CI/CD pipelines**
- 🔒 **Need isolated testing**
- 🌍 **Cross-platform validation**
- 📊 **Performance benchmarking**
- 🧹 **Clean environment testing**

## 📋 Test Coverage

Both testing environments provide:

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

### Docker Testing Workflow
```bash
# Build and run all tests
./tests/test-brew-change-docker.sh

# Menu structure:
# 🔧 Docker Management: Toggle GitHub Auth, Build/Rebuild, Clean, View logs
# 🧪 Container Testing: Performance, Network, Resources, Specific package
# 🐚 Container Access: Shell access and Debug mode
# ⚙️ Configuration: Environment switching, View results
```

### Advanced Usage
```bash
# Run specific Docker test
docker-compose -f tests/docker/docker-compose.brew-change.yml run brew-change-perf

# Debug with shell access
docker run --rm -it brew-change-ubuntu /bin/bash

# Clean environment
./tests/test-brew-change-docker.sh
# Choose option 10: Clean Docker Environment
```

## 📊 Results and Logging

### Local Testing
- Results shown directly in terminal
- Debug output available with `BREW_CHANGE_DEBUG=1`
- Logs printed to console

### Docker Testing
- Results saved to `tests/results/`
- Timestamped log files
- Container logs available
- Performance benchmarks stored

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

### Docker Configuration
```bash
# Override image name
export BREW_CHANGE_IMAGE_NAME="custom-test"

# Override results directory
export BREW_CHANGE_RESULTS_DIR="./custom-results"
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

### Docker Testing Issues
```bash
# Check Docker installation
docker --version
docker info

# Clean Docker environment
./tests/test-brew-change-docker.sh
# Choose option 10: Clean Docker Environment

# Rebuild without cache
./tests/test-brew-change-docker.sh
# Choose option 9: Rebuild Image (No Cache)
```

### Common Problems
- **Permission denied**: `chmod +x tests/*.sh`
- **brew-change not found**: Ensure current directory is in PATH or use `./brew-change`
- **Docker not running**: Start Docker Desktop/daemon
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
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Homebrew
        run: |
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
          echo '/home/linuxbrew/.linuxbrew/bin' >> $GITHUB_PATH
      
      - name: Make brew-change executable
        run: chmod +x brew-change
      
      - name: Run test suite in CI mode
        run: ./tests/test-brew-change-local.sh --ci

  docker-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Docker tests
        run: ./tests/test-brew-change-docker.sh
```

## 📈 Performance Benchmarks

### Expected Performance
| Environment | Single Package | 13 Packages | Memory Usage | Image Size |
|-------------|----------------|--------------|--------------|------------|
| **Local (macOS)** | 2-4 seconds | 45-55 seconds | 15-25MB | N/A |
| **Docker (Debian)** | 3-5 seconds | 50-60 seconds | 100-200MB | ~216.5MB |

### Docker Environment Packages
The Docker testing environment includes lightweight testing packages optimized for fast builds and realistic test scenarios:

| Package | Version | Purpose | Test Value |
|---------|---------|---------|------------|
| **jq** | Latest | JSON processor | ✅ Essential for API testing |
| **yq** | Latest | YAML/JSON processor | ⚡ Useful for test data |
| **tree** | Latest | Directory viewer | ❌ Optional for debugging |
| **htop** | Latest | Process monitor | ❌ Optional for debugging |
| **openssl@3.5** | 3.5.x | Outdated crypto library | ✅ **Outdated detection testing** |

**Package Size Impact**: ~16.5MB total for testing packages (vs ~300MB for runtime environments)

### Version Control System
To maintain consistency between development and Docker environments:

```bash
# Update Dockerfile with current package versions
cd tests/docker && ./update-dockerfile.sh

# Generate version commands manually
cd tests/docker && ./package-versions.sh
```

This ensures Docker tests always validate the same package scenarios as your development environment.

### Optimization Results
- ✅ **Build time**: Reduced from 30+ minutes to ~7 minutes (422.6s)
- ✅ **Image size**: Reduced from ~500MB to ~216.5MB (57% reduction)
- ⚡ **Single package**: <5 seconds ✅ achieved
- 🔄 **Multiple packages**: <60 seconds for 13 packages ✅ achieved
- 💾 **Memory usage**: <50MB peak (target for optimization)
- 🎯 **Success rate**: >95% ✅ achieved

### Key Optimizations Applied
- 🐳 **Base image**: Debian 12 Slim (optimal compatibility vs Alpine)
- 📦 **Packages**: Lightweight testing utilities vs heavy runtime environments
- 🔧 **Homebrew path**: Fixed user permissions for bottle downloads
- ⚡ **Build reliability**: Added `|| true` for post-install failures

## 🤝 Contributing

When adding new tests:
1. Update both local and Docker test suites
2. Maintain consistency between environments
3. Add documentation for new test scenarios
4. Update this README with new coverage areas

## 📄 License

These testing tools follow the same license as the brew-change utility.

---

**Last Updated**: 2025-12-27
**Version**: 1.4.1
**Compatibility**: macOS 10.15+, Linux, Docker 20.10+
**Build Time**: ~7 minutes (422.6s)
**Image Size**: ~216.5MB