#!/usr/bin/env bash
# Display formatting functions for brew-change

# Function to sanitize output by removing ANSI escape sequences and control characters
sanitize_output() {
    local input="$1"

    # Remove ANSI escape sequences (colors, formatting, etc.)
    # Use en_US.UTF-8 to support UTF-8 characters (emojis, arrows, etc.)
    input=$(echo "$input" | sed 's/\x1b\[[0-9;]*[mK]//g' 2>/dev/null || echo "$input")

    # Remove control characters (0x00-0x1F, 0x7F) but preserve printable characters
    # This preserves UTF-8 characters like → and 🎁 while removing actual control codes
    input=$(echo "$input" | tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null || echo "$input")

    echo "$input"
}

# Function to optimize GitHub markdown links and formatting
optimize_github_markdown() {
    local input="$1"

    # Clean up formatting and convert URLs to concise references
    # Note: Some sed implementations may show UTF-8 warnings with emojis, but output is correct
    ( echo "$input" | \
    # Convert all GitHub URLs to concise references
    sed 's|https://github\.com/[^/]*/[^/]*/pull/\([0-9]*\)|PR#\1|g' | \
    sed 's|https://github\.com/[^/]*/[^/]*/commit/\([a-f0-9]\{7\}\)[a-f0-9]*|Commit#\1|g' | \
    sed 's|https://github\.com/[^/]*/[^/]*/issues/\([0-9]*\)|Issue#\1|g' | \
    # Convert [#number](PR#number) pattern to (PR#number)
    sed 's/\[#\([0-9]*\)\](PR#\1)/(PR#\1)/g' | \
    # Fix double parentheses by removing one
    sed 's/((PR#\([0-9]*\)))/(PR#\1)/g' | \
    # Clean up dependency hash markdown syntax: replace with clean format using captured commit hash
    sed 's/.*Commit#\([a-f0-9]*\)).*/- Updated dependencies (Commit#\1):/' | \
    # Clean up issue references (conservative approach: leave plain #numbers unchanged)
    # sed 's/#\([0-9]\{1,\}\)/PR#\1/g' | \
    # UI/UX Consistency: Format "Full Changelog" lines with arrow indicator for external links
    sed 's/\*\*Full Changelog\*\*: */→ Full Changelog: /g' | \
    # UI/UX Standardization: Convert all bullet styles to consistent '-' format
    sed 's/^[[:space:]]*\*[[:space:]]*/- /g' | \
    sed 's/^[[:space:]]*\*[[:space:]]*/- /g' | \
    sed 's/^\*[[:space:]]*/- /g' | \
    # Clean up bullet points: normalize main bullets, preserve sub-bullets with 2-space indent
    sed 's/^[[:space:]]*-\{1\}[[:space:]]*/- /g' | \
    sed 's/^[[:space:]]*- /- /g' | \
    # Normalize sub-bullets to have exactly 2 spaces
    sed 's/^- \(@.*\)/  - \1/' | \
    # UI/UX Simplification: Convert GitHub username markdown links to simple @username format
    sed 's/\[@\([^]]*\)\](https:\/\/github\.com\/[^)]*)/@\1/g' | \
    sed 's/\[@\([^]]*\)\]([^)]*)/@\1/g' | \
    # UI/UX Improvement: Convert full commit hashes to GitHub standard hash format (7 chars)
    # Handle 40-character commit hashes at the beginning of lines (common format)
    sed 's/^\(- \)\([a-f0-9]\{40\}\)/\1Commit#\2/' | \
    # Handle standalone commit hashes of any length (7+ chars) that appear anywhere in text
    sed 's/\([[:space:]]\)\([a-f0-9]\{7,\}\)\([[:space:]]\)/\1Commit#\2\3/g' | \
    # Handle commit hashes at end of lines
    sed 's/\([[:space:]]\)\([a-f0-9]\{7,\}\)$/\1Commit#\2/g' | \
    # Handle commit hashes followed by punctuation
    sed 's/\([[:space:]]\)\([a-f0-9]\{7,\}\)\([.,;:!?]\)/\1Commit#\2\3/g' | \
    # Truncate all captured hashes to 7 characters after adding Commit# prefix
    sed 's/Commit#\([a-f0-9]\{7\}\)[a-f0-9]*/Commit#\1/g' | \
    # UI/UX Content Cleanup: Remove HTML and promotional content for terminal display
    perl -pe 'BEGIN{undef $/;} s/<details>.*?<\/details>//gs' | \
    # Remove promotional sections and HTML content (silent cleanup)
    perl -pe 's/Thoughts\? Questions\?.*$//gmi' | \
    perl -pe 's/<a href[^>]*>.*?<\/a>//g' | \
    perl -pe 's/<img[^>]*>//g' | \
    perl -pe 's/<\/?[^>]+>//g' | \
    # Remove stray dashes and formatting artifacts
    sed 's/-\s*-\s*$//g' | \
    sed 's/^-\s*-\s*$//g' | \
    sed 's/^\s*-\s*-\s*$//g' | \
    sed '/^\s*-\s*-\s*$/d' | \
    sed '/^\s*-\s*$/d' | \
    # Remove lines that are just dashes (with any spacing) - comprehensive patterns
    sed '/^[[:space:]]*-[[:space:]]*$/d' | \
    sed '/^[[:space:]]*--[[:space:]]*$/d' | \
    sed '/^[[:space:]]*-[[:space:]]*--[[:space:]]*$/d' | \
    # Remove lines containing only dash characters
    sed '/^[[:space:]]*[-]+[[:space:]]*$/d' | \
    # Remove empty lines
    sed '/^[[:space:]]*$/d' | \
    # Remove trailing whitespace
    sed 's/[[:space:]]*$//' | \
    # Filter download tables and replace with compact summaries
    filter_download_tables ) 2>/dev/null || true
}

