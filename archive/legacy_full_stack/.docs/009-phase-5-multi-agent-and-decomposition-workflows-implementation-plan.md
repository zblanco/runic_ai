# Phase 5 Implementation Plan: Multi-Agent And Decomposition Workflows

Status: implemented

Date: 2026-04-19

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`
- `.docs/007-phase-4-context-engineering-memory-and-retrieval-boundaries-implementation-plan.md`

References:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/010-react-vs-rlm-for-workflow-native-agent-composition.md`
- `https://arxiv.org/abs/2210.03629`
- `https://arxiv.org/abs/2305.10601`
- `https://proceedings.mlr.press/v235/kim24y.html`
- `https://arxiv.org/abs/2305.14325`
- `https://arxiv.org/abs/2306.05685`
- `https://arxiv.org/abs/2404.18796`
- `https://arxiv.org/abs/2510.11967`
- `https://arxiv.org/abs/2512.24601`
- `https://arxiv.org/abs/2603.20105`

## Progress

- [x] Wrote the Phase 5 implementation plan and companion ReAct vs RLM note.
- [x] Phase 5 delegation contracts, child execution substrate, and reference
      recipes are implemented in the library.
- [x] Provider-backed manual verification is complete. See
      `.docs/011-phase-5-manual-verification-report.md`.

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic HexDocs overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic workflow API:
  `https://hexdocs.pm/runic/Runic.Workflow.html`
- Official Runic package README:
  `https://hexdocs.pm/runic/readme.html`
- Tidewave lookup keys:
  `Runic`, `Runic.Workflow`, `Runic.map/2`, `Runic.reduce/3`,
  `Runic.rule/1`, `Runic.state_machine/1`, `Runic.process_manager/1`

## Goal

Build the first workflow-native delegation layer on top of the Phase 0 through
Phase 4 substrate so users can compose parent workflows, specialized child
agents, and smaller child LLM/tool workflows as typed Runic dataflow rather
than as prompt conventions or bespoke orchestration.

Phase 5 is successful when RunicAI has a clear, composable answer to:

"How do I let one workflow decompose work into child tasks, configure
specialized delegates with scoped context and policy, execute those children in
parallel or staged branches, and deterministically reduce their results back
into a parent outcome without losing waits, reviews, handoffs, or other control
semantics?"

## Current Starting Point

Phase 4 gives us a governed, context-aware single-thread substrate:

- `RunicAI.Agent.State`
- `RunicAI.Agent.TurnRequest`
- `RunicAI.Agent.TurnResult`
- `RunicAI.Agent.ContinueDecision`
- `RunicAI.Tool.*` contracts and execution planning
- `RunicAI.Control.*` policies plus `RunicAI.ReviewRequest`,
  `RunicAI.ReviewDecision`, `RunicAI.Wait`, and `RunicAI.ResumeSignal`
- `RunicAI.Context.*`, `RunicAI.Memory.*`, and `RunicAI.Retrieval.*`
- `RunicAI.Context.HandoffRequest` and `RunicAI.Context.HandoffArtifact`
- `RunicAI.Recipes.ChatAgentKernel`
- `RunicAI.Recipes.ConversationalToolAgent`
- `RunicAI.Recipes.GuardedOperatorToolAgent`
- `RunicAI.Recipes.SummaryBackedChatAgent`
- `RunicAI.Recipes.MemoryAwareToolAgent`
- `RunicAI.Recipes.HandoffContextBuilder`

What is still missing is the decomposition layer above that substrate:

- reusable special-purpose child role definitions
- a validated registry or catalog for those roles
- typed child-task descriptions distinct from live child execution
- explicit inheritance rules for context, tools, budgets, and memory scope
- a materialized child assignment/invocation contract
- normalized child result semantics for completion, failure, wait, review, and
  handoff
- deterministic join and reduction semantics for fan-out workloads
- reusable cohort, jury, and reviewer recipes built from the same contracts
- a reference answer for "planner/executor", "researcher/synthesizer", and
  "reviewer/editor/judge" on the existing workflow substrate

