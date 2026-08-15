# RunicAI Generated Component Promotion Plan

Status: active

Date: 2026-05-30

Last aligned: 2026-05-31, after the Runic Sandbox consumer-driven improvement
loop delivered proof-first generated-component execution, coordinator promotion
integration, attach event truth, and Docker restricted egress enforcement.

## Purpose

RunicAI's general-purpose RLM coordinator should be able to solve user intents
by building arbitrary Runic workflow graphs from a growing catalog of useful
components. The coordinator should prefer known components, detect real
capability gaps, generate new leaf components only when justified, prove those
leaves inside managed sandboxes, and promote useful proven components back into
the catalog with enough metadata for future retrieval.

The flywheel is:

```text
user intent
  -> retrieve candidate components
  -> detect graph or leaf capability gap
  -> plan a generated component contract in context
  -> build, test, and repair in sandbox
  -> prove with durable evidence
  -> decide promotion target
  -> catalog with searchable intent, contract, policy, and proof metadata
  -> reuse in later workflow generation
```

This plan is the RunicAI product/runtime layer above
`.docs/053-runic-sandbox-consumer-driven-improvement-plan.md`. The sandbox plan
provided the managed execution substrate. This plan completes the dynamic
workflow learning loop that consumes it.

## Product Goal

Complete a practical generated-component promotion path for a general-purpose
dynamic workflow problem-solving agent:

- the RLM coordinator observes user intent, available sources, policy, and
  current catalog coverage;
- it orients on input/output contracts, component kind, runtime, dependencies,
  sandbox profile, and success definition;
- it decides whether to reuse, adapt, generate, repair, promote, or reject;
- it acts through sandbox-only build/proof and catalog-backed workflow
  composition;
- it learns from each workflow run so recurring useful components become easier
  to retrieve and require less repair.

The important product outcome is not just "generated code passed once." It is
that future dynamic workflows become more reliable because the agent has a
larger, better-described library of sandbox-proven components to compose.

## Current Baseline

Delivered pieces now present in the repo:

- `RunicAI.Sandbox.GeneratedComponent` records generated component contracts,
  source/test artifact refs, interface, verification, provenance, metadata, and
  promotion status.
- `RunicAI.Sandbox.GeneratedComponentProposalPrompt` provides a contract-first
  prompt/schema surface.
- `RunicAI.Sandbox.GeneratedComponentBuilder` can write proposed source/tests
  into a sandbox session, execute verification, repair failed attempts through a
  callback, and return a verified or failed draft component.
- `RunicAI.Sandbox.GeneratedComponentProof.run/2` proves generated components
  through `runic_sandbox` attach-shaped execution and records attach summary,
  artifacts, cleanup, and verification evidence.
- `RunicAI.Sandbox.GeneratedComponentPromotionPolicy` distinguishes ephemeral,
  artifact-backed, and host-repo promotion targets, with host materialization
  review-gated.
- `RunicAI.Sandbox.GeneratedComponentPromotionFlow.run/2` ties proposal, proof,
  promotion decision, workflow composition, event maps, and repair context into
  one coordinator-facing seam.
