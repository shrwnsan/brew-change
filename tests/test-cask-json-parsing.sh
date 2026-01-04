#!/bin/bash
# Unit test for cask JSON field handling
# Verifies that casks use .token field instead of .name for identification

# Test helper functions
test_count=0
pass_count=0
fail_count=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected="$3"

    ((test_count++))
    echo -n "Test $test_count: $test_name ... "

    local result
    result=$(eval "$test_command" 2>/dev/null)

    if [[ "$result" == "$expected" ]]; then
        echo "PASS"
        ((pass_count++))
        return 0
    else
        echo "FAIL"
        echo "  Expected: $expected"
        echo "  Got:      $result"
        ((fail_count++))
        return 1
    fi
}

echo "======================================"
echo "Cask JSON Field Handling Unit Tests"
echo "======================================"
echo ""

# Sample JSON structure matching Homebrew's API v2
SAMPLE_CASK_JSON='{
  "formulae": [
    {"name": "example-formula", "current_version": "1.0.0"}
  ],
  "casks": [
    {
      "token": "rectangle",
      "name": ["Rectangle"],
      "installed_versions": ["0.88"],
      "current_version": "0.92"
    },
    {
      "token": "visual-studio-code",
      "name": ["Visual Studio Code"],
      "installed_versions": ["1.80.0"],
      "current_version": "1.85.0"
    }
  ]
}'

echo "Test Suite: Cask Token Extraction"
echo "-----------------------------------"

# Test 1: Extract cask tokens (parallel.sh line 70)
run_test \
    "Extract cask tokens from JSON" \
    "echo '$SAMPLE_CASK_JSON' | jq -r '.casks[].token'" \
    "rectangle
visual-studio-code"

# Test 2: Select cask by token (brew.sh line 69)
run_test \
    "Select cask by token field" \
    "echo '$SAMPLE_CASK_JSON' | jq -r '.casks[] | select(.token == \"rectangle\") | .current_version'" \
    "0.92"

# Test 3: Select cask by token with multiple matches
run_test \
    "Select specific cask by token" \
    "echo '$SAMPLE_CASK_JSON' | jq -r '.casks[] | select(.token == \"visual-studio-code\") | .current_version'" \
    "1.85.0"

# Test 4: Display formatting with name array (brew.sh line 138)
run_test \
    "Display cask with formatted name array" \
    "echo '$SAMPLE_CASK_JSON' | jq -r '.casks[] | select(.token == \"rectangle\") | \"\(.name | join(\" / \")) (\(.installed_versions | join(\", \")) → \(.current_version))\"'" \
    "Rectangle (0.88 → 0.92)"

# Test 5: Verify .name is an array (demonstrating the bug)
run_test \
    "Verify cask .name field is an array" \
    "echo '$SAMPLE_CASK_JSON' | jq -r '.casks[] | select(.token == \"rectangle\") | .name | type'" \
    "array"

# Test 6: Verify .token is a string
run_test \
    "Verify cask .token field is a string" \
    "echo '$SAMPLE_CASK_JSON' | jq -r '.casks[] | select(.token == \"rectangle\") | .token | type'" \
    "string"

# Test 7: Formula .name is a string (contrast with casks)
run_test \
    "Verify formula .name field is a string" \
    "echo '$SAMPLE_CASK_JSON' | jq -r '.formulae[] | .name | type'" \
    "string"

echo ""
echo "======================================"
echo "Test Results Summary"
echo "======================================"
echo "Total tests:  $test_count"
echo "Passed:       $pass_count"
echo "Failed:       $fail_count"
echo ""

if [[ $fail_count -eq 0 ]]; then
    echo "All tests PASSED!"
    exit 0
else
    echo "Some tests FAILED!"
    exit 1
fi