# Function to filter download tables and replace with compact summaries
filter_download_tables() {
    local input="${1:-}"

    # Create the awk script in a variable for better readability
    local awk_script='
    BEGIN {
        in_table = 0
        table_rows = 0
        platforms = ""
        platform_count = 0
        table_type = ""
    }

    # Detect table headers (looking for File, Platform, Checksum patterns)
    /\|.*File.*\|.*Platform.*\|.*Checksum.*\|/ {
        in_table = 1
        table_rows = 0
        platforms = ""
        platform_count = 0
        delete seen_platforms
        table_type = "full_parse"
        next
    }

    # Detect other download table patterns for fallback handling
    # Simple pattern for tables with Download or Architecture headers (excluding File|Platform|Checksum)
    /\|.*Architecture.*\|/ {
        in_table = 1
        table_rows = 0
        table_type = "fallback"
        next
    }

    # Skip table separator line (contains only dashes and pipes)
    in_table && /\|[-\s\|]*\|/ {
        next
    }

    # Process table rows
    in_table && /\|/ {
        # For fallback tables, just count rows and skip processing
        if (table_type == "fallback") {
            table_rows++
            next
        }

        # Full parsing for recognized table format
        # Split the row by pipe character
        split($0, cols, /\|/)

        # Extract platform from the correct column (index 3, not 2)
        if (length(cols) >= 4) {
            platform = cols[3]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", platform)

            # Normalize platform text for better matching
            gsub(/\([^)]*\)/, "", platform)  # Strip parentheses
            gsub(/[[:space:]]+/, " ", platform)  # Normalize spaces
            platform = tolower(platform)  # Case-insensitive matching

            # Map common platform patterns to consolidated names
            # Handle specific patterns first
            if (platform ~ /apple silicon macos|intel macos|aarch64.*apple.*darwin|x86_64.*apple.*darwin|apple.*silicon.*macos|\barm.*\bmacos|\bmac\b|\bdarwin\b/) {
                platform = "macOS"
            } else if (platform ~ /arm64 windows|x64 windows|x86 windows|aarch64.*windows|arm64.*windows|x86_64.*windows|\bwindows\b/) {
                platform = "Windows"
            } else if (platform ~ /arm64 linux|x64 linux|x86 linux|armv7 linux|ppc64 linux|ppc64le linux|riscv linux|s390x linux|arm64 musl linux|x64 musl linux|x86 musl linux|armv6 musl linux|armv7 musl linux|powerpc.*linux|riscv.*linux|s390x.*linux|arm.*linux|x86.*linux|x64.*linux|aarch64.*linux|armv.*linux|ppc64.*linux|ppc64le.*linux|musl.*linux|\blinux\b/) {
                platform = "Linux"
            }

            # Remove any markdown links
            gsub(/\[([^\]]*)\]\([^)]*\)/, "\\1", platform)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", platform)
        }

        # Use associative array for proper deduplication (exact matching, not substring)
        if (platform != "" && platform != "Platform" && !(platform in seen_platforms)) {
            seen_platforms[platform] = 1
            if (platform_count == 0) {
                platforms = platform
            } else {
                platforms = platforms ", " platform
            }
            platform_count++
        }

        table_rows++
        next
    }

    # End of table (empty line or non-table line)
    in_table && !/\|/ {
        if (table_rows > 0) {
            if (table_type == "fallback") {
                # Fallback: Simple message for unrecognized table formats
                print "📥 Download details available in release notes"
                print "🔗 View full release for platform information and downloads"
                print ""
            } else {
                # Full parsing: Generate compact summary with platform details
                if (table_rows <= 4) {
                    print "📥 Available for: " platforms
                } else {
                    print "📥 Available for: " platforms " (" platform_count " variants)"
                }
                print ""
            }
        }
        in_table = 0
        table_rows = 0
        platforms = ""
        platform_count = 0
        table_type = ""
        delete seen_platforms
    }

    # Normal lines - print as-is
    !in_table {
        print $0
    }

    END {
        # Handle case where file ends with a table
        if (in_table && table_rows > 0) {
            if (table_type == "fallback") {
                # Fallback: Simple message for unrecognized table formats
                print "📥 Download details available in release notes"
                print "🔗 View full release for platform information and downloads"
                print ""
            } else {
                # Full parsing: Generate compact summary with platform details
                if (table_rows <= 4) {
                    print "📥 Available for: " platforms
                } else {
                    print "📥 Available for: " platforms " (" platform_count " variants)"
                }
            }
        }
    }'

    # Apply the awk script to the input
    if [[ -n "$input" ]]; then
        echo "$input" | awk "$awk_script"
    else
        awk "$awk_script"
    fi
}