- `RunicAI.Sandbox.GeneratedComponentWorkflow.compose/3` converts verified
  generated components into ordinary assistant workflow blueprints without
  executing generated source on the host.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` accepts
  `generated_component_proposal:` for proof-gated composition, and
  `generated_component:` / `generated_components:` for already-verified
  composition.
- `runic_sandbox` now exposes attach readiness metadata, event bridge semantics,
  active attach lifecycle tracking, provider truth, and Docker restricted
  egress for scoped MCP-style access.
- Deterministic sandbox/RLM evaluation fixtures include generated-component
  promotion decisions and comparison harnesses.

At plan start, the missing pieces for the 054 flywheel were:

- a durable or replayable generated-component catalog with retrieval-facing
  indexes;
- gap-detection records that explain why an existing component was not enough;
- salience/usefulness scoring for deciding what should be kept, preferred, or
  retired;
- coordinator prompt/context plumbing that exposes catalog candidates and
  requires reuse-before-generation reasoning;
- catalog write/read APIs that make promoted components available to later
  workflow synthesis;
- dogfood scenarios that measure reuse rate, proof pass rate, repair count,
  promotion outcomes, and workflow quality over repeated intents;
- clear degradation behavior when catalog retrieval fails, sandbox proof fails,
  or review denies promotion.

Slices 1-10 below close the practical in-memory and deterministic dogfood scope.
Durable storage, broader live smokes, and workbench-specific rendering remain
explicit follow-ups in the completion audit.

## Design Principles

Generated code is never trusted because it compiled. A generated component
becomes reusable only after it has:

- an explicit input/output contract tied to the user intent and workflow role;
- an allowed runtime, dependency policy, and sandbox profile;
- generated source/test artifact provenance;
- sandbox proof evidence with bounded stdout/stderr and terminal status;
- deterministic examples, tests, contract checks, or smoke assertions;
- a promotion decision that can be reviewed and replayed;
- searchable catalog metadata describing when to retrieve it again.

The coordinator may generate drafts. The sandbox proves behavior. RunicAI
promotes a reviewed component contract and audited artifact reference. Host
native promotion remains a higher-trust follow-up, not the default.

## RALPH/OODA Loop

Use this loop for each implementation slice and later for the runtime agent.

### Observe

Collect the objective, source shape, desired outputs, policy constraints,
existing workflow graph, catalog candidates, previous proof outcomes, and
failure evidence.

### Orient

Classify the need:

- intent family, such as parse, normalize, rank, transform, validate, render,
  route, call tool, or coordinate subworkflow;
- input/output contract and example cases;
- component kind, such as Runic step, map, reduce, rule, accumulator,
  sandbox-backed leaf, tool adapter, or scorecard;
- runtime and dependency requirements;
- safety posture: no network, restricted network, live stdin, host writes,
  artifact-only, or host-native review;
- reuse posture: exact catalog hit, adaptable hit, missing leaf, or missing
  graph pattern.

### Decide

Choose one action:

- reuse a built-in or promoted catalog component;
- adapt a catalog component by parameters only;
- compose existing components into a new workflow graph;
- generate a new sandbox-backed leaf because the gap is narrow and testable;
- repair a failed generated leaf using proof evidence;
- request review for higher-trust promotion;
- reject the component and preserve the reason.

### Act

Execute the chosen action through the existing proof gates:

- build source/tests only inside the sandbox;
- run proof with attach events and bounded output;
- validate contract and acceptance checks;
- update proposal/proof/promotion events;
- compose the workflow only when the component is verified and policy allows
  use;
- write catalog metadata only after the promotion decision allows it.

### RALPH Runtime Mnemonic

For generated component promotion specifically:

```text
Retrieve -> Author -> Launch -> Prove -> Harvest
```

- Retrieve: search catalog and expose candidates to the coordinator.
- Author: draft the component contract, tests, proof plan, and safety policy
  before source.
- Launch: materialize source/tests in a managed sandbox and run verification.
- Prove: evaluate proof, contract, outputs, artifacts, policy, and repair
  evidence.
- Harvest: promote useful components into the catalog with searchable metadata
  and salience signals.

## Component Lifecycle

Current code has the compact statuses `:draft`, `:verified`, `:promoted`, and
`:rejected`. The product lifecycle should project those into the richer
operator-facing states below without forcing the core struct to carry every
transient phase:

```text
draft
  -> contract_validated
  -> sandbox_building
  -> sandbox_proving
  -> sandbox_verified
  -> review_required
  -> review_approved
  -> catalog_available
