# Phase 6 Implementation Plan: Stateful Integrated Agent Recipes

Status: draft implementation plan

Date: 2026-04-20

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`
- `.docs/007-phase-4-context-engineering-memory-and-retrieval-boundaries-implementation-plan.md`
- `.docs/009-phase-5-multi-agent-and-decomposition-workflows-implementation-plan.md`

References:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/010-react-vs-rlm-for-workflow-native-agent-composition.md`
- `/home/doops/wrk/libbit/apps/core/lib/core/agents/runic_agent_loop.ex`

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic HexDocs overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic workflow API:
  `https://hexdocs.pm/runic/Runic.Workflow.html`
- Official Runic package README:
  `https://hexdocs.pm/runic/readme.html`
- Tidewave lookup keys:
  `Runic`, `Runic.Workflow`, `Runic.state_of/1`, `Runic.accumulator/3`,
  `Runic.state_machine/1`, `Runic.Workflow.StateMachine`,
  `Runic.Workflow.ProcessManager`

## Goal

Build the additive workflow-owned stateful recipe family promised in the
roadmap so users can keep evolving agent state inside the workflow itself,
rather than depending on an external caller to persist state, decide whether to
run another turn, and manually re-enter the loop.

Phase 6 is successful when RunicAI has a clear answer to:

"How do I run one or many conversational agents as workflow-owned state,
drive them with typed signals, keep their control state scoped correctly, and
still reuse the same turn, tool, budget, guard, wait, and review contracts as
the existing turn-processor track?"

## Current Starting Point

Phase 5 leaves the library with a strong external-state substrate:

- `RunicAI.Agent.State`
- `RunicAI.Agent.TurnRequest`
- `RunicAI.Agent.TurnResult`
- `RunicAI.Agent.ContinueDecision`
- `RunicAI.Tool.*`
- `RunicAI.Control.*`
- `RunicAI.Wait`, `RunicAI.ReviewRequest`, `RunicAI.ResumeSignal`
- `RunicAI.Context.*`, `RunicAI.Memory.*`, `RunicAI.Retrieval.*`
- `RunicAI.Decomposition.*`
- `RunicAI.Recipes.ChatAgentKernel`
- `RunicAI.Recipes.ConversationalToolAgent`
- `RunicAI.Recipes.GuardedOperatorToolAgent`
- the Phase 4 and Phase 5 reference recipes

What is still missing is the workflow-owned runtime lane above those contracts:

- a durable identity model for one or many agent lanes inside the same workflow
- a typed signal envelope for external turns, resume inputs, wake-ups, and
  internal continuation
- a workflow-owned session state that wraps existing `Agent.State` rather than
  replacing it
- explicit state-aware routing driven by `state_of/1`
- integrated chat and tool recipes that run to quiescence without an external
  recursive loop
- queue, wait, review, and scheduled wake behavior that generic Runic runners
  can drive durably without a bespoke agent process topology

## Why This Phase Matters

Phase 5 answered "how do workflows split work into child tasks and join it
back together?"

Phase 6 needs to answer "how do workflows themselves own long-lived agent
threads, mailboxes, waits, and control state?"

This is the phase where RunicAI should finally cash in on one of Runic's most
important advantages over a narrow ReAct loop: the loop can be part of the
workflow graph rather than something wrapped around the graph.

The maintainable shape we want is:

1. external input arrives as a typed signal
2. the workflow reduces that signal into workflow-owned state
3. rules inspect state with `state_of/1` and route the next unit of work
4. existing turn, tool, and control components do the actual agent work
5. the result is reduced back into the owning session state
6. waits, reviews, wakes, and stops remain typed values, not process lore
7. a generic workflow runner can persist and resume the whole thing without a
   specialized agent server

That is the real value of this phase.
It should feel like an additive recipe family built from Runic primitives, not
like a second runtime hidden beside the library.

## The Core Design Choice: Identity And Scoping

The key architectural question in this phase is how to scope conversation and
control state when many agents may live inside the same workflow.

There are three broad options:

1. One distinct graph lane or accumulator set per agent.
   This is workable for tiny fixed recipes, but it makes identity a property of
   graph topology and becomes awkward for dynamic or reusable multi-agent
   workflows.
2. Many parallel accumulators keyed by `agent_id`.
   This preserves one workflow, but conversation state, retries, waits, usage,
   and review routing become fragmented across several maps that all have to be
   kept in sync.
