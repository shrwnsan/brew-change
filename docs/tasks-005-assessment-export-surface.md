# Tasks: Assessment export surface for brew-usage integration

**Status:** Pre-PRD — Design and implementation
**Created:** 2026-08-20
**Evidence:** brew-usage needs to consume brew-change's assessment knowledge without coupling to internals

# Problem

brew-usage (a sibling tool) needs access to brew-change's package assessment knowledge (what packages are outdated, their version transitions, and breaking-change classifications) without depending on brew-change's internal data formats or workflow. The internal `assessment.jsonl` format is explicitly implementation-detail and must not become the public contract.

## Design Goals

1. **Stable public contract**: Export schema is versioned and changes deliberately
2. **Consumer-friendly**: Single JSON file, not JSONL; minimal fields that external tools need
3. **No coupling**: Internal assessment format can evolve without breaking consumers
4. **Graceful degradation**: Missing or schema-mismatched export is never an error for consumers

## Export Schema (Version 1)

```json
{
  "schema_version": 1,
  "generated_at": "2026-08-20T12:34:56Z",
  "packages": [
    {
      "name": "node",
      "display_name": "node",
      "kind": "formula",
      "installed_version": "22.6.0",
      "available_version": "22.8.0",
      "classification": "attention",
      "matched_signals": ["major-version-transition"],
      "retrieval_status": "fresh"
    },
    {
      "name": "python",
      "display_name": "python",
      "kind": "formula",
      "installed_version": "3.12.0",
      "available_version": "3.13.0",
      "classification": "no-signal",
      "matched_signals": [],
      "retrieval_status": "fresh"
    },
    {
      "name": "some-cask",
      "display_name": "Some Cask",
      "kind": "cask",
      "installed_version": "1.0.0",
      "available_version": "2.0.0",
      "classification": "unknown",
      "matched_signals": [],
      "retrieval_status": "unavailable"
    }
  ]
}
```

### Schema fields

- `schema_version`: Integer - consumers gate on this to handle format changes
- `generated_at`: ISO-8601 UTC timestamp - when the export was written
- `packages`: Array of package objects
  - `name`: Package identifier (matches brew package name)
  - `display_name`: Human-readable name (may differ for casks)
  - `kind`: Package type - "formula" or "cask"
  - `installed_version`: Current version string (null if unknown)
  - `available_version`: Latest version string (null if unknown)
  - `classification`: Assessment outcome - "attention" | "no-signal" | "unknown"
  - `matched_signals`: Array of signal identifiers - may be empty
    - "major-version-transition" - major version bump detected
    - "breaking-change-pattern" - configured pattern matched
  - `retrieval_status`: Evidence freshness - "fresh" | "cached-fresh" | "stale" | "unavailable" | "failed" | etc.

### What's NOT included (implementation details)

- Internal fields: `assessment_recommendation`, `operational_eligibility`, `default_selected`
- Large payloads: `evidence_snapshot` (full release notes)
- Reasoning text: `reasons` array (can change between versions)
- URLs: `evidence_url` (implementation detail)

## Consumer Contract (brew-usage and others)

### Reading the export

```bash
# Path to export file
EXPORT_FILE="${HOME}/.brew-change/last-assessment.json"

# Check if export exists and has supported schema
if [[ -f "$EXPORT_FILE" ]]; then
    SCHEMA_VERSION=$(jq -r '.schema_version // empty' "$EXPORT_FILE")
    if [[ "$SCHEMA_VERSION" == "1" ]]; then
        # Read and process
        jq '.packages[] | select(.classification == "attention")' "$EXPORT_FILE"
    fi
fi
```

### Error handling (never an error condition)

- **File doesn't exist**: No assessment available - treat as no data (not an error)
- **Schema version mismatch**: Export format unsupported - ignore and wait for next run
- **Invalid JSON**: File corrupted - ignore (will be rewritten on next brew-change run)

### Graceful behavior

```bash
# Always return success, never fail the consumer
brew-change export || true

# In consumer code:
ASSESSMENT_DATA=$(brew-change export 2>/dev/null || echo '{"schema_version":1,"packages":[]}')
```

