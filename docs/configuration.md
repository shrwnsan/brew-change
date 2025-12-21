# Configuration

brew-change can be configured through environment variables to customize behavior, performance, and output.

## Environment Variables

### Performance Configuration

```bash
# Override default parallel job limit
# If not set, automatically calculated based on CPU cores and memory
# Maximum allowed: 1.5x the calculated value to prevent API rate limiting
export BREW_CHANGE_JOBS=4
```

```bash
# Override cache directory
# Default: $HOME/.cache/brew-change
export BREW_CHANGE_CACHE_DIR="$HOME/.cache/brew-change"
```

```bash
# Override cache duration in seconds
# Default: 3600 (1 hour)
export BREW_CHANGE_CACHE_DURATION=7200  # 2 hours
```

```bash
# Override retry attempts for network requests
# Default: 3
export BREW_CHANGE_MAX_RETRIES=2
```

```bash
# Override timeout for curl requests in seconds
# Default: 5
export BREW_CHANGE_TIMEOUT=10
```

### Debug and Logging

```bash
# Enable debug output
# Shows detailed timing, cache hits, network requests, and job allocation
export BREW_CHANGE_DEBUG=1
```

### Feature Flags

```bash
# (Alpha) Enable Documentation-Repository Pattern for modern CLI tools
# This enables fetching changelogs from GitHub docs repositories when binaries
# are distributed externally (e.g., claude-code, Google Cloud CLI, etc.)
export BREW_CHANGE_DOCS_REPO=1
```

## Default Configuration

### Parallel Job Calculation

When `BREW_CHANGE_JOBS` is not set, jobs are calculated automatically:

```bash
# Base calculation (minimum of):
# 1. CPU cores
# 2. Available memory in GB / 2 (1 job per 2GB RAM)
# 3. 8 (hard maximum for API rate limiting)

# Maximum allowed:
# 1.5x the calculated value (to prevent system overload)
```

Example calculations:
- **4 cores, 8GB RAM**: min(4, 4, 8) = 4 jobs → max 6 jobs
- **8 cores, 16GB RAM**: min(8, 8, 8) = 8 jobs → max 12 jobs
- **2 cores, 4GB RAM**: min(2, 2, 8) = 2 jobs → max 3 jobs

### Cache Configuration

```bash
# Default cache settings
BREW_CHANGE_CACHE_DIR="$HOME/.cache/brew-change"
BREW_CHANGE_CACHE_DURATION=3600  # 1 hour
BREW_CHANGE_CACHE_MAX_SIZE=100   # 100MB (not yet implemented)
```

### Network Configuration

```bash
# Default network settings
BREW_CHANGE_TIMEOUT=5          # 5 seconds per request
BREW_CHANGE_MAX_RETRIES=3      # 3 attempts with exponential backoff
BREW_CHANGE_RETRY_DELAY=1      # 1 second base delay
BREW_CHANGE_CONNECT_TIMEOUT=3  # 3 seconds connection timeout
```

## Configuration Examples

### For Slow Networks
```bash
export BREW_CHANGE_TIMEOUT=10
export BREW_CHANGE_MAX_RETRIES=5
export BREW_CHANGE_CACHE_DURATION=7200  # 2 hours
export BREW_CHANGE_JOBS=2
```

### For Fast Systems
```bash
export BREW_CHANGE_JOBS=8
export BREW_CHANGE_CACHE_DURATION=1800  # 30 minutes for fresh data
```

### For Resource-Constrained Systems
```bash
export BREW_CHANGE_JOBS=1  # Sequential processing
export BREW_CHANGE_CACHE_DIR="/tmp/brew-change"
export BREW_CHANGE_MAX_RETRIES=2
```

### For Development/Testing
```bash
export BREW_CHANGE_DEBUG=1
export BREW_CHANGE_CACHE_DURATION=60  # 1 minute for testing
export BREW_CHANGE_DOCS_REPO=1        # Enable experimental features
```

## Configuration Files

### Bash/Zsh Configuration
Add to your shell startup file (`~/.zshrc`, `~/.bash_profile`):

```bash
# brew-change configuration
export BREW_CHANGE_JOBS=4
export BREW_CHANGE_DEBUG=0  # Set to 1 for debugging
```

### Environment File (Advanced)
Create a `.env` file in the brew-change directory:

```bash
# .env file for brew-change configuration
BREW_CHANGE_JOBS=6
BREW_CHANGE_CACHE_DURATION=3600
BREW_CHANGE_DOCS_REPO=1
```

Load with:
```bash
source .env && ./brew-change -a
```

## System-specific Configuration

### macOS with Homebrew
```bash
# Optimize for typical macOS installation
export BREW_CHANGE_JOBS=4
export BREW_CHANGE_CACHE_DIR="$HOME/Library/Caches/brew-change"
```

### Docker/Container Environment
```bash
# Reduce resources in containers
export BREW_CHANGE_JOBS=2
export BREW_CHANGE_CACHE_DIR="/tmp/brew-change"
export BREW_CHANGE_TIMEOUT=3
```

### CI/CD Environments
```bash
# Conservative settings for CI
export BREW_CHANGE_JOBS=1  # Sequential for reliability
export BREW_CHANGE_CACHE_DURATION=60  # Fresh data each run
export BREW_CHANGE_MAX_RETRIES=1  # Fast failure
```

## Debug Configuration

### Enable Verbose Output
```bash
export BREW_CHANGE_DEBUG=1

# Run brew-change to see:
# - Package type detection
# - Cache hit/miss status
# - Network request timing
# - Parallel job allocation
# - Error conditions
```

### Performance Profiling
```bash
export BREW_CHANGE_DEBUG=1

# Time specific operations
time ./brew-change -a 2>&1 | grep "time:"
```

### Cache Analysis
```bash
# Check cache contents
ls -la ~/.cache/brew-change/

# Clear cache for testing
rm -rf ~/.cache/brew-change/*
```

## Troubleshooting Configuration

### Common Issues

#### Too Many Parallel Jobs
```bash
# Reduce to prevent API rate limiting
export BREW_CHANGE_JOBS=2
```

#### Cache Issues
```bash
# Clear cache and set shorter duration
rm -rf ~/.cache/brew-change/*
export BREW_CHANGE_CACHE_DURATION=300  # 5 minutes
```

#### Network Timeouts
```bash
# Increase timeout and reduce parallelism
export BREW_CHANGE_TIMEOUT=15
export BREW_CHANGE_JOBS=1
```

#### Debug Mode Too Verbose
```bash
# Disable debug output
unset BREW_CHANGE_DEBUG
export BREW_CHANGE_DEBUG=0
```

## Security Considerations

### File Permissions
Cache directory should have restricted permissions:
```bash
chmod 700 ~/.cache/brew-change/
```

### Environment Variable Security
- Avoid setting sensitive data in environment variables
- Use configuration files for persistent settings
- Be careful with custom cache directories

### Network Security
- Default timeouts prevent hanging connections
- Input validation protects against injection attacks
- URL validation prevents malicious requests