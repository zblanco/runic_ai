# Phase 9 Implementation Plan: RLM Execution Mode And Recursive Long-Context Workflows

Status: draft implementation plan

Date: 2026-04-24

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`
- `.docs/007-phase-4-context-engineering-memory-and-retrieval-boundaries-implementation-plan.md`
- `.docs/009-phase-5-multi-agent-and-decomposition-workflows-implementation-plan.md`
- `.docs/012-phase-6-stateful-integrated-agent-recipes-implementation-plan.md`
- `.docs/014-phase-7-observability-testing-and-evaluation-implementation-plan.md`
- `.docs/015-phase-8-advanced-runtime-adapters-and-optimization-hooks-implementation-plan.md`

References:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/010-react-vs-rlm-for-workflow-native-agent-composition.md`
- `https://arxiv.org/abs/2512.24601`
- `https://arxiv.org/abs/2603.20105`
- `https://github.com/lambda-calculus-LLM/lambda-RLM`
- `https://theharness.blog/blog/recursive-by-design/`
- `https://randomlabs.ai/blog/slate`

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic workflow API:
  `https://hexdocs.pm/runic/Runic.Workflow.html`
- Official Runic map/reduce docs:
  `Runic.map/2`, `Runic.reduce/3`
- Official Runic state docs:
  `Runic.accumulator/3`, `Runic.state_machine/1`
- Official Runic runtime docs:
  `Runic.Runner`, `Runic.Workflow.prepare_for_dispatch/1`,
  `Runic.Workflow.apply_runnable/2`

## Goal

Build an optional RLM-inspired execution mode for RunicAI where very large
inputs live outside the root model context, recursive decomposition is planned
and executed as typed Runic workflow data, and LLM calls are constrained to
bounded leaf or reducer operations.
The mode should support both static recursive plans and dynamic continuation
patterns where runtime-discovered work can extend the workflow, spawn child
workflows, or return an episode-like artifact that advances or satisfies a
parent objective.

Phase 9 is successful when RunicAI has a clear, composable answer to:

"How do I register a large document, corpus, codebase, or structured task as an
external environment, compile a bounded recursive plan over that environment,
execute the plan through Runic workflows, trace and budget every recursive
branch, and materialize a final artifact without turning an open-ended REPL into
the library's core runtime?"

The target design is closer to lambda-RLM than to a raw RLM REPL.
Runic workflows are the coordination substrate.
Elixir is the first execution language.
Other languages can be coordinated later through adapters, but the public model
should remain typed workflow data interpreted by RunicAI.
This is an implementation choice, not a theoretical expressivity limit: Runic's
dynamic workflow APIs, child workflows, external tools, and ordinary host
language computation are enough to encode recursive, continuation-style, and
generated-workflow execution when policy allows it.

## Current Starting Point

Earlier phases already provide most of the substrate Phase 9 needs.

Runic gives us:

- `Runic.step` as named lambda-like transformations
- `Runic.map` for bounded fan-out over enumerable inputs
- `Runic.reduce` for deterministic fan-in over mapped branches
- `Runic.rule` for explicit routing, termination, and guard decisions
- `Runic.accumulator` and `Runic.state_machine` for stateful progress tracking
- dynamic workflow construction through `Runic.Workflow.add/3` and
  `Runic.Workflow.merge/2`
- lazy and parallel execution through `Runic.Workflow.react_until_satisfied/3`
- the prepare, execute, apply split for external scheduling
- `Runic.Runner` for supervised and persisted workflow execution

RunicAI gives us:

- `RunicAI.Context.Bundle`, `RunicAI.Context.Ref`,
  `RunicAI.Context.HandoffArtifact`, `RunicAI.Context.Graph`,
  `RunicAI.Context.LineageSnapshot`, and `RunicAI.Context.ThreadStore`
- `RunicAI.Decomposition.Task`, `TaskPlan`, `Assignment`, `Result`,
  `JoinPolicy`, `Role`, and `Registry`
- `RunicAI.Control.*`, `RunicAI.Wait`, `RunicAI.ReviewRequest`,
  `RunicAI.ResumeSignal`, and `RunicAI.Error`
- `RunicAI.Harness.*`, `RunicAI.Runtime.*`, `RunicAI.Trace.*`,
  `RunicAI.Evaluation.*`, `RunicAI.Candidate.*`, and
  `RunicAI.Optimization.*`
- reference recipes for chat, tool use, memory-aware agents, decomposition,
  integrated stateful agents, runtime sessions, evaluation, and workflow-as-tool
  adapters

What Phase 9 must add is not another agent loop.
It must add the recursive long-context layer above those pieces:

- externalized prompt and artifact environments
- recursive plan and cost contracts
- a typed combinator algebra for split, filter, map, reduce, cross, score,
  select, review, and generate
- a compiler/interpreter from recursive plans to Runic workflows, staged
  workflow frontiers, child workflows, and validated continuations
- benchmarkable reference recipes that compete with normal RLM and direct
  long-context prompting

## Core Thesis

RLMs are valuable because they move long-context work out of one expanding
transcript and into symbolic execution over external state.
lambda-RLM sharpens that lesson: do not make the model invent a recursive
program on every run if the task structure already determines the plan.
The Slate architecture report adds a complementary systems lesson: long-horizon
agent performance is often bottlenecked by working-memory management,
synchronization, and the split between strategy and tactics, not simply by raw
model intelligence.
Its thread/episode framing is directly relevant to RunicAI: bounded worker
episodes, explicit context routing, and frequent synchronization can preserve
reactivity without forcing all work through one growing transcript or one rigid
task tree.

For RunicAI, the strongest version of the idea is:

