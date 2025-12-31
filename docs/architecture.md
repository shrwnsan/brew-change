# Architecture

## Modular Structure

```
brew-change/
├── brew-change                  # Main entry point
└── lib/
    ├── brew-change-config.sh    # Configuration and constants
    ├── brew-change-utils.sh     # Utility functions
    ├── brew-change-breaking.sh  # Breaking changes detection
    ├── brew-change-github.sh    # GitHub API integration
    ├── brew-change-npm.sh       # npm registry integration
    ├── brew-change-brew.sh      # Homebrew integration
    ├── brew-change-non-github.sh # Non-GitHub package handling
    ├── brew-change-display.sh   # Output formatting and display
    └── brew-change-parallel.sh  # Parallel processing logic
```

## Processing Flow

1. **Package Detection**: Identify outdated packages
2. **Type Classification**: Determine GitHub/npm/Non-GitHub
3. **Information Gathering**: Fetch release data from appropriate sources
4. **Breaking Changes Detection** (optional): Analyze release notes for breaking patterns
5. **Parallel Processing**: Handle multiple packages simultaneously
6. **Output Formatting**: Display clean, consistent results

## Security Features

- **URL validation**: Prevents malicious requests
- **Input sanitization**: Protects against injection attacks
- **Network timeouts**: Prevents hanging on slow responses
- **Scoped package support**: Safe handling of npm scoped packages

## Component Details

### Core Modules

- **brew-change-config.sh**: Centralized configuration management
- **brew-change-utils.sh**: Shared utilities and helper functions
- **brew-change-brew.sh**: Homebrew integration and package detection

### Data Sources

- **brew-change-github.sh**: GitHub API integration for release notes
- **brew-change-npm.sh**: npm registry integration for package metadata
- **brew-change-non-github.sh**: Fallback handling for non-GitHub packages

### Analysis

- **brew-change-breaking.sh**: Breaking changes pattern detection and highlighting

### User Interface

- **brew-change-display.sh**: Output formatting and presentation
- **brew-change-parallel.sh**: Concurrent processing management

## Data Flow

```
Homebrew API → Package Detection → Type Classification
                                     ↓
GitHub API ──────────────────────→ Information Gathering
                                     ↓
npm API ────────────────────────→ Breaking Detection (optional)
                                     ↓
Parallel Processing ──────────────→ Result Formatting
                                     ↓
Display Module ← ────────────────── Output
```

## Design Principles

1. **Modularity**: Each module has a single responsibility
2. **Parallelism**: Concurrent processing for performance
3. **Resilience**: Graceful fallbacks and error handling
4. **Security**: Input validation and safe defaults
5. **Extensibility**: Easy to add new package types and sources