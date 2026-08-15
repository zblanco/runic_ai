# Runic-Native Dynamic Workflow Generation Refactor Plan

Status: complete

Date: 2026-05-02

Last reviewed: 2026-05-02 by inspecting the current assistant RLM blueprint,
validator, compiler, coordinator, repair loop, smoke runner, shared RLM
components, and the local Runic dependency APIs.

Latest implementation slice:

- `WorkflowCompiler` no longer owns component dispatch, parent context merging,
  execution, or result extraction; it only maps accepted component policy data
  onto Runic scheduler policies during compilation.
- `ComponentFactory` now compiles default components to a shared
  `ComponentRuntime.run/2` adapter with per-node Runic `run_context`, so
  workspace/options/client handles are not captured in component work hashes.
- `WorkflowExecutor` now resolves Runic `Workflow.SchedulerPolicy` entries and
  still stops failed runnables before applying them so repair receives
  `RunicAI.Error` diagnostics.
- `WorkflowResults` extracts final context, artifacts, scorecards, component
  results, and intermediate outputs through Runic productions.
- Native map/reduce graph shapes are now available for map-shaped component
  specs and explicit `blueprint_reduce` fan-in nodes.
- `WorkflowExecutor` has an optional Runic Runner execution mode.
- `WorkflowMetrics` derives runtime metrics from Runic productions, including
  native map item and reduce fan-in production counts.
- Smoke run JSON/report artifacts now include execution metrics, native runtime
  nodes, runnable lifecycle event summaries, and serializer-backed graph
  excerpts.
- Terminal graph presentation can render Runic serializer output and native
  runtime-node summaries.
- Native map component policies now flow to per-item Runic runnables through the
  executor's logical component policy resolution.
- Fallback and dynamic assistant smoke matrices completed after the refactor.
- Durable local agent/workflow storage has been scoped in
  `.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`.

Completion review:

- The core architectural migration is complete: generated assistant blueprints
  now compile into Runic-owned workflow graphs that are also the runtime
  structure.
- The legacy assistant-specific `execute_once/4` interpreter path is gone.
- Observability and hardening items from the completion review are now covered:
  native Runic map/reduce executions are counted from productions, JSONL-capable
  stage events expose runnable graph details, and terminal graph presentation
  consumes Runic serializer outputs where available.

Motivated by:

- `.docs/031-general-purpose-dynamic-rlm-workflow-generation-implementation-plan.md`
- `.docs/033-assistant-rlm-general-purpose-completion-and-smoke-plan.md`
- The current `WorkflowBlueprint` / `ComponentBlueprint` /
  `WorkflowCompiler` path proving useful dynamic assistant behavior while still
  reimplementing graph traversal, component dispatch, contract checks, runtime
  state threading, and execution loops that Runic already provides.

Depends on:

- `Runic.Workflow.add/3`
- `Runic.Component`
- `Runic.Transmutable`
- `Runic.Workflow.Invokable`
- `Runic.Workflow.react_until_satisfied/3`
- `Runic.Workflow.prepare_for_dispatch/1`
- `Runic.Workflow.apply_runnable/2`
- `Runic.Workflow.SchedulerPolicy`
- `Runic.Runner`
- `Multigraph`
- `RunicAI.Assistant.RLM.WorkflowBlueprint`
- `RunicAI.Assistant.RLM.ComponentBlueprint`
- `RunicAI.RLM.Components.*`

## Goal

Refactor dynamic assistant/RLM workflow generation so accepted blueprints are
compiled into real Runic-native workflow graphs and then executed through Runic
evaluation, scheduling, hooks, facts, joins, map/reduce, and runner APIs.

The current implementation should be treated as a working vertical slice, not
as the target architecture. The refactor must preserve today's behavior:

- LLM-proposed workflow blueprints as data,
- generic fallback workflows,
- validation diagnostics and repair,
- bounded runtime repair,
- scorecard repair,
- workspace-bounded source and artifact handling,
- smoke scenario matrix artifacts,
- terminal events and JSONL traces,
- no generated `.ex` files or generated modules,
- Tier 0/Tier 1 generated function policy by default,
- Tier 2 review-gated and still deprioritized.

The architectural correction is that a generated workflow should become a
`%Runic.Workflow{}` that carries enough component and port information for
Runic to validate, traverse, execute, visualize, schedule, persist, and inspect
it. `WorkflowCompiler` should stop being a parallel workflow engine and focus more on converting RunicAI -> Runic which has all those capabilities.

## Current Baseline

The assistant RLM lane currently meets several important requirements:

- `Agent.run/3` accepts a workspace/objective and emits normalized stages.
- `Coordinator.propose/3` either uses a caller-provided blueprint, asks an LLM
  for blueprint JSON, or falls back to generic shapes.
- `WorkflowBlueprint`, `ComponentBlueprint`, `FunctionBlueprint`, and
  `ExecutionContext` define a data contract for generated workflows.