```text
external environment refs
  -> deterministic recursive plan
  -> typed Runic workflow graph, staged workflow frontier, or child workflow
  -> bounded LLM/tool leaves
  -> deterministic or policy-governed reducers and episode summaries
  -> materialized artifact with trace, provenance, cost, and quality metrics
```

The model should help where it is strong:

- classifying task intent when needed
- extracting facts from bounded slices
- answering bounded local questions
- judging or reviewing a specific artifact
- synthesizing a reducer result when deterministic reduction is not enough

The workflow should own what it is better at:

- partitioning and dependency ordering
- deciding when to pre-plan, when to grow a workflow, and when to delegate to a
  child workflow
- cost and depth limits
- branch scheduling
- policy inheritance
- provenance and lineage
- retries, reviews, waits, and fallbacks
- final artifact assembly

## Slate Takeaways For Phase 9

Random Labs' Slate report is useful because it describes RLM-like ideas as an
agent systems problem rather than only a long-context algorithm.
The parts worth carrying into Phase 9 are:

- Working memory is the scarce resource. External environments, late
  materialization, and episode summaries should keep root context lean instead
  of relying on lossy transcript compaction.
- Strategy and tactics should be separated. Planning, routing, budgeting, and
  review belong in the orchestrating workflow; tactical work belongs in bounded
  leaves, child workflows, or tool adapters.
- Expressivity matters, but so does inductive bias. RunicAI should expose
  enough structure to express dynamic recursion and continuation passing while
  making the safe, inspectable path the easy path.
- Episodes are better synchronization objects than opaque subagent messages.
  A child workflow should return a typed artifact with outcome, provenance,
  usage, and continuation metadata.
- Frequent synchronization is safer than blind N-step execution on mutable
  tasks. For codebase and artifact-generation recipes, staged execution and
  child episodes should be preferred over long generated programs that only
  report at the end.
- Fork-like interactive work maps to existing waits and review gates. Phase 9
  does not need a separate UI primitive, but it should let a branch pause for
  human input and return a normal episode when resumed.
- Cross-model composition should be natural. Different leaves, reducers, or
  child workflows can use different `RunicAI.LLM` policies as long as the
  episode boundary normalizes results.

## Phase 9 Boundaries

### In Scope

- Elixir-first prompt-as-environment adapters
- typed recursive plans over external context references
- lambda-RLM-style combinators expressed as Runic components
- deterministic cost estimates before execution
- bounded leaf LLM calls through `RunicAI.LLM`
- recursive child execution through existing decomposition contracts
- dynamic workflow extension through validated plan fragments and staged
  continuations
- episode outputs from child workflows that can be routed into downstream
  work or accepted as satisfying a parent objective
- trace, replay, evaluation, and benchmark support
- reference recipes for document QA, summarization, extraction, report
  generation, and codebase QA
- optional runtime integration through the Phase 8 session and runner layer

### Out Of Scope

- training a native recursive language model
- making arbitrary generated code the default orchestration language
- exposing a raw Python or Elixir REPL as the primary public API
- provider-specific long-context assumptions
- hidden automatic recursion inside ordinary chat and tool recipes
- unbounded self-modifying production workflows without typed plan, review,
  sandbox, and budget controls
- replacing Phase 4 context, Phase 5 decomposition, or Phase 8 runtime
  contracts

An open REPL adapter may eventually exist as an advanced tool execution adapter,
and generated code may eventually produce validated plan or workflow fragments.
Neither should be the Phase 9 center of gravity.

## Runic Fit And Primitive Gap Assessment

The useful lambda-RLM operators map directly onto existing Runic and RunicAI
concepts.

| lambda-RLM idea | RunicAI representation |
| --- | --- |
| symbolic input outside the context window | `RLM.Environment`, `Context.Ref`, `Context.ThreadStore` |
| `SPLIT` | step that returns `RLM.SliceSet` or child `TaskPlan` |
| `FILTER` | rule or step over slices, possibly with bounded LLM relevance calls |
| `MAP` | `Runic.map` over slices or `Decomposition.Assignment` values |
| leaf `sub_M` call | `RunicAI.LLM` step, child workflow, or tool adapter |
| `REDUCE` | `Runic.reduce` plus `Decomposition.JoinPolicy` |
| `CONCAT` | deterministic reducer |
| `CROSS` | product-generating step followed by map/reduce |
| task-dependent composition operator | `RLM.ReductionPolicy` or existing `JoinPolicy` |
| cost bound | `RLM.CostEstimate` plus `Control.BudgetPolicy` |
| recursion depth bound | `RLM.Policy.max_depth` plus plan validation |
| persistent execution state | accumulator, state machine, runtime session, or runner backend |

The apparent mismatch is that a materialized Runic workflow is DAG-based, while
recursion is often described as a self-call or fixed point.
That is not a real expressivity limit.
Runic workflows can be constructed, merged, advanced, and persisted at runtime;
workflow leaves can spawn child workflows; child results can be summarized as
episode or continuation artifacts; and tool adapters can run ordinary universal
computation when policy permits.
The meaningful Phase 9 question is therefore not "can Runic express recursion?"
It can.
The meaningful question is "which recursive or continuation form should be
made explicit, budgeted, typed, and observable by default?"

Practical encodings include:

1. Pre-expand a finite recursive tree into a workflow graph.
2. Execute one recursion frontier per workflow cycle, keeping the frontier in a
   state machine or runtime session.
3. Build staged child `TaskPlan` groups and execute them through the existing
   decomposition substrate.
4. Dynamically extend a workflow with validated plan fragments discovered by a
   leaf, reducer, or review step.
5. Spawn child workflows that return an `RLM.Episode` or `RLM.Continuation`
   whose output can feed downstream work or satisfy the parent objective.