3. One authoritative workflow-owned runtime state keyed by `agent_id`, plus
   typed envelopes for input and output.
   This keeps identity explicit in data rather than topology and gives rules
   one place to inspect when deciding what to do next.

Recommendation for Phase 6:

- Use a stable `agent_id` as the primary runtime key for each integrated agent
  lane.
- Keep `conversation_id` as optional correlation metadata rather than the
  reducer key.
- Store all live integrated state under one authoritative runtime state value:
  `RuntimeState.agents[agent_id]`.
- Let external turn-oriented signals carry `agent_id` directly.
- Preserve current `Wait`, `ReviewRequest`, `ResumeSignal`, and
  `ReviewDecision` contracts by keeping a `resume_index` inside runtime state
  that maps `resume_key -> agent_id`.
- Emit externally visible values through an identity-carrying envelope so
  replies, waits, reviews, and handoffs remain attributable to the correct
  agent.

This is the best fit for a reusable Runic-native library.
It takes the inspectability lessons from the libbit experiment while avoiding
its more app-specific "many internal accumulators for one turn loop" shape as
the primary public substrate.

## Integrated Runtime Composition Model

Phase 6 should make the stateful runtime readable as a chain of explicit
workflow transformations:

```text
Integrated.Signal
  -> RuntimeState reducer
  -> state-aware routing rule using state_of(:integrated_runtime)
  -> SessionState for one agent_id
  -> existing turn/tool/control components
  -> updated SessionState
  -> RuntimeState'
  -> Integrated.Emission | more Integrated.Signal | quiescence
```

The important layering rule is:

```text
workflow-owned orchestration
  wraps
existing turn/tool/control contracts
```

Not the reverse.

The phase should not create a second incompatible "integrated agent turn"
vocabulary.
Instead, the integrated runtime should project one `SessionState` into the same
`TurnRequest`, `TurnResult`, tool execution plan, budget decision, wait, and
review contracts that earlier phases already stabilized.

## Design Principles

### 1. Keep workflow-owned state additive

The existing persistence-agnostic turn-processor model remains first-class.
Phase 6 adds a new recipe family above it.

### 2. Keep one authoritative runtime state

Use one indexed runtime state keyed by `agent_id` as the source of truth for
live integrated sessions.
Do not make conversation, retries, waits, and usage drift across unrelated
public accumulators by default.

### 3. Keep `Agent.State` local and reusable

`RunicAI.Agent.State` remains the local conversational kernel state for one
thread.
Integrated identity should live outside it in a workflow-owned session wrapper.

### 4. Make `agent_id` the runtime identity, not role name or conversation id

Roles describe reusable behavior.
Conversation ids help correlate external threads.
Neither should be the reducer key for integrated state.

### 5. Use `state_of/1` for routing, not opaque controller steps

Rules should explicitly inspect workflow-owned state to decide whether an agent
lane is ready, waiting, review-blocked, exhausted, or complete.

### 6. Reuse the existing control contracts

Budgets, guards, waits, reviews, and resumes should remain the Phase 3 values.
The integrated runtime adds scoping and ownership, not duplicate control
taxonomies.

### 7. Keep resume routing explicit and stable

Resume signals and review decisions should resolve through a workflow-owned
`resume_index`, not by parsing strings or assuming one active agent at a time.

### 8. Treat scheduled wake-ups as data

No live sleep loops and no hidden mailbox process should be required.
`Wait.until` plus an explicit wake signal is the durable shape.

### 9. Support both fixed and dynamic multi-agent lanes

Small reference recipes may declare a fixed set of integrated agent ids up
front, but the substrate should not require graph topology to be the only
identity story.

### 10. Borrow from libbit selectively

The libbit experiment is a useful proof that stateful rules plus accumulators
plus `state_of/1` can model retries, usage, pending tool work, and lifecycle.
RunicAI should borrow that explicitness, but keep the public substrate smaller,
more typed, and more reusable.

## Recommended Contract Layering For Phase 6

### Layer 1: Existing shared contracts

These remain the work payloads and decisions inside the integrated runtime.

- `RunicAI.Agent.State`
- `RunicAI.Agent.TurnRequest`
- `RunicAI.Agent.TurnResult`
- `RunicAI.Agent.ContinueDecision`
- `RunicAI.Tool.*`
- `RunicAI.Control.*`
- `RunicAI.Wait`
- `RunicAI.ReviewRequest`
- `RunicAI.ResumeSignal`
- `RunicAI.ReviewDecision`
- optionally reused `RunicAI.Decomposition.Role` and `RunicAI.Decomposition.Registry`