## Why This Phase Matters

Phase 4 answered "what context should one thread keep active, compact, or hand
off?"

Phase 5 needs to answer "when should one thread become many, what should each
child actually receive, and how do those branches rejoin without collapsing
back into opaque prompt spaghetti?"

This is where Runic's real advantage over a linear ReAct-style loop should
become concrete.

ReAct remains useful inside a child recipe because it gives a good local
reason-act-observe kernel.
But ReAct alone does not define a reusable parent/child contract layer, scoped
inheritance rules, or deterministic fan-in semantics.

The maintainable shape we want is:

1. the parent decides to decompose through explicit typed values
2. each child receives a scoped role, task, context seed, and policy slice
3. child execution remains a recipe or workflow invocation, not a magic runtime
4. each child returns a normalized result envelope
5. the parent joins those results through a typed reduction policy
6. review, wait, handoff, and failure remain explicit values at every boundary
7. more elaborate patterns such as debate, juries, or cohort synthesis compile
   down to the same small set of contracts

This is also the right phase boundary for bringing the RLM discussion into
focus.
Inference for RunicAI: RLMs suggest that decomposition and programmatic child
invocation should be first-class workflow semantics, but the Phase 5 substrate
does not need to adopt an open-ended REPL runtime to benefit from that
insight.

## Decomposition Composition Model

Phase 5 should make delegation readable as a chain of named transformations:

```text
Parent Agent.State + goal + role registry
  -> Decomposition.TaskPlan
  -> Decomposition.Task[]
  -> Decomposition.Assignment[]
  -> parallel or staged child workflow execution
  -> Decomposition.Result[]
  -> Decomposition.JoinPolicy
  -> synthesized artifact | winning result | review request | wait | handoff
  -> Parent Agent.State'
```

The child path should be equally explicit:

```text
Task + Role + HandoffArtifact/Context.Bundle + InheritancePolicy
  -> Assignment
  -> child recipe or workflow
  -> Result(status: :completed | :failed | :review | :wait | :handoff)
  -> parent rule: join | retry | rescope | escalate | stop
```

The key design rule is that a delegated child is not necessarily "another
full agent."

Sometimes the child is a specialized conversational tool agent.
Sometimes it is a judge or reviewer.
Sometimes it is a very small workflow that only runs one LLM step or a narrow
LLM-plus-tools routine.

The substrate should therefore describe decomposition and delegation first,
with "agent" as one useful delegate kind rather than as the only ontology.

## Design Principles

### 1. Model decomposition as a contract layer, not as prompt theater

Parent-child delegation should move through typed values such as task plans,
assignments, inheritance policies, and child results.

Do not rely on prompt-only conventions like "pretend you are a sub-agent" as
the primary public abstraction.

### 2. Reuse the existing contracts whenever possible

Phase 5 should reuse:

- `RunicAI.Context.HandoffArtifact` for child seeding
- `RunicAI.Context.Bundle` for scoped active context
- `RunicAI.Tool.Selection` and related tool policy data
- `RunicAI.Control.BudgetPolicy` and `RunicAI.Context.WindowPolicy`
- `RunicAI.Wait`, `RunicAI.ReviewRequest`, and `RunicAI.ResumeSignal`
- `RunicAI.Error` for failure normalization

New Phase 5 contracts should wrap and coordinate these values rather than
redefining them.

### 3. Separate reusable child roles from per-task assignments

A role is a reusable profile: what kind of delegate this is, what recipe it
uses, what defaults it carries.

A task is one scoped unit of delegated work.
An assignment is the materialized child invocation for one task under one role.

Keeping those levels distinct is what lets a parent configure a fleet of
purpose-built delegates without smearing runtime state into reusable
definitions.

### 4. Make inheritance minimal, explicit, and inspectable

Children should inherit only the context, tools, budgets, and memory scope they
need.

