#!/usr/bin/env bash
# Configuration module for brew-change

# Set UTF-8 locale to handle emojis and special characters in release notes
# Fallback to C.UTF-8 if en_US.UTF-8 is not available
if locale -a 2>/dev/null | grep -q "^en_US.UTF-8"; then
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
elif locale -a 2>/dev/null | grep -q "^C.UTF-8"; then
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
fi

# Function to verify required dependencies
# Missing required dependencies are reported with the exact supported
# installation command for each (T3.1.2: plain-language remediation).
# Optional gh guidance lives in init_github_auth (one benefit-focused tip
# shown only when GitHub evidence will actually be gathered), so it is not
# repeated here.
verify_dependencies() {
    local missing_deps=()

    # Check for required commands
    if ! command -v brew >/dev/null 2>&1; then
        missing_deps+=("brew")
    fi

    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi

    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi

    # Report missing required dependencies with exact install commands
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}" >&2
        local dep
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                brew)
                    echo "  brew — the Homebrew package manager brew-change inspects." >&2
                    echo "    Install: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" >&2
                    echo "    Details: https://brew.sh" >&2
                    ;;
                jq)
                    echo "  jq: processes Homebrew's JSON output." >&2
                    echo "    Install: 'brew install jq'  (Linux without Homebrew: 'apt install jq' / 'dnf install jq')" >&2
                    ;;
                curl)
                    # NOTE: keep command mentions quoted — the URL-policy
                    # call-site inventory counts bare curl tokens on
                    # non-comment lines, and these are prose, not calls.
                    echo "  curl: fetches release notes and changelogs." >&2
                    echo "    Install: 'brew install curl'  (Linux without Homebrew: 'apt install curl' / 'dnf install curl')" >&2
                    ;;
            esac
        done
        return 1
    fi

    return 0
}

# Only define constants if not already defined
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    readonly SCRIPT_NAME="brew-change"
fi

if [[ -z "${CACHE_DIR:-}" ]]; then
    readonly CACHE_DIR="${BREW_CHANGE_CACHE_DIR:-${HOME}/.cache/brew-change}"
fi

if [[ -z "${API_RATE_LIMIT_DELAY:-}" ]]; then
    readonly API_RATE_LIMIT_DELAY=1  # seconds between API calls
fi

if [[ -z "${CACHE_EXPIRY:-}" ]]; then
    readonly CACHE_EXPIRY=3600       # 1 hour cache expiry
fi

if [[ -z "${MAX_RETRIES:-}" ]]; then
    readonly MAX_RETRIES=${BREW_CHANGE_MAX_RETRIES:-3}           # max network retry attempts
fi

if [[ -z "${RETRY_DELAY:-}" ]]; then
    readonly RETRY_DELAY=2           # seconds between retries
fi

# Documentation-Repository Pattern feature flag (alpha)
# Accept true/false or 1/0 values
if [[ -z "${BREW_CHANGE_DOCS_REPO:-}" ]]; then
    readonly BREW_CHANGE_DOCS_REPO="false"
fi

# Calculate optimal parallel jobs based on system resources
cpu_count=1
memory_gb=1

# Try to detect CPU count
if command -v sysctl >/dev/null 2>&1; then
    cpu_count=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
elif command -v nproc >/dev/null 2>&1; then
    cpu_count=$(nproc 2>/dev/null || echo 1)
fi

# Try to detect memory
if command -v sysctl >/dev/null 2>&1; then
    memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 1073741824)
    memory_gb=$((memory_bytes / 1073741824))
elif [[ -f /proc/meminfo ]]; then
    memory_gb=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}' || echo 1)
fi

# Calculate optimal jobs: min of CPU cores, 1 per 2GB RAM, and 8
max_jobs_by_cpu=$cpu_count
max_jobs_by_memory=$((memory_gb / 2))
max_jobs_absolute=8

# Use minimum of the three calculations
if [[ $max_jobs_by_cpu -lt $max_jobs_by_memory && $max_jobs_by_cpu -lt $max_jobs_absolute ]]; then
    calculated_jobs=$max_jobs_by_cpu
elif [[ $max_jobs_by_memory -lt $max_jobs_absolute ]]; then
    calculated_jobs=$max_jobs_by_memory
else
    calculated_jobs=$max_jobs_absolute
fi

# Ensure at least 1 job
[[ $calculated_jobs -lt 1 ]] && calculated_jobs=1

# Check if user has set BREW_CHANGE_JOBS
if [[ -n "${BREW_CHANGE_JOBS:-}" ]]; then
    # Enforce maximum limit to prevent abuse (1.5x recommended for safety)
    max_allowed=$((calculated_jobs * 3 / 2))  # Integer arithmetic for 1.5x

    if [[ $BREW_CHANGE_JOBS -lt 1 ]]; then
        echo "Warning: BREW_CHANGE_JOBS must be at least 1. Using 1 instead of $BREW_CHANGE_JOBS" >&2
        PARALLEL_JOBS=1
    elif [[ $BREW_CHANGE_JOBS -gt $max_allowed ]]; then
        echo "Warning: BREW_CHANGE_JOBS ($BREW_CHANGE_JOBS) exceeds maximum allowed ($max_allowed, 1.5x recommended)." >&2
        echo "Recommended value for your system: $calculated_jobs. Using maximum allowed ($max_allowed) instead to prevent API rate limiting and system resource strain." >&2
        PARALLEL_JOBS=$max_allowed
    else
        PARALLEL_JOBS=$BREW_CHANGE_JOBS
    fi
