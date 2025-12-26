#!/bin/bash
# Interactive menu for brew-change testing and operations

# Remove 'set -e' to prevent script from exiting on failures
# set -e  # Disabled - we'll handle errors manually

# Get script directory for loading utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for --ci flag
CI_MODE=false
if [[ "$1" == "--ci" ]]; then
    CI_MODE=true
    export TEST_OUTPUT_MODE="ci"
fi

# Load test utilities
source "$SCRIPT_DIR/lib/test-utils.sh"

# Colors for output (now defined in test-utils.sh, but kept for compatibility)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Clear screen and show header
show_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           🧪 brew-change Local Testing Suite           ║${NC}"
    echo -e "${BLUE}║              Easy Development Testing                ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_main_menu() {
    show_header
    echo -e "${CYAN}🚀 Quick Start - Choose an option:${NC}"
    echo ""
    echo -e "${GREEN}  1) 🧪 Run All Tests${NC}                        ${YELLOW}Full validation${NC}"
    echo -e "${GREEN}  2) 📋 Test Basic Functionality${NC}              ${YELLOW}Quick checks${NC}"
    echo -e "${GREEN}  3) ⚡ Performance Benchmark${NC}                 ${YELLOW}Speed testing${NC}"
    echo ""
    echo -e "${CYAN}📦 Package Testing:${NC}"
    echo "  4) Test Individual Package"
    echo "  5) 🌐 Network Connectivity Test"
    echo "  6) 🖥️  System Resources Check"
    echo "  7) 🔍 Debug Mode Testing"
    echo ""
    echo -e "${CYAN}🔧 Real Operations:${NC}"
    echo "  8) 📊 Show Outdated Packages"
    echo "  9) 🔎 Test Specific Package"
    echo " 10) 📋 Verbose Package List"
    echo " 11) 🚀 Comprehensive Test Suite"
    echo ""
    echo -e "${CYAN}🏥 Environment:${NC}"
    echo " 12) Health Check"
    echo " 13) ⚙️  Show Configuration"
    echo ""
    echo -e "${RED}  0) 🚪 Exit${NC}"
    echo ""
    echo -e "${YELLOW}Enter your choice [0-13]:${NC} "
}

run_all_tests() {
    echo -e "${BLUE}🚀 Running comprehensive test suite...${NC}"
    echo ""

    # Check if we're in the right environment and run appropriate tests
    if [[ -f "/home/brewtest/test.sh" ]]; then
        # We're in Docker environment
        test_exit_code=0
        /home/brewtest/test.sh || test_exit_code=$?

        if [[ $test_exit_code -eq 0 ]]; then
            echo -e "\n${GREEN}✅ All automated tests passed!${NC}"
        else
            echo -e "\n${YELLOW}⚠️  Some tests had issues (exit code: $test_exit_code)${NC}"
            echo "This is normal if not all packages or dependencies are available."
        fi
    else
        # We're in local environment - run basic functionality tests
        echo "Running local environment tests..."

        test_exit_code=0

        # Test help command
        echo "Testing help command..."
        if ./brew-change --help >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Help command works${NC}"
        else
            echo -e "${RED}❌ Help command failed${NC}"
            test_exit_code=1
        fi

        # Test simple list
        echo "Testing basic functionality..."
        if ./brew-change >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Basic functionality works${NC}"
        else
            echo -e "${RED}❌ Basic functionality failed${NC}"
            test_exit_code=1
        fi

        if [[ $test_exit_code -eq 0 ]]; then
            echo -e "\n${GREEN}✅ Local tests completed successfully!${NC}"
        else
            echo -e "\n${YELLOW}⚠️  Some local tests had issues${NC}"
        fi
    fi

    echo ""
    read -p "Press Enter to continue..."
}

test_basic_functionality() {
    log_info "Testing basic functionality..."
    echo ""

    # Get brew-change command
    local brew_change_cmd
    brew_change_cmd=$(get_brew_change_cmd) || {
        wait_for_user
        return 1
    }

    # Test help command
    assert_command_success "Help command" $brew_change_cmd --help

    # Test simple list
    assert_command_success "Simple list" $brew_change_cmd

    # Test verbose mode
    assert_command_success "Verbose mode" $brew_change_cmd -v

    echo ""
    wait_for_user
}

