# Tasks: TypeScript/Node.js Migration

**Parent PRD:** [prd-001-typescript-migration.md](./prd-001-typescript-migration.md)  
**Status:** Planning  
**Created:** 2026-01-05  

## Task Naming Convention

Tasks use the format: **T{Phase}.{Section}.{Task}**
- Example: **T1.3.1** = Phase 1, Section 3, Task 1
- Enables parallel work and clear dependencies
- Junior devs can pick up any task marked as ready

## Task States
- 🟢 **Ready** - Can be started immediately
- 🟡 **Blocked** - Depends on other tasks
- 🔵 **In Progress** - Currently being worked on
- ✅ **Done** - Completed and reviewed

---

## Phase 1: Core Infrastructure

### 1.1 Project Setup (5 tasks, ~4 hours)

- [ ] 🟢 **T1.1.1** Initialize npm project
  - Run `npm init -y` in project root
  - Set `"type": "module"` in package.json
  - Add `"version": "2.0.0-alpha.1"`
  - **Acceptance:** package.json exists and is valid JSON

- [ ] 🟡 **T1.1.2** Install TypeScript dependencies
  - Install: `typescript@^5.3.0`, `@types/node@^20.10.0`
  - Install: `tsx` for development (TS execution)
  - **Depends on:** T1.1.1
  - **Acceptance:** `tsc --version` works

- [ ] 🟡 **T1.1.3** Configure TypeScript compiler
  - Create `tsconfig.json` with NodeNext module resolution
  - Set `strict: true`, `target: ES2022`
  - Configure paths: `rootDir: ./src`, `outDir: ./dist`
  - **Depends on:** T1.1.2
  - **Acceptance:** `tsc --noEmit` runs without errors

- [ ] 🟡 **T1.1.4** Set up testing framework
  - Install: `jest@^29.7.0`, `@types/jest@^29.5.0`, `ts-jest@^29.1.0`
  - Create `jest.config.js` with ts-jest preset
  - Add test script: `"test": "jest"`
  - **Depends on:** T1.1.2
  - **Acceptance:** `npm test` runs (even with no tests)

- [ ] 🟡 **T1.1.5** Configure code quality tools
  - Install: `eslint@^8.55.0`, `@typescript-eslint/*`, `prettier@^3.1.0`
  - Create `.eslintrc.json` with TypeScript recommended
  - Create `.prettierrc.json` with 2-space, single-quote config
  - Add scripts: `"lint": "eslint src/"`, `"format": "prettier --write src/"`
  - **Depends on:** T1.1.2
  - **Acceptance:** `npm run lint` and `npm run format` work

- [ ] 🟡 **T1.1.6** Set up build pipeline
  - Add build script: `"build": "tsc"`
  - Add clean script: `"clean": "rm -rf dist/"`
  - Create `src/index.ts` with `console.log('Hello')` to test
  - Run build and verify `dist/index.js` created
  - **Depends on:** T1.1.3
  - **Acceptance:** `npm run build` produces `dist/` with JS files

### 1.2 Type Definitions (3 tasks, ~2 hours)

- [ ] 🟢 **T1.2.1** Define package types
  - Create `src/types/package.ts`
  - Define `PackageInfo`, `PackageVersion`, `PackageSource` interfaces
  - Add JSDoc comments for each field
  - **Reference:** See Bash `brew info --json=v2` output structure
  - **Acceptance:** File compiles with no errors

- [ ] 🟢 **T1.2.2** Define changelog types
  - Create `src/types/changelog.ts`
  - Define `Release`, `Changelog`, `ReleaseNote` interfaces
  - Match GitHub API release schema
  - **Reference:** https://docs.github.com/en/rest/releases/releases
  - **Acceptance:** File compiles with no errors

- [ ] 🟢 **T1.2.3** Define configuration types
  - Create `src/types/config.ts`
  - Define `Config` interface with cache, parallel, display, github sections
  - Use union types for `format: 'full' | 'compact'`
  - **Reference:** See PRD section 1.2
  - **Acceptance:** File compiles with no errors