```

Failure and retirement states:

```text
draft_rejected
sandbox_failed
contract_failed
review_rejected
promotion_revoked
catalog_retired
```

Each transition should preserve enough evidence to answer:

- what user intent and workflow role caused the component to be generated;
- which catalog candidates were considered and why they were insufficient;
- what input/output contract and examples were claimed;
- what source/test artifacts were produced;
- what sandbox backend/profile/command proved it;
- what stdout/stderr, exit status, events, and artifacts were observed;
- what promotion target was requested and approved or rejected;
- when the component was later reused and whether reuse succeeded.

## Catalog Shape

The catalog should start as a simple data-backed API that can be in-memory,
artifact-backed, or persisted later. The API matters more than the first store.

Required lookup inputs:

```elixir
%{
  objective: "normalize vendor invoice rows",
  intent_tags: [:parse, :normalize, :tabular],
  inputs: [%{name: "rows", type: "list<object>"}],
  outputs: [%{name: "invoice_facts", type: "list<object>"}],
  component_kind: :step,
  runtime: :python,
  policy: %{network: :disabled}
}
```

Required catalog entry fields:

```elixir
%{
  id: "generated:invoice_row_normalizer",
  name: "Invoice row normalizer",
  source: :agent_generated,
  status: :catalog_available,
  promotion_target: :artifact,
  component_kind: :sandbox_execute,
  language: :python,
  runtime: :python,
  entrypoint: "component.py:run",
  intent_tags: [:parse, :normalize, :tabular],
  input_signature: [%{name: "rows", type: "list<object>"}],
  output_signature: [%{name: "invoice_facts", type: "list<object>"}],
  examples: [%{input_ref: "...", output_ref: "..."}],
  sandbox_profile: %{backend: :docker, network: :disabled},
  verification: %{status: :pass, proof_ref: "proof_..."},
  artifacts: %{source: [...], tests: [...]},
  provenance: [...],
  salience: %{
    reuse_count: 0,
    successful_reuse_count: 0,
    last_used_at: nil,
    domains: ["invoices"]
  },
  metadata: %{}
}
```

Retrieval should prefer:

- exact contract and policy matches;
- promoted artifact-backed entries over merely verified ephemeral entries;
- lower-risk runtimes and no-network profiles;
- components with successful reuse history;
- components with examples close to the current source shape;
- recent proof evidence, unless a component has stable reuse history.

## Promotion Policy

Default generated-component proof policy:

```elixir
%{
  backend: :docker,
  runtime: :python,
  network: :disabled,
  timeout_ms: 30_000,
  max_output_bytes: 65_536,
  persist_changes?: false,
  host_writes?: false,
  review_required?: true,
  promotion_target: :ephemeral
}
```

Promotion targets:

- `:ephemeral`: usable in the current workflow after proof, but not retained as
  a durable catalog entry.
- `:artifact`: durable sandbox-backed catalog entry, default target for useful
  reusable components.
- `:host_repo`: explicit reviewed movement into the host codebase; never
  automatic.

Escalations must be explicit:

- network access requires `network: :restricted` and allow-list metadata;
- live stdin requires `attach_mode: :live_stream` and stdin support;
- dependency installation requires a declared dependency policy;
- service/MCP access requires scoped boundary metadata and backend support;
- host-native promotion requires user approval and branch hygiene checks.

## Implementation Slices

Deliver this in small slices. Each slice should add focused regression tests,
run package-local validation, record dogfood evidence, and update this document
with results before moving on.

| Slice | Scope | Deliverables | Acceptance criteria | Validation | Status |
| --- | --- | --- | --- | --- | --- |
| 0. Baseline alignment | Reframe 054 around the delivered 053 substrate and current RunicAI modules. | Updated plan, active goal, explicit OODA/RALPH loop, concrete slice ledger. | The next work starts from current proof/promotion code instead of re-building it. | `git diff --check` for doc edit. | Completed 2026-05-31 |
| 1. Catalog API skeleton | Add a generated-component catalog boundary independent of storage. | Catalog entry struct/schema, lookup query shape, in-memory store, ranking result, conversion from `GeneratedComponent` plus promotion decision. | Promoted artifact entries can be inserted, listed, retrieved by id, and searched by intent tags, IO signatures, runtime, and policy. | Focused catalog tests; no sandbox required. | Completed 2026-05-31 |
| 2. Gap decision record | Make reuse-before-generation observable. | `CapabilityGap` or equivalent record with objective, required contract, candidate ids, rejection reasons, and selected action. | Coordinator paths can explain exact reuse, adaptable reuse, generated leaf, or rejection; generated leaves require a gap record. | Coordinator/unit tests with seeded catalog candidates. | Completed 2026-05-31 |
| 3. Coordinator catalog context | Feed catalog candidates into dynamic proposal prompts and require candidate-aware decisions. | Prompt/context helper, candidate summarizer, validation that generated proposals cite a gap decision. | Dynamic workflow proposal uses catalog entries when valid and only emits generated proposals for narrow testable gaps. | Assistant RLM coordinator tests with fake LLM outputs. | Completed 2026-05-31 |
| 4. Promotion write path | Persist or artifact-link successful promotion decisions into the catalog. | Flow option for catalog writer, event for catalog write, duplicate/update semantics, salience initialization. | `GeneratedComponentPromotionFlow.run/2` can promote to artifact catalog after proof/review without host source execution. | Promotion-flow tests plus existing sandbox tests. | Completed 2026-05-31 |
| 5. Catalog-backed composition | Let coordinator compose later workflows from promoted entries without regenerating source. | `generated_component_catalog:` option or default catalog lookup, workflow blueprint metadata linking catalog ids and proof refs. | A second similar objective reuses a promoted component and skips source generation/proof unless policy requires re-proof. | Two-run deterministic dogfood test. | Completed 2026-05-31 |
| 6. Repair-to-catalog loop | Connect failed proof evidence to component repair and eventual promotion. | Repair context -> revised source/test proposal path, attempt counters, failed-component retention, no-promotion-on-failure invariant. | A failing generated component can be repaired in sandbox, then promoted; unrepaired failure leaves searchable negative evidence. | Builder/proof/promotion integration tests. | Completed 2026-05-31 |
| 7. Salience and retirement | Track reuse quality so the catalog improves rather than grows blindly. | Reuse outcome records, simple score, demotion/retirement policy, duplicate detection. | Frequently successful entries rank higher; failed or stale entries are demoted or require re-proof. | Catalog ranking tests and coordinator reuse callback test. | Completed 2026-05-31 |
| 8. Dogfood matrix | Measure the flywheel across repeated dynamic workflow intents. | Deterministic scenarios and optional live smokes for parse/normalize, report transform, tool adapter, restricted MCP/service call, and denied host promotion. | Report shows reuse rate, proof pass rate, repair count, promotion decisions, workflow completion, and residual risks. | `mix runic_ai.rlm.sandbox_eval`, focused tests, live Docker smoke when available. | Completed 2026-05-31 |
| 9. UI/trace visibility | Make promotion decisions inspectable in terminal/workbench traces. | Trace/read-model events for catalog search, gap decision, proof, repair, promotion, reuse, and retirement. | Operator can answer why a component was generated or reused from run evidence. | Live/workbench or terminal-focused smoke. | Completed 2026-05-31 |
| 10. Completion audit | Decide whether 054 is done enough to call the goal complete. | Requirement checklist, broad validation, docs reconciliation, follow-up roadmap. | General dynamic workflow runs can reuse promoted generated components and demonstrate lower repair/generation effort on repeated intents. | Full relevant test matrix plus current sandbox provider health checks. | Completed 2026-05-31 |

### Slice 1 Notes

Implementation result:

- Added `RunicAI.Sandbox.GeneratedComponentCatalog` as the public facade.
- Added `GeneratedComponentCatalog.Entry` for searchable promoted component
  records with intent tags, IO signatures, sandbox policy, proof/artifact refs,
  provenance, salience, and original `GeneratedComponent` contract.
- Added `GeneratedComponentCatalog.Query` for retrieval inputs.
- Added `GeneratedComponentCatalog.Result` for ranked matches and match reasons.
- Added `GeneratedComponentCatalog.Store`, a plain in-memory catalog with
  insert, list, get, and search APIs.
- `Entry.from_component/2` now converts promotable verified generated
  components plus promotion-decision metadata into catalog records.
- Search ranking currently requires semantic relevance from tags or IO
  signatures, then boosts runtime, component kind, policy, artifact promotion,
  and successful reuse history.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_catalog_test.exs` passed:
  `4 tests, 0 failures`.
