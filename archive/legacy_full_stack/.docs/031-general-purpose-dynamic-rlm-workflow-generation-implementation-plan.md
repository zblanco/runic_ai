# General Purpose Dynamic RLM Workflow Generation Implementation Plan

Status: in progress; dynamic proposal, shared components, smoke harness,
scorecard repair, Runic-native compiler/executor migration, and live
fallback/dynamic matrices implemented

Date: 2026-04-30

Last verified: 2026-05-01 via `mix compile --warnings-as-errors`, `mix test`,
live provider ping, fallback smoke matrix, dynamic smoke matrix, and focused
post-repair live reruns for Scenarios G/H

Motivated by:

- `.docs/017-phase-9-rlm-execution-mode-and-recursive-long-context-workflows-implementation-plan.md`
- `.docs/020-runic-rlm-architecture-explainer.md`
- `.docs/026-rlm-coding-agent-implementation-plan.md`
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`
- The need for a general assistant RLM agent that can synthesize and repair
  task-specific Runic workflows instead of relying on prebuilt domain extractors.

Depends on:

- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/014-phase-7-observability-testing-and-evaluation-implementation-plan.md`
- `.docs/017-phase-9-rlm-execution-mode-and-recursive-long-context-workflows-implementation-plan.md`
- `.docs/024-coding-harness-and-tools-implementation-plan.md`
- `.docs/026-rlm-coding-agent-implementation-plan.md`
- `.docs/027-rlm-coding-agent-reliability-implementation-plan.md`
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`

References:

- `Runic.step/2`, `Runic.map/2`, `Runic.reduce/3`, and
  `Runic.workflow/1` as ordinary workflow graph construction primitives.
- `RunicAI.Recipes.RLMSummarizer` as a narrow proof that split/materialize/map
  leaf/reduce workflows are useful.
- `RunicAI.Coding.RLM.WorkflowProposal`, `ProposalNode`,
  `WorkflowValidator`, and `WorkflowCompiler` as the current coding-specific
  generated workflow substrate.
- `RunicAI.Terminal.Event` as the presentation-neutral event layer for showing
  generated workflow plans, execution, repairs, and final artifacts.

## Goal

Build a general-purpose RLM assistant capability where the agent dynamically
designs, validates, executes, observes, and repairs Runic workflow graphs for
the user's objective.

The important shift is from domain-specific shipped extractors to
task-specific workflow synthesis:

```text
objective + sources + available capabilities
  -> propose workflow graph
  -> propose component/function blueprints
  -> validate safety and contracts
  -> compile into ordinary Runic components, often with anonymous functions
  -> execute workflow
  -> inspect outputs, evidence, and failures
  -> repair graph or function blueprints
  -> write final artifact