6. Allow generated code or generated workflow fragments only through tool
   adapters, validation, review gates, and explicit policy.

Recommendation:
do not add a new Runic primitive before Phase 9 begins.
The existing `step`, `map`, `reduce`, `rule`, `accumulator`, `state_machine`,
dynamic workflow composition, and runner APIs are enough to implement the first
version competently.
Boundedness is a product and governance boundary, not a theoretical limitation
of the substrate.

Potential future Runic primitive:
a bounded `unfold` or tree-map-reduce component may become worthwhile if Phase
9 repeatedly needs the same pattern:

```text
seed
  -> expand children until stop predicate
  -> map leaves
  -> reduce levels with traceable ancestry and cost bounds
```

That primitive should only be added if implementation proves that the pattern
cannot stay clear as ordinary `TaskPlan` plus `map` plus `reduce`.
The useful primitive would be bounded, typed, inspectable tree expansion, not
unrestricted cyclic graph execution.

## Design Principles

### 1. Runic is the recursive coordination substrate

The recursive plan should compile to Runic workflow structure, RunicAI
decomposition contracts, or staged Runic runtime advancement.
The model should not be asked to invent orchestration code when the workflow can
model the decomposition explicitly.

### 2. External state is addressed by references, not copied by default

Large inputs should enter through environment refs and slices.
Root prompts should receive handles, summaries, plan metadata, and bounded
materialized snippets only when a step actually needs them.

### 3. Plans are data, not hidden prompts

An RLM plan should be a validated public struct with task kind, source refs,
operators, budgets, estimates, and expected outputs.
Users should be able to inspect, serialize, diff, test, and replay it.

### 4. Recursive execution is bounded before it starts

Every recursive execution should have maximum depth, maximum branch count,
maximum leaf calls, maximum reducer calls, maximum environment reads, timeout,
and estimated cost.

### 5. Dynamic growth is explicit and validated

Phase 9 should allow runtime-discovered work to extend a workflow, spawn a child
workflow, or return a continuation-like result.
That growth must pass through typed plan fragments, policy validation, budget
checks, trace capture, and review gates when configured.
Generated code can be an advanced way to propose new workflow structure, but it
should not bypass the same validation path as hand-authored plans.

### 6. Episodes are first-class synchronization boundaries

The Slate report's strongest transferable idea is not a specific CLI design,
but the episode boundary: a bounded worker does scoped work, returns the
important result and provenance, and does not force the parent to inherit its
entire tactical trace.
RunicAI should model this with explicit episode or continuation artifacts that
can be routed into downstream nodes, summarized into parent state, or accepted
as satisfying a parent objective.

### 7. Frequent synchronization beats blind N-step execution

RLM-style recursion is strongest on immutable retrieval and analysis problems.
For mutable environments, code changes, and review-heavy tasks, Phase 9 should
prefer staged frontier execution, child workflow episodes, and review gates
over long blind generated programs that only report success or failure at the
end.

### 8. Stochastic work stays at typed leaves and selected reducers

Leaf LLM calls are expected.
Reducer LLM calls are allowed when the reduction is semantic.
The branching skeleton should remain deterministic unless a policy explicitly
uses a model to choose among typed alternatives.

### 9. Reuse Phase 4 and Phase 5 vocabulary

`Context.Ref`, `Context.Bundle`, `Context.HandoffArtifact`,
`Decomposition.Task`, `Assignment`, `Result`, and `JoinPolicy` remain the
language of scoped work.
Phase 9 should add recursive execution contracts around them, not replace them.

### 10. Elixir first, language neutral by adapter

The first environment and combinator runtime should be Elixir.
If a user wants Python, JavaScript, or shell-backed computation, it should be
coordinated through `Tool.ExecutionAdapter`, external worker adapters, or
environment adapters.
The public plan remains language-independent data.

### 11. Every branch produces trace and provenance

A Phase 9 run should explain itself through trajectory data:
which slices were read, how they were split, which leaves ran, which reducers
fired, which episodes or continuations were produced, what was filtered out,
what failed review, and what the estimated versus actual cost was.

### 12. Recipes should be task-shaped, not generic cleverness-shaped

The Harness article's strongest lesson is that the task structure often already
contains the decomposition plan.
Report templates, repository trees, document sections, and benchmark buckets
should drive plans before model-generated strategy does.

### 13. RLM mode is optional and explicit

Ordinary recipes should not silently switch into recursive execution.
Users opt in through `RunicAI.RLM` contracts or RLM-specific recipes.

## Recommended Contract Layering

### Layer 1: Environment And Source Contracts

These contracts externalize prompt state.

Recommended modules:

- `RunicAI.RLM.Environment`
- `RunicAI.RLM.EnvironmentRef`
- `RunicAI.RLM.Source`
- `RunicAI.RLM.Slice`
- `RunicAI.RLM.SliceSet`
- `RunicAI.RLM.Probe`
- `RunicAI.RLM.MaterializedArtifact`

`RunicAI.RLM.Environment` should be a behaviour, not one storage system.

Suggested callbacks:

- `init/1`
- `put_source/3`
- `get_source/2`
- `metadata/2`
- `size/2`
- `peek/4`
- `slice/3`
- `split/3`
- `search/3`
- `materialize/3`
- `delete/2`

Initial adapters:

- `RunicAI.RLM.Environments.InMemory`
- `RunicAI.RLM.Environments.ContextThreadStore`
- `RunicAI.RLM.Environments.Filesystem`

Important design rule:
environment reads return `Slice` values with provenance, not anonymous strings.
Actual text is materialized as late as possible.

### Layer 2: Recursive Planning Contracts

These describe what should happen before execution begins.

