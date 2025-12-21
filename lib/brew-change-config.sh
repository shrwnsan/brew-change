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
    
    # Check for optional commands
    local optional_deps=()
    if ! command -v gh >/dev/null 2>&1; then
        optional_deps+=("gh")
    fi
    
    # Report missing required dependencies
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}" >&2
        echo "Please install the missing commands and try again." >&2
        return 1
    fi
    
    # Report missing optional dependencies
    if [[ ${#optional_deps[@]} -gt 0 ]]; then
        echo "Warning: Missing optional dependencies: ${optional_deps[*]}" >&2
        echo "These commands enhance functionality but are not required." >&2
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
    
    cleanup() {
        local has_temp_files=false
        
        # Check if we have any temp files to clean
        if [[ -n "${TEMP_FILES[@]:-}" ]]; then
            for temp_file in "${TEMP_FILES[@]:-}"; do
                if [[ -n "$temp_file" && -f "$temp_file" ]]; then
                    has_temp_files=true
                    break
                fi
            done
        fi
        
        # Check if we have any temp files in cache directory
        if [[ ! $has_temp_files && -n "${CACHE_DIR:-}" && -d "$CACHE_DIR" ]]; then
            if find "$CACHE_DIR" -name ".*.tmp.$$" -type f -exec test -f {} \; >/dev/null; then
                has_temp_files=true
            fi
        fi
        
        # Check if we have any PIDs to kill
        if [[ ! $has_temp_files && -n "${BREW_CHANGE_PIDS:-}" ]]; then
            local has_pids=false
            for pid in "${BREW_CHANGE_PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    has_pids=true
                    break
                fi
            done
            has_temp_files=$has_pids
        fi
        
        # Only show cleanup and exit if there's something to clean
        if $has_temp_files; then
            echo "Cleaning up temporary files..." >&2

            # Remove all registered temp files
            for temp_file in "${TEMP_FILES[@]:-}"; do
                if [[ -n "$temp_file" && -f "$temp_file" ]]; then
                    rm -f "$temp_file" 2>/dev/null || true
                fi
            done

            # Cleanup any remaining temp files in cache directory
            if [[ -n "${CACHE_DIR:-}" && -d "$CACHE_DIR" ]]; then
                find "$CACHE_DIR" -name ".*.tmp.$$" -type f -delete 2>/dev/null || true
            fi

            # Kill any child processes (for parallel processing)
            if [[ -n "${BREW_CHANGE_PIDS:-}" ]]; then
                for pid in "${BREW_CHANGE_PIDS[@]}"; do
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -TERM "$pid" 2>/dev/null || true
                    fi
                done
            fi

            exit 130  # Standard exit code for SIGINT
        fi

        # Return success when no cleanup needed
        return 0
    }
    
    # Trap various signals for cleanup
    trap cleanup EXIT
    trap cleanup INT   # Ctrl+C
    trap cleanup TERM  # termination signal
    trap cleanup HUP   # hangup signal
    trap cleanup QUIT  # quit signal
    
    # Function to register temp files for cleanup
    register_temp_file() {
        local temp_file="$1"
        if [[ -n "$temp_file" ]]; then
            TEMP_FILES+=("$temp_file")
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
fi