- `mix test test/runic_ai/sandbox` passed: `44 tests, 0 failures`.

### Slice 2 Notes

Implementation result:

- Added `GeneratedComponentCatalog.CapabilityGap`, a validated decision record
  containing objective, required contract, considered candidates, rejection
  reasons, selected action, selected component id, and rationale.
- Added facade helpers `GeneratedComponentCatalog.capability_gap/1` and
  `capability_gap!/1`.
- `GeneratedComponentPromotionFlow.run/2` now requires `:capability_gap` and
  rejects proof-backed generated proposals unless the gap action is
  `:generate_leaf` or `:repair_generated`.
- Promotion-flow events now include
  `:generated_component_capability_gap_decided`.
- Failed proof repair context now includes the capability-gap summary so repair
  turns preserve why generation was attempted.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` forwards `:capability_gap` into
  the proof-gated generated-component promotion path.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_capability_gap_test.exs
  test/runic_ai/sandbox/generated_component_promotion_flow_test.exs` passed:
  `9 tests, 0 failures`.
- `mix test test/runic_ai/sandbox` passed: `49 tests, 0 failures`.
- `mix test test/runic_ai/assistant/rlm_blueprint_test.exs` passed:
  `21 tests, 0 failures`.

Next slice: feed catalog candidates into coordinator proposal context and make
dynamic workflow decisions candidate-aware instead of only accepting manually
provided gap records.