- `BlueprintValidator` checks basic graph shape, stop conditions, ids, known
  component types, generated function tier policy, node budget, and missing
  artifact-writer paths.
- `WorkflowCompiler.compile/3` can produce a `%Runic.Workflow{}` with named
  `Runic.step` nodes.
- `WorkflowCompiler.run/4` currently executes the same blueprint through its own
  sequential `execute_once/4` loop.
- Shared components exist for `SourceDiscovery`, `SourceSplitter`,
  `SourceMaterializer`, `TabularParser`, `LLMMap`, `RecordMap`, `RecordGroup`,
  `DocumentCompare`, `HierarchicalReduce`, `ReportComposer`, `ArtifactWriter`,
  `SchemaNormalizer`, `BlueprintTransform`, `ObjectiveScorecard`, and
  `BudgetLedger`.
- Smoke scenarios and persisted run details now compare fallback and dynamic
  strategies across long-document, tabular, directory, architecture, and
  document-comparison tasks.

This is enough to prove value. It is not yet using Runic as the execution and
composition substrate. Since RunicAI is a library meant to build on top of Runic's dynamic workflow composition and execution capabilities its a missed opportunity and fails to meet the goals of this library.

## Architectural Problem

`WorkflowCompiler` currently does too much:

- it manually topologically sorts `WorkflowBlueprint.edges`,
- it manually chooses parents for each node,
- it manually builds arity-specific `Runic.step` wrappers for one to four
  parents,
- it manually merges parent execution contexts,
- it manually dispatches by component type,
- it manually records outputs, artifacts, trace events, episodes, scorecards,
  and budgets,
- it manually decides latest output,
- it manually detects terminal nodes,
- and `run/4` bypasses the compiled `%Runic.Workflow{}` entirely.

The compiled Runic graph is therefore partly presentational. The actual runtime
semantics still live in an assistant-specific interpreter. That makes the
abstraction leaky in the exact place where Runic should be strongest:
components as runtime data connected into a workflow graph.

The important correction is:

```text
blueprint JSON
  -> normalized component specs with contracts
  -> Multigraph blueprint graph (to use graph traversal functions to verify graph correctness)
  -> Runic components
  -> Workflow.add/3 with port validation (port contracts align with RunicAI data models)
  -> %Runic.Workflow{}
  -> Runic execution / scheduler / runner
  -> Runic facts, results, failures, events, graph serializers
  -> Mapping of Runic -> RunicAI when needed
  -> assistant scorecard and repair decisions
```

`WorkflowCompiler` should become a translator and diagnostic collector. It
should not be the workflow engine.

## Runic Capabilities To Leverage

### Multigraph

Runic workflows already store structure in `Multigraph`. The blueprint layer
can also materialize a Multigraph view instead of repeatedly scanning lists
of edges.

Use Multigraph for:

- component vertices,
- labeled flow edges,
- optional port labels/properties,
- root and leaf discovery,
- `Multigraph.is_acyclic?/1`,
- `Multigraph.topsort/1`,
- `Multigraph.batch_topsort/1` for independent execution layers,
- `Multigraph.in_edges/3` and `Multigraph.out_edges/3` for diagnostics,
- path and reachability checks,
- graph summaries and visualization inputs.

The blueprint can remain JSON-friendly; the graph should be a derived
normalized view, for example `BlueprintGraph.build/1`.

### Component Protocol

`Runic.Component` already defines:

- `inputs/1`,
- `outputs/1`,
- `connectable?/2`,
- `connect/3`,
- `source/1`,
- `hash/1`.

`Workflow.add/3` already validates producer/consumer port compatibility by
default and raises a structured port incompatibility exception. The assistant
validator should use this as the authoritative validation surface after
component specs have been compiled to Runic components.

If Runic's current port types are too shallow, start with the existing schema
shape and add richer RunicAI metadata beside it. Do not fork a separate graph
contract checker unless Runic cannot express the requirement.

### Transmutable

`Runic.Transmutable.to_component/1` lets domain-specific data become Runic
components. This is the right bridge for accepted RunicAI component specs.

The proposal data should stay as `ComponentBlueprint`. After validation, each
blueprint should become a normalized spec:

```elixir
%RunicAI.RLM.ComponentSpec{
  id: "discover_sources",
  type: :source_discovery,
  params: %{paths: ["tmp/input.md"]},
  execution_shape: :step,
  inputs: [in: [type: :source_request]],
  outputs: [sources: [type: :source_set]],
  policy: %{scheduler: :io},
  metadata: %{blueprint_id: "..."}
}
```

Then `ComponentSpec` can either:

- implement `Runic.Transmutable` and return a built-in Runic component
  (`Step`, `Map`, `Reduce`, `Rule`, `Accumulator`), or
- later implement `Runic.Component` directly if retaining RunicAI metadata as
  a first-class workflow component is worth the extra protocol surface.

Phase 1 should prefer transmuting into built-in Runic components. That keeps the
change smaller and still moves validation/execution onto Runic.

