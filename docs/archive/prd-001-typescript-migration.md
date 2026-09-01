# PRD: TypeScript/Node.js Migration

**Status:** Draft  
**Created:** 2026-01-05  
**Owner:** Engineering Team  
**Target Version:** v2.0.0  
**Timeline:** 6 weeks  

## Overview

This PRD defines the implementation plan for migrating brew-change from Bash (~3,000 lines) to TypeScript/Node.js (~1,200 lines), improving maintainability, testability, and performance while maintaining backward compatibility.

## Goals

### Primary Goals
1. **Migrate to TypeScript** - Rewrite core functionality in TypeScript with full type safety
2. **Maintain CLI compatibility** - Preserve existing CLI interface and behavior
3. **Improve performance** - Achieve 45% faster parallel processing
4. **Enhance testability** - Reach 90%+ test coverage with comprehensive test suite
5. **Reduce code complexity** - Achieve 60% code reduction through better abstractions

### Secondary Goals
1. Enable new features (JSON output, config files, plugin system)
2. Improve error messages and user experience
3. Reduce maintenance burden
4. Attract more contributors

### Non-Goals
1. Changing the CLI interface or breaking existing scripts
2. Rewriting the Homebrew tap or distribution mechanism
3. Supporting package managers other than Homebrew (for now)

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Code reduction | 60% (3,000 → 1,200 lines) | Line count comparison |
| Test coverage | 90%+ | Jest coverage report |
| Parallel processing speed | <30s for 13 packages | Benchmark suite |
| Startup time | <100ms | Performance profiling |
| Zero regressions | 100% feature parity | Integration test suite |
| Adoption rate | 50% within 3 months | Homebrew analytics |

## Technical Architecture

### Phase 1: Core Infrastructure (Week 1-2)

#### 1.1 Project Setup
**Deliverable:** TypeScript project with build pipeline

```
brew-change-ts/
├── package.json
├── tsconfig.json
├── .eslintrc.json
├── jest.config.js
├── src/
├── dist/
└── tests/
```

**Dependencies:**
- TypeScript 5.x
- Node.js 18+ (LTS)
- Jest for testing
- ESLint + Prettier for code quality
- esbuild for fast compilation

**Configuration:**
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

#### 1.2 Type Definitions
**Deliverable:** Core type system

```typescript
// src/types/package.ts
export interface PackageInfo {
  name: string;
  versions: {
    current: string;
    latest: string;
  };
  source: {
    url: string;
    homepage: string;
  };
  type: 'formula' | 'cask';
  tap?: string;
}

// src/types/changelog.ts
export interface Release {
  tagName: string;
  publishedAt: string;
  body: string;
  htmlUrl: string;
  author?: string;
}

export interface Changelog {
  package: PackageInfo;
  release: Release;
  breakingChanges: boolean;
  formattedNotes: string;
}

// src/types/config.ts
export interface Config {
  cache: {
    dir: string;
    ttl: number;
  };
  parallel: {
    maxJobs: number;
  };
  display: {
    color: boolean;
    emoji: boolean;
    format: 'full' | 'compact';
  };
  github: {
    token?: string;
  };
}
```

#### 1.3 Core Utilities
**Deliverable:** Reusable utility functions

```typescript
// src/core/cache.ts
export class CacheService {
  constructor(private cacheDir: string, private ttl: number);
  async get<T>(key: string): Promise<T | null>;
  async set<T>(key: string, value: T): Promise<void>;
  async has(key: string): Promise<boolean>;
  async invalidate(key: string): Promise<void>;
  async clear(): Promise<void>;
}

// src/core/http.ts
export interface HttpOptions {
  timeout?: number;
  retries?: number;
  cache?: boolean;
  headers?: Record<string, string>;
}

export class HttpClient {
  async fetch<T>(url: string, options?: HttpOptions): Promise<T>;
  async fetchWithRetry<T>(url: string, options?: HttpOptions): Promise<T>;
}

// src/core/validation.ts
export class Validator {
  static validatePackageName(name: string): void;
  static validateUrl(url: string): void;
  static sanitizeOutput(text: string): string;
}
```