### 1.3 Core Utilities (15 tasks, ~12 hours)

#### CacheService (5 tasks)

- [ ] 🟡 **T1.3.1** Create CacheService class skeleton
  - Create `src/core/cache.ts`
  - Define class with constructor: `constructor(cacheDir: string, ttl: number)`
  - Add method signatures: `get<T>()`, `set<T>()`, `has()`, `invalidate()`, `clear()`
  - Import `fs/promises` for file operations
  - **Depends on:** T1.1.6
  - **Acceptance:** File compiles with no errors

- [ ] 🟡 **T1.3.2** Implement CacheService.get method
  - Read file from `{cacheDir}/{sha256(key)}.json`
  - Check TTL by comparing `mtime` with current time
  - Return `null` if expired or not found
  - Parse JSON and return typed result
  - **Depends on:** T1.3.1
  - **Test:** Mock fs, verify TTL logic with old/new files
  - **Acceptance:** Unit test passes

- [ ] 🟡 **T1.3.3** Implement CacheService.set method
  - Write JSON to temp file: `{cacheDir}/.{key}.tmp`
  - Use atomic rename to `{cacheDir}/{sha256(key)}.json`
  - Create cache directory if it doesn't exist (`mkdir -p`)
  - **Depends on:** T1.3.1
  - **Test:** Verify atomic write, directory creation
  - **Acceptance:** Unit test passes

- [ ] 🟡 **T1.3.4** Implement CacheService management methods
  - Implement `has()`: check if file exists and is not expired
  - Implement `invalidate()`: delete cache file
  - Implement `clear()`: delete all files in cache directory
  - **Depends on:** T1.3.2, T1.3.3
  - **Test:** Verify each method with mocked fs
  - **Acceptance:** Unit tests pass (95%+ coverage)

- [ ] 🟡 **T1.3.5** Add CacheService error handling
  - Wrap all fs operations in try-catch
  - Handle ENOENT (file not found) gracefully
  - Handle EACCES (permission denied) with clear errors
  - Log cache operations at debug level
  - **Depends on:** T1.3.4
  - **Test:** Simulate fs errors, verify handling
  - **Acceptance:** Error paths tested

#### HttpClient (5 tasks)

- [ ] 🟡 **T1.3.6** Create HttpClient class skeleton
  - Create `src/core/http.ts`
  - Define `HttpOptions` interface (timeout, retries, cache, headers)
  - Add constructor: `constructor(cache?: CacheService)`
  - Add method signatures: `fetch<T>()`, `fetchWithRetry<T>()`
  - Import `node-fetch` (install as dependency)
  - **Depends on:** T1.1.6
  - **Acceptance:** File compiles

- [ ] 🟡 **T1.3.7** Implement HttpClient.fetch basic method
  - Use `node-fetch` with timeout via AbortController
  - Add default timeout: 5000ms
  - Parse JSON response
  - Return typed result
  - **Depends on:** T1.3.6
  - **Test:** Mock fetch, verify timeout
  - **Acceptance:** Unit test passes

- [ ] 🟡 **T1.3.8** Add HttpClient caching support
  - Check cache before making request
  - Save response to cache after successful fetch
  - Use URL as cache key
  - **Depends on:** T1.3.7, T1.3.4
  - **Test:** Verify cache hit/miss behavior
  - **Acceptance:** Unit test passes

- [ ] 🟡 **T1.3.9** Implement HttpClient retry logic
  - Implement `fetchWithRetry` with exponential backoff
  - Retry on network errors and 5xx status codes
  - Don't retry on 4xx errors (except 429 rate limit)
  - Add jitter to backoff: `baseDelay * (1 + random(-0.25, 0.25))`
  - **Depends on:** T1.3.7
  - **Test:** Mock failed requests, verify retry attempts
  - **Acceptance:** Retry logic tested with various scenarios