### Invokable And Three-Phase Execution

Runic's runtime separates:

1. prepare,
2. execute,
3. apply.

That is exactly what dynamic RLM needs for repairable failures and future
distributed/parallel scheduling. The assistant should run compiled graphs
through either:

- `Workflow.react_until_satisfied/3` for simple in-process execution, or
- a small `RunicAI.RLM.WorkflowExecutor` wrapper over
  `Workflow.plan_eagerly/2`, `Workflow.prepare_for_dispatch/1`,
  `Runic.Workflow.Invokable.execute/2`, and `Workflow.apply_runnable/2` when
  it needs to capture failed runnables before Runic marks downstream nodes as
  unreachable.

The second path is likely needed for high-quality repair diagnostics, but it
should still use Runic runnables and events rather than assistant-specific node
dispatch.

Runic Runner's consolidate this into a scheduler + executor interface which leverages
the three phase execution model enabling optimized parallel execution models.

### Map, Reduce, Join, FanOut, FanIn

The current `llm_map`, `record_map`, and `hierarchical_reduce` components often
perform collection orchestration internally. Some of that can remain as a
component implementation detail, but the long-term direction should compile
map-like and reduce-like blueprint nodes into Runic `Map` and `Reduce`
components where the collection boundary is explicit.

This matters because Runic can then:

- fan out facts,
- run independent map work in parallel,
- fan in through `Reduce`,
- create join nodes for multi-parent components,
- expose the graph in results and serializers,
- apply scheduler policies to each mapped runnable,
- and avoid the compiler's parent-count-specific wrapper functions.

Note: that Reduce waits for all materialized upstream maps before outputting a fact,
for incremental outputs the Accumulator can be used instead of a Reduce.

### Runtime Context

Runic already supports runtime context on workflows. Assistant execution should
move workspace, model, client, write policy, event sink, and run id into
`run_context` instead of embedding mutable execution context into closures.

Recommended context layout:

```elixir
%{
  _global: %{
    workspace: workspace,
    objective: objective,
    model: model,
    client: client,
    write_policy: write_policy,
    run_id: run_id,
    event_sink: event_sink
  },
  discover_sources: %{params: %{...}},
  extract_slice_notes: %{params: %{...}}
}
```

Runtime context is intentionally not part of the workflow hash and not
serialized in Runic's event log, which is the right behavior for secrets,
clients, and workspace handles.

### Hooks, Policies, Runner, Serialization

Runic has first-class APIs we should use instead of assistant-only copies:

- hooks for before/after node instrumentation,
- scheduler policies for retries, deadlines, backoff, failure policy, and
  execution mode,
- `Workflow.results/3` and `Workflow.raw_productions/2` for result extraction,
- workflow serializers for Mermaid/DOT/Cytoscape/edgelist,
- `Runic.Runner` for managed execution, checkpointing, supervised task
  dispatch, persistence, and resume.

The assistant should not need all of these in the first refactor slice, but the
compiled graph must be compatible with them.

## Target Architecture

### Layer 1: Proposal Data

Keep `WorkflowBlueprint` and `ComponentBlueprint` as external proposal data.
They remain JSON-friendly and LLM-friendly.

Changes:

- `ComponentBlueprint.inputs` and `ComponentBlueprint.outputs` should become
  meaningful and validated, not decorative.
- `ComponentBlueprint.params` should be validated against the component catalog.
- Edges should support optional port mapping later:

```elixir
%{from: "discover", output: "sources", to: "split", input: "sources"}
```

The first migration can keep `{from, to}` edges and infer the only compatible
port when each side has one obvious port.

Our goal in the proposal is to make it as easy as possible for LLM / Agent workflow proposal generation and correction from any mistakes/errors feedback without having re-draft the whole workflow from scratch.

### Layer 2: Component Catalog

Add a catalog that knows how to validate params and compile each accepted
component type:

```text
RunicAI.RLM.ComponentCatalog
RunicAI.RLM.ComponentSpec
RunicAI.RLM.ComponentFactory
RunicAI.RLM.ValueContract
```

Responsibilities:

- list available component types for coordinator prompts,
- normalize params,
- declare input/output port schemas,
- declare execution shape (`:step`, `:map`, `:reduce`, `:rule`, `:accumulator`,
  `:side_effect_step`),
- map policy hints to Runic scheduler policies,
- compile to a Runic component,
- produce structured diagnostics for repair prompts.

The catalog replaces the large `dispatch/3` function in `WorkflowCompiler`.

It should be easy for the RLM agents to find the right component for the right problem and know how to compose it with other components.

### Layer 3: Blueprint Graph

Add `RunicAI.Assistant.RLM.BlueprintGraph` as the normalized graph view:

- vertices are `ComponentSpec` structs,
- edges are labeled `:flow`,
- edge properties may include port names and provenance,
- graph construction rejects duplicate ids before inserting vertices,
- graph validation uses Multigraph operations,
- topological order and batch order come from Multigraph.

