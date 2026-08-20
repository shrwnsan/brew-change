# T-004 Task 0 — LLM-Assisted Breaking-Change Triage (Research Spike)

**Status:** Spike complete 2026-08-21; go/no-go recorded in §8
**Decides:** Whether tasks-004 Task 2 (LLM-assisted triage) proceeds, and under which contracts; records the provider, input/output/fallback, and cost/latency decisions the Task 2 PRD must inherit.
**Spike question:** Can an LLM pass add signal where the breaking-change patterns are inconclusive — when the pattern says "no evidence" on a major bump, is that "no breaking" or "unknown"?

## 1. Field evidence: what actually went wrong in the 36-package run

The v1.16.0 verdict run (2026-08-20/21, real inventory) decomposes as
4 pattern-hit breaking · 2 major-only attention · 14 no-signal · 16–17
unknown. Inspecting those rows against the upstream sources yields an
error taxonomy with very different fixes:

- **(a) Pattern false positive** — `nnn` matched `drop support` inside
  "add Kitty drag-and-drop support to `dragdrop`". Substring grep,
  no word boundary. *Deterministic fix:* anchor the pattern list at
  word boundaries (and consider dropping bare `"breaking"` in favor of
  the phrase forms). Cheap, testable, no model needed.
- **(b) Retrieval gap** — `vercel 58→59` shows as major-only attention
  with "no notes", but the notes exist: the `vercel/vercel` monorepo
  publishes per-package changesets with explicit "Major Changes"
  sections (github.com/vercel/vercel/releases, tag `vercel@59.0.0`), and
  vercel.com/docs/cli/release-notes groups every release by SemVer
  impact. The npm-first detection path never fetched them. *Deterministic
  fix:* fall back to the GitHub repo release for npm packages whose
  registry metadata points at one. Had those notes been fetched, the
  existing `major changes` pattern would have fired on its own.
- **(c) True classification gap** — notes fetched, no pattern match,
  semantics genuinely ambiguous (e.g. "we rewrote the config format"
  contains no configured pattern). Rare in the field run; this is the
  only case where a model classifies better than the pattern set.
- **(d) No-notes unknowns (16–17 rows)** — casks (dropbox, spotify,
  …) and registry-silent formulae. Nothing was fetched, so nothing
  evidence-based can be said. Only parametric recall could speak here,
  and version-specific recall is exactly where models hallucinate.

Two of the four observed error classes are fixed deterministically and
should be fixed first (or alongside) regardless of the AI decision.

## 2. Design space: three possible LLM roles

- **R1 — classifier over fetched evidence.** brew-change fetches
  (existing policy-aware boundary + HTTP cache), then hands text to the
  model; the model is a smarter `detect_breaking_changes`. Fits the
  PRD-003 evidence model: provenance remains the fetched notes.
- **R2 — retrieval by the model (model fetches URLs). REJECTED.** The
  T1.6.2 destination policy (supported hosts, loopback/private
  rejection, redirect revalidation) is enforced at brew-change's fetch
  boundary; a model fetching arbitrary URLs escapes that boundary by
  construction and cannot be policy-audited. All fetching stays inside
  brew-change.
- **R3 — recall from parametric memory (no-notes rows).** No evidence,
  no retrieval timestamp — by the T1.3.1 contract such a row can never
  become `no-signal`. R3 is admissible **as display annotation only**
  ("ai-recall: likely patch, low confidence"), never as
  reclassification. v1 excludes even the annotation to keep the
  contract minimal; it is recorded here as an explicit non-goal.

## 3. Provider evaluation

The user suggestion on record is **glm-4.7**; it checks out:

- GLM-4.7 is served over an **OpenAI-compatible chat-completions REST
  API** (z.ai's own endpoint and every aggregator), so the client is
  `curl` + `jq` — zero new runtime dependencies, matching the project's
  stack. List pricing ≈ **$0.40/M input, $1.75/M output** (OpenRouter
  numbers; z.ai's GLM Coding Plan subscriptions offer quota-based
  access to the same model family).
- Alternates considered: OpenRouter (one OpenAI-compatible surface,
  many models — same curl shape), OpenAI/Anthropic direct (same shape),
  local Ollama (offline and free but a daemon; conflicts with the
  no-daemon posture — still usable because the whole feature is
  opt-in), and CLI-agent surfaces (`claude -p`, z.ai CLI pipes) —
  rejected: heavyweight dependencies, permissive harness behavior, and
  non-reproducible output contracts.
- **Decision:** provider-agnostic by construction. One OpenAI-compatible
  POST; base URL, model, and key come from env
  (`BREW_CHANGE_AI_URL`, `BREW_CHANGE_AI_MODEL`, default model
  `glm-4.7`, `BREW_CHANGE_AI_KEY`). The key is read from the
  environment only — never written to any cache or state file, never
  logged (the HTTP cache already keys authenticated entries by token
  fingerprint, but AI calls carry no per-user key in the cache at all).

### 3.1 Free-tier (`:free`) evaluation (asked by the maintainer, 2026-08-21)

OpenRouter's `:free` model variants are attractive for adoption — the
whole feature costs nothing — and the batched design fits them well:

- **Rate limits fit the one-call-per-run contract.** Free variants allow
  20 req/min and **50 req/day** with no credit purchase (1,000/day once
  ≥ $10 in credits exists). One batched call per `--ai` run means the
  free tier covers ~50 runs/day — far beyond interactive use.
- **The failure mode is already contracted.** 429 (rate-limited) and
  404 (model retired) both fall under §6: verbatim-pattern fallback plus
  the TTY stderr notice. Nothing new is needed to "support" free
  models — `BREW_CHANGE_AI_MODEL=z-ai/glm-5.2:free` with any OpenRouter
  key works through the same provider-agnostic surface. The Task 2 PRD
  should document this as the zero-cost path.
- **But free slugs must not be the default: they rotate.** Empirically,
  `z-ai/glm-4.5-air:free` and `z-ai/glm-4.7:free` have both been
  retired from the free tier; the current free Z.ai model is
  `z-ai/glm-5.2:free`, and it will retire too. A retired default would
  degrade every installation to fallback silently (stderr notice aside)
  — a support burden for a feature that is supposed to be invisible
  when it works. Defaults must be stable; free models are a documented
  choice, not a default.
- **Privacy caveat to disclose.** `:free` routes commonly train on
  submitted prompts (that is how upstream providers fund them); paid
  variants route to non-training providers. The payload here is
  changelog excerpts plus package names/versions — mild, and `--ai` is
  opt-in — but the README must state the difference so users who care
  can pay the ~$0.003/run or self-host (GLM-4.7 weights are
  MIT-licensed; another zero-cost route with the real glm-4.7 is
  Cerebras's free tier at 5 req/min).
- **Decision:** `:free` variants are first-class supported via the
  existing env surface (zero additional code), documented as the
  try-it-free path; the default model remains paid `glm-4.7` for
  stability and the stricter data policy.

### 3.2 Config surface: `~/.brew-change/config` (asked by the maintainer, 2026-08-21)

v1.17.0 established `~/.brew-change/` as a directory — as **tool-written
state** (`last-assessment.json`, the tasks-005 export). Putting model
config there adds a **user-written input** role to the same directory.
Accepted, with guardrails that keep the §3/§6 contracts enforceable:

- **File:** `~/.brew-change/config`, hand-edited `key=value` lines,
  `#` comments, entirely optional. brew-change only ever READS it —
  no wizard, no writes (the T3.1.1 no-configuration-wizard promise
  stands). Unknown keys are ignored (forward-compatible); malformed
  lines are skipped with a one-time stderr warning.
- **Recognized keys (v1): `model=` and `url=` only.** Notably NOT a
  general `BREW_CHANGE_*` config system — retrofitting every existing
  env knob with file precedence changes the behavior surface of the
  whole tool and needs its own ratification. Generalization is recorded
  as a non-goal for the Task 2 PRD.
- **The key never goes in the file — and the parser enforces it.**
  A `BREW_CHANGE_AI_KEY=` (or `key=`) line is ignored with a warning
  pointing at the env var. Making the refusal mechanical matters: config
  files attract pasted secrets by muscle memory, and §3's
  "never written to any cache or state file" contract must hold by
  construction, not by documentation alone. The key stays
  env-only (`BREW_CHANGE_AI_KEY`).
- **Parsing, never sourcing.** The file is read line-by-line and
  matched against the known keys — it is never `source`d or `eval`ed
  (AGENTS.md: no arbitrary execution from user input; a sourced config
  is code execution wearing a config file's clothes).
- **Precedence:** `--ai` mode flag > env (`BREW_CHANGE_AI_MODEL` /
  `_URL` / `_KEY`) > config file (`model` / `url`) > built-in defaults
  (paid `glm-4.7`, OpenRouter-compatible endpoint). Env-beats-file keeps
  one-off and CI overrides working without editing anything.
- The documented try-it-free incantation becomes a one-line edit:
  `model=z-ai/glm-5.2:free` in `~/.brew-change/config` plus any
  OpenRouter key in the environment.
- **Decision:** adopt for Task 2. Config file optional in every sense;
  absent file = env-only resolution exactly as research-009 §3
  originally recorded.

## 4. Input contract

- Scope (v1): rows with a **non-empty evidence snapshot where no
  breaking-change-pattern fired** — i.e. exactly the pattern-inconclusive
  set (major-only attention with notes, and no-signal rows being
  re-checked for false negatives). Confident pattern hits are **never
  re-judged** (pre-PRD rule); unknowns without snapshots are out (R3).
- One batched request per run: JSONL rows
  `{package, installed_version, available_version, evidence_source,
  excerpt}` with the snapshot truncated to 1200 chars; hard cap 20 rows
  (oldest-inventory order wins); temperature 0; no tool use; strict
  JSON-array response demanded by the prompt.

## 5. Output contract and the asymmetry rule

Per row: `{"package", "verdict": "breaking"|"likely-breaking"|"clean",
"justification" (≤120 chars), "confidence" (0–1)}`.

Mapping is **upgrade-only**:

- `breaking`/`likely-breaking` at confidence ≥ 0.7 over fresh evidence
  → `matched_signals` gains `ai-breaking`/`ai-likely-breaking`, the row
  becomes attention with reason `ai: <justification>`.
- `clean` **changes nothing**. It never reclassifies, never downgrades
  a heuristic, never creates `no-signal` — the row keeps exactly the
  engine verdict; the annotation is recorded only.

Rationale: the honest-assessment model must never let a model's "looks
fine" outweigh the ratified signals — comfort can only be withheld, not
granted, by the AI pass. (Cost of this rule, accepted knowingly: a
pattern false positive like `nnn` (§1a) stays flagged until the
deterministic word-boundary fix lands — the fix is the right cure, not
model veto.) Provenance: verdicts are always labeled `ai:` in reasons
and review detail; `retrieval_status` continues to describe only the
fetch, and the record gains one additive `ai_verdict` field (absorbed
by tolerant readers).

## 6. Fallback contract

No key · offline · timeout (30s hard) · HTTP 429/5xx · malformed JSON ·
any error → **today's patterns verbatim**, byte-identical output, plus a
single TTY-only stderr notice that AI triage was skipped. The flag is
opt-in only (`--ai`), never default, no telemetry, no state.

## 7. Cost/latency budget

- Field-run eligible set after §1's deterministic fixes: ≤ 20 rows,
  realistically the 10–15 snapshot-bearing pattern-miss rows. One
  batched call ≈ 4–6K input + <1K output tokens ≈ **$0.003–0.005 per
  run** at list prices; 2–8s typical latency against the 318s baseline
  (<3%), 30s timeout worst case (+9%, opt-in only). The baseline for
  non-`--ai` runs is unchanged: zero calls.
- AI verdicts enter the HTTP evidence cache in their own namespace,
  keyed by `(package, from, to, excerpt-hash, model)` with the source
  row's TTL class — stale-able, cleared by `--fresh`, re-run-stable
  exactly like fetched evidence (pre-PRD requirement). No token
  fingerprint needed: no per-user key enters the cache.

## 8. Go/no-go

- **GO (conditional)** on Task 2 v1 = R1 only: opt-in `--ai`,
  glm-4.7-by-default OpenAI-compatible call, batched single request,
  upgrade-only mapping with `ai:` provenance, cached verdicts, fallback
  verbatim. Preceded (or accompanied) by the two deterministic fixes —
  word-boundary patterns (§1a) and npm→GitHub notes fallback (§1b) —
  which resolve more of the observed field errors than the model would.
- **NO-GO:** R2 (model-side retrieval — URL-policy violation) and R3
  reclassification (evidence-model violation). R3-as-annotation is a
  recorded non-goal for v1.
- Task 2 implementation proceeds only from a PRD inheriting these
  contracts and only with maintainer approval (unchanged gate).

## 9. Open questions the Task 2 PRD must settle

Flag spelling (`--ai` vs `--triage-ai`), the confidence threshold
(0.7 proposed), whether `ai-likely-breaking` rows render in the
verdict's Breaking group or a distinct group, stderr skip-notice
wording, and whether the §1b GitHub fallback for npm packages ships in
the same release (recommended: yes — it is user-visible value even
without `--ai`).