### Slice 3 Notes

Implementation result:

- Added `GeneratedComponentCatalog.Context` for coordinator-facing catalog
  context.
- `GeneratedComponentCatalog.prompt_context/2` now searches a provided
  in-memory catalog and returns prompt-ready candidate summaries with match
  reasons, contract signatures, runtime, sandbox profile, verification, and
  salience.
- `GeneratedComponentCatalog.gap_for_proposal/3` now derives a
  `CapabilityGap` from a draft generated component and current catalog search
  results.
- `BlueprintProposalPrompt.prompt/3` now includes generated component catalog
  context and explicit reuse-before-generation instructions.
- `RunicAI.Assistant.RLM.Coordinator.prompt/3` and dynamic blueprint generation
  now enrich prompt options with catalog context.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` can derive the required
  capability gap from `:generated_component_catalog` when a proof-gated
  `:generated_component_proposal` is supplied without an explicit
  `:capability_gap`.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_catalog_context_test.exs
  test/runic_ai/sandbox/generated_component_promotion_flow_test.exs
  test/runic_ai/assistant/rlm_blueprint_test.exs` passed:
  `31 tests, 0 failures`.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs`
  passed: `74 tests, 0 failures`.

Next slice: add a promotion write path so successful artifact promotions can
insert or update catalog entries automatically instead of stopping at a
promotion-flow result.

### Slice 4 Notes

Implementation result:

- `GeneratedComponentPromotionFlow.run/2` now accepts
  `:generated_component_catalog`.
- Successful `:artifact` promotions insert a catalog entry through
  `GeneratedComponentCatalog.entry_from_component/2` and
  `GeneratedComponentCatalog.insert/2`.
- Promotion-flow results now include `:catalog` and `:catalog_entry` so callers
  can carry the updated in-memory catalog into the next coordinator turn.
- Promotion-flow events now include
  `:generated_component_catalog_written` when an artifact-backed component is
  inserted into the catalog.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` forwards
  `:generated_component_catalog` into the proof-gated promotion flow.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_promotion_flow_test.exs`
  passed: `8 tests, 0 failures`.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs`
  passed: `75 tests, 0 failures`.

Next slice: add catalog-backed composition so a later coordinator turn can
search the catalog and compose a matching promoted generated component without
rerunning generation or proof.

### Slice 5 Notes

Implementation result:

- Added `GeneratedComponentCatalog.search_context/2` and `best_match/2` facade
  helpers over the coordinator catalog context.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` now checks a provided
  `:generated_component_catalog` before dynamic generation or fallback routes
  when catalog reuse is enabled.
- A catalog hit composes through `GeneratedComponentWorkflow.compose/3` using
  the promoted component stored in the selected catalog entry.
- Catalog-backed composition metadata records
  `proposal_kind: :generated_component_catalog_reuse`, the selected catalog
  entry id, ranking score, and match reasons.
- If no catalog hit exists, the coordinator continues through the existing
  dynamic/fallback/routed path with catalog reuse disabled for that pass.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_promotion_flow_test.exs`
  passed: `9 tests, 0 failures`.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs`
  passed: `76 tests, 0 failures`.

Next slice: connect failed proof repair evidence to catalog/dogfood outcomes so
failed generated components can either repair into promotion or leave negative
evidence for future avoidance.

### Slice 6 Notes

Implementation result:

- Added `GeneratedComponentCatalog.NegativeEvidence` for failed proof attempts.
- `GeneratedComponentCatalog.Store` now stores reusable entries separately from
  negative evidence.
- Added `record_negative_evidence/2`, `negative_evidence/1`, and
  `search_negative_evidence/2` APIs.
- `GeneratedComponentCatalog.prompt_context/2` now includes matching negative
  evidence summaries so future generation can avoid repeated failed shapes.
- `GeneratedComponentPromotionFlow.run/2` records negative evidence in the
  catalog when proof fails and a catalog store is provided.
- Promotion-flow events now include
  `:generated_component_negative_evidence_recorded`.
- The repair path can reuse the failed flow's updated catalog, run a corrected
  generated component proof, and promote the repaired component while
  preserving the earlier negative evidence.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_catalog_test.exs
  test/runic_ai/sandbox/generated_component_catalog_context_test.exs
  test/runic_ai/sandbox/generated_component_promotion_flow_test.exs` passed:
  `18 tests, 0 failures`.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs`
  passed: `79 tests, 0 failures`.

Next slice: add salience and retirement behavior so repeated successful reuse
raises ranking confidence and failed or stale entries can be demoted without
deleting their evidence.

### Slice 7 Notes

Implementation result:

- Added public facade APIs `GeneratedComponentCatalog.record_reuse/4` and
  `GeneratedComponentCatalog.retire/3`.
- `GeneratedComponentCatalog.Store.record_reuse/4` records successful and
  failed reuse counts, last-use timestamps, and lightweight last outcome
  metadata.
- Successful reuse boosts search ranking through the existing salience score so
  frequently useful entries are preferred over otherwise equivalent matches.
- Repeated failed reuse can retire an entry with
  `retire_after_failures: count`, preserving the catalog entry and evidence but
  excluding it from future search.
- Manual retirement records a reason, timestamp, and review/policy details for
  later trace inspection.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` now accepts
  `:generated_component_catalog_reuse_callback`, called when catalog-backed
  composition selects an entry. Callers that own a durable store can record the
  eventual workflow success or failure through `record_reuse/4`.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_catalog_test.exs`
  passed: `8 tests, 0 failures`.
- `mix test test/runic_ai/sandbox/generated_component_catalog_test.exs
  test/runic_ai/assistant/rlm_blueprint_test.exs` passed:
  `31 tests, 0 failures`.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs`
  passed: `83 tests, 0 failures`.
- `mix format --check-formatted`, `mix compile`, and `git diff --check`
  passed.

Next slice: add the deterministic dogfood matrix that runs repeated intents and
reports reuse rate, proof pass rate, repair count, promotion decisions, and
workflow completion quality.

### Slice 8 Notes

Implementation result:

- Added deterministic scenario
  `generated_component_promotion_flywheel` to
  `RunicAI.RLM.SandboxEvaluationFixtures`.
- The fixture models two repeated intents: first run records a
  `:generate_leaf` capability gap, sandbox proof, artifact promotion, and
  catalog write; second run retrieves the catalog entry and records successful
  reuse.
- The fixture records dogfood metrics for generated components, promoted
  components, catalog hits, reused components, proof pass rate, reuse rate,
  repair count, workflow completion rate, and promotion decisions.
- `mix runic_ai.rlm.sandbox_eval` Markdown reports now include a
  `Generated Component Flywheel` section when those metrics are present.
- Wrote fixture artifacts:
  `tmp/rlm_sandbox_eval/reports/generated-component-flywheel.json` and
  `tmp/rlm_sandbox_eval/reports/generated-component-flywheel.md`.

Validation:

- `mix test test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs` passed:
  `11 tests, 0 failures`.
- `mix test test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs
  test/runic_ai/rlm/sandbox_eval_task_test.exs` passed:
  `18 tests, 0 failures`.