### Phase 2: Service Layer (Week 3-4)

#### 2.1 GitHub Service
**Deliverable:** GitHub API integration

```typescript
// src/services/github.ts
export class GitHubService {
  constructor(
    private http: HttpClient,
    private cache: CacheService,
    private token?: string
  );

  async extractRepo(source: PackageSource): Promise<string | null>;
  async fetchRelease(repo: string, version: string): Promise<Release>;
  async fetchReleases(repo: string, limit?: number): Promise<Release[]>;
  private tryAlternativeTag(repo: string, tag: string): Promise<Release | null>;
}
```

**Features:**
- Extract GitHub repo from various URL formats
- Fetch release notes with tag fallback (v1.0.0 vs 1.0.0)
- Handle rate limiting with exponential backoff
- Support authenticated requests via GitHub token

#### 2.2 Homebrew Service
**Deliverable:** Homebrew integration

```typescript
// src/services/homebrew.ts
export class HomebrewService {
  async getPackage(name: string): Promise<PackageInfo>;
  async getOutdatedPackages(): Promise<PackageInfo[]>;
  async getInstalledVersion(name: string): Promise<string>;
  async getTapInfo(tap: string): Promise<TapInfo>;
  async searchPackages(query: string): Promise<string[]>;
}
```

**Features:**
- Parse `brew outdated --json=v2` output
- Handle formulae and casks
- Support tap-prefixed packages
- Extract version information with revision numbers

#### 2.3 NPM Service
**Deliverable:** NPM registry integration

```typescript
// src/services/npm.ts
export class NpmService {
  constructor(
    private http: HttpClient,
    private cache: CacheService
  );

  async getPackageInfo(packageName: string): Promise<NpmPackageInfo>;
  async getReleaseDate(packageName: string, version: string): Promise<string>;
  isNpmPackage(url: string): boolean;
  extractPackageName(url: string): string | null;
}
```

#### 2.4 Breaking Changes Service
**Deliverable:** Breaking changes detection

```typescript
// src/services/breaking-changes.ts
export class BreakingChangesService {
  detectBreakingChanges(releaseNotes: string): boolean;
  extractBreakingSection(releaseNotes: string): string | null;
  getBreakingPatterns(): string[];
}
```

#### 2.5 Non-GitHub Service
**Deliverable:** Alternative source handlers

```typescript
// src/services/non-github.ts
export class NonGitHubService {
  constructor(private http: HttpClient);

  async fetchReleaseNotes(
    source: string,
    version: string,
    homepage?: string
  ): Promise<string | null>;
  
  private async fetchSourceForge(pkg: string, version: string): Promise<string | null>;
  private async fetchCrabNebula(pkg: string, version: string): Promise<string | null>;
  private async fetchGeneric(url: string, version: string): Promise<string | null>;
}
```

### Phase 3: CLI & Display (Week 5)

#### 3.1 CLI Framework
**Deliverable:** Command-line interface

```typescript
// src/cli/index.ts
import { Command } from 'commander';

export function createCli(): Command {
  const program = new Command();
  
  program
    .name('brew-change')
    .version(VERSION)
    .description('See what changed in your Homebrew packages');
  
  program
    .argument('[package]', 'Show changelog for specific package')
    .option('-a, --all', 'Show detailed changelogs for all outdated packages')
    .option('-v, --verbose', 'Show outdated packages with version numbers')
    .option('-b, --id-breaking', 'Highlight packages with breaking changes')
    .option('--json', 'Output in JSON format')
    .action(handleCommand);
  
  return program;
}
```

#### 3.2 Display Service
**Deliverable:** Terminal output formatting