Recommended modules:

- `RunicAI.RLM.TaskKind`
- `RunicAI.RLM.Policy`
- `RunicAI.RLM.Plan`
- `RunicAI.RLM.PlanNode`
- `RunicAI.RLM.PlanPatch`
- `RunicAI.RLM.Pipeline`
- `RunicAI.RLM.CostModel`
- `RunicAI.RLM.CostEstimate`
- `RunicAI.RLM.Planner`

`TaskKind` should start small:

- `:summarization`
- `:qa`
- `:classification`
- `:extraction`
- `:analysis`
- `:report_generation`
- `:codebase_qa`
- `:custom`

`Policy` should include:

- `:context_window`
- `:leaf_window`
- `:max_depth`
- `:max_branching_factor`
- `:max_leaf_calls`
- `:max_reduce_calls`
- `:max_environment_reads`
- `:max_child_workflows`
- `:max_plan_patches`
- `:max_estimated_tokens`
- `:max_estimated_cost`
- `:accuracy_target`
- `:allowed_combinators`
- `:concurrency`
- `:review_policy`
- `:cache_policy`
- `:metadata`

`CostEstimate` should include:

- estimated leaf calls
- estimated reducer calls
- estimated filter calls
- estimated environment reads
- estimated child workflows and plan patches
- estimated input/output tokens
- estimated latency class
- estimated monetary cost when price data is available
- confidence or assumptions

Do not make one global cost formula too early.
Start with a pluggable `CostModel` and a default heuristic inspired by
lambda-RLM's branching-factor and depth planning.

### Layer 3: Combinator Algebra

These are typed operators that can compile to Runic components.

Recommended modules:

- `RunicAI.RLM.Combinator`
- `RunicAI.RLM.Combinators.Split`
- `RunicAI.RLM.Combinators.Filter`
- `RunicAI.RLM.Combinators.MapLeaf`
- `RunicAI.RLM.Combinators.Reduce`
- `RunicAI.RLM.Combinators.Concat`
- `RunicAI.RLM.Combinators.Cross`
- `RunicAI.RLM.Combinators.Score`
- `RunicAI.RLM.Combinators.Select`
- `RunicAI.RLM.Combinators.Review`

Each combinator should declare:

- input contract
- output contract
- whether it can call an LLM
- whether it can access the environment
- deterministic versus stochastic behavior
- cost contribution
- trace event kind
- validator

This gives us the lambda-RLM benefit of a small verified runtime without
pretending we need to implement a full lambda-calculus evaluator.

### Layer 4: Execution Contracts

These track a recursive run as it advances.

Recommended modules:

- `RunicAI.RLM.ExecutionSpec`
- `RunicAI.RLM.ExecutionState`
- `RunicAI.RLM.ExecutionResult`
- `RunicAI.RLM.Frontier`
- `RunicAI.RLM.ChildWorkflowSpec`
- `RunicAI.RLM.Episode`
- `RunicAI.RLM.Continuation`
- `RunicAI.RLM.LeafRequest`
- `RunicAI.RLM.LeafResult`
- `RunicAI.RLM.ReductionRequest`
- `RunicAI.RLM.ReductionResult`
- `RunicAI.RLM.RunSummary`

`ExecutionSpec` should bind:

- environment ref
- plan
- policy
- LLM policy
- decomposition registry or role registry
- runtime backend options
- trace capture policy
- metadata

`Episode` should capture:

- child workflow or worker identity
- parent plan node id
- input refs and policy snapshot
- compressed outcome
- provenance and materialized artifacts
- whether the episode satisfies, partially satisfies, blocks, or extends the
  parent objective
- resume token or continuation ref when more work can continue from the same
  scoped state

`Continuation` should capture:

- the next frontier, child workflow, or plan patch to execute
- required policy and budget deltas
- routing hints for downstream reducers or review gates
- the episode or trace segment that justified the continuation

`ExecutionResult` should normalize:

- `:completed`
- `:failed`
- `:review`
- `:wait`
- `:budget_exhausted`
- `:partial`

These statuses should reuse `RunicAI.Error`, `Wait`, `ReviewRequest`, and
existing result envelopes instead of inventing a detached RLM-only control
taxonomy.
When a child workflow fulfills a parent objective, the `ExecutionResult` should
include the satisfying `Episode` rather than pretending the parent computed the
answer locally.

### Layer 5: Compiler And Recipe Layer

These turn plans into executable Runic workflows.

Recommended modules:

- `RunicAI.RLM.WorkflowCompiler`
- `RunicAI.RLM.WorkflowInterpreter`
- `RunicAI.Steps.RLMPlan`
- `RunicAI.Steps.RLMSplit`
- `RunicAI.Steps.RLMFilter`
- `RunicAI.Steps.RLMMapLeaves`
- `RunicAI.Steps.RLMReduce`
- `RunicAI.Steps.RLMReview`
- `RunicAI.Steps.RLMMaterialize`

Recommended recipes:

- `RunicAI.Recipes.RLMSummarizer`
- `RunicAI.Recipes.RLMDocumentQA`
- `RunicAI.Recipes.RLMExtraction`
- `RunicAI.Recipes.RLMReportGenerator`
- `RunicAI.Recipes.RLMCodebaseQA`

The compiler should support three execution strategies:

1. Pre-expanded finite workflow:
   compile the full recursive plan into a DAG when depth and branching are
   known.
2. Staged frontier execution:
   run one bounded frontier at a time, using `ExecutionState` to track pending
   nodes and reducer readiness.
3. Dynamic continuation execution:
   allow a bounded step to return a validated `PlanPatch`,
   `ChildWorkflowSpec`, `Episode`, or `Continuation` that extends the current
   workflow, spawns child work, or routes a child result into parent state.