This should replace `BlueprintValidator.check_edges/2`,
`BlueprintValidator.check_cycles/2`, `WorkflowCompiler.topological_order/1`,
`WorkflowCompiler.parent_ids/2`, and `WorkflowCompiler.output_component_id/2`.

### Layer 4: Runic Compiler

`WorkflowCompiler.compile/3` should become:

```text
WorkflowBlueprint.from_input
  -> ComponentCatalog.normalize_all
  -> BlueprintGraph.build
  -> static validation
  -> Enum.reduce(topsort, Runic.workflow(name: ...), Workflow.add(component, to: parents))
  -> attach run_context, hooks, scheduler policies, output metadata
```

Compilation should not execute component work. It should return:

- `%Runic.Workflow{}`,
- normalized blueprint,
- component specs,
- blueprint graph,
- validation report,
- node name map,
- output component ids,
- graph summary,
- scheduler policies,
- required runtime context keys.

### Layer 5: Runic Executor

Replace `WorkflowCompiler.execute_once/4` with a Runic executor:

```text
compiled.workflow
  -> Workflow.put_run_context(runtime_context)
  -> Workflow.plan_eagerly(initial_input)
  -> repeat:
       Workflow.prepare_for_dispatch
       execute runnables serially or concurrently
       capture failed runnables as structured diagnostics
       Workflow.apply_runnable
     until not Workflow.is_runnable?
  -> extract results, artifacts, scorecards, facts, trace summaries
```

The executor can start simple and serial, then enable `async: true` or custom
dispatch once parity is proven.

A `RunicAI.RLM.ComponentError` exception wrapper is acceptable at the component
adapter boundary: existing `RunicAI.RLM.Components.*.run/3` functions return
`{:ok, output}` or `{:error, %RunicAI.Error{}}`, while Runic marks failed
steps through exceptions. The executor should convert those failures back into
normal `RunicAI.Error` diagnostics for repair, not expose raw exception strings
as the repair contract.

## Feature Parity Map

| Current requirement | Current implementation | Runic-native target |
| --- | --- | --- |
| Generated blueprint as data | `WorkflowBlueprint` JSON contract | Keep contract, add graph view and real port contracts |
| Known generic components | `ComponentBlueprint.type` plus compiler dispatch | `ComponentCatalog` validates and compiles component specs |
| Graph validation | Manual edge/id/cycle scans | `BlueprintGraph` + Multigraph + `Workflow.add/3` port validation |
| Component contracts | `inputs`/`outputs` exist but are weak | Runic component `inputs/1` / `outputs/1` are authoritative |
| Multi-parent components | Manual parent count and context merge | Runic `Workflow.add(..., to: [:a, :b])` creates joins |
| Map/reduce work | Often hidden inside component `run/3` | Map-like specs compile to `Runic.map`; reduce specs compile to `Runic.reduce` where practical |
| Runtime context | `ExecutionContext` map threaded manually | Workflow input facts plus Runic `run_context` |
| Node execution | `execute_once/4` sequential loop | Runic `react_until_satisfied` or three-phase executor |
| Events | Manual `emit_stage/4` | Executor/hooks derive events from runnables and Runic facts |
| Budgets | `BudgetLedger.record/3` in manual loop | Scheduler deadlines, component-local caps, and Runic-native budget accumulator/check components |
| Artifacts | `record_output/3` in compiler context | Artifact writer output facts plus result extraction |
| Scorecard | `ObjectiveScorecard` dispatch and latest scorecard | Scorecard component output fact selected by component id/type |
| Runtime repair | Manual dispatch returns `{:error, Error}` | Failed runnable diagnostics mapped to repair loop |
| Graph summary | Manual summary from blueprint order | Runic workflow graph + serializer-backed summary |
| Persistence | Smoke runner persists selected result maps | Store build log, blueprint graph, Runic graph summary, facts/results, scorecard, repair history |

## Value Contract Vocabulary

Use simple Runic-compatible port types first. Add richer metadata only where
needed for repair messages and smoke reports.

Suggested value types:

- `:assistant_input`
- `:source_request`
- `:source_set`
- `:source_slices`
- `:materialized_slices`
- `:records`
- `:record_items`
- `:record_groups`
- `:comparisons`
- `:llm_items`
- `:synthesis`
- `:report`
- `:artifact`
- `:scorecard`
- `:budget_summary`
- `:any`

Suggested component contracts:

| Type | Shape | Inputs | Outputs |
| --- | --- | --- | --- |
| `source_discovery` | `:step` | `source_request | assistant_input` | `source_set` |
| `source_splitter` | `:step` | `source_set | source_request` | `source_slices` |
| `source_materializer` | `:step` | `source_slices` | `materialized_slices` |
| `tabular_parser` | `:step` | `source_set | materialized_slices` | `records` |
| `record_map` | `:map` or `:step` | `records | record_items` | `record_items` |
| `record_group` | `:step` or `:reduce` | `record_items | records` | `record_groups` |
| `document_compare` | `:step` | `source_set | materialized_slices` | `comparisons` |
| `llm_map` | `:map` or `:step` | `materialized_slices | records | comparisons` | `llm_items` |
| `llm_leaf` | `:step` | `llm_items | record_groups | comparisons | report | any` | `synthesis` |
| `blueprint_transform` | `:step` or `:map` | `any` | `any` |
| `blueprint_reduce` | `:reduce` or `:step` | `any` | `any` |
| `report_composer` | `:step` | `synthesis | record_groups | comparisons | any` | `report` |
| `artifact_writer` | `:side_effect_step` | `report | synthesis | any` | `artifact` |
| `objective_scorecard` | `:step` or `:rule` | `artifact | report | synthesis | any` | `scorecard` |
| `budget_ledger` | `:accumulator` or `:step` | `any` | `budget_summary` |

Do not overfit these types to smoke scenarios. They are value-level contracts,
not domains.

## Component Factory Direction

Component adapters should be small and boring. A step-shaped adapter should
look conceptually like:

```elixir
Runic.step(
  name: spec.id,
  inputs: spec.inputs,
  outputs: spec.outputs,
  work: fn input, ctx ->
    case SourceDiscovery.run(context(:workspace), input, context(:params)) do
      {:ok, output} -> output
      {:error, error} -> raise RunicAI.RLM.ComponentError, error: error
    end
  end
)
```

Map-shaped adapters should move item-level work into Runic where practical:

```text
records/slices input
  -> Runic.map(item_fn, name: :extract_slice_notes)
  -> Runic.reduce(init, reducer_fn, name: :merge_slice_notes, map: :extract_slice_notes)
```

This does not require deleting the existing `run/3` functions immediately.
The factory can call existing modules first, then split them into lower-level
item functions as the graph model matures.

## Validation Direction

Validation should be staged:

1. **Shape validation**: JSON and struct normalization. This remains in
   `WorkflowBlueprint` and `ComponentBlueprint`.
2. **Catalog validation**: component type exists, params are valid, policy is
   allowed, function tiers are allowed.
3. **Blueprint graph validation**: duplicate ids, unknown vertices, cycles,
   roots, leaves, unreachable nodes, terminal scorecard presence, node budget.
4. **Runic component contract validation**: compile specs to Runic components
   and use `Workflow.add/3` with default port validation. Convert
   incompatibilities to diagnostics.
5. **Runtime context validation**: use `Workflow.required_context_keys/1` and
   `Workflow.validate_run_context/2` where components declare context needs.
6. **Policy validation**: write policy, generated-function tier policy,
   scheduler policy shape, model/client availability, runtime budgets.
7. **Objective validation**: run `ObjectiveScorecard` as a workflow component
   and let `Agent.run/3` decide whether scorecard repair is needed.

Diagnostics should stay structured and repair-friendly:

- `:unknown_component_type`
- `:invalid_component_params`
- `:unknown_edge_source`
- `:unknown_edge_target`
- `:cycle`
- `:unreachable_component`
- `:missing_terminal_scorecard`
- `:port_type_mismatch`
- `:missing_required_input_port`
- `:function_tier_rejected`
- `:write_policy_rejected`
- `:missing_runtime_context`
- `:scheduler_policy_rejected`

## Repair Direction

The repair loop should receive graph/component diagnostics, not compiler
implementation details.

Repair inputs should include:

- original blueprint,
- normalized component specs when available,
- Multigraph-derived graph summary,
- Runic port mismatch diagnostics,
- failed runnable node id/type/name,
- failed runnable input fact preview,
- failed runnable error normalized as `RunicAI.Error`,
- latest facts from parent components,
- latest scorecard residual risks.

Repair actions should remain conservative:

1. fix invalid params,
2. insert missing transform/materialization nodes,
3. reconnect mismatched edges,
4. lower function tier,
5. replace a custom transform with a Tier 0/Tier 1 built-in,
6. adjust prompts/reducers for source-cue failures,
7. remove or fill invalid artifact writers,
8. fall back to a generic Runic-native workflow.

Repair should be able to discern when to:

Adjust component options vs Restructure the workflow vs write custom dynamic components (arbitrary elixir) vs rewrite / reapproach whole blueprint/workflow design

The best way to prompt and tune our repair loops of dynamic workflow generation will evolve out of smoke testing and evals

Do not make repair generate `.ex` files or modules.

## Implementation Phases

### Phase 0: Characterize Current Behavior

Deliverables:

- [x] Characterize the new Runic-native `WorkflowCompiler.run/4` outputs for
      split/map/reduce/write/scorecard workflows.
- [x] Add tests that capture validation diagnostics for bad ids, bad edges,
      cycles, bad artifact paths, rejected function tiers, incompatible ports,
      and runtime component failures.
