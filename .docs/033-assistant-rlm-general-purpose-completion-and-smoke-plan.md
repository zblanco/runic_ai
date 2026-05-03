# Assistant RLM General-Purpose Completion And Smoke Plan

Status: implementation slice landed; fallback and dynamic live matrices run;
scorecard repair/progression artifacts added; Runic-native compiler/executor
migration in progress

Date: 2026-04-30

Last verified: 2026-05-01 via `mix compile --warnings-as-errors`, `mix test`,
live provider ping, fallback smoke matrix, dynamic smoke matrix, and focused
post-repair live reruns for Scenarios G/H.

Motivated by:

- `.docs/031-general-purpose-dynamic-rlm-workflow-generation-implementation-plan.md`
- `.docs/032-wandering-inn-assistant-rlm-workflow-diagrams.md`
- `livebooks/assistant-rlm-dynamic-workflow.livemd`
- The successful long-document assistant run over
  `tmp/wandering-inn-10-59-t.assistant-rlm.jsonl`

## Current State

The first assistant RLM vertical slice works:

- terminal route: `mix runic_ai.agent --agent assistant`
- workflow contracts: `WorkflowBlueprint`, `ComponentBlueprint`,
  `FunctionBlueprint`, `ExecutionContext`
- validator: graph shape, stop conditions, component ids, function tier policy
- compiler/executor: accepted blueprint to Runic workflow, Runic
  `Workflow.add/3` port validation, Runic run-context-backed component
  adapters, scheduler policies, and three-phase Runic execution
- generic components:
  - `SourceDiscovery`
  - `SourceSplitter`
  - `SourceMaterializer`
  - `TabularParser`
  - `LLMMap`
  - `RecordMap`
  - `RecordGroup`
  - `DocumentCompare`
  - `HierarchicalReduce`
  - `ReportComposer`
  - `ArtifactWriter`
  - `SchemaNormalizer`
  - `BlueprintTransform`
  - `ObjectiveScorecard`
  - `BudgetLedger`
- generic fallback coordinator:
  - source discovery
  - source split
  - materialize
  - LLM map
  - LLM reduce/synthesize
  - tabular parse/group/report
  - document compare/report
  - artifact write
  - objective verification
- dynamic coordinator:
  - asks for workflow blueprint JSON, not final domain output
  - includes a capability manifest and component-shape examples
  - validates model-proposed blueprints
  - attempts targeted repair from validation diagnostics
  - falls back to generic shapes when proposal/repair fails
- smoke harness:
  - `SmokeScenario` catalog with fixture generation for Scenarios B-H
  - `SmokeRunner` with per-scenario `tmp/assistant_smoke/reports` reports and
    matrix writer
  - per-run JSON detail artifacts under `tmp/assistant_smoke/runs`, including
    blueprint, compiled graph summary, validation report, scorecard,
    repair history, and Runic-production-derived intermediate-output previews
  - `SmokeExpectation` deterministic checks for artifact, required sections,
    scorecard, and expected workflow capabilities; source-cue and artifact
    quality observations now come from the runtime `ObjectiveScorecard` when
    available
  - strategy comparison writer for fallback-vs-dynamic matrix deltas
  - `TraceSummary` helper for comparable graph/component/budget/scorecard
    summaries
  - `mix runic_ai.assistant.smoke` repeatable task with `--strategy fallback`
    and `--strategy dynamic`, plus `--compare` for existing fallback/dynamic
    matrices
- terminal events and JSONL traces
- live long-document smoke succeeded and its generated artifact has been moved
  to `tmp/assistant_smoke/artifacts/wandering-inn-10-59-t-summary.md`
- runtime scorecards now support `required_source_cues` and
  `require_artifact_quality?`; blocked scorecards trigger one bounded
  scorecard-diagnostic repair attempt before the agent returns

This is now a stronger implementation baseline, but it is still not enough to
claim robust dynamic RLM generality. The code can generate, validate, repair, and
fall back across multiple generic shapes. The first full matrix shows useful
progress and several concrete next repairs. Dynamic proposals improved shape
selection for tabular tasks. The immediate follow-up moved source-cue/artifact
quality checks into the runtime scorecard and added one scorecard repair
attempt; the remaining question is whether live Scenario G/H reruns improve
fact preservation.

## Live Matrix Results: 2026-05-01

Setup:

```sh
mix run -e 'case RunicAI.LLM.generate_text("openai:gpt-5.4-mini", "Reply with exactly pong.") do {:ok, result} -> IO.puts(RunicAI.LLM.Result.text(result)); other -> IO.inspect(other) end'

mix runic_ai.assistant.smoke \
  --cwd . \
  --strategy fallback \
  --model openai:gpt-5.4-mini \
  --max-llm-map-concurrency 2 \
  --max-runtime-ms 900000

mix runic_ai.assistant.smoke \
  --cwd . \
  --strategy dynamic \
  --model openai:gpt-5.4-mini \
  --max-llm-map-concurrency 2 \
  --max-runtime-ms 900000
```

Matrix artifacts:

- `tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-fallback.md`
- `tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-dynamic.md`
- `tmp/assistant_smoke/reports/assistant-rlm-smoke-strategy-comparison.md`

Summary:

| Scenario | Fallback | Dynamic | Main Observation |
| --- | --- | --- | --- |
| `long_document_wiki` | pass | pass | Both use split/materialize/map/reduce/write/scorecard. |
| `meeting_actions` | review | review | Artifact satisfies content checks, but workflow misses `record_group` and `report_composer`. |
| `research_brief` | review | review | Good artifact path; workflow still acts like generic split/map/reduce rather than claim/evidence records. |
| `ticket_clusters` | fail | review | Dynamic adds `record_map` and satisfies artifact/source checks; still misses `report_composer`. |
| `notes_digest` | review | review | Directory/source synthesis works, but cross-file record grouping is not selected. |
| `architecture_report` | pass | pass | Both strategies cover source discovery, splitting, map/reduce, write, and scorecard. |
| `csv_cleanup` | fail | fail | Dynamic uses tabular/record components, but output misses fixture-specific cues `ADA@example.COM` and `bea@invalid`. |
| `document_comparison` | fail | fail | Dynamic uses comparison plus LLM leaves, but final artifact claims source contents were unavailable and misses change cues. |

Important measurement lesson:

- Section-only scorecards were too weak. The first dynamic pass produced some
  section-shaped artifacts that were raw maps or generic prose. The runtime
  `ObjectiveScorecard` now checks required source cues and optional artifact
  quality, so these failures can block normal workflow execution instead of
  only appearing in smoke reports.
- Source-cue checks remain a deterministic proxy, not a complete groundedness
  proof. They are useful as a hard gate for known fixtures and as a diagnostic
  for repair prompts.
- Scorecard-driven repair is implemented with a single bounded repair attempt.
  The next live matrix should measure whether it improves Scenario G/H rather
  than only increasing runtime.

Recommended next trial:

1. Re-run Scenario G and H after scorecard repair to see whether the agent can
   preserve fixture facts instead of producing generic summaries.
2. Add an optional LLM judge lane for artifact usefulness, separate from
   deterministic pass/fail checks.
3. Compare fallback/dynamic matrices with
   `mix runic_ai.assistant.smoke --compare`.

## Focused Post-Repair Reruns: 2026-05-01

Commands:

```sh
mix runic_ai.assistant.smoke \
  --cwd . \
  --strategy dynamic \
  --scenario csv_cleanup,document_comparison \
  --model openai:gpt-5.4-mini \
  --max-llm-map-concurrency 2 \
  --max-runtime-ms 900000 \
  --label dynamic-repair-gh

mix runic_ai.assistant.smoke \
  --cwd . \
  --strategy dynamic \
  --scenario document_comparison \
  --model openai:gpt-5.4-mini \
  --max-llm-map-concurrency 2 \
  --max-runtime-ms 900000 \
  --label dynamic-repair-h3
```

Results:

| Scenario | Latest Result | Main Observation |
| --- | --- | --- |
| `csv_cleanup` | review / `objective_satisfied` | Dynamic run now preserved `ADA@example.COM`, `bea@invalid`, and `duplicate`; remaining warning is workflow shape missing `report_composer`. |
| `document_comparison` | review / `objective_satisfied` | After fixing structured-map prompt text, the run preserved `one business day`, `immediately`, and `Enterprise customers` and wrote all required sections. Remaining warning is workflow shape missing `record_group` and `report_composer`. |

New artifacts:

