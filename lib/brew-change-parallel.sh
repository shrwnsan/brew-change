#!/usr/bin/env bash
# Parallel processing functions for brew-change

# Function to check system resources
check_system_resources() {
    # Check load average on Unix-like systems
    local load_threshold=4.0
    local current_load=0
    
    if command -v uptime >/dev/null 2>&1; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            current_load=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//')
        else
            # Linux
            current_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
        fi
    fi
    
    # Convert to float comparison
    if (( $(echo "$current_load > $load_threshold" | bc -l 2>/dev/null || echo "0") )); then
        echo "Warning: High system load ($current_load) detected, reducing parallel jobs" >&2
        return 1
    fi
    
    return 0
}

# Function to adjust jobs based on system resources
adjust_jobs_for_resources() {
    local requested_jobs="$1"
    local adjusted_jobs="$requested_jobs"
    
    # Check system resources
    if ! check_system_resources; then
        # Reduce jobs by half if system is under load
        adjusted_jobs=$((requested_jobs / 2))
        [[ $adjusted_jobs -lt 1 ]] && adjusted_jobs=1
        echo "Adjusted parallel jobs from $requested_jobs to $adjusted_jobs due to system load" >&2
    fi
    
    echo "$adjusted_jobs"
}



# Function to process packages in parallel
process_packages_parallel() {
    local outdated_packages="$1"
    local jobs="$2"

    # Adjust jobs based on system resources
    jobs=$(adjust_jobs_for_resources "$jobs")

    # ENHANCED: Create unified array for all packages - our new functions handle everything!
    local packages=()

    # Add formulas
    while IFS= read -r package; do
        if [[ -n "$package" && "$package" != "null" ]]; then
            packages+=("$package:false")
        fi
    done < <(echo "$outdated_packages" | jq -r '.formulae[].name' 2>/dev/null)

    # Add casks
    while IFS= read -r package; do
        if [[ -n "$package" && "$package" != "null" ]]; then
            packages+=("$package:true")
        fi
    done < <(echo "$outdated_packages" | jq -r '.casks[].name' 2>/dev/null)

    if [[ ${#packages[@]} -eq 0 ]]; then
        echo "No outdated packages found."
        return 0
    fi
    
    # Process packages in parallel using background processes
    if [[ ${#packages[@]} -eq 1 ]]; then
        echo "Processing ${#packages[@]} package..."
    else
        echo "Processing ${#packages[@]} packages in parallel (max $jobs jobs)..."
    fi
    echo ""

    # Process in batches to respect job limit
    local batch_size=$jobs
    local processed=0
    local start_time=$(date +%s)

    for (( i=0; i<${#packages[@]}; i+=batch_size )); do
        local pids=()
        local temp_files=()

        # Process a batch
        for (( j=i; j<i+batch_size && j<${#packages[@]}; j++ )); do
            package_type="${packages[j]}"
            package="${package_type%:*}"
            is_cask="${package_type#*:}"

            # Store temp file name for later output
            local temp_file=$(mktemp -t brew-change-output.XXXXXX 2>/dev/null)
            temp_files+=("$temp_file")

            # Add small delay before starting each job to avoid thundering herd
            if [[ $j -gt 0 ]]; then
                sleep 0.$((RANDOM % 5 + 1))  # 0.1-0.5s random delay
            fi

            # Run in background
            {
                # Capture output to temp file, handling failures gracefully
                if show_package_changelog "$package" > "$temp_file" 2>&1; then
                    # Success, output already captured
                    true
                else
                    # Failure occurred, but we want to continue processing other packages
                    echo "Error: Failed to process package '$package'" > "$temp_file"
                    echo "This package will be skipped, but other packages will continue processing." >> "$temp_file"
                    true  # Explicit success to prevent script termination
                fi
            } &
            local bg_pid=$!
            pids+=("$bg_pid")

            # Register PID for cleanup if available
            if [[ -z "${BREW_CHANGE_SUBPROCESS:-}" ]] && command -v register_pid >/dev/null 2>&1; then
                register_pid "$bg_pid"
            fi
        done

        # Wait for current batch to complete
        for pid_idx in "${!pids[@]}"; do
            pid="${pids[pid_idx]}"
            wait "$pid"
            # Update progress counter immediately after each job completes
            ((processed++))
            if [[ ${#packages[@]} -gt 1 ]]; then
                echo -ne "\r\033[KProgress: $processed/${#packages[@]} packages processed...\n" >&2
            fi
        done

        # Output all temp files for this batch with proper separators
        for (( j=0; j<${#temp_files[@]}; j++ )); do
            if [[ -f "${temp_files[j]}" ]]; then
                # Add newline before each package output for better separation
                echo ""
                cat "${temp_files[j]}"
                # Add separator for all packages except the last one in this batch
                if [[ $((j + 1)) -lt ${#temp_files[@]} ]] || [[ $((i + batch_size)) -lt ${#packages[@]} ]]; then
                    echo "---"
                fi
                # Clean up
                rm -f "${temp_files[j]}" 2>/dev/null
            fi
        done

        # Add rate limiting delay between batches to avoid hitting API limits
        if [[ $((i + batch_size)) -lt ${#packages[@]} ]]; then
            # Check if rate_limit_delay function exists and call it
            if declare -f rate_limit_delay >/dev/null 2>&1; then
                rate_limit_delay
            else
                # Fallback: sleep for configured delay
                sleep "${API_RATE_LIMIT_DELAY:-1}"
            fi
        fi
    done

    # Clear progress line and show summary for multi-package processing
    if [[ ${#packages[@]} -gt 1 ]]; then
        echo -ne "\r\033[K" >&2
        echo "" >&2
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "Completed processing $processed packages in ${duration}s" >&2
    fi
}