### Layer 2: Integrated identity and envelope contracts

These make workflow-owned orchestration explicit.

- `RunicAI.Integrated.AgentRef`
- `RunicAI.Integrated.Signal`
- `RunicAI.Integrated.Emission`
- `RunicAI.Integrated.PendingWork`

### Layer 3: Workflow-owned live state

These are the reducer targets for the stateful runtime.

- `RunicAI.Integrated.SessionState`
- `RunicAI.Integrated.RuntimeState`

### Layer 4: Stateful routing and recipes

These are the Runic-native pieces that make the integrated family usable.

- runtime signal normalization
- runtime reduction
- ready-lane selection and state-aware routing
- turn materialization and result reduction
- pause, resume, and wake registration
- integrated chat and tool recipes

## Recommended Public Contracts

These should be the minimum new Phase 6 contracts or contract extensions.

### `RunicAI.Integrated.AgentRef`

Purpose: durable identity and profile reference for one workflow-owned agent
lane.

Suggested fields:

- `:id`
- `:role`
- `:parent_id`
- `:conversation_id`
- `:metadata`

Notes:

- `:id` is the primary workflow-owned key and must be stable for the life of
  the lane.
- `:role` may reuse a Phase 5 `Decomposition.Role` or a simpler recipe-local
  identifier.
- `:conversation_id` is optional correlation data, not the main reducer key.

### `RunicAI.Integrated.Signal`

Purpose: normalized envelope for external input and internal runtime events.

Suggested fields:

- `:kind` -
  `:start | :receive_turn | :continue | :review_decision | :resume | :wake | :spawn | :stop`
- `:agent_id`
- `:payload`
- `:correlation_id`
- `:scheduled_for`
- `:metadata`

Notes:

- External user turns and workflow-directed commands should normally carry
  `:agent_id` directly.
- Resume and review signals may omit `:agent_id` at the input boundary if the
  runtime can resolve them through `resume_index`.
- Keep this contract small; it is an envelope, not a second turn-result schema.

### `RunicAI.Integrated.Emission`

Purpose: attach integrated identity to an externally visible outcome without
changing the underlying shared payload contracts.

Suggested fields:

- `:agent_id`
- `:kind` - `:reply | :final | :review | :wait | :handoff | :status`
- `:value`
- `:metadata`

Notes:

- The emitted `:value` should usually be an existing shared contract such as
  `TurnResult`, `ReviewRequest`, `Wait`, or `HandoffArtifact`.
- This contract is what keeps multi-agent outputs attributable without forcing
  `agent_id` onto every existing Phase 1 through Phase 5 value.

### `RunicAI.Integrated.PendingWork`

Purpose: represent the current unit of runtime-owned work for one agent lane.

Suggested fields:

- `:kind` - `:turn | :tool_batch | :review | :wait | :resume | :handoff | :spawn`
- `:request`
- `:checkpoint`
- `:resume_key`
- `:metadata`

Notes:

- `Agent.State.pending_action` remains useful as the local conversational
  kernel marker.
- `PendingWork` is the workflow-owned orchestration wrapper that says what the
  integrated runtime is actively doing next.

### `RunicAI.Integrated.SessionState`

Purpose: live workflow-owned state for one integrated agent lane.

Suggested fields:

- `:agent` - `RunicAI.Integrated.AgentRef`
- `:agent_state` - `RunicAI.Agent.State`
- `:status` -
  `:idle | :queued | :running | :waiting | :review | :completed | :halted`
- `:inbox`
- `:pending_work`
- `:control`
- `:metadata`

Notes:

- `:control` should carry the per-agent counters and scoped control ledger that
  the libbit experiment proved useful: attempts, retry counts, usage, model
  calls, tool calls, and last budget snapshot.
- Keep these control values scoped to one session so two agents in the same
  workflow cannot contaminate each other's limits or retries.
- Do not duplicate transcript history outside `:agent_state`.

### `RunicAI.Integrated.RuntimeState`

Purpose: authoritative workflow-owned state for the whole integrated runtime.

Suggested fields:

- `:agents` - `%{agent_id => SessionState}`
- `:ready_queue`
- `:resume_index` - `%{resume_key => agent_id}`
- `:scheduled`
- `:metadata`

Notes:

- `:agents` is the main source of truth.
- `:resume_index` exists so current `Wait` and `ReviewRequest` contracts can be
  reused without requiring callers to always pass both `agent_id` and
  `resume_key` on resume.
- `:scheduled` should keep enough information to translate `Wait.until` into
  explicit wake signals later.

## Recommended Module And File Layout

```text
lib/runic_ai/
  integrated/
    agent_ref.ex
    signal.ex
    emission.ex
    pending_work.ex
    session_state.ex
    runtime_state.ex
  steps/
    normalize_integrated_signal.ex
    select_ready_agent.ex
    materialize_integrated_turn.ex
    apply_integrated_turn_result.ex
    register_integrated_pause.ex
    resolve_integrated_resume.ex
    emit_integrated_value.ex
  recipes/
    integrated_agent_kernel.ex
    integrated_chat_agent.ex
    integrated_tool_agent.ex
```

Recommended contract reuse in place:

- `RunicAI.Agent.State` remains the conversation-owning kernel state.
- `RunicAI.Control.*`, `RunicAI.Wait`, `RunicAI.ReviewRequest`, and
  `RunicAI.ResumeSignal` remain the control vocabulary.
- `RunicAI.Decomposition.Role` may be reused when integrated lanes need
  reusable role profiles.

## Recommended Substrate Shape

The first Phase 6 substrate should be:

1. one authoritative `Runic.state_machine` or equivalent stateful reducer for
   `RuntimeState`
2. rules that inspect `state_of(:integrated_runtime)` to route ready work
3. ordinary existing RunicAI steps for prompt assembly, generation,
   interpretation, tool execution, budget evaluation, and guard evaluation
4. one optional audit-style accumulator for trace or emission history where it
   adds clear value

Recommendation:

- Start with a `state_machine` as the primary substrate.
- Use `ProcessManager` only if it clearly simplifies queued signal handling or
  scheduled wake coordination after the state-machine path is proven.
- Avoid making "many separate public accumulators per concern" the main library
  interface.

That gives the library one authoritative runtime state while still staying very
close to Runic's native stateful building blocks.

## Implementation Workstreams

### Workstream 1 - Freeze Identity, Envelope, And Runtime-State Contracts

Outcome: the stateful recipe family has explicit public nouns before wiring
recipes around them.

Deliverables:

- [ ] Add `RunicAI.Integrated.AgentRef`, `Signal`, `Emission`,
      `PendingWork`, `SessionState`, and `RuntimeState`.
- [ ] Decide the allowed lifecycle statuses for integrated sessions.
- [ ] Decide the minimum required `control` ledger shape inside
      `SessionState`.
- [ ] Decide how `resume_index` is maintained and invalidated.
- [ ] Document the identity rule that `agent_id` is primary and
      `conversation_id` is secondary.

Implementation notes:

- Keep `Agent.State` unchanged.
- Keep `agent_id` out of `TurnRequest` and `TurnResult`; it belongs in the
  integrated envelope layer.
- Prefer small structs plus helper APIs over recipe-local loose maps.

### Workstream 2 - Build The Runtime Reducer And State-Aware Routing Layer

Outcome: the workflow can accept signals, reduce them into state, and route the
next unit of work using `state_of/1`.

Deliverables:

- [ ] Add the authoritative integrated runtime state machine.
- [ ] Handle at least:
      `:start`, `:receive_turn`, `:continue`, `:review_decision`,
      `:resume`, `:wake`, and `:stop`.
- [ ] Add state-aware rules for:
      ready-to-run, blocked-on-review, blocked-on-wait, exhausted, and
      completed lanes.
- [ ] Add helper steps for signal normalization and ready-agent selection.
- [ ] Add tests proving that routing decisions only touch the targeted
      `agent_id`.

Implementation notes:

- When we say "reducer" in this context we usually mean Runic.accumulator and not a Runic.reduce which is for map/reduce operations and have a different use case
- Prefer explicit rules with `state_of(:integrated_runtime)` over one opaque
  "runtime controller" step.
- Let the reducer own queue mutation and lifecycle transitions.
- Keep any optional audit accumulator read-only from the routing perspective.

### Workstream 3 - Reuse The Existing Conversational Kernel Inside The Integrated Lane

Outcome: RunicAI can offer a workflow-owned chat loop without an external
recursive caller.

Deliverables:

- [ ] Add a step that projects one `SessionState` into an ordinary
      `RunicAI.Agent.TurnRequest`.