- `tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-dynamic-repair-gh.md`
- `tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-dynamic-repair-h3.md`
- `tmp/assistant_smoke/runs/assistant-rlm-smoke-dynamic-repair-gh-csv_cleanup.json`
- `tmp/assistant_smoke/runs/assistant-rlm-smoke-dynamic-repair-h3-document_comparison.json`

Implementation note:

- The first post-repair `document_comparison` run exposed that generated
  `llm_map` prompts using `{{text}}` after a structured `document_compare`
  output received empty text. `LLMMap` now serializes structured records into
  `{{text}}` when no text/content field exists, so downstream prompts see the
  comparison payload.
- The deterministic `report_composer` fallback now receives required sections
  from coordinator fallbacks and renders distinct section bodies, preventing a
  repaired comparison report from collapsing into only `Summary`.

## Remaining Work Surfaced By Smoke Testing

Highest priority:

- [x] Move fixture/source-cue checks from `SmokeExpectation` into
      `ObjectiveScorecard`, or add equivalent provenance/evidence requirements
      that can run during normal workflow execution.
- [x] Add scorecard-failure repair: when required sections, source cues, or
      artifact-quality checks fail, feed diagnostics back into blueprint repair
      or synthesis repair instead of only reporting the failure after the run.
- [x] Teach generated comparison and tabular workflows to preserve concrete
      fixture facts. Scenario G missed `ADA@example.COM` and `bea@invalid`;
      Scenario H missed `one business day`, `immediately`, and
      `Enterprise customers`. Focused post-repair reruns now preserve these
      facts, while workflow-shape warnings remain.
- [x] Improve blueprint proposal guidance so record/table tasks choose
      `record_map`, `record_group`, and `report_composer` consistently, instead
      of falling back to generic `llm_leaf` synthesis when a deterministic
      report composer would provide better structure.

Evaluation and progression:

- [ ] Add an optional LLM-judge lane for artifact usefulness, groundedness, and
      specificity, but keep deterministic checks as the hard gate.
- [x] Persist compiled graph summaries and selected intermediate artifacts so
      progression analysis can compare prompts, graph choices, and failure modes
      across runs without rereading terminal output.
- [x] Add a scenario-run comparison artifact that summarizes fallback vs dynamic
      deltas by component shape, objective status, source cues, runtime, and
      repair history.

Runtime and terminal:

- [ ] Add terminal integration tests that assert blueprint display, node
      progress display, final artifact display, and JSONL trace coverage.
- [ ] Exercise compile/runtime/scorecard repair paths with live or scripted
      failure injection. Scorecard repair now has scripted coverage; compile
      and runtime repair injection remain open.

Architecture:

- [ ] Keep Tier 2 deprioritized. The matrix did not prove Tier 1 is too weak;
      the immediate failures are evidence preservation and repair-loop issues.
- [ ] Defer coding `WorkflowProposal` conversion until a concrete codebase
      scenario needs it. The architecture scenario passed without a bridge.
- [x] Move generated smoke artifacts out of `.docs` and into
      `tmp/assistant_smoke`; keep numbered planning docs in `.docs`.

## What Is Left In 031

### Contract And Interop Gaps

- [ ] Decide whether assistant blueprints need conversion helpers from coding
      `WorkflowProposal`.
- [ ] If yes, keep conversion one-way and narrow: coding proposal summaries may
      become assistant source/report nodes, but assistant workflows should not be
      forced into coding node kinds.

Recommendation:

- Defer broad conversion. Add only a small `coding_report` bridge after Scenario
  F proves the assistant needs codebase exploration from coding-agent substrate.

### Source And Artifact Component Gaps

- [x] Finish source splitting modes and tests:
  - markdown heading
  - paragraph
  - line
  - byte
  - directory source discovery
  - multi-file provenance
- [x] Add a scripted `LLMMap` concurrency/budget test.
- [x] Add a reusable source-discovery component for files/directories/globs.

Recommendation:

- Extract `SourceDiscovery` before running directory, repo, or multi-document
  smokes. It is a common-use component for both assistant and coding agents.

### Function Blueprint Gaps

- [ ] Implement Tier 2 AST/source validator only if scenarios show Tier 1 is too
      weak.
- [ ] Keep Tier 2 review-gated and disabled by default.
- [ ] Add tests for rejected Tier 2 unsafe forms.
- [ ] Add repairable-error tests for invalid generated expressions.

Recommendation:

- Do not prioritize Tier 2 yet. First pressure Tier 1 with tabular cleanup,
  ticket clustering, and multi-document comparison. If Tier 1 expression
  blueprints are insufficient, improve Tier 1 before opening Tier 2.

### Compiler And Runtime Gaps

- [x] Carry budgets into every relevant node:
  - source count
  - slice count
  - bytes per slice
  - total materialized bytes
  - LLM map calls
  - reduce calls
  - runtime wall clock
- [x] Persist compiled graph summaries and intermediate artifacts.
- [x] Add a real workflow-run report artifact per run.
- [ ] Add terminal integration test that asserts:
  - blueprint shown
  - node progress shown
  - final artifact shown
  - JSONL trace contains graph and scorecard.

Recommendation:

- Implement a `BudgetLedger` or `RunMetrics` component before running all
  scenarios. It will make scenario comparison objective instead of anecdotal.

### Coordinator Gaps

- [x] Add real blueprint proposal generation:
  - ask an LLM for a workflow blueprint, not the final domain output
  - provide a capability manifest
  - validate and repair the blueprint before compile
  - fall back to generic report workflow if proposal fails
- [x] Add multiple generic fallback shapes:
  - split/map/reduce/report
  - inspect/search/report
  - classify/group/report
  - compare/synthesize/report
  - parse/normalize/report
  - artifact-write report
- [x] Add targeted blueprint repair, not only whole-plan generic fallback.

Recommendation:

- This is the main missing piece for "dynamic RLM" rather than "generic RLM
  report pipeline." It should be the next implementation slice.

### Evidence And Repair Gaps

- [x] Strengthen objective scorecards:
  - required artifact exists
  - required sections exist
  - required source cues exist where declared
  - artifact quality checks for repeated raw map dumps or repeated sections
  - source coverage
  - provenance coverage
  - structured schema coverage where requested
  - residual risks
- [x] Add scorecard failure tests.
- [ ] Add targeted repair tests for:
  - [x] validation failure
  - compile failure
  - runtime node failure
  - [x] scorecard failure.

Recommendation:

- Scorecards should be scenario-driven. Each smoke scenario should declare
  expectations up front, then write expected-vs-observed smoke reports into
  `tmp/assistant_smoke/reports`.

## Completion Strategy

### Phase A: Make Scenario Runs Comparable

Deliverables:

- [x] Add `RunicAI.Assistant.RLM.SmokeRunner`.
- [x] Define `SmokeScenario` data:
  - id
  - objective
  - inputs
  - output
  - required sections
  - expected workflow capabilities
  - manual review checklist
- [x] Add JSONL trace summary helper:
  - nodes generated
  - component types used
  - source count
  - slice count
  - materialized count
  - LLM map count
  - reduce group count
  - write result
  - scorecard status
  - repair history.
- [x] Write a `tmp/assistant_smoke/reports` report per scenario.
- [x] Write a consolidated `tmp/assistant_smoke/reports` matrix across all
      scenarios.

Why first:

- Running all scenarios without a comparable harness will produce many artifacts
  but weak evidence. We need a consistent measurement shape.

### Phase B: Add Common-Use Components

Deliverables:

- [x] `SourceDiscovery`: explicit files, directories, extension filters, shallow
      globs, max file count, provenance.
- [x] `TabularParser`: CSV/JSONL/markdown-table ingestion into records.
- [x] `RecordMap`: map over records with LLM or Tier 1 transform.
- [x] `RecordGroup`: group/dedupe/rank records with Tier 0/Tier 1 functions.
- [x] `DocumentCompare`: pair sources, align chunks, emit change candidates.
- [x] `ReportComposer`: generic sectioned markdown composer that can use
      generated section plans.
- [x] `ObjectiveScorecard`: reusable verification component with required
      sections/schema/artifact/source coverage, required source cues, and
      artifact quality checks.
- [x] `BudgetLedger`: tracks and enforces node budgets at runtime.

Coding-agent crossover:

- `SourceDiscovery`, `BudgetLedger`, `ObjectiveScorecard`, `ArtifactWriter`, and
  trace-summary helpers should be shared with coding agents.
- `TabularParser`, `RecordMap`, and `RecordGroup` are useful for coding-agent
  work when processing logs, test output, issue exports, CI failures, or review
  comments.