The pre-expanded path should be built first because it is easier to test and
inspect.
The staged path becomes important for very large dynamic trees and durable
runtime sessions.
The dynamic continuation path should come after both are stable, because it is
the most expressive and needs the strongest validation, replay, and trace
contracts.

## Recommended Module And File Layout

```text
lib/runic_ai/
  rlm.ex
  rlm/
    environment.ex
    environment_ref.ex
    source.ex
    slice.ex
    slice_set.ex
    probe.ex
    materialized_artifact.ex
    task_kind.ex
    policy.ex
    plan.ex
    plan_node.ex
    plan_patch.ex
    pipeline.ex
    cost_model.ex
    cost_estimate.ex
    planner.ex
    combinator.ex
    execution_spec.ex
    execution_state.ex
    execution_result.ex
    frontier.ex
    child_workflow_spec.ex
    episode.ex
    continuation.ex
    leaf_request.ex
    leaf_result.ex
    reduction_request.ex
    reduction_result.ex
    run_summary.ex
    workflow_compiler.ex
    workflow_interpreter.ex
    environments/
      in_memory.ex
      context_thread_store.ex
      filesystem.ex
    combinators/
      split.ex
      filter.ex
      map_leaf.ex
      reduce.ex
      concat.ex
      cross.ex
      score.ex
      select.ex
      review.ex
  steps/
    rlm_plan.ex
    rlm_split.ex
    rlm_filter.ex
    rlm_map_leaves.ex
    rlm_reduce.ex
    rlm_review.ex
    rlm_materialize.ex
  recipes/
    rlm_summarizer.ex
    rlm_document_qa.ex
    rlm_extraction.ex
    rlm_report_generator.ex
    rlm_codebase_qa.ex
```

Top-level `RunicAI.RLM` should be a small facade:

- `put_source/3`
- `plan/2`
- `estimate/2`
- `compile/2`
- `run/2`
- `run_until_satisfied/2`
- `continue/2`
- `materialize/2`
- `summarize_episode/1`
- `summarize_run/1`

It should not hide the lower-level contracts.
Advanced users should be able to build and execute plans directly.

## Recursive Composition Model

The first executable model should be a deterministic plan interpreter.
Dynamic continuation support should be layered on after static plans and staged
frontiers are reliable.

### Planning Path

```text
goal + environment refs + RLM.Policy
  -> task-kind detection or explicit task kind
  -> source metadata and size probes
  -> recursive plan nodes
  -> cost estimate
  -> validation against budget policy
```

Task-kind detection can be model-assisted, but it should be optional.
If the caller provides `task_kind`, planning should require zero LLM calls.

### Execution Path

```text
RLM.ExecutionSpec
  -> WorkflowCompiler
  -> Runic workflow, staged frontier workflow, or child workflow spec
  -> split/filter/map/reduce/review/materialize components
  -> optional episode or continuation outputs
  -> RLM.ExecutionResult
  -> Context.Ref / MaterializedArtifact / HandoffArtifact
```

### Leaf Path

```text
RLM.Slice + LeafRequest + LLM policy
  -> bounded materialized text
  -> RunicAI.LLM request
  -> LeafResult with provenance and usage
  -> Decomposition.Result-compatible envelope
```

### Reduction Path

```text
LeafResult[] or ReductionResult[]
  -> deterministic reducer or semantic reducer LLM call
  -> ReductionResult
  -> parent reducer or final materialization
```

### Continuation Path

```text
LeafResult or ReductionResult or ReviewResult
  -> typed PlanPatch / ChildWorkflowSpec / Episode / Continuation
  -> validation against RLM.Policy and Control.BudgetPolicy
  -> dynamic workflow extension, child workflow execution, or parent
     objective satisfaction
  -> traceable episode output routed to downstream nodes
```

This keeps the recursive tree or graph explicit, even when it grows at runtime.
It also lets ordinary decomposition recipes use RLM leaves and lets RLM recipes
reuse ordinary decomposition children.

## Workstream 1: Environment And Slice Substrate

Deliverables:

- [ ] Add `RunicAI.RLM.Environment` behaviour.
- [ ] Add `EnvironmentRef`, `Source`, `Slice`, `SliceSet`, `Probe`, and
      `MaterializedArtifact`.
- [ ] Implement `Environments.InMemory`.
- [ ] Implement `Environments.ContextThreadStore` on top of existing context
      checkpoint contracts.
- [ ] Implement `Environments.Filesystem` for local document and codebase
      experiments.
- [ ] Add provenance-preserving `peek`, `slice`, `split`, `metadata`, and
      `materialize` helpers.
- [ ] Add tests for stable refs, source metadata, slice boundaries,
      provenance, and late materialization.

Implementation notes:

- Start with text sources and filesystem paths.
- Treat source material as immutable during a run.
- Materialized text should carry the slice id and environment ref in metadata.
- Do not require an embedding or vector backend for the first version.

## Workstream 2: Recursive Planning And Cost Estimation

Deliverables:

- [ ] Add `TaskKind`, `Policy`, `Plan`, `PlanNode`, `Pipeline`,
      `CostModel`, `CostEstimate`, and `Planner`.
- [ ] Add `PlanPatch` for validated runtime extension of an existing plan.
- [ ] Support explicit task-kind planning with zero LLM calls.
- [ ] Add optional bounded task-kind detection as one model call.
- [ ] Compute branching factor, leaf chunk size, depth, and expected call
      counts.
- [ ] Estimate child workflow and plan patch allowance for dynamic runs.
- [ ] Validate plans against `RLM.Policy` and `Control.BudgetPolicy`.
- [ ] Add tests for bounded planning across small, medium, and oversized
      sources.