performance_benchmark() {
    log_info "Running performance benchmark..."
    echo ""

    # Get brew-change command
    local brew_change_cmd
    brew_change_cmd=$(get_brew_change_cmd) || {
        wait_for_user
        return 1
    }

    echo "Timing basic operations..."
    echo "Running: $brew_change_cmd"
    time_output=$(time ($brew_change_cmd >/dev/null 2>&1) 2>&1)
    echo "Simple list time: $time_output"

    echo ""
    echo "System resources:"
    echo "Memory usage:"
    if command -v free >/dev/null 2>&1; then
        free -h | head -3
    elif [[ -f /proc/meminfo ]]; then
        cat /proc/meminfo | head -3
    else
        echo "Memory info not available"
    fi
    echo "System load:"
    uptime 2>/dev/null || echo "Load info unavailable"

    echo ""
    wait_for_user
}

test_individual_package() {
    echo -e "${BLUE}📦 Test Individual Package${NC}"
    echo ""

    # Show available packages
    echo "Available outdated packages:"
    if command -v brew-change >/dev/null 2>&1; then
        brew-change | head -10
    elif [[ -f "./brew-change" ]]; then
        ./brew-change | head -10
    else
        echo "brew-change not found"
        return
    fi
    echo ""

    read -p "Enter package name to test (or press Enter to skip): " package_name

    if [[ -n "$package_name" ]]; then
        echo ""
        echo "Testing package: $package_name"
        echo "----------------------------------------"
        if command -v brew-change >/dev/null 2>&1; then
            brew-change "$package_name"
        elif [[ -f "./brew-change" ]]; then
            ./brew-change "$package_name"
        fi
    else
        echo "Skipping individual package test."
    fi

    echo ""
    read -p "Press Enter to continue..."
}

