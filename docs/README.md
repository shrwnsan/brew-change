# brew-change Documentation

## 📖 Guides

- **[The Trusted Update Workflow](trusted-update.md)** — upgrade behavior, the `-b` verdict, first run, dashboard defaults, evidence caching & re-entry, accessibility modes
- **[Assessment Export](assessment-export.md)** — the versioned JSON feed for external tools (schema + consumer contract)
- **[Package Types](package-types.md)** — GitHub, npm, third-party taps, hybrid packages, docs-repository pattern
- **[Configuration](configuration.md)** — every environment variable in one reference
- **[Troubleshooting](../README.md#-troubleshooting)** — quick fixes live in the README

## 📚 Reference

- **[Technical Documentation](technical-documentation.md)** — comprehensive feature and architecture guide
- **[Architecture](architecture.md)** — modular `lib/` structure and processing pipeline
- **[Performance](performance.md)** — benchmarks and optimization notes

## 🛠️ Development & Planning

Active PRDs, task graphs, and ratified decision records (research-NNN):

- [PRD 003 — Trusted Update Workflow](dev/prd-003-trusted-update-workflow.md) and its [task graph](dev/tasks-003-trusted-update-workflow.md)
- [Tasks 004 — `-b` verdict summary + LLM triage](dev/tasks-004-b-verdict-summary-llm-triage.md) (Task 0/1 shipped; Task 2 parked — see [research-009](dev/research-009-llm-triage.md))
- [Tasks 005 — Assessment Export Surface](dev/tasks-005-assessment-export-surface.md) (shipped; the export's design record)
- Decision records: [research-004](dev/research-004-cli-default-compatibility.md) · [research-005](dev/research-005-assessment-record-contract.md) · [research-006](dev/research-006-progress-event-contract.md) · [research-007](dev/research-007-dashboard-actions.md) · [research-008](dev/research-008-evidence-cache-resume.md) · [research-009](dev/research-009-llm-triage.md) · [research-010](dev/research-010-native-app-dd.md)
- [Novice usability session kit](dev/novice-checks-t3.4.1.md)

## 🗄️ Archive

Superseded and historical records, preserved as-is:

- [TypeScript migration PRD](archive/prd-001-typescript-migration.md) · [task breakdown](archive/tasks-001-typescript-migration.md) · [refactor assessment](archive/eval-001-typescript-refactor-assessment.md) — evaluated and shelved (Bash stays)
- [Multi-package support PRD](archive/prd-002-multi-package-support.md) — shipped in v1.6.0
- [Standalone roadmap](archive/standalone-roadmap.md) — the v1.4.0-era project vision (superseded by the PRD/task era)
- [Migration background](archive/migration-background.md) — dotfiles → standalone history
- [Performance comparison](archive/performance-comparison.md) — 2025-12 benchmark record
- [Self-implementation guide](archive/self-implementation-guide.md) — pre-implementation design essay
- [Phase 1 implementation plan](archive/superpowers-phase-1-plan.md) — executed agent plan