else
    PARALLEL_JOBS=$calculated_jobs
fi

readonly PARALLEL_JOBS

# Ensure cache directory exists with secure permissions (safe to run multiple times)
if [[ ! -d "$CACHE_DIR" ]]; then
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"
fi

# Cleanup stale temp files from previous runs
if command -v find >/dev/null 2>&1; then
    find "$CACHE_DIR" -name ".*.tmp.*" -type f -mmin +5 -delete 2>/dev/null || true
fi

# Clean up temporary files on exit (only in main process)
if [[ -z "${BREW_CHANGE_SUBPROCESS:-}" ]]; then
    # Store temp files for cleanup
    TEMP_FILES=()
    TEMP_DIRS=()
    BREW_CHANGE_STTY_STATE=""

    # Idempotent core cleanup: removes temp files/dirs, kills registered PIDs.
    # Safe to call multiple times; guards against re-entry via
    # _BC_CLEANUP_DONE sentinel.
    _BC_CLEANUP_DONE=""

    cleanup() {
        # Idempotent guard: skip if already cleaned
        [[ "$_BC_CLEANUP_DONE" == "1" ]] && return 0
        _BC_CLEANUP_DONE="1"

        if [[ -n "${BREW_CHANGE_STTY_STATE:-}" && -r /dev/tty ]]; then
            stty "$BREW_CHANGE_STTY_STATE" < /dev/tty 2>/dev/null || true
            BREW_CHANGE_STTY_STATE=""
        fi

        # Kill any registered child processes first (so they don't hold files)
        if [[ -n "${BREW_CHANGE_PIDS:-}" ]]; then
            for pid in "${BREW_CHANGE_PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    kill -TERM "$pid" 2>/dev/null || true
                fi
            done
            for pid in "${BREW_CHANGE_PIDS[@]}"; do
                local attempts=0
                while kill -0 "$pid" 2>/dev/null && [[ $attempts -lt 20 ]]; do
                    sleep 0.05
                    attempts=$((attempts + 1))
                done
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL "$pid" 2>/dev/null || true
                fi
                wait "$pid" 2>/dev/null || true
            done
        fi

        # Remove all registered temp files
        if [[ ${#TEMP_FILES[@]} -gt 0 ]]; then
            for temp_file in "${TEMP_FILES[@]:-}"; do
                if [[ -n "$temp_file" && -f "$temp_file" ]]; then
                    rm -f "$temp_file" 2>/dev/null || true
                fi
            done
        fi

        # Remove all registered temp directories
        if [[ ${#TEMP_DIRS[@]} -gt 0 ]]; then
            for temp_dir in "${TEMP_DIRS[@]:-}"; do
                if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
                    rm -rf "$temp_dir" 2>/dev/null || true
                fi
            done
        fi

        # Cleanup any remaining temp files in cache directory
        if [[ -n "${CACHE_DIR:-}" && -d "$CACHE_DIR" ]]; then
            find "$CACHE_DIR" -name ".*.tmp.$$" -type f -delete 2>/dev/null || true
        fi

        return 0
    }

    # EXIT trap: run cleanup, but do NOT overwrite the current exit status.
    # The cleanup function always returns 0; we restore $? after it.
    _bc_on_exit() {
        local saved_status=$?
        cleanup
        return "$saved_status"
    }
    trap '_bc_on_exit' EXIT

    # Signal-specific handlers: cleanup, clear trap, exit conventional status.
    # Clearing the trap prevents recursive invocation if cleanup itself triggers
    # the same signal.
    _bc_on_INT()  { cleanup; trap - INT;  exit 130; }
    _bc_on_TERM() { cleanup; trap - TERM; exit 143; }
    _bc_on_HUP()  { cleanup; trap - HUP;  exit 129; }
    _bc_on_QUIT() { cleanup; trap - QUIT;  exit 131; }

    trap '_bc_on_INT'  INT   # Ctrl+C
    trap '_bc_on_TERM' TERM  # termination signal
    trap '_bc_on_HUP'  HUP   # hangup signal
    trap '_bc_on_QUIT' QUIT  # quit signal
    
    # Function to register temp files for cleanup
    register_temp_file() {
        local temp_file="$1"
        if [[ -n "$temp_file" ]]; then
            TEMP_FILES+=("$temp_file")
        fi
    }

    # Function to register temp directories for cleanup
    register_temp_dir() {
        local temp_dir="$1"
        if [[ -n "$temp_dir" ]]; then
            TEMP_DIRS+=("$temp_dir")
        fi
    }
    
    # Function to register PIDs for cleanup
    register_pid() {
        local pid="$1"
        if [[ -n "$pid" ]]; then
            if [[ -z "${BREW_CHANGE_PIDS:-}" ]]; then
                BREW_CHANGE_PIDS=("$pid")
            else
                BREW_CHANGE_PIDS+=("$pid")
            fi
        fi
    }

    unregister_pid() {
        local removed_pid="$1"
        local remaining=()
        local pid
        for pid in "${BREW_CHANGE_PIDS[@]:-}"; do
            if [[ "$pid" != "$removed_pid" ]]; then
                remaining+=("$pid")
            fi
        done
        BREW_CHANGE_PIDS=("${remaining[@]}")
    }

    register_terminal_state() {
        BREW_CHANGE_STTY_STATE="$1"
    }

    unregister_terminal_state() {
        BREW_CHANGE_STTY_STATE=""
    }
fi