Least privilege should be the default, not full parent duplication.

### 5. Keep fan-out and fan-in deterministic around stochastic leaves

The child LLM/tool calls remain effect boundaries.
But the branching skeleton, grouping, join order, and reduction policy should
stay deterministic and inspectable as workflow data.

In category-theoretic terms, the useful move here is to keep the product-like
fan-out and reducer-based reassembly explicit even when the leaves are
stochastic.

### 6. Let advanced patterns compile to the same base contracts

Planner/executor, researcher/synthesizer, reviewer/editor, debate, jury, and
judge patterns should all be recipes over the same core contracts.

Do not introduce a separate bespoke runtime vocabulary for each pattern.

### 7. Bubble child control outcomes instead of flattening them away

A child that needs review, needs to wait, or wants to emit a handoff should be
able to say so through a normalized result envelope.

The parent may choose to surface, transform, or handle that outcome, but it
should not disappear into one recipe-local branch.

### 8. Prefer Runic-native branching and reduction over ad hoc orchestration

Use `Runic.map`, `Runic.reduce`, `Runic.rule`, explicit workflow joins, and small named steps
before inventing custom concurrency helpers.

This phase should look like a natural extension of Phase 2 tool execution and
Phase 4 handoff/context assembly.

### 9. Fit the current turn-processor recipe family first

The first target remains the persistence-agnostic recipe family where callers
persist the latest state and typed outputs however they want.

Phase 6 can later add more integrated workflow-owned state and lifecycle
control.

### 10. Keep RLM inspiration in scope, but RLM runtime machinery out of scope

Inference for RunicAI: the important import from RLM right now is
programmatic child invocation over scoped context, not a raw REPL plus
free-form code generation as a new mandatory runtime.

That distinction keeps Phase 5 disciplined and leaves room for later RLM or
lambda-RLM inspired adapters.

## Recommended Contract Layering For Phase 5

### Layer 1: Reusable delegate profiles and selection

These describe what kinds of children can be invoked.

- `RunicAI.Decomposition.Role`
- `RunicAI.Decomposition.Registry`
- `RunicAI.Decomposition.InheritancePolicy`

### Layer 2: Parent planning and child materialization

These describe what work should be delegated and how a concrete child call is
formed.

- `RunicAI.Decomposition.Task`
- `RunicAI.Decomposition.TaskPlan`
- `RunicAI.Decomposition.Assignment`
- reused `RunicAI.Context.HandoffArtifact` or `RunicAI.Context.Bundle`

### Layer 3: Child outcomes and reduction semantics

These keep parent-child coordination typed and inspectable.

- `RunicAI.Decomposition.Result`
- `RunicAI.Decomposition.JoinPolicy`
- `RunicAI.Decomposition.Evaluation`
- reused `RunicAI.Wait`, `RunicAI.ReviewRequest`, `RunicAI.Error`,
  `RunicAI.Context.HandoffArtifact`

### Layer 4: Decomposition-native steps and recipes

These are the reusable Runic pieces that make the layer practical.

- child-task planning
- assignment materialization
- child execution
- result normalization
- staged fan-out and deterministic fan-in
- judge and jury reduction
- reference recipes proving the layer fits the earlier kernels

## Recommended Public Contracts

These should be the minimum new Phase 5 contracts or contract extensions.

### `RunicAI.Decomposition.Role`

Purpose: reusable special-purpose delegate profile for one child workflow kind.

Suggested fields:

- `:name`
- `:kind` - `:agent | :workflow | :llm`
- `:description`
- `:builder` - recipe module/function or workflow constructor reference
- `:system`
- `:defaults` - model, llm opts, control/context/tool defaults
- `:accepts` - optional task-kind tags or capability labels
- `:metadata`

Notes:

- [ ] Keep the builder explicit and injectable, similar in spirit to
      `Tool.Definition.executor`.
- [ ] A role is reusable configuration, not live runtime state.
- [ ] Allow simple child workflows that are not full conversational agents.