Implementation notes:

- Make the default planner deterministic.
- Keep the first cost model simple and visible.
- Store cost assumptions in `CostEstimate.assumptions`.
- Track estimated versus actual calls so evaluation can improve the model.
- A `PlanPatch` should never bypass full plan validation; it should be treated
  as a proposed continuation of the current plan under the remaining budget.

## Workstream 3: Typed Combinator Library

Deliverables:

- [ ] Add the `Combinator` behaviour or struct contract.
- [ ] Implement split, filter, map-leaf, reduce, concat, cross, score, select,
      and review combinators.
- [ ] Declare deterministic/stochastic behavior and cost contribution for each
      combinator.
- [ ] Reuse `Decomposition.JoinPolicy` for reduction behavior when possible.
- [ ] Add tests for each combinator independent of workflow execution.

Implementation notes:

- `Split` should support document-boundary, section-boundary, token-budget,
  line-range, and word-boundary strategies over time.
- `Filter` can start deterministic and later support bounded relevance calls.
- `Cross` should produce typed pair or tuple slices for tasks such as
  contradiction checks and cross-document comparison.
- `Review` should produce ordinary `ReviewRequest` or typed review artifacts
  when a human or model gate is required.

## Workstream 4: Workflow Compiler And Interpreter

Deliverables:

- [ ] Add `WorkflowCompiler` for pre-expanded finite plans.
- [ ] Add `WorkflowInterpreter` for staged frontier execution.
- [ ] Compile plan nodes to named Runic components.
- [ ] Support validated `PlanPatch` and `ChildWorkflowSpec` application in the
      interpreter after pre-expanded and staged execution are stable.
- [ ] Use `Runic.map` for leaf fan-out and `Runic.reduce` for fan-in.
- [ ] Use rules for filtering, budget gates, stop decisions, and review
      routing.
- [ ] Use accumulators or state machines for staged execution state.
- [ ] Add tests that inspect compiled workflow structure and final results.

Implementation notes:

- Build the pre-expanded compiler first.
- Keep component names stable and human-readable:
  `:rlm_split_1`, `:rlm_leaf_1_3`, `:rlm_reduce_2`.
- Preserve plan node ids in trace metadata.
- The compiler should reject unbounded or invalid plans before execution.
- Dynamic workflow extension should happen only through the interpreter path,
  so replay and policy checks remain centralized.

## Workstream 5: Leaf And Reduction Execution

Deliverables:

- [ ] Add `LeafRequest`, `LeafResult`, `ReductionRequest`, and
      `ReductionResult`.
- [ ] Add `Episode` and `Continuation` result helpers for child workflow and
      dynamic execution outputs.
- [ ] Implement bounded LLM leaf calls through `RunicAI.LLM`.
- [ ] Implement deterministic reducers for concat, majority vote, merge
      extraction, and structured artifact merge.
- [ ] Implement semantic reducers for summary merge, QA synthesis, analysis
      synthesis, and report section composition.
- [ ] Add caching hooks for repeated leaf requests.
- [ ] Add tests with `RunicAI.Testing.ScriptedLLM`.

Implementation notes:

- Leaf prompts should receive only materialized bounded slices plus explicit
  task instructions.
- Reducer prompts should receive child outputs and provenance, not the original
  full source by default.
- Each leaf result should include source refs, usage, latency, and policy
  metadata.
- Episodes should retain enough provenance to replay or audit the scoped work
  without forcing the parent prompt to inherit every tactical step.

## Workstream 6: Control, Runtime, And Observability Integration

Deliverables:

- [ ] Add recursive-specific budget gates for depth, calls, reducer calls,
      environment reads, child workflows, plan patches, estimated tokens, and
      actual usage.
- [ ] Emit trace events for planning, split, filter, leaf, reduce, review,
      materialize, episode, continuation, child workflow, cache hit, retry, and
      budget exhaustion.
- [ ] Integrate with `RunicAI.Runtime` for supervised and runner-backed runs.
- [ ] Support waits and review gates during recursive execution.
- [ ] Add replay support for a completed RLM trajectory.
- [ ] Add tests for budget exhaustion, partial results, review pause/resume,
      continuation resume, child episode satisfaction, and trace structure.

Implementation notes:

- Recursive runs should report estimated versus actual cost.
- A paused branch should resume by plan node id and environment ref.
- Runtime integration should be optional; headless execution should work first.
- Child workflows should inherit explicit policy and return typed episodes;
  they should not implicitly mutate parent state.

## Workstream 7: Reference Recipes

Deliverables:

- [ ] Publish `RunicAI.Recipes.RLMSummarizer`.
- [ ] Publish `RunicAI.Recipes.RLMDocumentQA`.
- [ ] Publish `RunicAI.Recipes.RLMExtraction`.
- [ ] Publish `RunicAI.Recipes.RLMReportGenerator`.
- [ ] Publish `RunicAI.Recipes.RLMCodebaseQA`.
- [ ] Add recipe tests with fake environments and scripted LLM responses.
- [ ] Add at least one provider-backed manual verification report.

Recommended recipe shapes:

### RLM Summarizer

```text
source ref
  -> split by size or section
  -> map summary leaves
  -> reduce summaries hierarchically
  -> final concise summary with provenance
```

### RLM Document QA

```text
question + source refs
  -> split
  -> optional relevance filter
  -> map bounded QA leaves
  -> select relevant partial answers
  -> synthesize final answer with citations
```

### RLM Extraction

```text
schema or extraction goal + source refs
  -> split
  -> map extraction leaves
  -> merge and dedupe structured facts
  -> review coverage gaps
  -> materialize extraction artifact
```

