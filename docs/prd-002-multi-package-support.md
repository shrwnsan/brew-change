# PRD: Multi-Package Support

**Status:** Draft
**Created:** 2026-04-02
**Owner:** Engineering Team
**Target Version:** v1.6.0
**Timeline:** 1-2 days

## Overview

Enable `brew-change` to accept multiple package names as positional arguments (e.g., `brew-change mlx-lm llama.cpp bun`), filling the gap between single-package mode and the `-a` (all outdated) flag.

## Background & Motivation

### Current State

`brew-change` has two modes for changelog viewing:

- **Single package**: `brew-change node` — one package at a time
- **All outdated**: `brew-change -a` — processes every outdated package in parallel

There is no middle ground. A user who wants changelogs for 2-3 specific packages must run the command multiple times or run `-a` and sift through everything.

### Homebrew Convention

22+ Homebrew commands accept variadic `[formula|cask ...]` arguments (`brew install`, `brew info`, `brew outdated`, `brew livecheck`, etc.). Only `brew log` (the closest built-in analog) is single-package — and that's considered a limitation.

`brew-change` not accepting multiple positional args violates established Homebrew CLI convention and user expectations.

### Ecosystem Gap

No tool in the Homebrew ecosystem fetches upstream release notes. `brew-change` is the only tool in this niche. Multi-package support further differentiates it as the `apt-listchanges`-equivalent for Homebrew.

## Goals

### Primary Goals
1. Accept multiple positional package arguments: `brew-change pkg1 pkg2 pkg3`
2. Process each package sequentially, displaying changelogs in order
3. Maintain full compatibility with existing single-package behavior
4. Maintain compatibility with flag combinations (`-b`, `-v`)

### Non-Goals
1. Parallel execution for multi-package mode (sequential is sufficient for 2-5 packages)
2. Interactive prompts to "switch to `-a` mode" — the user chose specific packages for a reason
3. Hard limits on package count — let GitHub API rate limits be the natural ceiling
4. Changes to `-a` (all outdated) behavior

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Multi-package support | `brew-change pkg1 pkg2` works | Manual testing |
| Single-package regression | `brew-change node` unchanged | Existing tests pass |
| Flag compatibility | `-b pkg1 pkg2` works | Manual testing |
| Error handling | Invalid package doesn't block valid ones | Manual testing |
| Help text updated | Usage examples reflect multi-package | Review |

## Technical Design

### Change Scope

**Single file**: `brew-change` (main entry point), ~20 lines modified.

No changes needed to:
- `lib/brew-change-brew.sh` — `show_package_changelog()` is stateless, safe for repeated calls
- `lib/brew-change-display.sh` — all display functions are stateless
- `lib/brew-change-utils.sh` — all utility functions are stateless
- `lib/brew-change-github.sh` — `init_github_auth()` is idempotent (guards against re-init)
- `lib/brew-change-parallel.sh` — no changes needed for sequential multi-package

### Implementation

#### 1. Argument Parsing

Replace single `PACKAGE` scalar with `PACKAGES` array:

```bash
# Before (line 93):
PACKAGE=""

# After:
PACKAGES=()

# Before (line 123):
*)
    PACKAGE="$1"
    shift
    ;;

# After:
*)
    PACKAGES+=("$1")
    shift
    ;;
```

#### 2. Main Execution Logic

Replace single-package branch with multi-package loop:

```bash
if [ ${#PACKAGES[@]} -gt 0 ]; then
    # Soft warning at 10+ packages
    if [ ${#PACKAGES[@]} -gt 10 ]; then
        echo "Note: ${#PACKAGES[@]} packages specified. For all outdated packages, consider: brew-change -a"
        echo ""
    fi

    echo "Processing changelog for ${#PACKAGES[@]} package(s)..."
    echo ""

    for pkg in "${PACKAGES[@]}"; do
        if check_package_exists "$pkg"; then
            show_package_changelog "$pkg"
        else
            echo "Error: Package '$pkg' not found in Homebrew"
            # Continue processing remaining packages
        fi
        # Separator between packages (skip for last)
    done
else
    # ... existing outdated/all/verbose logic unchanged
fi
```

#### 3. Flag Interactions

**Current behavior** (must be preserved for backward compat): when a package name is provided, the specific-package branch runs and the outdated/all/verbose branch is completely skipped. This means `brew-change -a node` currently shows node's changelog and ignores `-a`.

**New precedence rule**: packages always win over `-a`/`-v`. This preserves existing behavior.