# Function to format release notes
format_release_notes() {
    local release_json="$1"
    local version="$2"
    local github_repo="$3"  # Add GitHub repo for link generation
    local is_multi_package="${4:-false}"  # Add flag for multi-package context
    
    if [[ -z "$release_json" || "$release_json" == "null" ]]; then
        echo "  (No release notes found for $version)"
        echo ""
        return 0
    fi
    
    local published_at=$(echo "$release_json" | jq -r '.published_at // "Unknown date"')
    local body=$(echo "$release_json" | jq -r '.body // empty')
    local html_url=$(echo "$release_json" | jq -r '.html_url // ""')  # Get release URL
    
    # Format date relative to now using shared function
    local relative_date=$(get_release_relative_date "$release_json")
    
    # Output formatted release notes
    echo "📋 Release $version ($relative_date)"

    # Add release link if available
    if [[ -n "$html_url" && "$html_url" != "null" && "$html_url" != "" ]]; then
        echo "📋 Release: $html_url"
        echo ""
    fi

    # Debug info for unknown dates (only show if explicitly debugging)
    if [[ "$relative_date" == "Unknown date" ]]; then
        if [[ -n "$published_at" && "$published_at" != "null" ]]; then
            echo "🔍 Debug: Raw date from API: $published_at"
        else
            echo "🔍 Debug: No published_at field in API response"
            echo "🔍 Debug: This might be a tag without a formal GitHub release"
        fi
    fi

    if [[ -n "$body" && "$body" != "null" && "$body" != "" ]]; then
        # Sanitize body and optimize GitHub markdown formatting
        local sanitized_body
        sanitized_body=$(sanitize_output "$body")

        # Apply GitHub markdown optimization
        optimize_github_markdown "$sanitized_body"
    else
        echo "Release note has no details."
        # Add direct tag link as fallback
        if [[ -n "$github_repo" && "$github_repo" != "" ]]; then
            echo "🔗 Tag: https://github.com/$github_repo/releases/tag/$version"
        fi
    fi
    echo ""
}