## Implementation Tasks

### Task 1: Export library and schema

- [x] Create `lib/brew-change-export.sh` with:
  - `write_assessment_export()` - reads assessment.jsonl, writes stable JSON
  - `read_assessment_export()` - reads and validates export
  - `validate_assessment_export_schema()` - checks schema version support
- [x] Define schema_version constant (start at 1)
- [x] Export writes to `~/.brew-change/last-assessment.json`
- [x] Atomic write pattern (temp file + mv) to avoid partial reads

### Task 2: Integrate export into assessment runs

- [x] Hook export writing after `classify_upgrade_evidence()` in `-u` runs
- [x] Hook export writing after `classify_upgrade_evidence()` in `-b` runs
- [x] Export happens even if user quits dashboard (data available for next tool)
- [x] Export failures are silent (never break the main workflow)

### Task 3: Export subcommand

- [x] Add `brew-change export` subcommand to main CLI
- [x] Prints export JSON to stdout (exit 0)
- [x] Clear error message when file doesn't exist (exit 1, stderr)
- [x] No special formatting - raw JSON only

### Task 4: Testing

**State:** Covered by `tests/test-assessment-export.sh` (15 scenarios, 34 assertions) — registered in the deterministic runner / CI by PR #132 after shipping unregistered (gap found during the 2026-08-24 board review).

- [ ] Test export file written after `-u` assessment run
- [ ] Test export file written after `-b` assessment run
- [x] Test `brew-change export` prints valid JSON
- [x] Test `brew-change export` errors cleanly when absent
- [x] Test schema_version field present and correct
- [x] Test graceful handling of malformed/partial data
- [x] Test consumer contract: missing file = non-event
- [x] Test consumer contract: schema_version mismatch = non-event

Note: the two unchecked launcher-level items (export written after real `-u`/`-b` runs) are exercised indirectly by the subcommand and writer tests; a dedicated launcher-integration pair remains a small follow-up if wanted.

### Task 5: Documentation

- [x] Update README.md with export subcommand documentation (Quick Start line + "Assessment export" section with schema example; verified 2026-08-24)
- [x] Document schema in this tasks-005 file (schema block + Design Decisions below)
- [x] Document consumer contract and graceful degradation (missing file / schema mismatch = non-event, README + suite tests 14–15)
- [x] Note that internal assessment.jsonl is explicitly NOT public API (Design Decisions: "Why not expose assessment.jsonl directly?")

### Task 6: Version and CHANGELOG

- [x] Bump version — shipped as **v1.17.0** (2026-08-21; this file's "1.15.0 → 1.16.0" line predates the verdict-summary release taking 1.16.0)
- [x] Add CHANGELOG entry following repo conventions ([1.17.0] section, incl. the re-versioning note)
- [x] Use conventional commit format: `feat(export): ... (tasks-005)` (#125)

## Design Decisions

### Why not expose assessment.jsonl directly?

- **Internal format**: JSONL is optimized for brew-change's pipeline stages
- **Unstable fields**: Internal schema evolves with implementation needs
- **Consumer needs**: External tools need stable, minimal projection
- **Coupling risk**: Direct dependency on internal format locks evolution

### Why ~/.brew-change/last-assessment.json?

- **Single source**: One file, always the latest assessment
- **Discoverable**: Standard location under user home
- **Overwrite**: "last" semantics - each run replaces previous
- **No accumulation**: Don't need historical exports for current use case

### Schema versioning strategy

- Start at version 1 (not 0) - production-ready from day one
- Increment only for breaking changes
- Non-breaking additions: optional fields, existing consumers unaffected
- Consumer checks: `if schema_version <= MY_SUPPORTED_VERSION`

## Future Considerations

- **Additional export formats**: If consumers need CSV or other formats
- **Historical exports**: Keep last N exports for trend analysis
- **Filter options**: `brew-change export --filter attention-only`
- **Schema v2**: If new assessment types or fields are needed