```

The phase is successful when RunicAI can answer:

"Can an RLM assistant design its own Runic workflow for a non-coding task, (hell or even a coding task if it needs to)
compile it without generated files/modules, run it over bounded sources, repair
bad graph/function choices, and produce a durable artifact with evidence?"

2026-05-01 matrix note:

- The live fallback matrix is recorded in
  `tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-fallback.md`.
- The live dynamic matrix is recorded in
  `tmp/assistant_smoke/reports/assistant-rlm-smoke-matrix-dynamic.md`.
- Dynamic proposal generated materially different shapes for long-document,
  tabular, directory, codebase, and comparison tasks.
- The smoke harness now checks artifact existence, required sections,
  fixture-specific source cues, artifact quality, objective scorecard status,
  and expected workflow capabilities.
- Runtime scorecards now accept required source cues and artifact-quality
  checks. Scorecard failures trigger one bounded in-loop repair attempt, and
  smoke runs persist per-run JSON details in `tmp/assistant_smoke/runs`.
- `LLMMap` now serializes structured records into `{{text}}` when no text field
  exists, which lets generated workflows map over outputs like
  `DocumentCompare` instead of silently giving the model an empty text prompt.

## Non-Goal: Domain Extractor Library

This plan should not add first-class `EventExtractor`, `CharacterExtractor`,
`PlotPointExtractor`, ticket-clustering, meeting-action, or research-paper
extractor modules as permanent RunicAI domain components.

Those may be useful outputs of a generated workflow for a particular run, but
they should not become the product abstraction. RunicAI should provide:

- graph proposal contracts,
- safe function/component blueprints,
- source slicing and materialization,
- LLM leaf invocation,
- map/reduce orchestration,
- artifact writing,
- validation and repair loops,
- observability and terminal presentation.

If a capability is dangerous, generic, and reusable, extract it as a carefully
designed RunicAI component. Examples include artifact writing, guarded command
execution, JSON/schema normalization, source splitting, budget gates, review
gates, and generated-function validation. The long-tail task logic should be
generated per workflow.

## Core Design Idea

Runic components already accept anonymous functions. The RLM assistant should
therefore compile generated workflow specs into ordinary Runic graphs without
writing generated `.ex` files or modules.

The model should not usually emit arbitrary Elixir source. Instead it should
emit data that describes functions and components. The compiler turns accepted
data into closures:

```elixir
Runic.step(fn input -> ... end, name: :normalize_events)
Runic.map(fn slice -> ... end, name: :extract_chunk_facts)
Runic.reduce([], fn fact, acc -> ... end, name: :merge_facts)
```

The closure bodies can come from several safety tiers.

## Function Safety Tiers

### Tier 0: Parameterized Built-Ins

The safest and preferred tier. The model chooses from generic operations and
parameters:

```text
source.split(markdown_heading | paragraph | bytes | lines)
source.materialize(max_bytes)
llm.map(prompt, schema, model, max_concurrency)
collection.flatten
collection.dedupe_by(keys)
collection.group_by(key)
collection.sort_by(key)
artifact.write_markdown(path, content)
```

The compiler owns all Elixir closures. The model only chooses data.

### Tier 1: Validated Expression Blueprints

For simple custom transforms, the model emits a restricted expression AST or
JSON expression language:

```text
get(input, "characters")
map(input.events, pick(["actor", "event", "evidence"]))
dedupe_by(input, ["canonical_name", "event"])
join(input.sections, "\n\n")
template("# {{title}}\n\n{{body}}", input)
```

The compiler validates the expression and builds an anonymous function from a
trusted interpreter or closure generator. This allows task-specific glue logic
without `Code.eval_*`.

### Tier 2: Reviewed Elixir Function Blueprints

For cases where the expression language is too weak, the model may propose
Elixir function AST/source, but it must be treated as review-gated and unsafe
by default.

Rules:

- No generated modules or files are required for the first version.
- The generated function is parsed to AST, validated against a strict allowlist,
  and compiled into an anonymous function only after validation or operator
  approval.
- Allowed forms should be pure data transforms: literals, pattern matching,
  `case`, `cond`, `Enum`, `Map`, `List`, `String`, `Regex`, arithmetic, and
  local anonymous helper functions if the validator can prove they stay inside
  the same allowlist.
- Blocked forms include `File`, `System`, `Code`, `:os`, process primitives,
  `spawn`, `send`, `receive`, `Task`, networking, application environment
  access, arbitrary module calls, atom creation from strings, and dynamic apply.

Same-BEAM Elixir evaluation is not a real security sandbox. Tier 2 is a power
tool for trusted/local workflows and should be review-gated in the terminal
harness. If we need untrusted arbitrary code later, it must run in an external
sandboxed process with explicit I/O contracts.

### Tier 3: Extracted RunicAI Components

When a generated pattern appears repeatedly, is safety-critical, or deserves a
strong public contract, extract it as a real RunicAI component. Examples:

- guarded artifact writer,
- structured LLM map step,
- hierarchical reduce step,
- schema repair step,
- provenance-aware source splitter,
- generated-function validator.

This should be a product decision after observing repeated generated workflows,
not a preemptive domain taxonomy.

## Proposed Namespace

```text
lib/runic_ai/assistant/
  rlm/agent.ex
  rlm/coordinator.ex
  rlm/workflow_blueprint.ex
  rlm/component_blueprint.ex
  rlm/function_blueprint.ex
  rlm/blueprint_validator.ex
  rlm/workflow_compiler.ex
  rlm/execution_context.ex
  rlm/repair_loop.ex
  rlm/artifact_writer.ex
  rlm/smoke.ex

lib/runic_ai/rlm/components/
  source_splitter.ex
  source_materializer.ex
  llm_map.ex
  hierarchical_reduce.ex
  blueprint_transform.ex
  artifact_writer.ex
  schema_normalizer.ex