### RLM Report Generator

```text
report template dependency tree + source refs
  -> plan section dependencies
  -> per-section extraction
  -> review contract alignment
  -> generate sections in dependency order
  -> cross-section consistency checks
  -> final document artifact
```

### RLM Codebase QA

```text
question + repository source refs
  -> file and symbol probes
  -> split by files or symbol ranges
  -> map local code understanding leaves
  -> cross-file synthesis
  -> answer with file references
```

## Workstream 8: Benchmark And Evaluation Harness

Deliverables:

- [ ] Add an RLM benchmark runner on top of `RunicAI.Evaluation`.
- [ ] Support direct prompting, Phase 5 decomposition, open-RLM-like adapter if
      available, and lambda-RLM-style Runic execution as comparable candidates.
- [ ] Record accuracy, contains/exact/F1 where appropriate, rubric scores,
      estimated calls, actual calls, estimated tokens, actual tokens, latency,
      environment reads, episode count, continuation count, synchronization
      frequency, and cost.
- [ ] Add context length buckets for synthetic and real tasks.
- [ ] Add trajectory comparison views or artifacts.

Recommended exercise families:

- sequential needle-in-a-haystack over synthetic long contexts
- long document QA over source documents that exceed the leaf window
- multi-document QA where evidence is scattered across sources
- code repository understanding over local files
- extraction over long technical documents
- report/template generation with dependency ordering
- cross-section or cross-document contradiction detection

The lambda-RLM repository currently benchmarks tasks such as S-NIAH,
single-document QA, multi-document QA, and code QA.
RunicAI should mirror those task shapes where practical, then add
workflow-native tasks where Runic's decomposition model should shine:
template-aware report generation, artifact lineage checks, review gates, and
resumable long-running execution.
Slate's thread/episode framing suggests an additional comparison axis:
quality and latency as a function of synchronization frequency.
Benchmarks should distinguish blind N-step execution from staged episode
execution, especially on mutable codebase tasks where intermediate feedback
matters.

## Workstream 9: Adapter Path For Other Execution Languages

Deliverables:

- [ ] Define how an environment adapter can delegate source inspection or
      deterministic transforms to an external worker.
- [ ] Define how a combinator can call a language-specific tool adapter without
      changing the public plan.
- [ ] Define how generated code or generated workflow fragments can be treated
      as proposals that return typed artifacts, not unchecked parent workflow
      mutations.
- [ ] Add one optional external-worker example only after the Elixir path is
      stable.

Implementation notes:

- Other languages should be workers beneath the typed plan, not the plan
  language itself.
- Do not expose generated Python or generated Elixir as the default recursive
  execution mechanism.
- When generated code proposes more work, normalize it to `PlanPatch`,
  `ChildWorkflowSpec`, `Episode`, or `Continuation` before execution continues.
- Use existing tool/runtime adapters for process isolation, timeouts, and
  normalization.

## Recommended Implementation Sequence

1. Land the environment contracts and `InMemory` adapter.
   This proves prompt-as-environment without adding recursion yet.
2. Add source refs, slices, and late materialization.
   This is the data boundary every later component depends on.
3. Add explicit task-kind planning and cost estimates.
   Avoid model-assisted planning until the deterministic path is solid.
4. Implement split, map-leaf, concat/reduce, and materialize.
   This gives the smallest useful lambda-RLM-like workflow.
5. Publish `RLMSummarizer` and `RLMDocumentQA`.
   These give early executable feedback.
6. Add filter, select, semantic reducers, and review.
   This unlocks QA, extraction, and report-generation behavior.
7. Add staged frontier execution.
   Do this after pre-expanded workflows reveal the right state shape.
8. Integrate runtime sessions, waits, review resume, and runner persistence.
   Reuse Phase 8 instead of building a separate RLM process topology.
9. Add `Episode`, `Continuation`, and child workflow support.
   This is the bridge from static recursion to Slate-like thread weaving.
10. Add validated `PlanPatch` support for dynamic workflow growth.
    Keep it behind strict policy and replay requirements at first.
11. Add benchmark candidates and provider-backed verification.
    Compare direct prompting, normal decomposition, and RLM execution.
12. Consider a Runic primitive only if the compiler/interpreter pattern becomes
    repetitive enough to justify a bounded unfold/tree-map-reduce component.

## Verification Plan

Phase 9 should not be considered complete until these are covered.

- [ ] Contract tests for every `RunicAI.RLM.*` struct and behaviour.
- [ ] Environment adapter tests for put, get, metadata, split, slice, peek,
      materialize, provenance, and immutability.
- [ ] Planner tests for depth, branching factor, leaf window, cost estimates,
      budget rejection, and explicit task-kind behavior.
- [ ] Combinator tests for split, filter, map-leaf, reduce, concat, cross,
      score, select, and review.
- [ ] Workflow compiler tests that inspect generated component names, graph
      shape, and result extraction.
- [ ] Leaf and reducer tests with scripted LLMs and deterministic usage data.
- [ ] Runtime tests for wait, review, resume, budget exhaustion, partial
      result handling, and runner-backed continuation.
- [ ] Episode and continuation tests proving child workflow outputs can be
      routed into downstream work or accepted as satisfying parent objectives.
- [ ] Dynamic `PlanPatch` tests proving invalid, over-budget, and untraceable
      workflow growth is rejected.
- [ ] Trace tests proving every plan node and materialized artifact can be
      tied back to source refs.
- [ ] Evaluation tests comparing direct and RLM-style execution over fixture
      tasks.
- [ ] Provider-backed manual verification over at least one long document QA
      task and one template/report-style task.

## Benchmark Metrics

Track at least:

- answer quality:
  exact match, contains, token F1, rubric score, or task-specific score