- [ ] Reuse `AssembleTurnPrompt`, `GenerateTurn`, `InterpretTurn`, and
      `ContinueChat` inside the integrated recipe.
- [ ] Add a reducer step that applies `TurnResult` and `ContinueDecision` back
      into the owning `SessionState`.
- [ ] Emit `Integrated.Emission` values for replies and final answers.
- [ ] Add a reference `RunicAI.Recipes.IntegratedChatAgent`.

Implementation notes:

- The integrated runtime owns the loop.
- The shared conversational kernel still owns turn semantics.
- This is the first point where the phase proves it is additive rather than a
  replacement track.

### Workstream 4 - Add Tool Execution And Phase 3 Control Semantics

Outcome: the integrated recipe family can do the narrow useful tool-agent work
without losing the shared control surface.

Deliverables:

- [ ] Reuse `SelectTools`, `AttachVisibleTools`, `PlanToolExecution`,
      `ExecuteToolCalls`, `ReduceToolResults`, and `AppendToolObservations`
      inside the integrated runtime.
- [ ] Reuse `EvaluateBudget`, `EvaluateGuard`, `ApplyReviewDecision`, and
      `NormalizeResumeSignal`.
- [ ] Register emitted `Wait` and `ReviewRequest` values in `resume_index`.
- [ ] Clear or update `resume_index` when review or resume flows complete.
- [ ] Track attempts, retries, tool counts, model counts, and token usage in
      `SessionState.control`.
- [ ] Add a reference `RunicAI.Recipes.IntegratedToolAgent`.

Implementation notes:

- `RunicAI.Control.BudgetSnapshot` should remain the canonical summarized
  budget view.
- The integrated runtime should scope these control values per `agent_id` even
  when several agents share the same workflow.
- This is where the libbit-inspired control ledger belongs, but in a typed
  session wrapper rather than several unrelated public accumulators.

### Workstream 5 - Add Multi-Agent Lane Management And Spawn/Handoff Integration

Outcome: more than one integrated agent can live inside the same workflow
without crossing conversation or control state.

Deliverables:

- [ ] Support fixed integrated lane declarations for reference recipes.
- [ ] Support dynamic lane creation with stable generated `agent_id` values.
- [ ] Allow a handoff or spawn decision to become a new `Signal` or
      `PendingWork` targeting another lane.
- [ ] Reuse Phase 5 role defaults where they fit for lane creation.
- [ ] Add tests covering two or more integrated agents in one workflow with
      independent queues, waits, and budgets.

Implementation notes:

- Do not use workflow component names as the durable agent identity.
- Distinguish reusable role/profile configuration from live lane identity.
- Phase 5 child-task ids and Phase 6 `agent_id` values may be related, but they
  are not the same concept.

### Workstream 6 - Add Durable Wait, Scheduled Wake, And Queued Interaction Patterns

Outcome: a generic Runic runner can drive the stateful recipes durably without
specialized agent process code.

Deliverables:

- [ ] Show queued-turn behavior where turns can accumulate while one lane is
      busy or waiting.
- [ ] Show scheduled wake behavior using `Wait.until` plus explicit `:wake`
      signals.
- [ ] Add one example of deferred continuation after a wait or review.
- [ ] Document how `Workflow.prepare_for_dispatch/1`,
      `Workflow.apply_runnable/2`, or `Runic.Runner` can drive the recipe.
- [ ] Add tests covering wake routing and resumed execution for the correct
      `agent_id`.

Implementation notes:

- Waiting should be represented as state plus emitted `Wait`, not as sleeping
  code.
- Libbit or any other generic workflow runner should be able to persist the
  workflow and later feed it another signal.

### Workstream 7 - Reference Recipes, Documentation, And Verification

Outcome: the phase is teachable and safe to build on.

Deliverables:

- [ ] Publish `IntegratedAgentKernel`, `IntegratedChatAgent`, and
      `IntegratedToolAgent` reference recipes.
- [ ] Add docs explaining when to choose the integrated stateful track versus
      the turn-processor track.
- [ ] Update README and phase docs so the new recipe family is discoverable.
- [ ] Add contract, routing, recipe, and multi-agent isolation tests.
- [ ] Add at least one provider-backed manual verification path.

Implementation notes:

- The docs should make the coexistence story explicit:
  turn-processor recipes for caller-owned state, integrated recipes for
  workflow-owned state.