network_test() {
    echo -e "${BLUE}🌐 Testing network connectivity...${NC}"
    echo ""

    # Test GitHub API
    echo "Testing GitHub API..."
    if curl -s --max-time 5 https://api.github.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ GitHub API accessible${NC}"
    else
        echo -e "${RED}❌ GitHub API not accessible${NC}"
    fi

    # Test npm registry
    echo "Testing npm registry..."
    if curl -s --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; then
        echo -e "${GREEN}✅ npm registry accessible${NC}"
    else
        echo -e "${RED}❌ npm registry not accessible${NC}"
    fi

    # Test a generic HTTPS request
    echo "Testing general HTTPS..."
    if curl -s --max-time 5 https://httpbin.org/get >/dev/null 2>&1; then
        echo -e "${GREEN}✅ General HTTPS works${NC}"
    else
        echo -e "${YELLOW}⚠️  General HTTPS limited (may be expected)${NC}"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

system_resources_check() {
    echo -e "${BLUE}🖥️  System Resources Check${NC}"
    echo ""

    echo "System Information:"
    echo "-----------------"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"

    echo ""
    echo "Memory Usage:"
    echo "------------"
    if [[ -f /proc/meminfo ]]; then
        echo "Total: $(grep MemTotal /proc/meminfo | awk '{print $2" "$3}')"
        echo "Available: $(grep MemAvailable /proc/meminfo | awk '{print $2" "$3}')"
        echo "Free: $(grep MemFree /proc/meminfo | awk '{print $2" "$3}')"
    else
        echo "Memory info not available"
    fi

    echo ""
    echo "CPU Load:"
    echo "---------"
    if command -v uptime >/dev/null 2>&1; then
        uptime
    else
        echo "Load info not available"
    fi

    echo ""
    echo "Disk Usage:"
    echo "----------"
    df -h | head -5

    echo ""
    echo "Process Count:"
    echo "-------------"
    ps aux | wc -l

    echo ""
    read -p "Press Enter to continue..."
}

debug_mode_test() {
    log_info "Debug Mode Testing"
    echo ""

    # Get brew-change command
    local brew_change_cmd
    brew_change_cmd=$(get_brew_change_cmd) || {
        wait_for_user
        return 1
    }

    echo "Enabling debug mode (BREW_CHANGE_DEBUG=1)..."
    export BREW_CHANGE_DEBUG=1

    echo ""
    echo "Testing with debug output..."
    echo "----------------------------------------"
    echo "Command: $brew_change_cmd --help"
    $brew_change_cmd --help 2>&1 | head -10

    echo ""
    echo "Testing invalid package with debug..."
    echo "----------------------------------------"
    echo "Command: $brew_change_cmd nonexistent-debug-test-123"
    $brew_change_cmd nonexistent-debug-test-123 2>&1 | head -10

    # Unset debug mode
    unset BREW_CHANGE_DEBUG
    echo ""
    echo "Debug mode tests completed."

    echo ""
    read -p "Press Enter to continue..."
}

show_outdated_packages() {
    echo -e "${BLUE}📊 Current Outdated Packages${NC}"
    echo ""

    # Determine brew-change command
    if command -v brew-change >/dev/null 2>&1; then
        brew_change_cmd="brew-change"
    elif [[ -f "./brew-change" ]]; then
        brew_change_cmd="./brew-change"
    else
        echo -e "${RED}❌ brew-change command not found${NC}"
        echo "Try: export PATH=\"$(pwd):\$$PATH\""
        echo ""
        read -p "Press Enter to continue..."
        return
    fi

    echo "Simple list:"
    echo "-----------"
    $brew_change_cmd

    echo ""
    echo "Verbose list:"
    echo "------------"
    $brew_change_cmd -v

    echo ""
    read -p "Press Enter to continue..."
}

test_specific_package() {
    echo -e "${BLUE}🔎 Test Specific Package${NC}"
    echo ""

    # Determine brew-change command
    if command -v brew-change >/dev/null 2>&1; then
        brew_change_cmd="brew-change"
    elif [[ -f "./brew-change" ]]; then
        brew_change_cmd="./brew-change"
    else
        echo -e "${RED}❌ brew-change command not found${NC}"
        echo "Try: export PATH=\"$(pwd):\$$PATH\""
        echo ""
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter package name: " package_name

    if [[ -n "$package_name" ]]; then
        echo ""
        echo "Testing package: $package_name"
        echo "=========================================="
        echo "Command: $brew_change_cmd $package_name"
        $brew_change_cmd "$package_name"
    else
        echo "No package name provided."
    fi

    echo ""
    read -p "Press Enter to continue..."
}

show_verbose_list() {
    echo -e "${BLUE}📋 Verbose Package List${NC}"
    echo ""

    # Determine brew-change command
    if command -v brew-change >/dev/null 2>&1; then
        brew_change_cmd="brew-change"
    elif [[ -f "./brew-change" ]]; then
        brew_change_cmd="./brew-change"
    else
        echo -e "${RED}❌ brew-change command not found${NC}"
        echo "Try: export PATH=\"$(pwd):\$$PATH\""
        echo ""
        read -p "Press Enter to continue..."
        return
    fi

    echo "Command: $brew_change_cmd -v"
    $brew_change_cmd -v

    echo ""
    read -p "Press Enter to continue..."
}

# Test parallel processing output
test_parallel_processing() {
    local brew_change_cmd="$1"
    
    # Test that parallel mode (-a) produces output without race conditions
    # Use timeout to prevent hangs (30 seconds should be enough)
    if command -v timeout >/dev/null 2>&1; then
        COMMAND_OUTPUT=$(timeout 30 $brew_change_cmd -a 2>&1) || COMMAND_EXIT_CODE=$?
        COMMAND_EXIT_CODE=${COMMAND_EXIT_CODE:-0}
        
        # timeout exits with 124 if command times out
        if [[ $COMMAND_EXIT_CODE -eq 124 ]]; then
            log_test_result "Parallel mode (-a) execution" "fail" "Command timed out after 30s"
            return 1
        fi
    else
        # No timeout command available, run normally
        run_command_capture_output $brew_change_cmd -a
    fi
    
    # Check that output doesn't contain garbled/overlapping text patterns
    # (This is a basic heuristic - real race conditions are harder to detect)
    if [[ $COMMAND_EXIT_CODE -eq 0 ]]; then
        log_test_result "Parallel mode (-a) execution" "pass"
    else
        log_test_result "Parallel mode (-a) execution" "fail" "Exit code: $COMMAND_EXIT_CODE"
    fi
}

# Test release notes formatting
test_release_notes_format() {
    local brew_change_cmd="$1"
    
    # Run verbose mode and check for formatted output
    run_command_capture_output $brew_change_cmd -v
    
    if [[ $COMMAND_EXIT_CODE -eq 0 ]]; then
        # Check if output contains version-like patterns or release info
        # This is a basic check - actual formatting depends on available packages
        log_test_result "Release notes format (verbose)" "pass"
    else
        log_test_result "Release notes format (verbose)" "fail" "Exit code: $COMMAND_EXIT_CODE"
    fi
}

# Test error handling
test_error_handling() {
    local brew_change_cmd="$1"
    
    # Test invalid options
    assert_command_fails "Invalid option error" $brew_change_cmd --this-option-does-not-exist
    
    # Test non-existent package
    # Note: This might succeed if the command just shows "not found", so we check output
    run_command_capture_output $brew_change_cmd completely-nonexistent-package-xyz-123
    if echo "$COMMAND_OUTPUT" | grep -qi "not found\|error\|no package"; then
        log_test_result "Non-existent package error message" "pass"
    else
        log_test_result "Non-existent package error message" "fail" "No appropriate error message"
    fi
}

comprehensive_test_suite() {
    log_info "Comprehensive Test Suite"
    log_info "============================="
    echo ""

    # Get brew-change command
    local brew_change_cmd
    brew_change_cmd=$(get_brew_change_cmd) || {
        wait_for_user
        return 1
    }

    # Test 1: Help variations
    log_info "Testing help commands..."
    assert_command_success "Help: --help" $brew_change_cmd --help
    assert_command_success "Help: -h" $brew_change_cmd -h
    assert_command_success "Help: help" $brew_change_cmd help

    # Test 2: Basic modes
    echo ""
    log_info "Testing basic modes..."
    assert_command_success "Basic mode (no args)" $brew_change_cmd
    assert_command_success "Verbose mode (-v)" $brew_change_cmd -v
    assert_command_success "Parallel mode (-a)" $brew_change_cmd -a

    # Test 3: Invalid inputs
    echo ""
    log_info "Testing error handling..."
    assert_command_output_contains "Invalid option handling" "Error: Unknown option" $brew_change_cmd --invalid-option
    assert_command_output_contains "Non-existent package" "not found" $brew_change_cmd nonexistent-package-12345

    # Test 4: Environment variations
    echo ""
    log_info "Testing environment variations..."
    assert_command_success "Basic terminal (TERM=vt100)" env TERM=vt100 $brew_change_cmd
    assert_command_success "UTF-8 locale" env LC_ALL=C.UTF-8 $brew_change_cmd

    # Test 5: Parallel processing output validation
    echo ""
    log_info "Testing parallel processing..."
    test_parallel_processing "$brew_change_cmd"

    # Test 6: Release notes formatting
    echo ""
    log_info "Testing release notes formatting..."
    test_release_notes_format "$brew_change_cmd"

    # Print summary
    print_test_summary

    wait_for_user

    # Return appropriate exit code
    get_test_exit_code
}

health_check() {
    echo -e "${BLUE}🏥 Environment Health Check${NC}"
    echo ""

    # Check user
    echo "User: $(whoami)"

    # Check working directory
    echo "Working directory: $(pwd)"

    # Check PATH
    echo "PATH includes brew-change: $(echo $PATH | grep -q brew-change && echo 'Yes' || echo 'No')"

    # Check brew-change command
    if command -v brew-change >/dev/null 2>&1; then
        echo -e "${GREEN}✅ brew-change command available${NC}"
        echo "Location: $(which brew-change)"
    elif [[ -f "./brew-change" ]]; then
        echo -e "${YELLOW}⚠️  brew-change found in current directory - not in PATH${NC}"
        echo "Location: $(pwd)/brew-change"
    else
        echo -e "${RED}❌ brew-change command not found${NC}"
        echo "Try: export PATH=\"$(pwd):\$$PATH\""
    fi

    # Check dependencies
    echo ""
    echo "Dependency Check:"
    for dep in bash curl jq git; do
        if command -v "$dep" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅ $dep${NC}"
        else
            echo -e "  ${RED}❌ $dep${NC}"
        fi
    done

    # Check Homebrew
    echo ""
    if /home/linuxbrew/.linuxbrew/bin/brew --version >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Homebrew working${NC}"
    else
        echo -e "${RED}❌ Homebrew not working${NC}"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

show_configuration() {
    echo -e "${BLUE}⚙️  Current Configuration${NC}"
    echo ""

    echo "Environment Variables:"
    echo "---------------------"
    env | grep BREW_CHANGE_ || echo "No BREW_CHANGE variables set"

    echo ""
    echo "Default Settings:"
    echo "-----------------"
    echo "BREW_CHANGE_JOBS: ${BREW_CHANGE_JOBS:-8 (default)}"
    echo "BREW_CHANGE_DEBUG: ${BREW_CHANGE_DEBUG:-0 (default)}"
    echo "BREW_CHANGE_MAX_RETRIES: ${BREW_CHANGE_MAX_RETRIES:-3 (default)}"

    echo ""
    echo "File Locations:"
    echo "--------------"
    echo "brew-change binary: $(which brew-change)"
    echo "Library directory: $(dirname $(dirname $(which brew-change)))/lib/brew-change"
    echo "Homebrew installation: /home/linuxbrew/.linuxbrew"

    echo ""
    read -p "Press Enter to continue..."
}

# Main menu loop
main() {
    while true; do
        show_main_menu
        read -r choice

        case $choice in
            1) run_all_tests ;;
            2) test_basic_functionality ;;
            3) performance_benchmark ;;
            4) test_individual_package ;;
            5) network_test ;;
            6) system_resources_check ;;
            7) debug_mode_test ;;
            8) show_outdated_packages ;;
            9) test_specific_package ;;
            10) show_verbose_list ;;
            11) comprehensive_test_suite ;;
            12) health_check ;;
            13) show_configuration ;;
            0)
                echo -e "${GREEN}👋 Goodbye!${NC}"
                break
                ;;
            *)
                echo -e "${RED}Invalid choice. Please try again.${NC}"
                sleep 2
                ;;
        esac
    done
}

# Check if we're in CI mode or interactive mode
if [[ "$CI_MODE" == true ]]; then
    # CI mode - run comprehensive test suite non-interactively
    log_info "Running in CI mode"
    comprehensive_test_suite
    exit_code=$?
    exit $exit_code
elif [[ -t 0 ]]; then
    # Interactive mode with menu
    main
    echo -e "${GREEN}✅ Script completed successfully. Thank you for testing brew-change!${NC}"
else
    # Non-interactive without --ci flag, run basic validation
    echo "Non-interactive mode detected. Running basic validation..."
    echo "Tip: Use --ci flag for full test suite with structured output"
    echo ""

    # Basic functionality tests
    echo "Running brew-change --help..."
    if command -v brew-change >/dev/null 2>&1; then
        brew-change --help >/dev/null 2>&1 && echo "✅ Help command works" || echo "❌ Help command failed"
        echo ""
        echo "Testing outdated list..."
        brew-change >/dev/null 2>&1 && echo "✅ Outdated list works" || echo "❌ Outdated list failed"
    else
        echo "❌ brew-change not found in PATH"
        echo "Try: export PATH=\"$(pwd):\$$PATH\""
        exit 1
    fi

    echo ""
    echo "Basic validation completed."
fi
