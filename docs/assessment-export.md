# Assessment Export

`brew-change export` prints the last assessment run data to stdout as JSON.
External tools like [brew-usage](https://github.com/shrwnsan/brew-usage) can
consume this to integrate brew-change's assessment knowledge without
coupling to its internal data formats.

```bash
brew-change export    # Print last assessment as JSON to stdout
```

The export is written automatically at the end of any assessment run (`-u`
or `-b`) to `~/.brew-change/last-assessment.json` with a stable, versioned
schema designed for external consumers:

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
    }
  ]
}
```

The export includes package names, versions, classifications
(attention/no-signal/unknown), and matched signals while excluding internal
implementation details and large payloads.

## Consumer contract

- Gate on `schema_version`; treat missing or unsupported schema versions as
  non-events (never errors).
- A missing export file is a non-event, not a failure.
- The internal `assessment.jsonl` pipeline format is explicitly **not**
  public API — consume the export only.

The full schema design and design rationale live in
[dev/tasks-005-assessment-export-surface.md](dev/tasks-005-assessment-export-surface.md).