- The recipes should feel like thin workflow assemblies over shared contracts,
  not a parallel framework.

## Recommended Implementation Sequence

1. Freeze the integrated identity and state contracts first.
2. Land the runtime reducer and state-aware routing second.
3. Prove the integrated chat kernel third.
4. Add tool orchestration and Phase 3 controls fourth.
5. Add multi-agent lane management fifth.
6. Add queued, wait, and scheduled-wake patterns sixth.
7. Finish with docs, verification, and reference recipes.

## Recommended Early Decisions

These decisions are worth making before implementation starts so the phase does
not sprawl.

1. Use a `RunicAI.Integrated.*` namespace for the new workflow-owned recipe
   family.
   This keeps the lane additive and avoids overloading the existing
   `RunicAI.Agent.*` contracts with workflow-runtime concerns.
2. Make `agent_id` the stable runtime primary key.
   Do not overload `role`, `conversation_id`, or `resume_key` as the identity
   of an integrated lane.
3. Keep `Agent.State` as the local conversational kernel state.
   Identity, mailboxes, and control scoping belong in the integrated session
   wrapper around it.
4. Use one authoritative `RuntimeState` keyed by `agent_id`.
   Do not make conversation, usage, retry, and review routing separate public
   keyed accumulators unless a later need proves that split necessary.
5. Preserve the Phase 3 public control contracts.
   Route `ResumeSignal` and `ReviewDecision` through `resume_index` rather than
   forcing users to learn a second integrated-only resume contract.
6. Emit identity-carrying outputs through `Integrated.Emission`.
   This is the cleanest way to make multi-agent outputs attributable while
   leaving earlier public contracts intact.
7. Start with `state_machine` as the default substrate.
   Add `ProcessManager` only if queued signal orchestration or wake management
   clearly becomes simpler with it.
8. Keep generic runner compatibility as a hard requirement.
   The workflow should be drivable by Runic's normal prepare/execute/apply
   model or `Runic.Runner`, not a custom always-on agent process.

## Verification Plan

Phase 6 should be considered complete only when the following verification work
is done.

- [ ] Contract tests for `Integrated.AgentRef`, `Signal`, `Emission`,
      `PendingWork`, `SessionState`, and `RuntimeState`.
- [ ] Runtime reducer tests covering start, receive turn, continue, review,
      resume, wake, and stop signals.
- [ ] State-aware routing tests proving rules match only the targeted lane and
      do not leak control state across agents.
- [ ] Resume-index tests covering both review and wait flows.
- [ ] Integrated chat recipe tests covering repeated turns without an external
      recursive loop.
- [ ] Integrated tool recipe tests covering tool execution, budget checks,
      waits, and reviews.
- [ ] Multi-agent isolation tests covering at least two concurrent agent lanes
      in one workflow with independent conversation and control state.
- [ ] Scheduled wake and queued interaction tests.
- [ ] At least one provider-backed manual verification run showing a workflow-
      owned conversation that pauses and resumes through the integrated runtime.
- [ ] Documentation updates explaining the track choice and the identity model.

## Out Of Scope For This Phase

Keep these out of Phase 6 so the integrated substrate lands coherently.

- No mandatory specialized agent server, mailbox process, or bespoke runtime
  topology.
- No provider-owned assistant thread API should become the core abstraction.
- No full Phase 7 observability and evaluation suite is required yet.
- No distributed queue or external scheduler service is required yet.
- No requirement that every multi-agent workflow migrate from the Phase 5
  decomposition model into the integrated stateful model.
- No broad expansion of `Agent.State` into a giant workflow-runtime struct.

## Exit Criteria

Phase 6 is complete when all of the following are true.

- [ ] RunicAI has a workflow-owned stateful recipe substrate built from Runic
      stateful primitives and explicit `state_of/1` routing.
- [ ] The integrated substrate reuses the shared turn, tool, and control
      contracts instead of replacing them.
- [ ] A stable `agent_id`-based identity model exists for one or many agent
      lanes in the same workflow.
- [ ] Chat and tool workflows can run as workflow-owned recipes without an
      external recursive loop deciding whether to submit another turn.
- [ ] Wait, review, and resume flows work inside the integrated runtime with
      correct per-agent scoping.
- [ ] Generic Runic workflow runners can execute and persist the recipes
      without a custom agent process topology.
- [ ] The docs make it obvious when to choose the integrated stateful track and
      when to keep using the external-state turn-processor track.