- [ ] 🟡 **T1.3.10** Add HttpClient rate limit handling
  - Detect 429 status code
  - Parse `Retry-After` header
  - Wait specified time before retry
  - Throw `RateLimitError` if max retries exceeded
  - **Depends on:** T1.3.9
  - **Test:** Mock 429 response with Retry-After
  - **Acceptance:** Rate limit handling tested

#### Validation (5 tasks)

- [ ] 🟡 **T1.3.11** Create Validator class skeleton
  - Create `src/core/validation.ts`
  - Define static class `Validator`
  - Add method signatures (all static)
  - **Depends on:** T1.1.6
  - **Acceptance:** File compiles

- [ ] 🟡 **T1.3.12** Implement validatePackageName
  - Check package name is not empty
  - Check length ≤ 100 characters
  - Allow only: `[a-zA-Z0-9._/@-]`
  - Block path traversal: `../`, `~/`
  - Throw descriptive error on validation failure
  - **Depends on:** T1.3.11
  - **Reference:** Port from `brew-change-utils.sh:validate_package_name`
  - **Test:** Valid names pass, invalid names throw
  - **Acceptance:** Test coverage 100%

- [ ] 🟡 **T1.3.13** Implement validateUrl
  - Check URL starts with `http://` or `https://`
  - Validate against allowed domains (github.com, npmjs.org, etc.)
  - Block suspicious patterns (javascript:, data:, file:)
  - Throw descriptive error on validation failure
  - **Depends on:** T1.3.11
  - **Reference:** Port from `brew-change-utils.sh:validate_url`
  - **Test:** Valid URLs pass, malicious URLs throw
  - **Acceptance:** Test coverage 100%

- [ ] 🟡 **T1.3.14** Implement sanitizeOutput
  - Remove ANSI escape sequences: `\x1b\[[0-9;]*[mK]`
  - Remove control characters: `\x00-\x1F` (except newlines/tabs)
  - Preserve UTF-8 characters (emojis, arrows)
  - **Depends on:** T1.3.11
  - **Reference:** Port from `brew-change-display.sh:sanitize_output`
  - **Test:** Verify with ANSI codes, emojis, control chars
  - **Acceptance:** Sanitization works correctly

- [ ] 🟡 **T1.3.15** Create Validator unit test suite
  - Test all validation methods comprehensively
  - Include edge cases and malicious inputs
  - Target 100% code coverage
  - **Depends on:** T1.3.12, T1.3.13, T1.3.14
  - **Acceptance:** `npm test src/core/validation.test.ts` passes

## Phase 2: Service Layer

### 2.1 GitHub Service
- [ ] Implement Repo Extraction
  - Create `src/services/github.ts`
  - Implement `extractRepo` method
  - Support release, archive, and .git URL formats
  - **Test:** Verify extraction from diverse URL samples
- [ ] Implement Release Fetching
  - Add `fetchRelease` method
  - Add authenticated request support
  - Add fallback logic (v-prefix)
  - **Test:** Mock GitHub API responses (success, 404, rate limit)
- [ ] Implement Rate Limiting handling
  - Add error handling for 403 Rate Limit
  - Implement wait/retry logic
  - **Test:** Simulate rate limit headers

### 2.2 Homebrew Service
- [ ] Implement Package Info Parsing
  - Create `src/services/homebrew.ts`
  - Implement `getPackage` using `brew info --json=v2`
  - Parse formulae and casks correctly
  - **Test:** Use mock JSON output from brew
- [ ] Implement Outdated Check
  - Implement `getOutdatedPackages`
  - Parse `brew outdated --json=v2`
  - Handle revision numbers
  - **Test:** Mock outdated JSON with various states

### 2.3 NPM Service
- [ ] Implement NPM Registry Client
  - Create `src/services/npm.ts`
  - Implement `getPackageInfo`
  - Implement `getReleaseDate`
  - **Test:** Mock NPM registry responses