- [x] Close the old "compiled graph is not used by `run/4`" characterization as
      superseded: `run/4` now executes the compiled Runic workflow directly.
- [x] Snapshot expected smoke-run persisted fields: blueprint, graph summary,
      validation report, intermediate outputs, scorecard, repair history.

Validation:

- [x] `mix test test/runic_ai/assistant/rlm_agent_test.exs`
- [x] `mix test test/runic_ai/assistant/rlm_blueprint_test.exs`

### Phase 1: Define Component Catalog And Contracts

Deliverables:

- [x] Add `RunicAI.RLM.ValueContract`.
- [x] Add `RunicAI.RLM.ComponentSpec`.
- [x] Add `RunicAI.RLM.ComponentCatalog`.
- [x] Move component type list out of `ComponentBlueprint` into the catalog, or
      make `ComponentBlueprint.types/0` delegate to the catalog.
- [x] Define param validation for all current component types.
- [x] Define Runic-compatible input/output schemas for all current component
      types.
- [x] Keep coordinator manifest output stable, but source it from the catalog.

Validation:

- [x] Unit test each current component type has a catalog entry.
- [x] Unit test invalid params return structured diagnostics.
- [x] Unit test manifest includes the same public component names currently
      offered to the coordinator.

### Phase 2: Add BlueprintGraph

Deliverables:

- [x] Add `RunicAI.Assistant.RLM.BlueprintGraph.build/2`.
- [x] Represent normalized component specs as Multigraph vertices.
- [x] Represent blueprint edges as labeled `:flow` edges with optional port
      metadata.
- [x] Replace manual cycle detection with `Multigraph.is_acyclic?/1`.
- [x] Replace manual topological order with `Multigraph.topsort/1`.
- [x] Add `batch_topsort` summary for independent layers.
- [x] Add root/leaf/unreachable diagnostics from Multigraph queries.
- [x] Keep the public `WorkflowBlueprint` struct JSON-friendly; do not encode
      the graph in generated blueprint JSON.

Validation:

- [x] Unit test duplicate ids.
- [x] Unit test unknown edge endpoints.
- [x] Unit test cycles.
- [x] Unit test root/leaf detection.
- [x] Unit test batch topological layers for a branching graph.

### Phase 3: Compile ComponentSpecs To Runic Components

Deliverables:

- [x] Add `RunicAI.RLM.ComponentFactory.to_runic/2`.
- [x] Compile step-shaped specs to `Runic.Workflow.Step` or `Runic.step`.
- [x] Compile side-effect specs such as `artifact_writer` to steps with clear
      write-policy ports.
- [x] Compile map-shaped specs to `Runic.map` where the input is a collection
      and the item operation can be expressed safely.
- [x] Compile reduce-shaped specs to `Runic.reduce` where parent map/fan-in
      semantics are available.
- [x] Keep existing component modules' `run/3` functions usable by the factory
      for parity.
- [x] Add `RunicAI.RLM.ComponentError` for adapter-boundary failures that need
      to become repairable diagnostics.

Validation:

- [x] Unit test every current component type compiles to a Runic component.
- [x] Unit test `Runic.Component.inputs/1` and `outputs/1` match catalog
      contracts.
- [x] Unit test `Workflow.add/3` rejects an incompatible edge.
- [x] Unit test component `{:error, %RunicAI.Error{}}` becomes a failed runnable
      diagnostic, not a successful output fact.

### Phase 4: Replace Compiler Traversal With Workflow.add

Deliverables:

- [x] Refactor `WorkflowCompiler.compile/3` to build the workflow by reducing
      over the `BlueprintGraph` topsort.
- [x] Use `Workflow.add(workflow, component, to: parent_names)` for all
      connections.
- [x] Remove arity-specific `node_step/3` variants.
- [x] Remove compiler-owned parent context merging.
- [x] Remove compiler-owned `topological_order/1`, `build_order/5`,
      `parent_ids/2`, and `output_component_id/2` once graph helpers replace
      them.
- [x] Capture `Runic.IncompatiblePortError` and convert it into a structured
      compile diagnostic.
- [x] Attach scheduler policies from component specs to the workflow.
- [x] Attach run-context requirements without closing over workspace/client
      secrets in component hashes.

Validation:

- [x] Existing assistant compile tests pass.
- [x] New compile tests assert real Runic workflow structure and port
      validation.
- [x] Graph summary comes from compiled Runic workflow plus blueprint metadata.

### Phase 5: Replace execute_once With A Runic Executor

Deliverables:

- [x] Add `RunicAI.RLM.WorkflowExecutor`.
- [x] Execute compiled workflows through Runic's three-phase APIs.
- [x] Emit existing assistant stage names from executor/runnable lifecycle:
      `node_started`, `node_completed`, `node_failed`, `execution_completed`.
- [x] Preserve `Agent.run/3` result shape: `blueprint`, `proposal`,
      `validation_report`, `compiled`, `workflow`, `context` or replacement
      execution summary, `output`, `artifacts`, `trace`, `episodes`,
      `scorecard`.