- provenance quality:
  citation correctness, source coverage, unsupported claim rate
- cost:
  estimated calls, actual calls, estimated tokens, actual tokens, price when
  available
- latency:
  wall time, leaf concurrency, reducer bottlenecks
- reliability:
  error rate, retry count, review count, budget exhaustion count
- synchronization:
  episode count, continuation count, child workflow count, time between parent
  synchronization points
- predictability:
  estimated versus actual call count and token count
- inspectability:
  percentage of final output with traceable source refs

The key comparison is not only quality.
It is quality per predictable unit of work.
The lambda-RLM literature and Harness article both emphasize that variance and
unbounded decomposition are central failures of open-ended RLM loops.
RunicAI should measure that directly.

## Safety And Governance

Phase 9 adds powerful execution behavior, so the policy boundary should be
strict.

- Environment adapters must define what sources can be read.
- Filesystem access should be explicit and path-scoped.
- Recursive runs must have hard depth and call limits.
- Reducer LLM calls should count against the same budget as leaf calls.
- Every environment materialization should be traceable.
- Open code execution should remain a tool adapter with sandboxing, not the
  default RLM plan language.
- Dynamic workflow growth should require validated `PlanPatch` or
  `ChildWorkflowSpec` artifacts and should record who or what proposed the
  continuation.
- Episode outputs should be immutable records; applying them to parent state
  should be an explicit reducer or routing decision.
- Human review should be available for high-impact reducers and final
  materialization.
- Partial results should be explicit when budgets are exhausted.

## Documentation Plan

Add documentation that teaches the model in layers:

1. What RLM mode is and when to use it.
2. How external environments differ from prompt context.
3. How a recursive plan is costed before execution.
4. How each combinator maps to Runic workflow components.
5. How to build a custom environment adapter.
6. How to build a custom combinator.
7. How episode and continuation artifacts differ from ordinary subagent
   message passing.
8. How dynamic workflow growth is validated and replayed.
9. How to benchmark RLM mode against direct prompting and ordinary
   decomposition recipes.

The examples should show real source refs, plan output, estimated cost, trace
events, and final artifacts.
Avoid examples that only print a final answer.

## Open Decisions

- Namespace:
  `RunicAI.RLM.*` is concise, but `RunicAI.Recursive.*` is clearer to users who
  do not know the literature.
  Recommendation: use `RunicAI.RLM.*` for the execution mode and document the
  acronym clearly.
- Plan representation:
  a tree is natural for recursive decomposition, while a DAG is natural for
  shared sources and reducer reuse.
  Recommendation: model `PlanNode` as a graph-friendly node with parent ids,
  not a nested-only tree.
- Episode satisfaction:
  decide how a child workflow declares that its episode fully satisfies,
  partially satisfies, blocks, or extends the parent objective.
  Recommendation: start with explicit status fields on `Episode` and route
  through normal reducers rather than implicit parent mutation.
- Dynamic growth:
  decide whether `PlanPatch` can add arbitrary graph nodes or only append to
  the current frontier.
  Recommendation: begin with frontier-only growth, then generalize after replay
  and trace behavior are proven.
- Chunking strategy:
  start with deterministic text and file splitters, then add semantic section
  splitters.
- Cost model:
  start heuristic and pluggable.
  Do not promise exact pricing until provider usage data and tokenizer support
  are reliable.
- Semantic reducers:
  decide which reducers should be model calls by default and which should be
  deterministic.
- Benchmark scope:
  decide whether to import external datasets or keep a small local synthetic
  suite first.

## Exit Criteria

Phase 9 exits when:

- users can register long-context sources as external environment refs
- users can build or request a validated recursive plan with a cost estimate
- the first plan compiler can execute bounded split, map, and reduce workflows
- leaf LLM calls receive bounded slices rather than full source context
- child workflow episodes can satisfy or advance parent objectives without
  losing provenance
- dynamic plan patches are validated, traceable, and budgeted before they are
  applied
- recursive execution reuses existing budget, wait, review, trace, and
  decomposition contracts
- at least two reference recipes are implemented and documented
- benchmark fixtures compare direct prompting and RLM execution
- provider-backed verification demonstrates improved predictability or quality
  on a long-context task
- no new mandatory runtime ontology has been introduced

## Working Conclusion

RunicAI can implement the valuable part of lambda-RLM without copying its Python
runtime.

Runic steps already model lambda-like transformations.
Runic map and reduce already model the core fan-out/fan-in pattern.
Runic stateful components and runner-backed sessions can model long-running
frontiers.
Runic dynamic workflow construction and child workflow execution can model
runtime growth, continuation passing, and episode-returning subwork.
RunicAI's context, decomposition, runtime, trace, and evaluation layers already
provide the contracts a recursive execution mode needs.

The default Phase 9 architecture is therefore not:

```text
untyped model-written code
  -> unchecked code controls recursion
  -> workflow observes from the side
```

It is:

```text
workflow plans and validates recursion
  -> typed combinators execute through Runic
  -> model solves bounded leaves, semantic reducers, and proposed continuations
  -> child workflows return traceable episodes
  -> trace, cost, provenance, and controls remain first-class
```

Generated code and generated workflow fragments are still possible, but they
should enter through tool adapters and return typed artifacts before they affect
the parent workflow.
That keeps RunicAI fully expressive without making uncontrolled self-modifying
execution the common path.

At this stage there is no clear need to add a primitive to Runic itself.
If Phase 9 reveals a true abstraction gap, the likely candidate is a bounded
tree-unfold or recursive map-reduce component.
Until then, the right move is to prove the design using Runic's existing DAG,
map/reduce, state, dynamic composition, and runner facilities.