```typescript
// src/display/renderer.ts
export class DisplayRenderer {
  constructor(private config: DisplayConfig);
  
  renderChangelog(changelog: Changelog): void;
  renderOutdatedList(packages: PackageInfo[]): void;
  renderPackageHeader(pkg: PackageInfo, hasBreaking: boolean): void;
  renderError(error: Error): void;
  renderSuggestions(similar: string[]): void;
}

// src/display/formatters/changelog.ts
export class ChangelogFormatter {
  format(releaseNotes: string): string;
  optimizeGitHubMarkdown(text: string): string;
  filterDownloadTables(text: string): string;
  sanitize(text: string): string;
}
```

**Features:**
- Chalk for colors and styling
- Terminal width detection
- Progress indicators with ora
- Markdown formatting

#### 3.3 Parallel Processor
**Deliverable:** Concurrent package processing

```typescript
// src/parallel/processor.ts
export class ParallelProcessor {
  constructor(
    private maxJobs: number,
    private services: Services
  );

  async processPackages(packages: PackageInfo[]): Promise<Changelog[]>;
  private async processPackage(pkg: PackageInfo): Promise<Changelog>;
  private adjustJobsForResources(): number;
}
```

**Features:**
- Process multiple packages concurrently
- Resource-aware job limiting
- Progress tracking
- Error isolation (one failure doesn't stop others)

### Phase 4: Integration & Testing (Week 5-6)

#### 4.1 Backward Compatibility
**Deliverable:** Wrapper script with fallback

```bash
#!/usr/bin/env bash
# brew-change (main entry point)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v node >/dev/null 2>&1; then
    # Use TypeScript version
    NODE_VERSION=$(node --version | sed 's/v\([0-9]*\).*/\1/')
    if [[ $NODE_VERSION -ge 18 ]]; then
        exec node "$SCRIPT_DIR/lib/cli.js" "$@"
    else
        echo "Warning: Node.js 18+ required, found v$NODE_VERSION" >&2
        echo "Using legacy Bash version" >&2
    fi
fi

# Fallback to Bash version
exec "$SCRIPT_DIR/lib/brew-change-bash" "$@"
```

#### 4.2 Test Suite
**Deliverable:** Comprehensive tests

```typescript
// tests/unit/services/github.test.ts
describe('GitHubService', () => {
  describe('extractRepo', () => {
    it('extracts from release URLs', () => {});
    it('extracts from archive URLs', () => {});
    it('handles .git suffix', () => {});
    it('returns null for non-GitHub URLs', () => {});
  });
  
  describe('fetchRelease', () => {
    it('fetches release by exact tag', async () => {});
    it('falls back to v-prefix tag', async () => {});
    it('handles rate limiting', async () => {});
    it('uses cache when available', async () => {});
  });
});

// tests/integration/cli.test.ts
describe('CLI Integration', () => {
  it('shows outdated list', async () => {});
  it('shows package changelog', async () => {});
  it('handles breaking changes flag', async () => {});
  it('outputs JSON format', async () => {});
});

// tests/e2e/compatibility.test.ts
describe('Bash Compatibility', () => {
  it('produces same output as Bash version', async () => {});
  it('handles all CLI flags', async () => {});
  it('exits with same codes', async () => {});
});
```

**Coverage targets:**
- Unit tests: 95%+
- Integration tests: 90%+
- E2E tests: Key user flows

## Implementation Details

### Build & Distribution

#### NPM Package Structure
```json
{
  "name": "brew-change",
  "version": "2.0.0",
  "bin": {
    "brew-change": "./dist/cli.js"
  },
  "files": [
    "dist/",
    "lib/brew-change-bash"
  ],
  "scripts": {
    "build": "tsc && chmod +x dist/cli.js",
    "test": "jest",
    "lint": "eslint src/",
    "format": "prettier --write src/"
  }
}
```

#### Homebrew Formula Updates
```ruby
class BrewChange < Formula
  desc "See what changed in your Homebrew packages"
  homepage "https://github.com/shrwnsan/brew-change"
  url "https://github.com/shrwnsan/brew-change/archive/v2.0.0.tar.gz"
  license "MIT"
  
  depends_on "node" => :recommended
  depends_on "jq"
  
  def install
    # Install TypeScript version
    system "npm", "install", "--production"
    system "npm", "run", "build"
    
    libexec.install Dir["*"]
    
    # Create wrapper script
    (bin/"brew-change").write_env_script libexec/"dist/cli.js", {}
    
    # Keep Bash version as fallback
    (libexec/"lib").install "brew-change" => "brew-change-bash"
  end
  
  test do
    assert_match "brew-change version", shell_output("#{bin}/brew-change --version")
  end
end
```

### Error Handling

#### Custom Error Classes
```typescript
// src/errors/index.ts
export class BrewChangeError extends Error {
  constructor(message: string, public code: string) {
    super(message);
    this.name = 'BrewChangeError';
  }
}

export class PackageNotFoundError extends BrewChangeError {
  constructor(
    public packageName: string,
    public candidates: string[] = []
  ) {
    super(`Package '${packageName}' not found`, 'PACKAGE_NOT_FOUND');
  }
}

export class NetworkError extends BrewChangeError {
  constructor(message: string, public url: string) {
    super(message, 'NETWORK_ERROR');
  }
}

export class RateLimitError extends BrewChangeError {
  constructor(public retryAfter: number) {
    super(`Rate limit exceeded, retry after ${retryAfter}s`, 'RATE_LIMIT');
  }
}
```

### Configuration

#### Config File Support
```typescript
// src/config/loader.ts
export class ConfigLoader {
  static async load(): Promise<Config> {
    const defaultConfig = this.getDefaults();
    const userConfig = await this.loadUserConfig();
    const envConfig = this.loadEnvConfig();
    
    return merge(defaultConfig, userConfig, envConfig);
  }
  
  private static async loadUserConfig(): Promise<Partial<Config>> {
    const configPath = path.join(os.homedir(), '.brew-change.json');
    if (await fs.pathExists(configPath)) {
      return JSON.parse(await fs.readFile(configPath, 'utf-8'));
    }
    return {};
  }
  
  private static loadEnvConfig(): Partial<Config> {
    return {
      github: {
        token: process.env.GITHUB_TOKEN || process.env.BREW_CHANGE_GITHUB_TOKEN
      },
      parallel: {
        maxJobs: parseInt(process.env.BREW_CHANGE_JOBS || '0') || undefined
      }
    };
  }
}
```

## Migration Plan

### Week 1-2: Foundation
- [ ] Set up TypeScript project structure
- [ ] Configure build pipeline and tooling
- [ ] Implement core type definitions
- [ ] Create utility classes (cache, HTTP, validation)
- [ ] Write unit tests for utilities (target: 95%+ coverage)

### Week 3-4: Services
- [ ] Implement GitHub service with full feature parity
- [ ] Implement Homebrew service
- [ ] Implement NPM service
- [ ] Implement breaking changes detection
- [ ] Implement non-GitHub sources
- [ ] Write comprehensive service tests (target: 90%+ coverage)

### Week 5: CLI & Display
- [ ] Implement CLI framework with commander
- [ ] Create display renderer with formatting
- [ ] Implement parallel processor
- [ ] Write integration tests
- [ ] Create backward compatibility wrapper

### Week 6: Testing & Release
- [ ] E2E testing against Bash version
- [ ] Performance benchmarking
- [ ] Documentation updates
- [ ] Beta release with opt-in flag
- [ ] Community feedback and bug fixes
- [ ] v2.0.0 stable release

## Rollout Strategy

### Beta Phase (Week 6)
```bash
# Opt-in beta testing
brew-change --use-ts-version
```

**Goals:**
- Get feedback from early adopters
- Identify edge cases
- Verify performance improvements
- Fix critical bugs

### Stable Release (Week 7)
```bash
# v2.0.0 with automatic Node.js detection
brew upgrade brew-change
```

**Communication:**
- Release notes highlighting benefits
- Migration guide for users without Node.js
- Blog post about the rewrite
- Social media announcements

### Deprecation (Week 20, +3 months)
```bash
# v2.2.0 with deprecation warnings
Warning: Bash version deprecated, will be removed in v3.0.0
Install Node.js for continued support: brew install node
```

### Final (Week 52, +1 year)
```bash
# v3.0.0 removes Bash fallback entirely
Error: Node.js required. Install: brew install node
```

## Risks & Mitigation

### Technical Risks

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Performance regression | High | Benchmark suite, performance budgets |
| Node.js dependency issues | Medium | Bash fallback for 1 year |
| Breaking CLI changes | High | Strict compatibility tests |
| Test suite gaps | Medium | Coverage requirements, manual testing |

### User Experience Risks

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Resistance to Node.js | Medium | Clear benefits communication, easy installation |
| Learning curve for contributors | Low | Good documentation, TypeScript is popular |
| Migration friction | Medium | Transparent rollout, good error messages |

## Documentation Updates

### Required Updates
- [ ] README.md - Update installation and usage
- [ ] CONTRIBUTING.md - Add TypeScript guidelines
- [ ] docs/architecture.md - Document new architecture
- [ ] docs/development.md - Setup instructions for TS
- [ ] API documentation with TypeDoc
- [ ] Migration guide for contributors

### New Documentation
- [ ] TypeScript style guide
- [ ] Testing guidelines
- [ ] Service integration guide (for plugins)
- [ ] Performance optimization guide

## Success Criteria

### Must Have (v2.0.0)
- ✅ 100% CLI compatibility with Bash version
- ✅ All existing features working
- ✅ 90%+ test coverage
- ✅ Performance equal or better than Bash
- ✅ Zero critical bugs in beta

### Should Have (v2.1.0)
- ✅ JSON output format
- ✅ Config file support
- ✅ Improved error messages
- ✅ Plugin system foundation

### Could Have (v2.2.0+)
- Watch mode
- Web dashboard
- IDE integration
- Additional package sources

## Dependencies

### Runtime Dependencies
```json
{
  "dependencies": {
    "commander": "^11.0.0",
    "chalk": "^5.3.0",
    "ora": "^7.0.0",
    "node-fetch": "^3.3.0",
    "fs-extra": "^11.2.0"
  }
}
```

### Development Dependencies
```json
{
  "devDependencies": {
    "typescript": "^5.3.0",
    "@types/node": "^20.10.0",
    "jest": "^29.7.0",
    "@types/jest": "^29.5.0",
    "eslint": "^8.55.0",
    "@typescript-eslint/eslint-plugin": "^6.15.0",
    "prettier": "^3.1.0",
    "esbuild": "^0.19.0"
  }
}
```

## Timeline Summary

| Week | Phase | Deliverables |
|------|-------|--------------|
| 1-2 | Foundation | Project setup, types, core utilities |
| 3-4 | Services | GitHub, Homebrew, NPM, breaking changes |
| 5 | CLI & Display | Commands, formatting, parallel processing |
| 6 | Testing | E2E tests, benchmarks, beta release |
| 7 | Release | v2.0.0 stable |

---

## Approval

- [ ] Technical Lead Review
- [ ] Architecture Review
- [ ] Security Review
- [ ] Documentation Review
- [ ] Stakeholder Sign-off

---

**Related Documents:**
- [eval-001-typescript-refactor-assessment.md](./eval-001-typescript-refactor-assessment.md) - Initial evaluation
- [architecture.md](../architecture.md) - Current architecture
- [tasks-001-typescript-migration.md](./tasks-001-typescript-migration.md) - Detailed task breakdown

---

**Document History:**
- 2026-01-05: Initial PRD created