- `DocumentCompare` is useful for codebase docs, changelog diffs, migrations,
  generated reports, and PR review workflows.

### Phase C: Make Coordinator Truly Dynamic

Deliverables:

- [x] Add a `BlueprintProposalPrompt` that asks for a workflow blueprint JSON
      object.
- [x] Include the capability manifest and examples of valid component shapes.
- [x] Ask for generated prompts and Tier 1 functions where useful.
- [x] Validate model-proposed blueprints.
- [ ] Add targeted repair prompts:
  - [x] validation diagnostics
  - compile errors
  - runtime node errors
  - [x] scorecard failures via bounded scorecard-diagnostic fallback repair.
- [x] Keep generic fallbacks as high-confidence recovery, not the main proof.

Acceptance criteria:

- At least three scenarios generate different workflow shapes.
- At least one scenario uses Tier 1 transforms.
- At least one scenario uses record/table components.
- At least one scenario uses multi-source comparison.
- At least one deliberately broken generated blueprint repairs successfully.

### Phase D: Run The Scenario Matrix

Recommendation:

- Run all scenarios, but treat them as a staged matrix.
- The first pass may use the generic fallback to establish baseline behavior.
- The second pass should use dynamic blueprint proposal.
- The third pass should use targeted repair/failure injection.

This gives three useful measurements:

1. How far the generic report pipeline goes.
2. Whether dynamic graph generation chooses materially better workflows.
3. Whether repair loops make the system more robust than one-shot generation.

## Scenario Matrix

### Scenario A: Long Fiction Chapter Wiki Page

Status:

- [x] First live smoke completed.
- [x] JSONL trace exists.
- [x] Artifact exists.
- [x] Diagrams written in `.docs/032`.
- [x] Livebook explanation written.

Current workflow shape:

```text
source file
  -> paragraph split
  -> materialize 20 slices
  -> LLM map slice notes
  -> LLM reduce wiki page
  -> write tmp artifact
  -> verify artifact
```

Next measurement:

- [ ] Re-run after `BudgetLedger` and stronger scorecard.
- [ ] Measure section coverage and source coverage.
- [ ] Compare generic fallback vs model-proposed blueprint.

### Scenario B: Meeting Transcript To Decisions And Action Register

Input fixture:

- `tmp/assistant_meeting_transcript.md`

Expected workflow pressure:

- speaker/time-aware splitting
- generated schema for decisions/actions/open questions/risks
- grouping by owner/deadline/topic
- final register artifact

Useful components surfaced:

- `SourceSplitter` with speaker-aware mode or configurable section splitter
- `LLMMap`
- `SchemaNormalizer`
- `RecordGroup`
- `ReportComposer`
- `ObjectiveScorecard`

Command target:

```sh
mix runic_ai.agent \
  "Turn tmp/assistant_meeting_transcript.md into tmp/assistant_smoke/artifacts/assistant-meeting-actions.md with decisions, action items, owners, deadlines, open questions, and risks." \
  --agent assistant \
  --input tmp/assistant_meeting_transcript.md \
  --output tmp/assistant_smoke/artifacts/assistant-meeting-actions.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/assistant-meeting-actions.assistant-rlm.jsonl
```

### Scenario C: Research Paper Or RFC Brief

Input fixture:

- `tmp/assistant_research_brief.md`

Expected workflow pressure:

- section-aware splitting
- claim/evidence extraction
- glossary extraction
- implementation implications
- limitations

Useful components surfaced:

- markdown-heading splitter
- `LLMMap`
- `RecordGroup`
- `ReportComposer`
- provenance-aware scorecard

Command target:

```sh
mix runic_ai.agent \
  "Create a research brief from tmp/assistant_research_brief.md with problem statement, method, claims, evidence, limitations, glossary, and implementation implications." \
  --agent assistant \
  --input tmp/assistant_research_brief.md \
  --output tmp/assistant_smoke/artifacts/assistant-research-brief.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/assistant-research-brief.assistant-rlm.jsonl
```

### Scenario D: Support Ticket Cluster Synthesis

Input fixture:

- `tmp/assistant_tickets.jsonl`

Expected workflow pressure:

- JSONL parsing
- generated classification prompt
- grouping by theme/failure mode/severity
- ranking by frequency/impact
- examples as evidence

Useful components surfaced:

- `TabularParser`
- `RecordMap`
- `RecordGroup`
- `SchemaNormalizer`
- Tier 1 `group_by`, `dedupe_by`, `sort_by`
- `ReportComposer`

Command target:

```sh
mix runic_ai.agent \
  "Cluster tmp/assistant_tickets.jsonl into themes, summarize customer impact, identify repeated failure modes, and write tmp/assistant_smoke/artifacts/assistant-ticket-themes.md." \
  --agent assistant \
  --input tmp/assistant_tickets.jsonl \
  --output tmp/assistant_smoke/artifacts/assistant-ticket-themes.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/assistant-ticket-themes.assistant-rlm.jsonl
```

### Scenario E: Personal Knowledge Base Weekly Digest

Input fixture:

- `tmp/assistant_notes/`

Expected workflow pressure:

- directory source discovery
- multi-file provenance
- per-file extraction
- cross-file dedupe
- "what changed over time" synthesis

Useful components surfaced:

- `SourceDiscovery`
- `SourceSplitter`
- `LLMMap`
- `RecordGroup`
- time-aware metadata extraction
- `ReportComposer`

Command target:

```sh
mix runic_ai.agent \
  "Write a weekly digest from tmp/assistant_notes with recurring themes, commitments, unresolved threads, and suggested follow-ups." \
  --agent assistant \
  --input tmp/assistant_notes \
  --output tmp/assistant_smoke/artifacts/assistant-weekly-digest.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/assistant-weekly-digest.assistant-rlm.jsonl
```

### Scenario F: Codebase Architecture Report Without Code Changes

Input:

- this repository

Expected workflow pressure:

- source discovery over code/docs
- bounded file selection
- source citation
- no mutation except `.docs`
- possible reuse of coding-agent source indexing

Useful components surfaced:

- `SourceDiscovery`
- coding `CodebaseEnvironment` bridge
- code-aware source splitter
- `LLMMap`
- `ReportComposer`
- `ObjectiveScorecard`

Command target:

```sh
mix runic_ai.agent \
  "Build a high-level architecture report for RunicAI, focusing on runtime, RLM, terminal harness, and coding-agent boundaries. Write it to tmp/assistant_smoke/artifacts." \
  --agent assistant \
  --input . \
  --output tmp/assistant_smoke/artifacts/assistant-runic-ai-architecture-report.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/assistant-runic-ai-architecture-report.assistant-rlm.jsonl
```

### Scenario G: CSV/Data Cleanup Strategy

Input fixture:

- `tmp/assistant_messy_contacts.csv`

Expected workflow pressure:

- CSV parsing
- rule inference
- preview rows
- uncertainty reporting
- Tier 1 normalization transforms

Useful components surfaced:

- `TabularParser`
- `RecordMap`
- `RecordGroup`
- Tier 1 `template`, `get`, `pick`, `dedupe_by`, `sort_by`
- `ArtifactWriter`

Command target:

```sh
mix runic_ai.agent \
  "Infer cleanup rules for tmp/assistant_messy_contacts.csv, produce a cleaned preview, explain uncertain rows, and write a cleanup plan to tmp/assistant_smoke/artifacts." \
  --agent assistant \
  --input tmp/assistant_messy_contacts.csv \
  --output tmp/assistant_smoke/artifacts/assistant-contacts-cleanup-plan.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/assistant-contacts-cleanup-plan.assistant-rlm.jsonl
```

### Scenario H: Multi-Document Comparison

Input fixtures:

- `tmp/assistant_policy_old.md`
- `tmp/assistant_policy_new.md`

Expected workflow pressure:

- paired source splitting
- alignment or paired comparison
- change classification
- affected stakeholder extraction
- migration brief

Useful components surfaced:

- `SourceDiscovery`
- `DocumentCompare`
- `LLMMap`
- `RecordGroup`
- `ReportComposer`

Command target:

```sh
mix runic_ai.agent \
  "Compare tmp/assistant_policy_old.md and tmp/assistant_policy_new.md, identify material changes, affected stakeholders, and open questions. Write a migration brief to tmp/assistant_smoke/artifacts." \
  --agent assistant \
  --input tmp/assistant_policy_old.md \
  --input tmp/assistant_policy_new.md \
  --output tmp/assistant_smoke/artifacts/assistant-policy-migration-brief.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/assistant-policy-migration-brief.assistant-rlm.jsonl
```