| Invocation | Behavior |
|---|---|
| `brew-change pkg1 pkg2` | Process both sequentially |
| `brew-change -a` | Unchanged — process all outdated |
| `brew-change -a pkg1` | Process pkg1 only (packages win, `-a` ignored) |
| `brew-change pkg1 -a` | Same — process pkg1 only |
| `brew-change -b pkg1 pkg2` | Process both with breaking change detection (`IDENTIFY_BREAKING` is already set by arg parsing) |
| `brew-change -v pkg1 pkg2` | Process both (packages win, `-v` ignored — same as current single-package behavior) |

The `-b` flag requires explicit handling: `IDENTIFY_BREAKING` is already set during arg parsing, but the current code only checks it inside the `-a` branch. For multi-package mode, export `IDENTIFY_BREAKING` before calling `show_package_changelog` so parallel-mode breaking change detection runs per-package. This is a minor addition (~2 lines) in the multi-package loop.

#### 4. Error Handling

- If a package doesn't exist, print error and continue with remaining packages
- If a package has no changelog available, show existing "no release notes" behavior and continue
- Exit code: `1` if any package fails, `0` if all succeed
- Package separators: `---` between packages (consistent with parallel mode output in `brew-change-parallel.sh:151`)

#### 5. Help Text Update

Update usage examples in `usage()` function:

```
Arguments:
  PACKAGE ...    Show changelog for one or more specific packages

Examples:
  brew-change node                # Show changelog for single package
  brew-change node python git     # Show changelogs for multiple packages
  brew-change -a                  # Show detailed changelogs for all outdated packages
  brew-change -b node python      # Check specific packages for breaking changes
```

## Rate Limiting & Scale

### Natural Ceiling

GitHub API rate limits serve as the natural upper bound:

| Auth Level | API calls/pkg | Practical Limit |
|---|---|---|
| Unauthenticated | 1-2 | ~20-30 packages |
| Authenticated (token) | 1-2 | ~100+ packages |

### Soft Warning

At 10+ packages, print an informational hint (non-blocking, no prompt):

```
Note: 12 packages specified. For all outdated packages, consider: brew-change -a
```

Rationale for **not** prompting to rerun with `-a`:
- The user chose specific packages intentionally
- Multi-package and `-a` serve different use cases
- Interactive prompts are already a friction point; adding another undermines clarity

### No Hard Limit

No artificial cap. Reasons:
- Un-Homebrew-like — `brew install`, `brew info`, etc. accept unlimited args
- Power users scripting the tool shouldn't hit unexpected limits
- GitHub's 403 responses are already handled gracefully by existing error handling

## Edge Cases

| Case | Expected Behavior |
|---|---|
| Package not found | Print error, continue with remaining. Exit 1. |
| Mix of found/not found | Process valid ones, summarize failures at end |
| Cask + formula mix | `check_package_exists` handles both — no special case needed |
| Tap-prefixed names (`charmbracelet/tap/crush`) | Already handled by `check_package_exists` |
| Duplicate package names | Process once, skip duplicates with a note |
| No packages specified (current behavior) | Fall through to outdated listing — unchanged |
| Single package (current behavior) | Identical to current behavior — zero regression |

## Test Plan

### Manual Testing

```bash
# Single package (regression check)
brew-change node

# Two packages
brew-change node git

# Three packages including a cask
brew-change node git firefox

# Invalid package mixed with valid
brew-change node nonexistent git

# With breaking change detection
brew-change -b node python

# Non-existent package only
brew-change nonexistent

# Existing flags unchanged
brew-change -a
brew-change -v
brew-change --version
brew-change --help
```

### Existing Tests

All existing tests in `tests/` must continue to pass without modification.

**Note**: Existing test coverage for argument parsing is minimal — only `--help`, basic invocation, `-v`, and invalid-option checks. No tests exist for flag+package combinations. This is acceptable for MVP; manual testing is sufficient given the small change scope.

## Codebase Notes

- `lib/brew-change-display.sh:244` has an unused `is_multi_package` parameter in `format_release_notes()`. This can be leveraged if multi-package output needs any formatting adjustments (e.g., truncating long release notes when multiple packages are shown).
- `lib/brew-change-parallel.sh:151` uses `---` as the package separator. Multi-package sequential mode should use the same separator for consistency.

## Future Considerations

- **Parallel multi-package**: If usage patterns show users frequently passing 5+ packages, consider reusing `process_packages_parallel` for multi-package mode. Not needed for MVP.
- **JSON output**: When JSON output mode is added (per TypeScript migration PRD), multi-package results should be a JSON array.