# Function to show package changelog in full format
show_package_changelog_full() {
    local package="$1"
    local current_version="$2"
    local latest_version="$3"
    local package_info="$4"

    # Skip if versions are the same (should be handled earlier, but double-check)
    if [[ "$current_version" == "$latest_version" ]]; then
        return 0
    fi

    # Get package details
    local source_url=""
    local homepage=$(echo "$package_info" | jq -r '.homepage // ""' 2>/dev/null || echo "")

    # Handle different URL fields for casks vs formulas
    source_url=$(echo "$package_info" | jq -r '.urls.stable.url // ""' 2>/dev/null || echo "")
    if [[ -z "$source_url" || "$source_url" == "null" ]]; then
        # Try cask URL field for casks
        source_url=$(echo "$package_info" | jq -r '.url // ""' 2>/dev/null || echo "")
    fi

  
    # Check if this is an npm registry package first
    local relative_date="Unknown date"
    local release_json=""
    local is_npm_package=false

    if [[ -n "$source_url" && "$source_url" != "null" ]] && is_npm_registry_url "$source_url"; then
        # Handle npm registry package
        is_npm_package=true
        local npm_release_date
        if npm_release_date=$(get_npm_release_date "$source_url" "$latest_version" 2>/dev/null); then
            local npm_package_name
            npm_package_name=$(extract_npm_package_name "$source_url")
            release_json=$(create_npm_package_info "$npm_package_name" "$latest_version" "$npm_release_date")
            relative_date=$(get_release_relative_date "$release_json")
        else
            echo "⚠️ Could not fetch release date from npm registry" >&2
        fi
    fi

    # Try to extract GitHub repo (even for npm packages if homepage points to GitHub)
    local github_repo=""
    local should_use_github=false

    if [[ "$is_npm_package" != "true" ]] || ([[ "$is_npm_package" == "true" ]] && [[ -n "$homepage" && "$homepage" != "null" && "$homepage" =~ github\.com ]]); then
        if github_repo=$(extract_github_repo "$source_url" "$homepage" "$package"); then
            should_use_github=true
        else
            # Non-GitHub package - try to fetch release notes from other sources
            local domain=""
            if [[ -n "$source_url" && "$source_url" != "null" && "$source_url" != "" ]]; then
                domain=$(echo "$source_url" | sed -E 's|^https?://([^/]+).*$|\1|' | sed 's|^www\.||')
            fi

            # Use create_package_header to get proper installation date formatting
            create_package_header "$package" "$current_version" "$latest_version" "Unknown date" "$package_info"
            echo ""

            # Try to fetch non-GitHub release notes
            if [[ -n "$domain" ]]; then
                echo "🔍 Searching for release notes from $domain..."
                local non_github_result=""
                if non_github_result=$(fetch_non_github_release_notes "$package" "$latest_version" "$source_url" "$homepage"); then
                    # Extract the actual web URL from the result (lines containing URLs)
                    local web_url=""
                    web_url=$(echo "$non_github_result" | grep -o -E 'https?://[^[:space:]]+' | tail -1)

                    # Extract release notes (everything except the URL lines)
                    local release_notes=""
                    release_notes=$(echo "$non_github_result" | grep -v -E '^https?://' | sed '/^$/d')

                    if [[ -n "$release_notes" && "$release_notes" != "null" ]]; then
                        # Real release notes found - show them
                        echo ""
                        echo "📋 Release Notes:"
                        # Sanitize and format the release notes
                        local sanitized_notes
                        sanitized_notes=$(sanitize_output "$release_notes")
                        # Convert blank line markers to actual blank lines
                        sanitized_notes="${sanitized_notes//__BLANK_LINE_MARKER__/}"
                        echo "$sanitized_notes"
                        echo ""
                        # Only show "Learn more" if we have a URL that's NOT already in the release notes
                        if [[ -n "$web_url" ]]; then
                            # Check if the URL is already mentioned in the release notes
                            if [[ ! "$sanitized_notes" =~ $web_url ]]; then
                                echo "🌐 Learn more: $web_url"
                            fi
                        fi
                    else
                        # No real release notes found - show clean link only
                        echo ""
                        if [[ -n "$web_url" ]]; then
                            echo "🌐 Learn more: $web_url"
                        else
                            echo "🌐 Package: $domain"
                        fi
                    fi
                else
                    # Function returned 1 - no release notes found at all
                    echo "🚫 No release notes available."
                    echo ""
                    # Show learn more link without the searching message
                    local brew_info=""
                    local homepage=""
                    if brew_info=$(brew info --json=v2 "$package" 2>/dev/null); then
                        homepage=$(echo "$brew_info" | jq -r '.formulae[0].homepage // .casks[0].homepage // ""' 2>/dev/null || echo "")

                        # Convert http to https
                        if [[ -n "$homepage" && "$homepage" =~ ^http:// ]]; then
                            homepage="https://${homepage#http://}"
                        fi

                        if [[ -n "$homepage" && "$homepage" != "null" && "$homepage" != "" ]]; then
                            echo "🌐 Learn more: $homepage"
                        else
                            # Fallback to domain
                            echo "🌐 Learn more: https://$domain"
                        fi
                    else
                        # Fallback to domain
                        echo "🌐 Learn more: https://$domain"
                    fi
                fi
            else
                echo "🚫 No release notes available."
                echo ""
                echo "No GitHub repository found"
                echo "🌐 Package: More info available via 'brew info $package'"
            fi
            echo ""
            return 0
        fi

        # For npm+GitHub packages, use GitHub release notes but keep npm release date if we have it
        if [[ "$is_npm_package" == "true" && "$should_use_github" == "true" && -n "$release_json" ]]; then
            # We have npm info - keep it for display but don't fetch GitHub (avoid API calls)
            # The npm info already has the date, and GitHub release notes will be fetched later if needed
            :
        elif [[ "$should_use_github" == "true" ]]; then
            # Pure GitHub package or npm package without release date info
            # Handle revision numbers in version (e.g., 0.61_1 -> 0.61)
            local github_version="$latest_version"
            if [[ "$latest_version" =~ ^(.+_[0-9]+)$ ]]; then
                # Strip revision number for GitHub lookup
                github_version="${latest_version%_*}"
            fi
            release_json=$(fetch_github_release "$github_repo" "$github_version" 2>/dev/null)
            if [[ -n "$release_json" && "$release_json" != "null" ]]; then
                relative_date=$(get_release_relative_date "$release_json")
            else
                # No release found, fall back to treating as non-GitHub
                should_use_github=false
            fi
        fi
    fi

    # If GitHub detection failed (no releases found), handle as non-GitHub package
    if [[ "$should_use_github" == "false" ]]; then
        local domain=""
        if [[ -n "$source_url" && "$source_url" != "null" && "$source_url" != "" ]]; then
            domain=$(echo "$source_url" | sed -E 's|^https?://([^/]+).*$|\1|' | sed 's|^www\.||')
        fi

        # Use create_package_header to get proper installation date formatting
        create_package_header "$package" "$current_version" "$latest_version" "Unknown date" "$package_info"
        echo ""

        # Try to fetch non-GitHub release notes
        if [[ -n "$domain" ]]; then
            local non_github_result=""
            if non_github_result=$(fetch_non_github_release_notes "$package" "$latest_version" "$source_url" "$homepage"); then
                # Extract the actual web URL from the result (lines containing URLs)
                local web_url=""
                web_url=$(echo "$non_github_result" | grep -o -E 'https?://[^[:space:]]+' | tail -1)

                # Extract release notes (everything except the URL lines)
                local release_notes=""
                release_notes=$(echo "$non_github_result" | grep -v -E '^https?://' | sed '/^$/d')

                if [[ -n "$release_notes" && "$release_notes" != "null" ]]; then
                    # Real release notes found - show them
                    echo ""
                    echo "📋 Release Notes:"
                    # Sanitize and format the release notes
                    local sanitized_notes
                    sanitized_notes=$(sanitize_output "$release_notes")
                    # Convert blank line markers to actual blank lines
                    sanitized_notes="${sanitized_notes//__BLANK_LINE_MARKER__/}"
                    echo "$sanitized_notes"
                    echo ""
                    # Only show "Learn more" if we have a URL that's NOT already in the release notes
                    if [[ -n "$web_url" ]]; then
                        # Check if the URL is already mentioned in the release notes
                        if [[ ! "$sanitized_notes" =~ $web_url ]]; then
                            echo "🌐 Learn more: $web_url"
                        fi
                    fi
                else
                    # No real release notes found - show clean link only
                    echo ""
                    if [[ -n "$web_url" ]]; then
                        echo "🌐 Learn more: $web_url"
                    else
                        echo "🌐 Package: $domain"
                    fi
                fi
            else
                # Function returned 1 - no release notes found at all
                show_non_github_fallback "$package" "$source_url"
            fi
        else
            echo "🚫 No release notes available."
            echo ""
            echo "No GitHub repository found"
            echo "🌐 Package: More info available via 'brew info $package'"
        fi
        echo ""
        return 0
    fi

    # Detect breaking changes if flag is set
    local has_breaking="false"
    if [[ "$IDENTIFY_BREAKING" == "true" && -n "$release_json" && "$release_json" != "null" ]]; then
        local body
        body=$(echo "$release_json" | jq -r '.body // empty' 2>/dev/null)
        if [[ -n "$body" && "$body" != "null" ]]; then
            if detect_breaking_changes "$body"; then
                has_breaking="true"
            fi
        fi
    fi

    # Create package header using shared function
    create_package_header "$package" "$current_version" "$latest_version" "$relative_date" "$package_info" "$has_breaking"
    echo ""

    # Process and display release notes using shared function
    # For npm+GitHub packages, show GitHub release notes with npm date
    if [[ "$is_npm_package" == "true" && "$should_use_github" == "true" ]]; then
        # Fetch GitHub release notes for npm+GitHub packages
        local github_release_json=""
        # Handle revision numbers in version (e.g., 0.61_1 -> 0.61)
        local github_version="$latest_version"
        if [[ "$latest_version" =~ ^(.+_[0-9]+)$ ]]; then
            # Strip revision number for GitHub lookup
            github_version="${latest_version%_*}"
        fi
        if github_release_json=$(fetch_github_release "$github_repo" "$github_version" 2>/dev/null); then
            # Use GitHub release notes but keep npm relative date
            process_release_notes "$package" "$latest_version" "$github_repo" "$source_url" "$github_release_json"
        else
            # GitHub fetch failed, fall back to npm info display
            echo "Release $latest_version published to npm registry"
            if [[ -n "$release_json" ]]; then
                local npm_url=$(echo "$release_json" | jq -r '.html_url // ""')
                if [[ -n "$npm_url" && "$npm_url" != "null" ]]; then
                    echo "📋 Release: $npm_url"
                fi
            fi
        fi
    else
        # Standard processing for pure npm or pure GitHub packages
        process_release_notes "$package" "$latest_version" "$github_repo" "$source_url" "$release_json"
    fi
    echo ""
}