- [ ] Implement NPM Detection
  - Add `isNpmPackage` helper
  - Add `extractPackageName` helper
  - **Test:** Verify against npmjs.org URLs

### 2.4 Breaking Changes Service
- [ ] Implement Detection Logic
  - Create `src/services/breaking-changes.ts`
  - Implement `detectBreakingChanges`
  - Port regex patterns from Bash
  - **Test:** Verify against sample release notes with/without breaking changes

### 2.5 Non-GitHub Service
- [ ] Implement SourceForge Handler
  - Create `src/services/non-github.ts`
  - Add SourceForge fetching logic
  - **Test:** Mock SourceForge HTML responses
- [ ] Implement Generic Handler
  - Add fallback scraping logic
  - **Test:** Mock generic HTML pages

## Phase 3: CLI & Display

### 3.1 CLI Framework
- [ ] Setup Commander
  - Create `src/cli/index.ts`
  - Define program name, version, description
  - Define arguments and options
- [ ] Implement Command Handlers
  - Create handlers for default, `--all`, `--verbose`
  - Wire up services to commands

### 3.2 Display Renderer
- [ ] Implement Terminal Renderer
  - Create `src/display/renderer.ts`
  - Implement `renderChangelog` with colors
  - Implement `renderOutdatedList`
  - **Test:** Snapshot testing for output format
- [ ] Implement Markdown Formatter
  - Create `src/display/formatters/changelog.ts`
  - Port `optimizeGitHubMarkdown` logic
  - Port `filterDownloadTables` logic
  - **Test:** Verify markdown transformation

### 3.3 Parallel Processor
- [ ] Implement Concurrency Control
  - Create `src/parallel/processor.ts`
  - Implement `p-limit` style queue
  - Add resource usage check
- [ ] Implement Progress Tracking
  - Integrate `ora` for spinners
  - Add progress bar for batch operations

## Phase 4: Integration & Testing

### 4.1 Backward Compatibility
- [ ] Create Wrapper Script
  - Create `bin/brew-change-wrapper`
  - Add Node.js detection logic
  - Add Bash fallback execution
- [ ] Integration Testing
  - Verify wrapper selects correct version
  - Verify arguments passed correctly

### 4.2 End-to-End Tests
- [ ] Create E2E Suite
  - Setup `tests/e2e/`
  - Test `brew-change node` flow
  - Test `brew-change --all` flow
  - Test error conditions
- [ ] Verify Output Parity
  - Compare Bash vs TS output
  - Ensure formatting matches expectations

## Phase 5: Documentation & Release

### 5.1 Documentation
- [ ] Update README
  - Add new installation instructions
  - Document JSON output feature
- [ ] Update Developer Docs
  - Document build process
  - Document testing requirements

### 5.2 Release Preparation
- [ ] Prepare Beta Release
  - Bump version to 2.0.0-beta.1
  - Create release tag
- [ ] Update Homebrew Formula
  - Update `brew-change.rb`
  - Add node dependency
  - Update install method

---

## Summary

**Phase 1 (Weeks 1-2):** 23 granular tasks broken down from 3 high-level tasks  
**Estimated effort:** ~18 hours for Phase 1  
**Parallelization:** Up to 5 developers can work simultaneously on independent tasks

### Task Dependencies
- 🟢 **Ready tasks** (6): Can start immediately
  - T1.1.1, T1.2.1, T1.2.2, T1.2.3
- 🟡 **Blocked tasks** (17): Depend on other tasks completing first

### Next Steps
1. Phase 2, 3, 4, 5 tasks need similar granular breakdown
2. Assign task IDs and time estimates
3. Create GitHub issues from this task list
4. Set up project board with columns: Ready / In Progress / Review / Done

---

**Note:** Phase 1 has been fully broken down into junior-dev-friendly tasks. Phases 2-5 retain high-level structure and should be similarly expanded before implementation begins.