lib/runic_ai/terminal/
  assistant_runner.ex
```

The assistant namespace is not "personal assistant business logic." It is the
general coordinator/compiler/repair layer for non-coding dynamic workflows.
Shared RLM components live under `RunicAI.RLM.Components` when they are generic
enough to be useful outside the assistant.

## Workflow Blueprint Contract

The assistant should generate a workflow blueprint as data:

```elixir
%RunicAI.Assistant.RLM.WorkflowBlueprint{
  id: "...",
  objective: "...",
  sources: [%{id: "chapter", path: "tmp/wandering-inn-10-59-t.md"}],
  components: [
    %{id: "split", type: :source_splitter, params: %{strategy: :paragraph, max_bytes: 8_000}},
    %{id: "extract", type: :llm_map, params: %{prompt: "...", schema: %{...}}},
    %{id: "merge", type: :blueprint_reduce, params: %{function: %{tier: 1, expr: ...}}},
    %{id: "compose", type: :llm_leaf, params: %{prompt: "..."}},
    %{id: "write", type: :artifact_writer, params: %{path: ".docs/031-...md"}}
  ],
  edges: [
    %{from: "split", to: "extract"},
    %{from: "extract", to: "merge"},
    %{from: "merge", to: "compose"},
    %{from: "compose", to: "write"}
  ],
  stop_conditions: ["artifact written", "objective scorecard satisfied"],
  policies: %{
    mutation: %{allowed_paths: [".docs/**"], review: :ask},
    generated_functions: %{max_tier: 1},
    budgets: %{max_nodes: 20, max_llm_calls: 80, max_runtime_ms: 900_000}
  },
  metadata: %{domain_guess: :document_synthesis}
}
```

This is intentionally generic. A chapter-summary run may generate event,
character, and plot extraction prompts. A meeting run may generate action-item
and decision extraction prompts. A data-cleaning run may generate normalization
and grouping transforms.

## Component Blueprint Contract

Component blueprints should compile into Runic-native components:

| Blueprint type | Compiles to | Notes |
| --- | --- | --- |
| `:source_splitter` | `Runic.step/2` | Splits refs/files into slices with provenance. |
| `:source_materializer` | `Runic.map/2` or `Runic.step/2` | Late materialization. |
| `:llm_map` | `Runic.map/2` | Calls `RunicAI.LLM` over slices or records. |
| `:llm_leaf` | `Runic.step/2` | Single synthesis call over bounded parent outputs. |
| `:blueprint_transform` | `Runic.step/2` or `Runic.map/2` | Tier 0/1 generated function. |
| `:blueprint_reduce` | `Runic.reduce/3` or `Runic.step/2` | Merge, dedupe, group, rank. |
| `:review_gate` | Existing guard/review contract | Operator approval for risky plans/actions. |
| `:artifact_writer` | Guarded write component | Writes durable files through workspace policy. |
| `:child_agent` | Agent runner component | Optional standard/RLM child workflows. |
| `:verification` | Objective/evidence gate | Checks output shape and requested deliverables. |

The compiler should construct anonymous functions inside trusted code wherever
possible. The model describes intent and parameters; RunicAI constructs the
closures.

## Validation Requirements

Validation must happen before workflow execution and after every repair patch.

Graph validation:

- ids are stable and unique,
- edges reference existing nodes,
- graph is acyclic unless a bounded recurrence node is explicitly supported,
- every node has named inputs/outputs,
- stop conditions are non-empty,
- fan-out/fan-in is within budget,
- source materialization caps are present for large inputs,
- LLM map concurrency and call counts are bounded.

Function blueprint validation:

- tier is allowed by policy,
- expression/source validates against its tier,
- input and output shapes are declared,
- no unsafe modules, dynamic calls, process primitives, filesystem, shell, or
  network access,
- no `String.to_atom/1` or atom generation from user data,
- no unbounded recursion or obvious unbounded loops,
- output is JSON-safe or serializable for artifact persistence.

Mutation validation:

- artifact writes are limited to allowed paths,
- `.docs` writes are permitted for assistant reports,
- workspace mutation outside allowed paths requires review,
- shell and command execution are blocked unless the workflow explicitly
  declares a guarded command component and policy allows it.

Objective validation:

- requested output artifacts exist,
- final output has required sections or schema,
- final output cites source refs/spans when requested,
- residual risks are explicit,
- the agent cannot mark success only because the final LLM says "done."

## Dynamic Repair Loop

The repair loop should reason over concrete failures:

```text
proposal invalid
  -> repair blueprint