### `RunicAI.Decomposition.Registry`

Purpose: validated catalog of named delegation roles.

Suggested fields:

- `:roles`
- `:metadata`

Notes:

- [ ] A small validated registry keeps "fleet of purpose-built agents" concrete
      without requiring any external service.
- [ ] The initial registry can remain plain data with validation and lookup
      helpers.
- [ ] Avoid coupling registry lookup to any particular provider, process, or
      persistence topology.

### `RunicAI.Decomposition.InheritancePolicy`

Purpose: declare how parent context, budgets, tools, and memory scope should be
projected into a child.

Suggested fields:

- `:context_mode` - `:handoff | :bundle | :refs | :none`
- `:max_context_refs`
- `:tool_mode` - `:inherit | :subset | :override | :none`
- `:allowed_tools`
- `:budget_mode` - `:slice | :copy | :fresh | :none`
- `:budget_overrides`
- `:memory_scope`
- `:metadata`

Notes:

- [ ] Make least-privilege inheritance the default.
- [ ] Keep selectors and overrides serializable as plain data.
- [ ] Reuse existing policy contracts instead of creating second versions for
      children.

### `RunicAI.Decomposition.Task`

Purpose: one scoped unit of delegated work.

Suggested fields:

- `:id`
- `:goal`
- `:role` - role name or `Decomposition.Role`
- `:instructions`
- `:input`
- `:handoff` - optional `RunicAI.Context.HandoffArtifact`
- `:context_bundle` - optional `RunicAI.Context.Bundle`
- `:output_contract`
- `:priority`
- `:depends_on`
- `:metadata`

Notes:

- [ ] Prefer `HandoffArtifact` as the canonical seed when the child is another
      thread-like workflow.
- [ ] Let `:output_contract` start as a validated descriptive map plus optional
      validator callback rather than introducing a large new schema system.
- [ ] Keep the task independent of process identity or runtime ownership.

### `RunicAI.Decomposition.TaskPlan`

Purpose: describe the planned set of child tasks and the intended execution
grouping before any child runs.

Suggested fields:

- `:tasks`
- `:groups` - staged task ids or grouped task lists
- `:join_policy`
- `:metadata`

Notes:

- [ ] This is the Phase 5 analogue of `Tool.ExecutionPlan`.
- [ ] Separate model-visible planning from workflow-visible execution.
- [ ] Support simple parallel groups first, with staged groups as the next
      extension.

### `RunicAI.Decomposition.Assignment`

Purpose: materialized child invocation ready to execute or later resume.

Suggested fields:

- `:id`
- `:task`
- `:role`
- `:inheritance`
- `:input`
- `:seed_state`
- `:resume_key`
- `:metadata`

Notes:

- [ ] Keep assignment creation deterministic from role + task + inherited data.
- [ ] `:seed_state` should stay optional so small child workflows are not forced
      into one agent-state shape.
- [ ] `:resume_key` gives the parent a stable way to correlate later child
      review or wait outcomes.

### `RunicAI.Decomposition.Result`

Purpose: normalize how a child completed or what coordination it requires.

Suggested fields:

- `:task_id`
- `:status` - `:completed | :failed | :review | :wait | :handoff | :cancelled`
- `:output`
- `:artifacts`
- `:error`
- `:review_request`
- `:wait`
- `:handoff`
- `:child_state`
- `:metadata`

Notes:

- [ ] Reuse `RunicAI.Wait`, `RunicAI.ReviewRequest`, `RunicAI.Error`, and
      `RunicAI.Context.HandoffArtifact` directly instead of wrapping them in new
      mini-taxonomies.
- [ ] Parent joins should operate on normalized `Result` values, not on raw
      recipe-specific return tuples.
- [ ] `:child_state` keeps resume behavior persistence-agnostic.

### `RunicAI.Decomposition.JoinPolicy`

Purpose: declare how the parent reduces a set of child results.

Suggested fields:

- `:mode` - `:all | :all_settled | :first_success | :quorum | :score | :merge | :custom`
- `:quorum`
- `:score_by`
- `:on_partial_failure`
- `:synthesizer`
- `:metadata`

Notes:

- [ ] Keep deterministic outer reduction separate from stochastic child
      content.
- [ ] Built-in modes should cover early fan-out, reviewer, and jury patterns.
- [ ] A custom reducer can exist, but it should remain opt-in rather than the
      only path.

### `RunicAI.Decomposition.Evaluation`

Purpose: normalized reviewer or judge assessment over one candidate artifact or
child result.

Suggested fields:

- `:subject_id`
- `:judge`
- `:score`
- `:verdict`
- `:reason`
- `:metadata`

Notes:

- [ ] Keep this smaller than a full Phase 7 evaluator substrate.
- [ ] Use it to support reviewer/editor/judge and panel-of-judges recipes.
- [ ] Preserve enough structure that later observability or evaluation work can
      reuse it rather than replace it.

## Recommended Module And File Layout

Phase 5 should add a decomposition namespace rather than scattering these
concerns across `Agent.State`, `Context.HandoffArtifact`, and recipe-local
maps.

```text
lib/runic_ai/
  decomposition/
    role.ex
    registry.ex
    inheritance_policy.ex
    task.ex
    task_plan.ex
    assignment.ex
    result.ex
    join_policy.ex
    evaluation.ex
  steps/
    plan_child_tasks.ex
    build_child_assignments.ex
    execute_child_assignments.ex
    reduce_child_results.ex
    judge_candidates.ex
  recipes/
    planner_executor_workflow.ex
    parallel_research_synthesizer.ex
    reviewer_editor_jury.ex
```

Recommended contract extensions in place:

- `RunicAI.Agent.State.pending_action` may need to carry a `TaskPlan`,
  active assignment ids, or a reduction checkpoint for parent recipes that
  pause mid-decomposition.
- `RunicAI.Context.HandoffArtifact` should remain the canonical child seed for
  thread-like workflows rather than introducing a second delegation-handoff
  struct.
- `RunicAI.ReviewRequest`, `RunicAI.Wait`, and `RunicAI.ResumeSignal` should be
  reused directly for parent-child coordination instead of being wrapped inside
  a new Phase 5-only control vocabulary.

## Workstream 1: Decomposition Substrate And Planning Contracts

This workstream establishes the durable contract layer that later workstreams
compose.

Deliverables:

- [ ] Add `RunicAI.Decomposition.Role`, `RunicAI.Decomposition.Registry`,
      `RunicAI.Decomposition.Task`, `RunicAI.Decomposition.TaskPlan`, and
      `RunicAI.Decomposition.JoinPolicy`.
- [ ] Add validation helpers and lookup helpers for named child roles.
- [ ] Support grouped or staged task planning through `TaskPlan.groups`.
- [ ] Add focused contract tests for role validation, task validation, and
      deterministic task-plan construction.
- [ ] Document the difference between reusable role profiles and per-task
      plans.

Implementation notes:

- Separate planner output from executor behavior the same way Phase 2 separates
  `TurnResult` from `Tool.ExecutionPlan`.
- Keep the first plan model small and serializable.
- Do not require a particular queue, worker pool, or process topology just to
  express the plan.

## Workstream 2: Scoped Inheritance And Child Assignment Materialization

This workstream turns parent state plus a task plan into concrete child
invocations.

Deliverables:

- [ ] Add `RunicAI.Decomposition.InheritancePolicy` and
      `RunicAI.Decomposition.Assignment`.
- [ ] Add a child-assignment builder step that derives child input from role,
      task, handoff artifact, context bundle, and inheritance policy.
- [ ] Support scoped budget slicing, tool subsetting, and context projection.
- [ ] Reuse `Context.HandoffArtifact` and `Context.Bundle` as primary seed
      inputs.
- [ ] Add tests proving that parent context and tool surfaces are narrowed
      deterministically and minimally.