- [x] Extract artifacts from `artifact_writer` output facts.
- [x] Extract latest scorecard from `objective_scorecard` / `verification`
      output facts.
- [x] Extract intermediate outputs with `Workflow.raw_productions/2` or a
      graph-aware helper.
- [x] Preserve runtime repair behavior for artifact-writer failures and other
      failed nodes.
- [x] Keep serial execution as the default until parity tests pass; then enable
      async execution by policy or option.

Validation:

- [x] Current `RLMAgentTest` passes without the manual `execute_once/4` path.
- [x] Scripted runtime failure still triggers one bounded repair pass.
- [x] Scorecard failure still triggers one bounded scorecard repair pass.
- [x] Smoke runner run JSON still includes graph summary, validation report,
      scorecard, repair history, and intermediate previews.

### Phase 6: Make Budgets Runic-Native

Deliverables:

- [x] Move local component caps into catalog param validation and component
      adapters.
- [x] Map `max_runtime_ms` to Runic execution deadlines / scheduler policies.
- [x] Map LLM and I/O retries/timeouts to `Workflow.SchedulerPolicy`.
- [x] Add a Runic-native budget tracker, preferably an accumulator or explicit
      budget-check component, for global metrics that cannot be enforced by
      local caps.
- [x] Keep `BudgetLedger.summary/1` output shape stable for smoke reports.

Validation:

- [x] Budget-overrun tests still produce structured `RunicAI.Error`
      diagnostics.
- [x] Smoke run summaries still report node counts, component counts, LLM map
      calls, reduce calls, artifact writes, and elapsed time.

### Phase 7: Move More Work Into Runic Map/Reduce

Deliverables:

- [x] Split `LLMMap` into collection extraction plus item-level LLM operation so
      it can compile to `Runic.map`.
- [x] Split `RecordMap` into item-level transform/LLM operations so it can
      compile to `Runic.map`.
- [x] Compile map/reduce blueprint pairs into Runic fan-out/fan-in when the
      graph shape is explicit.
- [x] Remove the generated-workflow reliance on whole-collection map/reduce
      step execution; keep `run/3` only as the reusable component module API
      while generated map/reduce shapes compile natively.
- [x] Add scheduler policies that limit map concurrency and retry LLM item
      calls without wrapping the entire map as one black-box step.

Validation:

- [x] Unit test a slice map can execute with `async: true`.
- [x] Unit test a reduce waits for all mapped facts.
- [x] Unit test a map item failure produces a repairable runnable diagnostic.
- [x] Smoke run graph summaries visibly show map/fan-in structure for
      split/map/reduce scenarios.

### Phase 8: Observability, Serialization, And Runner Path

Deliverables:

- [x] Generate terminal graph summaries from Runic workflow serializers where
      practical.
- [x] Include Mermaid/DOT/Cytoscape outputs in debug artifacts only when useful.
- [x] Use Runic facts and component outputs as the source of intermediate-output
      previews.
- [x] Add optional `Runic.Runner` execution mode for long-running assistant
      workflows.
- [x] Evaluate ETS/Mnesia/custom store options for durable assistant runs after
      in-process parity is stable.
- [x] Keep terminal and JSONL event contract presentation-neutral.

Validation:

- [x] Terminal assistant integration test still shows blueprint, node progress,
      repairs, final artifact, and scorecard.
- [x] JSONL trace includes enough Runic graph and runnable information to debug
      repair decisions.
- [x] Optional runner mode can start, run, query results, and stop a workflow in
      a scripted test.

### Phase 9: Remove The Assistant-Specific Interpreter

Deliverables:

- [x] Delete or shrink `WorkflowCompiler.dispatch/3`.
- [x] Delete `execute_once/4`.
- [x] Delete manual context merge and output recording helpers after Runic
      extraction replaces them.
- [x] Remove legacy compatibility wrappers where the new Runic-native result
      model replaces the previous execution context.
- [x] Update `.docs/031` and `.docs/033` checklists to mark the Runic-native
      compiler/executor migration complete.

Validation:

- [x] `mix compile --warnings-as-errors`
- [x] `mix test test/runic_ai/assistant`
- [x] `mix test test/runic_ai/terminal`
- [x] `mix test`
- [x] Fallback smoke matrix still runs.
- [x] Dynamic smoke matrix still runs.
- [x] Strategy comparison still runs.

## Completed Hardening Work

The core compiler/executor migration is done, and the final hardening pass
closed the observability, scheduler-policy, and durability-scoping gaps that
remained after the first Runic-native execution slice.

### 1. Accurate Runtime Metrics

Native Runic execution metrics now come from Runic productions and compiled
component metadata instead of the removed compiler-owned execution context.

- [x] Derive node/component counts from Runic productions, runnable lifecycle
  events, or workflow execution state rather than the removed compiler-owned
  execution context;