- `mix runic_ai.rlm.sandbox_eval --scenario
  generated_component_promotion_flywheel --output-dir
  tmp/rlm_sandbox_eval/reports --basename generated-component-flywheel`
  passed and wrote one-harness JSON/Markdown reports.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs
  test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs
  test/runic_ai/rlm/sandbox_eval_task_test.exs` passed:
  `101 tests, 0 failures`.
- `mix format --check-formatted`, `mix compile`, and `git diff --check`
  passed.

Next slice: add trace/read-model visibility for catalog search, gap decision,
proof, repair, promotion, reuse, and retirement so the operator can explain a
generated component's lifecycle from run evidence.

### Slice 9 Notes

Implementation result:

- Added `GeneratedComponentCatalog.Trace`, a plain-map read-model projection for
  catalog entries, search results, gap decisions, and negative evidence.
- Added facade helper `GeneratedComponentCatalog.trace_events/1`.
- Entry trace events expose catalog availability/retirement, promotion
  decision metadata, last reuse outcome, reuse counts, verification status, and
  retirement reason/details.
- Search-result trace events expose selected entry id, score, match reasons,
  and query objective.
- Capability-gap and negative-evidence trace events use the same event names as
  the promotion flow so terminal/workbench layers can render lifecycle evidence
  consistently.

Validation:

- `mix test test/runic_ai/sandbox/generated_component_catalog_test.exs` passed:
  `9 tests, 0 failures`.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs
  test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs
  test/runic_ai/rlm/sandbox_eval_task_test.exs` passed:
  `102 tests, 0 failures`.
- `mix format --check-formatted`, `mix compile`, and `git diff --check`
  passed.

Next slice: perform the completion audit against the 054 quality gates, run the
final relevant matrix, and document any residual follow-ups before marking the
goal complete.

### Slice 10 Notes

Completion audit:

- Catalog API: completed for in-memory/replayable usage with entry, query,
  result, store, insert/list/get/search, negative evidence, salience,
  retirement, and trace projection APIs.
- Reuse-before-generation: completed through prompt catalog context,
  `CapabilityGap`, coordinator-derived gap records, and promotion-flow
  enforcement that generated leaves require a generation-capable gap decision.
- Proof-gated promotion: completed for artifact-backed generated components
  through `GeneratedComponentPromotionFlow.run/2`, sandbox proof, promotion
  policy, catalog write, and workflow composition.
- Catalog-backed composition: completed through coordinator lookup and
  `GeneratedComponentWorkflow.compose/3`, with metadata linking selected catalog
  entry id, match score, and match reasons.
- Repair/negative evidence: completed for failed proof attempts, future prompt
  context, and repair-to-promotion preservation of earlier failure evidence.
- Salience/retirement: completed through reuse outcome recording, search
  ranking boosts for successful reuse, automatic failure retirement, and manual
  retirement metadata.
- Dogfood evidence: completed through deterministic
  `generated_component_promotion_flywheel` fixture and generated JSON/Markdown
  report showing proof pass rate, reuse rate, repair count, workflow completion,
  and promotion decisions.
- Trace visibility: completed as catalog read-model event projections plus
  existing promotion-flow events and coordinator reuse callback event.

Quality-gate audit:

- Generated component source is not executed on the host during proof.
- Workflow composition requires verified/promoted generated components.
- Catalog promotion requires proof evidence and a promotion decision.
- Host-native promotion still requires explicit review approval.
- Catalog retrieval preserves runtime, network, and filesystem policy inputs.
- Failed proof evidence is preserved for repair and future avoidance.
- The coordinator can explain why it generated a component instead of reusing a
  candidate through catalog context and gap records.

Residual follow-ups:

- Replace or back the in-memory catalog with a durable artifact/Ecto store once
  product persistence requirements settle.
- Render the trace projection in the Workbench/terminal UI instead of only
  exposing plain event maps.
- Add live Docker/restricted-network dogfood smokes when the host backend is
  healthy and credentials are available.
- Expand the deterministic matrix beyond parse/normalize into tool adapters,
  restricted MCP/service calls, and denied host-promotion variants.
- Decide re-proof policy for artifact-backed entries on runtime, dependency,
  source hash, or sandbox-policy drift.

Validation:

- `mix runic_ai.rlm.sandbox_eval --scenario
  generated_component_promotion_flywheel --output-dir
  tmp/rlm_sandbox_eval/reports --basename generated-component-flywheel`
  passed and wrote JSON/Markdown dogfood reports.