Implementation notes:

- The default inheritance mode should be narrower than "copy everything."
- Parent-to-child transfer should stay inspectable as plain data.
- This is the main place where the Phase 4 context work should pay off.

## Workstream 3: Child Execution And Result Normalization

This workstream gives Phase 5 one explicit path for invoking children and
collecting typed outcomes.

Deliverables:

- [ ] Add `RunicAI.Decomposition.Result`.
- [ ] Add a child-executor adapter path that can invoke a role's builder as a
      child workflow, recipe, or narrow function-based delegate.
- [ ] Support child completion, failure, review, wait, and handoff outcomes.
- [ ] Normalize raw child outputs into `Decomposition.Result`.
- [ ] Preserve child state for later resume when a child pauses or asks for
      review.
- [ ] Add step and contract coverage for all supported result states.

Implementation notes:

- The initial target is synchronous or explicit child execution inside the
  parent workflow, not a new autonomous runtime.
- Bubble child control values upward instead of flattening them into generic
  errors.
- Keep the adapter explicit and injectable so tests can provide fake child
  delegates the same way they provide fake LLM clients or tool executors.

## Workstream 4: Fan-Out, Staging, And Deterministic Joins

This workstream makes parallel decomposition a natural part of the graph.

Deliverables:

- [ ] Add execution helpers that dispatch one assignment per branch using
      `Runic.map`, explicit child workflows, or a similarly Runic-native
      structure.
- [ ] Support `:parallel`, `:serial`, and staged group execution from
      `TaskPlan.groups`.
- [ ] Add `reduce_child_results` behavior driven by `JoinPolicy`.
- [ ] Support early join modes such as all, all-settled, first-success, quorum,
      score, and merge.
- [ ] Add recipe wiring examples for file-by-file analysis, source gathering,
      and plan-step execution.
- [ ] Add tests covering grouping, ordering, partial failures, and reduction
      determinism.

Implementation notes:

- LLMCompiler is a useful design reference here: planning, dispatch, and join
  should remain visibly separate phases.
- Keep grouping and dependency information inside the typed plan rather than in
  recipe-local branching code.
- The reduction skeleton should stay deterministic even when children are not.

## Workstream 5: Cohort, Judge, And Jury Patterns

This workstream turns multi-perspective coordination into a reusable recipe
family.

Deliverables:

- [ ] Add `RunicAI.Decomposition.Evaluation`.
- [ ] Publish a reviewer/editor recipe where one child proposes and another
      child revises.
- [ ] Publish a planner/executor/judge recipe where a judge evaluates one or
      more child outputs before final completion.
- [ ] Support both a single judge and a panel-of-judges reduction path.
- [ ] Preserve per-judge reasons and scores in structured metadata.
- [ ] Add tests for score aggregation, quorum behavior, disagreement handling,
      and human-review fallback.

Implementation notes:

- Treat judges as ordinary child roles over the same substrate rather than as a
  new privileged runtime concept.
- `LLM-as-a-judge` is useful, but the "judges vs juries" literature is a good
  warning against over-trusting one opaque scorer.
- Debate-style recipes should stay bounded and typed; Phase 5 does not need an
  open-ended social simulation runtime.

## Workstream 6: Reference Recipes And Documentation

This workstream proves the decomposition layer fits the earlier kernels.

Deliverables:

- [ ] Publish a planner/executor workflow showing parent planning, child
      execution, and deterministic reduction.
- [ ] Publish a parallel research/synthesizer workflow that fans out evidence
      gathering and rejoins into one synthesis.
- [ ] Publish a reviewer/editor/jury workflow showing candidate generation plus
      a judge or jury branch before final completion.
- [ ] Add examples showing a reusable role registry and per-task overrides.
- [ ] Update README and docs so decomposition becomes a visible first-class
      library lane.
- [ ] Add focused end-to-end tests over fake delegates and at least one
      provider-backed manual verification path.

Implementation notes:

- The recipes should read like controlled extensions of the current kernels,
  not like a fresh bespoke runtime.
- Each recipe should make context slicing, role specialization, and reduction
  semantics concrete.

## Recommended Implementation Sequence

1. Land the decomposition contracts first.
   `Role`, `Registry`, `Task`, `TaskPlan`, and `JoinPolicy` are the substrate
   every later workstream depends on.
2. Land inheritance and assignment materialization next.
   This is the bridge between Phase 4 handoff/context work and actual child
   execution.
3. Add child execution and result normalization.
   Once children can run and return typed results, the phase becomes testable.
4. Add grouped fan-out and deterministic joins.
   This is where Runic's branching advantages become concrete.
5. Add judge and jury patterns.
   These should compile to the same `Result`, `Evaluation`, and `JoinPolicy`
   values instead of inventing a new substrate.
6. Finish with reference recipes, docs, and provider-backed manual
   verification.

## Recommended Early Decisions

These decisions are worth making before implementation starts so the phase does
not sprawl.

1. Use a `RunicAI.Decomposition.*` namespace instead of `RunicAI.MultiAgent.*`.
   Not every child is a full agent, and the broader namespace keeps the library
   honest about that.
2. `Context.HandoffArtifact` should remain the canonical inter-thread seed.
   Phase 4 already solved this part; Phase 5 should build on it.
3. Child planning should compile to `TaskPlan`, not raw task lists.
   That preserves the separation between planning and execution.
4. Default child context transfer should be scoped, not wholesale.
   `:handoff` or a narrow `Context.Bundle` slice should be the normal path.
5. Child results should reuse `Wait`, `ReviewRequest`, `Error`, and
   `HandoffArtifact` directly.
   That keeps control semantics uniform across single-agent and multi-agent
   recipes.
6. Initial child execution should remain synchronous or explicitly nested in the
   current recipe family.
   Durable actor-style orchestration belongs later with Phase 6.
7. RLM-style symbolic delegation is the right conceptual inspiration, but an
   open-ended REPL runtime is not required for the initial Phase 5 substrate.
8. Keep room for a later lambda-RLM inspired typed combinator layer.
   If that lane arrives, it should plug into the same public contracts rather
   than replace them.

## Verification Plan

Phase 5 implementation should be considered complete only when the following
verification work is done.

- [ ] Contract tests for role, registry, inheritance, task, task plan,
      assignment, result, join policy, and evaluation contracts.
- [ ] Assignment-materialization tests covering tool subsetting, context
      slicing, budget inheritance, and deterministic seed construction.
- [ ] Child-execution tests covering completed, failed, review, wait, and
      handoff child outcomes.
- [ ] Fan-out and join tests covering parallel groups, staged groups, quorum,
      score-based joins, and partial-failure handling.
- [ ] Recipe tests for planner/executor, parallel research/synthesizer, and
      reviewer/editor/jury patterns.
- [ ] At least one provider-backed manual verification run showing parent
      planning, parallel child work, and a reviewer or judge branch before
      final completion.
- [ ] Documentation updates so users can discover the decomposition layer from
      the roadmap, README, and recipe docs.

## Out Of Scope For This Phase

The plan should stay disciplined about what Phase 5 does not need to solve yet.

- No distributed worker pool, queue, or actor bus is required yet.
- No workflow-owned long-lived child mailbox runtime is required yet.
- No open-ended REPL or free-form code-generation RLM scaffold should be added
  to the core library in this phase.
- No external marketplace or networked registry service is required yet.
- No full Phase 7 observability suite is required yet.
- No claim that one model-based judge is universally reliable or unbiased
  should be baked into the design.

## Exit Criteria

Phase 5 is done when RunicAI users can define specialized child roles, plan
delegated tasks, fan out child work in parallel or staged groups, rejoin those
branches through typed reduction policies, and surface wait, review, handoff,
and failure outcomes using the same workflow-native contract model already
established for single-agent recipes.