- [x] Count native map item executions and reduce fan-in completions explicitly;
- [x] Ensure `BudgetLedger.summary/1` remains the report shape while metrics are
  sourced from Runic facts/events;
- [x] Add a regression test that fails if a native map/reduce workflow reports zero
  executed nodes or zero map calls after processing items.

### 2. Native Map/Fan-In Structure In Reports

Smoke reports now expose the internal Runic item-selection, map, reduce, and
finalizer structure clearly enough for debugging.

- [x] Include selected Runic serializer excerpts in per-scenario debug artifacts;
- [x] Expose native generated node names such as map item selectors and reduce
  fan-in nodes in smoke graph summaries;
- [x] Make terminal graph summaries consume the same serializer-backed graph data.

### 3. Scheduler Controls For Native Map Work

Map-specific concurrency/retry controls now apply to native map item runnables
without wrapping the whole collection as one step.

- [x] Map catalog policy hints such as `max_concurrency`, retry count, timeout, and
  scheduler class onto native map components;
- [x] Add tests for LLM item retry and map concurrency limits without wrapping the
  whole collection as one step;
- [x] Preserve the failed-runnable diagnostic path for individual item failures.

### 4. JSONL And Terminal Observability

Terminal behavior remains presentation-neutral, and JSONL-capable event payloads
now carry enough Runic-native graph/runnable information to debug repair
decisions without reopening internal workflow structs.

- [x] Add runnable id, node name, component id/type, input preview, output preview,
  and failure details to assistant JSONL events;
- [x] Add graph serializer paths or compact serializer payloads to smoke run JSON
  where useful;
- [x] Add a terminal regression that verifies graph progress, repair details, final
  artifact, and scorecard are visible from the Runic-native events.

### 5. Durable Runner Persistence Scoping

Optional Runic Runner execution is tested. Durable storage is now scoped as a
follow-on implementation track in
`.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`.

- [x] Evaluate ETS/Mnesia/custom stores only after the metric and JSONL surfaces are
  settled;
- [x] Keep the current Runner mode optional until persistence/resume semantics are
  designed around Runic facts rather than assistant-specific snapshots.

## Open Design Decisions

### Wrapper Component Or Built-In Runic Components

Default decision: compile `ComponentSpec` into built-in Runic components first.

Use a custom RunicAI component wrapper only if we need metadata to be a
first-class graph vertex rather than metadata on names, facts, component
outputs, or graph summaries.

### Port Schema Richness

Default decision: start with Runic's existing `:any`, exact atoms, `{:list,
type}`, and `{:one_of, types}` compatibility model.

If repair diagnostics need richer shape checks, add RunicAI metadata beside the
Runic ports rather than bypassing Runic's compatibility path.

### Runtime Failure Semantics

Default decision: component adapters raise a small `ComponentError` wrapper when
existing component modules return `{:error, %RunicAI.Error{}}`; the Runic
executor converts failed runnables back into normal `RunicAI.Error`
diagnostics for repair loops.

Do not let `{:error, error}` become a successful fact.

### Budget Accounting

Default decision: local caps stay inside component params; global budget
enforcement moves to scheduler policies and a Runic-native budget component or
accumulator.

Do not keep global budget mutation hidden inside the compiler loop.

### Tier 2

Default decision: keep Tier 2 out of scope for this refactor unless the
Runic-native contract work proves Tier 1 cannot express necessary transforms.

## Acceptance Criteria

Current acceptance status:

- [x] Generated assistant blueprints compile into `%Runic.Workflow{}` graphs
      whose structure is the runtime structure.
- [x] Incompatible generated edges are caught by Runic component/port
      validation.
- [x] `Agent.run/3` no longer depends on `WorkflowCompiler.execute_once/4`.
- [x] Multi-parent nodes use Runic joins rather than compiler context merging.
- [x] Map/reduce-heavy workflows can use Runic fan-out/fan-in.
- [x] Runtime node failures are captured as failed runnables and feed the repair
      loop.
- [x] Scorecards and artifacts are extracted from Runic output facts.
- [x] Terminal and smoke reports still expose the existing result fields.
- [x] Fallback and dynamic smoke matrices remain comparable.
- [x] The compiler has become a translator from accepted data to Runic
      components, not an assistant-specific workflow VM.
- [x] Smoke budget/runtime metrics accurately reflect native Runic map/reduce
      execution.
- [x] JSONL and terminal graph/runnable observability are strong enough to debug
      repair decisions without inspecting workflow internals manually.

## Near-Term Implementation Recommendation

Do not start another execution-model rewrite. The Runic-native execution model
is now in place.

The next implementation sequence moves to the durability proposal:

1. add a package-local SQLite store contract and schema;
2. add a `Runic.Runner.Store` SQLite adapter;
3. wire terminal/assistant event write-through into SQLite;
4. add run inspection and replay helpers;
5. keep JSONL as an export surface and ETS as an optional live cache.