## Measurement Rubric

Every scenario should produce a manual verification report with:

- [ ] command run
- [ ] input fixture summary
- [ ] generated blueprint graph
- [ ] component types used
- [ ] generated prompts
- [ ] generated Tier 1 functions, if any
- [ ] source count and slice count
- [ ] materialized count and truncation status
- [ ] LLM map/reduce counts
- [ ] artifact path and byte size
- [ ] required section coverage
- [ ] source/provenance coverage
- [ ] residual risks
- [ ] repair history
- [ ] gaps discovered
- [ ] reusable component candidates

Horizontal capability is "sufficient" when:

- [ ] all eight scenarios complete with `.docs` artifacts and JSONL traces
- [ ] at least four distinct workflow shapes are generated
- [ ] at least three scenarios use task-specific prompts beyond the generic
      report fallback
- [ ] at least two scenarios use structured records or tables
- [ ] at least one scenario uses multi-source comparison
- [ ] at least one scenario uses directory source discovery
- [ ] at least one scenario triggers and repairs a validation/compile/runtime or
      scorecard failure
- [ ] common components are promoted into stable `RunicAI.RLM.Components`
      contracts
- [ ] coding-agent integration opportunities are documented and at least one is
      implemented

## Recommended Order

1. Scenario A replay hardening:
   - strengthen scorecard
   - add trace summary report
   - make existing long-document run the baseline
2. Scenario C:
   - validates markdown-heading split and evidence/provenance behavior
3. Scenario H:
   - validates multi-document comparison and motivates `DocumentCompare`
4. Scenario G:
   - validates tabular parsing and Tier 1 transforms
5. Scenario D:
   - validates JSONL records, clustering, grouping, and ranking
6. Scenario E:
   - validates directory source discovery and multi-file synthesis
7. Scenario B:
   - validates meeting/action-register patterns and structured report sections
8. Scenario F:
   - validates codebase source discovery and coding-agent substrate crossover

Why not start by running all eight immediately:

- The current generic fallback will probably produce plausible reports for many
  of them, but it will hide missing dynamic generation capability.
- A staged pass lets us add the common components that each scenario pressures,
  then rerun the matrix with better evidence.

Why eventually run all eight:

- They cover long prose, meetings, technical papers, JSONL support data,
  directory notes, codebases, CSV records, and multi-document comparison.
- That is a strong horizontal spread for "technical personal assistant" use.
- The component gaps they surface are likely to matter for coding agents too.

## Immediate Implementation Checklist

- [x] Add `SourceDiscovery`.
- [x] Add `BudgetLedger`.
- [x] Add `ObjectiveScorecard` component.
- [x] Add `SmokeScenario` and `SmokeRunner`.
- [x] Add trace summary helper and `.docs` report writer.
- [x] Add dynamic blueprint proposal prompt and schema.
- [x] Add targeted repair loop over validation diagnostics.
- [x] Add fixtures for Scenarios B-H.
- [x] Run Scenario A with strengthened scorecard.
- [x] Run Scenarios C, H, and G as the first horizontal proof set.
- [x] Run the remaining scenarios after source discovery, tabular parsing, and
      comparison components land.

## Coding-Agent Integration Candidates

These should move from assistant-specific learnings into shared coding-agent
capabilities:

- `SourceDiscovery`: codebase report generation, PR review, issue triage,
  architecture summaries.
- `BudgetLedger`: objective budgets, child-agent call budgets, command/runtime
  budgets.
- `ObjectiveScorecard`: standard and RLM coding agents need the same "artifact
  exists, expected sections, tests run, risks explicit" discipline.
- `TraceSummary`: terminal traces, CI debugging traces, coding-agent smoke
  reports.
- `DocumentCompare`: docs diffs, changelog analysis, migration notes, PR review.
- `TabularParser` and `RecordGroup`: CI logs, test failures, issue exports,
  review comments, support tickets.
- `ReportComposer`: durable `.docs` reports from coding-agent and assistant
  workflows.

The target architecture is shared substrate first:

```text
RunicAI.RLM.Components
  -> assistant RLM coordinator
  -> coding RLM coordinator
  -> terminal harness presentation
  -> Livebook/docs explanations
```

The assistant should not own generic capabilities that coding agents can use.
It should own coordinator policy, dynamic blueprint proposal, and the
assistant-facing workflow objective.