function blueprint rejected
  -> simplify to lower safety tier or ask for review

workflow compile failure
  -> repair component params/edges/function blueprint

runtime node failure
  -> inspect node input/output/error and repair only affected subgraph

objective gate failure
  -> add missing extraction/synthesis/checking node or adjust prompts/reducers
```

Repair should prefer smaller, safer changes:

1. lower a Tier 2 function into Tier 1 expression blueprints,
2. replace custom transforms with parameterized built-ins,
3. narrow sources or chunk sizes,
4. add intermediate reduction,
5. ask for review only when capability is truly needed.

## Terminal Harness Shape

The terminal harness should add an assistant route without making the existing
coding RLM path carry unrelated semantics:

```sh
mix runic_ai.agent \
  "Summarize tmp/wandering-inn-10-59-t.md as a wiki page and write it to tmp/assistant_smoke/artifacts" \
  --agent assistant \
  --cwd . \
  --detail expanded \
  --jsonl tmp/assistant-summary.trace.jsonl
```

Optional structured flags can make common assistant tasks easier without
becoming domain components:

```sh
--input tmp/wandering-inn-10-59-t.md
--output .docs/031-wandering-inn-10-59-t-summary.md
--allow-generated-functions tier1
--allow-generated-functions tier2-review
--write-policy docs-only
```

Terminal events should show:

- generated workflow blueprint,
- generated component/function blueprints,
- validation errors/warnings,
- compiled Runic graph summary,
- node progress,
- LLM map progress and chunk counts,
- repair patches,
- review gates,
- final artifact path,
- evidence scorecard.

## Phase 0: Assistant Workflow Blueprint Contracts

Deliverables:

- [x] Define `RunicAI.Assistant.RLM.WorkflowBlueprint`.
- [x] Define `ComponentBlueprint` with type, params, input/output contracts,
      policy, provenance, and metadata.
- [x] Define `FunctionBlueprint` with tier, expression/source, declared inputs,
      declared outputs, and safety metadata.
- [x] Define `ExecutionContext` for objective, sources, workspace, artifacts,
      event sink, budgets, and policy.
- [ ] Add conversion helpers from existing coding `WorkflowProposal` only where
      concepts overlap; do not force assistant workflows into coding node kinds.

Validation:

- [x] Unit test valid and invalid blueprint construction.
- [x] Unit test unique node ids, missing edges, missing stop conditions, and
      invalid component types.
- [x] Unit test JSON round-trip for generated blueprints.

## Phase 1: Generic RLM Source And Artifact Components

Deliverables:

- [x] Extract or add `RunicAI.RLM.Components.SourceSplitter`.
- [x] Support markdown heading, paragraph, line, byte, and existing structural
      slice modes with provenance.
- [x] Extract or add `SourceMaterializer` with max bytes per slice and max total
      bytes per node.
- [x] Add `LLMMap` for bounded map-over-slices or map-over-records calls with
      model/client/prompt/schema params.
- [x] Add `HierarchicalReduce` for multi-level fan-in when parent outputs exceed
      synthesis budgets.
- [x] Add guarded `ArtifactWriter` that writes through workspace path policy and
      review gates.
- [x] Add `SchemaNormalizer` for parsing/repairing LLM JSON-like outputs without
      domain-specific schemas.

Validation:

- [x] Unit test splitter provenance and overlap behavior.
- [x] Unit test materialization caps on a large text fixture.
- [x] Unit test LLM map with scripted clients and bounded concurrency.
- [x] Unit test hierarchical reduce keeps parent outputs under configured caps.
- [x] Unit test artifact writer allows `.docs` and blocks unsafe paths.

## Phase 2: Safe Function Blueprint Compiler

Deliverables:

- [x] Implement Tier 0 built-in operation compiler.
- [x] Implement Tier 1 expression blueprint interpreter or closure generator.
- [x] Define the Tier 1 expression language for `get`, `pick`, `map`, `filter`,
      `flatten`, `group_by`, `dedupe_by`, `sort_by`, `join`, `template`,
      `json_encode`, and simple conditionals.
- [ ] Implement Tier 2 AST/source validator behind an explicit policy flag.
- [ ] Compile accepted Tier 2 blueprints into anonymous functions without
      writing generated files/modules.
- [ ] Review-gate Tier 2 by default in the terminal harness.
- [x] Emit validation diagnostics that are useful for RLM repair.

Validation:

- [x] Unit test Tier 0 operation compilation.
- [x] Unit test Tier 1 expression execution over nested maps/lists.
- [ ] Unit test blocked Tier 2 forms: `File`, `System`, `Code`, dynamic apply,
      process primitives, network-ish modules, and atom creation.
- [ ] Unit test accepted Tier 2 pure transforms if Tier 2 is implemented in this
      phase.
- [ ] Unit test generated function failures are caught as repairable node
      errors.

## Phase 3: Assistant Workflow Compiler

Deliverables:

- [x] Compile `WorkflowBlueprint` into `Runic.Workflow`.
- [x] Compile each component blueprint into a named Runic component.
- [x] Support fan-out/fan-in over map and reduce components.
- [x] Attach provenance and blueprint ids to node outputs and trace events.
- [x] Carry budgets into generated LLM calls, materialization calls, and reduce
      nodes.
- [x] Return structured compile errors instead of raising when possible.
- [x] Preserve compiled graph summaries for terminal display and persistence.
      Graph summaries now include blueprint metadata plus compiled Runic
      workflow serializer data; durable runner persistence remains open.

Validation:

- [x] Unit test component compilation for each blueprint type.
- [x] Unit test graph construction with fan-out/fan-in.
- [x] Unit test invalid function blueprint blocks workflow compilation.
- [x] Integration test blueprint -> Runic workflow -> deterministic execution.

## Phase 4: General Assistant RLM Coordinator

Deliverables:

- [x] Add `RunicAI.Assistant.RLM.Coordinator` that prompts for workflow
      blueprints, not domain-specific outputs.
- [x] Provide the coordinator a capability manifest:
      component types, function tiers, source limits, allowed writes, LLM models,
      child-agent availability, and terminal review policy.
- [x] Add fallback blueprints for high-confidence generic shapes:
      split/map/reduce/report, inspect/search/report, classify/group/report,
      compare/synthesize/report, and artifact-write report.
- [x] Keep fallbacks generic and parameterized; they should not encode fiction,
      meeting, research, ticket, or code-review domain schemas.
- [x] Allow generated prompts/schemas inside `LLMMap` and `LLMLeaf` nodes.
- [ ] Support plan repair from blueprint validation and compile diagnostics.
      Validation-diagnostic and scorecard-diagnostic repair are implemented;
      runtime node repair now has one bounded blueprint repair pass; Runic port
      mismatch compile diagnostics are structured for repair prompts.

Validation:

- [x] Scripted coordinator test for document synthesis workflow generation.
- [x] Scripted coordinator test for tabular/data cleaning workflow generation.
- [ ] Test invalid generated blueprint falls back to safe generic workflow.
- [x] Test repaired blueprint replaces an invalid generated graph.

## Phase 5: Execution, Evidence, And Repair

Deliverables:

- [x] Add `RunicAI.Assistant.RLM.Agent.run/3`.
- [x] Emit stage events compatible with `RunicAI.Terminal.Event`.
- [x] Execute compiled workflow with bounded budgets.
- [x] Record episodes/artifacts for each generated node.
- [x] Add objective/evidence scorecard for assistant outputs:
      required artifacts, required sections/schema, source coverage, provenance,
      required source cues, residual risks, and output quality checks.
- [ ] Implement repair loop over validation, compile, runtime, and scorecard
      failures.
      Validation failure repair and one bounded scorecard repair attempt are
      implemented; runtime node failures now trigger one bounded blueprint
      repair pass; Runic port mismatch compile diagnostics are normalized, but
      dedicated compile-repair attempts are still future work.
- [x] Persist generated blueprint, compiled graph summary, intermediate
      artifacts, final artifact, scorecard, and repair history.

Validation:

- [ ] Unit test scorecard failure for missing artifact.
- [x] Unit test scorecard failure for missing required sections/schema.
- [x] Unit test scorecard failure for missing required source cues and artifact
      quality.
- [x] Unit test scorecard failure triggers one bounded repair attempt.
- [x] Unit test runtime node failure triggers targeted blueprint repair.
- [x] Integration test full run with scripted LLM clients and generated
      split/map/reduce/write workflow.

## Phase 6: Terminal Harness Integration

Deliverables:

- [x] Add `--agent assistant` to `mix runic_ai.agent`.
- [x] Add optional `--input PATH`, `--output PATH`,
      `--allow-generated-functions tier0|tier1|tier2-review`, and
      `--write-policy none|docs-only|workspace-review`.
- [x] Add `RunicAI.Terminal.AssistantRunner`.
- [x] Render generated workflow blueprints and function blueprint summaries.
- [x] Render validation/compile/execute/repair stages.
- [x] Render final artifact paths and objective scorecards.
- [x] Write all normalized events to JSONL.

Validation:

- [x] Unit test CLI parsing for assistant options.
- [x] Unit test assistant runner with scripted generated blueprint.
- [ ] Integration test terminal output includes blueprint, node progress,
      repairs, final artifact, and JSONL trace.

## Phase 7: Long-Document Assistant Smoke

Use `tmp/wandering-inn-10-59-t.md` as the motivating exercise, but keep the
implementation generic.

Objective:

```text
Read tmp/wandering-inn-10-59-t.md coherently without stuffing the full chapter
into one prompt. Write a wiki-style chapter page under
tmp/assistant_smoke/artifacts with:

- high-level overview,
- events that happened and by who,
- notable characters and what they did,
- major plot points,
- important reveals/setup,
- overall takeaways,
- source-span or chunk provenance where practical.
```

Expected generated workflow shape:

```text
source file
  -> split into bounded slices
  -> generated LLM map prompt/schema for per-slice facts
  -> generated reducer for dedupe/entity/thread merging
  -> generated synthesis prompt for wiki page
  -> artifact writer to tmp/assistant_smoke/artifacts
  -> scorecard verifies requested sections and artifact exists
```

Manual smoke command target:

```sh
mix runic_ai.agent \
  "Read tmp/wandering-inn-10-59-t.md and write a wiki-style chapter page in .docs" \
  "with overview, events by actor, notable characters, plot points, reveals, and takeaways." \
  --agent assistant \
  --input tmp/wandering-inn-10-59-t.md \
  --output tmp/assistant_smoke/artifacts/wandering-inn-10-59-t-summary.md \
  --allow-generated-functions tier1 \
  --write-policy docs-only \
  --detail expanded \
  --jsonl tmp/wandering-inn-10-59-t.assistant-rlm.jsonl \
  --max-runtime-ms 900000
```

Validation:

- [ ] Manual output artifact exists under `.docs`.
- [ ] Artifact is not just a one-shot summary; it reflects chunked synthesis.
- [ ] Artifact contains all requested sections.
- [ ] JSONL trace shows generated workflow, chunk count, map/reduce progress,
      final writer node, and scorecard.
- [ ] If the first generated workflow fails, repair history shows a bounded
      graph/function repair.

## Additional Manual Smoke Scenarios

These are deliberately varied assistant tasks. They should exercise dynamic
workflow generation rather than fixed recipes.

### Scenario A: Long Fiction Chapter Wiki Page

Input: `tmp/wandering-inn-10-59-t.md`

Task: wiki-style chapter page with events, characters, plot threads, reveals,
and takeaways.

Capability pressure:

- long document splitting,
- generated extraction prompts,
- entity/thread dedupe,
- artifact writing,
- provenance.

### Scenario B: Meeting Transcript To Decisions And Action Register

Fixture: add `tmp/assistant_meeting_transcript.md`.

Task:

```text
Turn this transcript into tmp/assistant_smoke/artifacts/assistant-meeting-actions.md
with decisions, action items, owners, deadlines, open questions, and risks.
```

Capability pressure:

- source chunking by speaker/time,
- generated action-item schema,
- dedupe repeated decisions,
- final structured report.

### Scenario C: Research Paper Or RFC Brief

Fixture: add a public-domain or project-owned markdown paper/RFC excerpt under
`tmp/assistant_research_brief.md`.

Task:

```text
Create a research brief with problem statement, method, claims, evidence,
limitations, glossary, and implementation implications.
```

Capability pressure:

- section-aware splitting,
- claim/evidence extraction,
- glossary generation,
- synthesis across sections.

### Scenario D: Support Ticket Cluster Synthesis

Fixture: JSONL or markdown ticket export under `tmp/assistant_tickets.jsonl`.

Task:

```text
Cluster tickets into themes, summarize customer impact, identify repeated
failure modes, and write tmp/assistant_smoke/artifacts/assistant-ticket-themes.md.
```

Capability pressure:

- parsing semi-structured input,
- generated grouping/reducer functions,
- ranking by frequency/severity,
- evidence examples.

### Scenario E: Personal Knowledge Base Weekly Digest

Fixture: a directory `tmp/assistant_notes/` with daily markdown notes.

Task:

```text
Write a weekly digest with recurring themes, commitments, unresolved threads,
and suggested follow-ups.
```

Capability pressure:

- multi-file source discovery,
- generated per-file extractors,
- cross-file dedupe,
- "what changed over time" synthesis.

### Scenario F: Codebase Architecture Report Without Code Changes

Input: this repository.

Task:

```text
Build a high-level architecture report for RunicAI, focusing on runtime,
RLM, terminal harness, and coding-agent boundaries. Write it to
tmp/assistant_smoke/artifacts.
```

Capability pressure:

- read/search over code,
- dynamic graph design for repo exploration,
- source citations,
- artifact writing,
- no mutation outside `.docs`.

### Scenario G: CSV/Data Cleanup Strategy

Fixture: `tmp/assistant_messy_contacts.csv`.

Task:

```text
Infer cleanup rules, produce a cleaned preview, explain uncertain rows, and
write a cleanup plan to tmp/assistant_smoke/artifacts.
```

Capability pressure:

- generated parsing and normalization transforms,
- Tier 1 expression blueprints,
- uncertainty reporting,
- tabular artifact summaries.

### Scenario H: Multi-Document Comparison

Fixture: `tmp/assistant_policy_old.md` and `tmp/assistant_policy_new.md`.

Task:

```text
Compare the documents, identify material changes, affected stakeholders, and
open questions. Write a migration brief to tmp/assistant_smoke/artifacts.
```

Capability pressure:

- paired source splitting,
- generated comparison workflow,
- change classification,
- final synthesis with evidence.

## Automated Test Strategy

Unit tests:

- blueprint contracts,
- graph validator,
- function blueprint validator,
- Tier 0/Tier 1 function execution,
- component compiler,
- artifact writer path policy,
- scorecard checks.

Integration tests with scripted clients:

- generated split/map/reduce/write workflow over a synthetic long document,
- invalid blueprint repair,
- invalid function blueprint repair,
- objective scorecard repair,
- terminal assistant runner JSONL export.

Manual smokes:

- run at least three scenarios from the list above before calling this phase
  complete:
  - one long single-document synthesis,
  - one multi-document or directory synthesis,
  - one semi-structured data synthesis.

## Design Risks

- Arbitrary Elixir execution in the BEAM is not a sandbox. Tier 2 must be
  reviewed and tightly validated.
- If the expression language is too weak, the model will over-request Tier 2.
  Repair prompts should teach it to prefer Tier 0/Tier 1.
- If the coordinator sees too many component choices, it may produce invalid
  graphs. Capability manifests should start small and grow from smoke evidence.
- If final reports are judged only by model self-report, the assistant will
  overclaim. Scorecards must check artifacts and requested sections.
- If source splitting loses provenance, final artifacts will be hard to audit.
  Source refs/spans should be first-class from Phase 1.

## Completion Criteria

- `mix compile --warnings-as-errors`
- `mix test test/runic_ai/assistant`
- `mix test test/runic_ai/terminal`
- `mix test`
- Manual long-document assistant smoke writes a `.docs` artifact.
- Manual multi-source assistant smoke writes a `.docs` artifact.
- Manual semi-structured assistant smoke writes a `.docs` artifact.
- JSONL traces for manual smokes show generated graph, validation, execution,
  repairs if any, final artifact, and scorecard.

The intended outcome is not a chapter summarizer. The intended outcome is a
RunicAI RLM assistant that can generate the workflow a chapter summarizer needs,
then generate a different workflow for the next assistant task.