- `mix runic_ai.rlm.sandbox_eval --live-lanes --output-dir
  tmp/rlm_sandbox_eval/reports --basename sandbox-live-lanes-preflight-054`
  passed provider preflight and wrote JSON/Markdown reports with `Ready: 4`,
  `Passed: 0`, `Skipped: 0`, `Blocked: 0`.
- `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs
  test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs
  test/runic_ai/rlm/sandbox_eval_task_test.exs` passed:
  `102 tests, 0 failures`.
- `mix format --check-formatted`, `mix compile`, and `git diff --check`
  passed.

Decision: the 054 implementation goal is complete for the current practical
scope: a general-purpose coordinator can retrieve catalog candidates, explain a
capability gap, generate and prove a sandbox-backed leaf, promote it into a
searchable catalog, reuse it on a later intent, update salience, retain failure
evidence, and emit trace-ready lifecycle evidence.

## First Dogfood Scenario

Use a deliberately small repeated intent so the catalog flywheel is visible:

1. Run A asks the coordinator to normalize semi-structured invoice rows into a
   stable list of invoice facts.
2. The catalog has no matching component, so the coordinator records a gap,
   drafts a contract, generates a Python or Bash sandbox leaf, proves it, and
   promotes it as an artifact-backed component.
3. Run B asks a similar invoice-normalization objective with different fixture
   rows.
4. The coordinator retrieves the promoted component, composes it into the new
   workflow, and skips source generation unless contract drift requires repair
   or re-proof.

Success signals:

- Run A has a gap record, proof evidence, and a catalog entry.
- Run B has a catalog hit and generated no new source for the same component
  role.
- Run B still validates objective output through the workflow scorecard.
- Any failure creates repair or retirement evidence rather than silently falling
  back to unchecked generated code.

## Quality Gates

Every slice should keep these invariants true:

- Generated component source is not executed on the host during proof.
- Workflow composition requires verified/promoted generated components.
- Catalog promotion requires proof evidence and a promotion decision.
- Host-native promotion requires explicit review approval.
- Catalog retrieval does not bypass runtime, network, or filesystem policy.
- Failed proof evidence is preserved for repair and future avoidance.
- The coordinator explains why it did not use an existing candidate before
  generating a new component.

## Validation Commands

Use the narrowest commands that exercise the slice, then broaden at audit
points:

```bash
mix test test/runic_ai/sandbox
mix test test/runic_ai/assistant/rlm_blueprint_test.exs
mix test test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs
mix runic_ai.rlm.sandbox_eval
mix compile
mix format --check-formatted
git diff --check
```

For substrate-sensitive work, also run:

```bash
cd packages/runic_sandbox && mix test
cd packages/runic_sandbox && mix runic_sandbox.doctor --format json
```

Live smokes should be recorded only when the relevant backend is available:

- JustBash or fake registry for deterministic source/test/proof loops;
- Docker for live attach and restricted egress;
- Sprites/Vmsan/Remote when provider credentials and host prerequisites are
  already healthy.

## Open Decisions

- Should the first catalog store be an in-memory process, a JSON artifact under
  run outputs, or an Ecto-backed table?
- Should catalog entries store full source artifacts, content-addressed refs, or
  only proof artifact refs for the first pass?
- What is the minimum useful contract matching algorithm: tag/IO exact match,
  deterministic scoring, or embedding-backed retrieval?
- Should artifact-backed promoted entries require re-proof on every reuse, on
  content hash change, or on policy/runtime drift only?
- How should negative evidence be represented so the coordinator avoids
  repeating bad generated component shapes?
- Which promotion events belong in core RunicAI traces versus Workbench-specific
  read models?

## Non-Goals

- Do not execute unreviewed generated component source on the host.
- Do not make host-native generated modules the default promotion target.
- Do not create a permanent domain-specific component taxonomy before evidence
  shows repeated utility.
- Do not require full long-lived provider CLI containment before catalog-backed
  generated component reuse.
- Do not let catalog retrieval silently weaken sandbox, network, dependency, or
  filesystem policy.
- Do not duplicate backend implementation details outside `packages/runic_sandbox`.
