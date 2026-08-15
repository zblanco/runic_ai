# RunicAI Workflow-Native Agent Roadmap

Status: draft roadmap

Date: 2026-04-19

References:
- `.docs/001-poc-llm-components.md`
- `.docs/010-react-vs-rlm-for-workflow-native-agent-composition.md`
- `/home/doops/wrk/libbit/.docs/agentic-composition-coverage-proposal.md`
- `https://papers.voltropy.com/LCM`
- `https://ampcode.com/news/handoff`
- `https://github.com/mssteuer/lossless-hermes-py`
- `https://arxiv.org/abs/2512.24601`
- `https://arxiv.org/abs/2603.20105`

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic HexDocs overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic workflow API:
  `https://hexdocs.pm/runic/Runic.Workflow.html`
- Official Runic package README:
  `https://hexdocs.pm/runic/readme.html`
- Tidewave lookup keys worth keeping handy:
  `Runic`, `Runic.Workflow`, `Runic.rule/1`, `Runic.map/2`,
  `Runic.reduce/3`, `Runic.accumulator/3`, `Runic.state_machine/1`

## Goal

Build RunicAI into a utility library of typed, composable Runic components that
let users assemble conversational agents, tool-using assistants, multi-agent
workflows, RAG pipelines, context-management systems, and control/guard layers
without introducing a bespoke "agent runtime" as the primary abstraction.

The key product shape is:

- Runic components first
- agent recipes second
- optional ergonomic wrappers last

## Recipe Tracks

RunicAI should deliberately support two recipe families:

1. Turn-processor recipes:
   the workflow processes one turn, returns typed results, and leaves
   persistence/runtime topology to the caller.
2. Workflow-owned stateful recipes:
   the workflow itself holds evolving state via accumulators, state machines,
   FSMs, or process-manager style components when users want a more concrete
   actor/runtime model.

These are complementary, not competing directions.
The second track should arrive as an additive recipe family, not as a migration
away from the persistence-agnostic turn processor model.

The target is to reach the useful capabilities people like in `sagents`
especially the clear conversational loop, tool calling, middleware-like control
points, budgets, waits, review gates, and observability, while leaning into what
Runic does better: explicit dataflow, inspectable state transitions, and
parallel workflow branches.

## Roadmap Priorities

### Priority 1: Sagents-style parity on a workflow substrate

These phases deliver the narrow but very useful "conversational LLM agent with
tool calling" capability:

1. Phase 0 - Contracts and core substrate
2. Phase 1 - Conversational loop kernel
3. Phase 2 - Tool calling and capability execution
4. Phase 3 - Controls, guards, and operator interaction

### Priority 2: Workflow-native expansion

These phases take the library beyond a single-agent loop:

5. Phase 4 - Retrieval, memory, and context management
6. Phase 5 - Multi-agent and decomposition workflows
7. Phase 6 - Stateful integrated agent recipes

### Priority 3: Hardening and improvement

These phases make the library operable and tunable:

8. Phase 7 - Observability, testing, and evaluation

### Priority 4: Advanced and optional lanes

These phases should stay explicitly later so the core library stays coherent:

9. Phase 8 - Advanced runtime adapters and optimization hooks
10. Phase 9 - RLM execution mode and recursive long-context workflows

## Architectural Rules To Keep Stable

- Runic workflows and components remain the execution substrate.
- The persistence-agnostic turn processor model remains a first-class public
  recipe family.
- Workflow-owned stateful agent recipes are a future additive lane, not a
  replacement for the external-state model.
- A "stateful agent" is a recipe composed from steps, rules, accumulators, and
  state machines, not a separate runtime ontology.
- Workflow-owned stateful recipes should reuse the same public turn, tool,
  guard, wait, and review contracts wherever possible rather than inventing a
  disconnected runtime-only vocabulary.
- Every public component should have a clear typed input/output contract,
  preferably a small public struct or a validated typed map with typespecs.
- Policies such as model choice, tool visibility, budget limits, and review
  behavior should be injected as data, not hidden in prompts.
- Control points must be explicit and inspectable: continue, stop, wait, retry,
  review, handoff, and spawn should exist as workflow semantics, not just
  prompt conventions.
- Provider-specific integrations should sit behind adapters so the core library
  stays useful with just Runic plus ReqLLM and user-supplied functions.
- Any future RLM execution mode should remain an optional adapter or recipe
  family layered on the same public contracts, not a replacement for the
  workflow-native substrate or a new mandatory runtime ontology.

## Phase 0 - Contracts And Core Substrate

Priority: P0

Outcome: later components can compose cleanly because the public data shapes and
result semantics are stable.

This phase should absorb the current POC work and turn it into a durable
foundation instead of a one-off set of LLM helpers.

- [ ] Define the canonical public contracts for the library.
      At minimum this should cover message history, conversation state, prompt
      bundle, agent turn result, tool request, tool result, guard decision,
      retrieval query/result, memory entry, child task, and trace event.
- [ ] Standardize result envelopes and error taxonomy across components.
      A workflow step should not invent a fresh return shape for every feature;
      success, retryable failure, terminal failure, wait, and review-needed
      outcomes need consistent representation.
- [ ] Finish the core LLM access layer as a stable public facade.
      `RunicAI.LLM` and the current POC steps should become the base dependency
      for later phases rather than being bypassed by new agent modules.
- [ ] Define policy injection conventions.
      Establish how components receive model policy, tool policy, budget policy,
      and runtime opts through plain data and Runic run context.
- [ ] Add validation helpers for contract boundaries.
      Inputs should fail early and clearly when a workflow wires incompatible
      components together.
- [ ] Publish one reference recipe that proves the contracts fit together.
      A small chat workflow using prompt assembly, LLM invocation, conversation
      accumulation, and explicit stop rules is enough for this phase.

Exit from this phase when a later plan can describe agent features in terms of
shared contracts instead of ad hoc maps.

## Phase 1 - Conversational Loop Kernel

Priority: P0

Outcome: users can build a stateful conversational assistant entirely from
Runic components, even before tool calling is added.

- [ ] Build a reusable agent-state accumulator or state machine.
      It should track conversation history, turn count, stop state, outstanding
      action, and any scoped scratch data needed for the next step.
- [ ] Add prompt/context assembly components for a turn.
      These should combine system instructions, conversation window, pinned
      context, optional retrieved material, and optional tool observations into
      one model-ready bundle.
- [ ] Add a structured turn-generation step.
      The model-facing output should be normalized into a typed turn result such
      as assistant reply, final answer, tool requests, wait request, handoff
      request, or failure.
- [ ] Add explicit continuation and termination rules.
      Max turns, final-answer contract, stop token, guard-triggered stop, and
      invalid-turn recovery should all be represented as workflow semantics.
- [ ] Add history repair and turn normalization.
      This should make malformed or partial model outputs safe to feed back into
      the workflow without forcing every recipe to patch them manually.
- [ ] Provide a reference "chat agent kernel" workflow.
      This recipe should demonstrate the minimal stateful agent loop shape that
      later phases extend.

Exit from this phase when RunicAI has a clear answer to "how do I build a
conversation-driven stateful agent without writing my own loop?"

## Phase 2 - Tool Calling And Capability Execution

Priority: P0

Outcome: users can assemble a conventional conversational tool agent that is
roughly the core `sagents` experience, but as a workflow recipe.

- [ ] Define the tool contract and registry surface.
      A tool should have stable metadata, parameter schema, execution callback,
      timeout policy, and normalized result shape.
- [ ] Add a component that exposes a selected tool set to a model turn.
      Tool visibility needs to be explicit so workflows can vary available
      capabilities by state, role, or policy.
- [ ] Add a tool-execution step with normalized observations.
      Tool calls should validate input, execute through a single adapter path,
      and emit structured observations that can be appended to agent state.
- [ ] Support iterative tool-use turns.
      A workflow should be able to loop through model -> tool request -> tool
      execution -> updated context -> next model turn until completion.
- [ ] Add fallback behavior for tool failures.
      Retryable failures, user-visible errors, alternate tool routes, and
      forced stop behavior should be composable rather than buried in one loop.
- [ ] Publish a reference "conversational tool agent" recipe.
      This recipe is the main parity milestone for a workflow-native replacement
      of the narrow agent-loop abstraction.

Exit from this phase when a user can define an agent with tools, policies, and
conversation state using only RunicAI contracts and Runic workflows.

## Phase 3 - Controls, Guards, And Operator Interaction

Priority: P0

Outcome: the agent loop becomes governable, inspectable, and safe enough for
real operator-facing workflows.

- [ ] Add budget gate components.
      These should enforce limits on turns, tool calls, model calls, estimated
      spend, elapsed time, and recursion depth.
- [ ] Add guard components around risky actions.
      Pre-tool, post-tool, pre-answer, and pre-handoff guard points should be
      first-class so workflows can insert policy checks without rewriting the
      recipe.
- [ ] Add review-gate components for human approval or edit.
      Users should be able to pause a workflow before a sensitive tool call or
      before a final answer and resume it with an explicit decision object.
- [ ] Add durable wait/resume primitives.
      Waiting for user input, an external signal, or a scheduled wake-up should
      be represented as workflow state, not as an ad hoc process concern.
- [ ] Add retry and fallback policy wrappers.
      Retries, backoff, alternate model selection, alternate tool routing, and
      graceful degradation should become reusable wrappers around core steps.
- [ ] Publish a guarded operator-agent recipe.
      This recipe should show clear read/write policy differences, review gates,
      wait states, and budget exhaustion behavior.

Exit from this phase when RunicAI can express explicit budgets, waits, review
gates, and fallback logic as composable workflow concerns.

## Phase 4 - Retrieval, Memory, And Context Management

Priority: P1

Outcome: users can build RAG and memory-aware agents without collapsing all
state into one growing conversation blob.

- [ ] Define retrieval query and retrieval result contracts.
      These should work across lexical, embedding, graph, or user-defined
      retrieval backends without making the rest of the workflow backend-aware.
- [ ] Add context-bundle assembly components.
      A workflow needs a standard way to merge recent conversation, pinned
      facts, retrieved evidence, memory entries, and tool observations.
- [ ] Add memory write/read components.
      The initial target should be episodic memory and simple semantic memory,
      both with provenance so later turns know where context came from.
- [ ] Add summarization and compaction components.
      Token pressure and long-running sessions should be handled through
      explicit summarization and context reduction steps rather than hidden
      truncation.
- [ ] Add retrieval-aware answer and tool-agent recipes.
      At least one recipe should show direct answer generation from retrieved
      context and another should show a tool agent that retrieves before acting.
- [ ] Add lineage-friendly context metadata.
      Compacted or retrieved context should retain enough provenance for later
      inspection, replay, or targeted expansion.

Exit from this phase when users can choose between plain chat history, RAG,
summary-backed context, and memory-backed context using the same workflow model.

## Phase 5 - Multi-Agent And Decomposition Workflows

Priority: P1

Outcome: RunicAI starts using Runic's real advantage over a single-process agent
loop: explicit branching, child workflows, and parallel reduction.

- [x] Define child-task and handoff contracts.
      Parent and child branches should exchange a stable task description,
      scoped context, budgets, expected output contract, and status/result data.
- [x] Add spawn and join recipes for child workflows.
      A parent workflow should be able to launch children, await results, and
      reduce them deterministically without inventing custom orchestration each
      time.
- [x] Add fan-out and reduction helpers for parallel subproblems.
      File-by-file analysis, source gathering, plan-step execution, and judge
      ensembles are all natural fits for workflow-native parallelism.
- [x] Add role-specialized recipe templates.
      Planner/executor, researcher/synthesizer, reviewer/editor, and
      planner/executor/judge are good early compositions because they make the
      branching model concrete.
- [x] Add scoped inheritance rules for policy and context.
      Children should inherit only the budgets, tools, memory scope, and
      context slices they actually need.
- [x] Publish one multi-agent reference workflow.
      The milestone recipe should show parent planning, parallel child work, a
      join step, and a reviewer or judge branch before final completion.

Exit from this phase when multi-agent behavior feels like a natural extension of
the same contracts used for single-agent workflows.

## Phase 6 - Stateful Integrated Agent Recipes

Priority: P1

Outcome: users can choose a workflow-owned, stateful agent recipe when they
want a more integrated actor/process shape, while still building from the same
typed contracts and Runic components as the turn-processor track.

Reference: `/home/doops/wrk/libbit/apps/core/lib/core/agents/runic_agent_loop.ex

- [ ] Publish a stateful recipe substrate built from Runic-native stateful
      components.
      Accumulators, state machines, FSMs, process managers, and state-aware
      routing, including meta conditions such as `state_of/1` where it fits,
      should become the main building blocks for this recipe family.
- [ ] Define the integrated-agent state contract layering.
      The recipe should keep shared public contracts for messages, turns, tool
      batches, guards, waits, and reviews while adding only the minimal extra
      recipe-owned state needed for inbox, pending work, and lifecycle control.
- [ ] Add stateful loop recipes for chat and tool-using agents.
      At minimum this phase should prove a workflow-owned chat loop and a
      workflow-owned tool loop that hold evolving state inside the workflow
      rather than requiring the caller to persist and resubmit it every turn.
- [ ] Add explicit lifecycle controls for integrated recipes.
      Start, receive turn, enqueue work, continue, suspend, resume, and stop
      should all be represented as workflow semantics rather than hand-rolled
      process logic around the workflow.
- [ ] Add state-aware control recipes using the same Phase 3 contracts.
      Budget checks, guard points, review gates, and waits should compose into
      the stateful recipe family without requiring duplicate control modules.
- [ ] Add examples of durable and scheduled interaction patterns.
      This phase should show how the same stateful recipe can support queued
      turns, deferred work, scheduled wake-ups, or external resume signals while
      staying persistence-agnostic at the library boundary.
- [ ] Publish one reference "integrated stateful agent" recipe.
      The milestone recipe should make it obvious when a user should choose this
      track over the external-state turn processor model and how both can
      coexist cleanly in the same library.

Exit from this phase when RunicAI can offer workflow-owned stateful agent
recipes as an additive option built from the same contracts and controls as the
turn-processor track.

## Phase 7 - Observability, Testing, And Evaluation

Priority: P1

Outcome: agent recipes become debuggable, benchmarkable, and safer to evolve.

- [ ] Define a structured trace/event model for all major transitions.
      Turns, tool calls, guard decisions, waits, resumes, child branches, and
      final outcomes should emit uniform events.
- [ ] Add deterministic testing helpers.
      Fake LLMs, fake tools, canned retrieval backends, and trace assertions
      should make workflow tests easy to write without process-heavy machinery.
- [ ] Add trajectory capture and replay support.
      Users should be able to inspect an execution after the fact and replay key
      branches during debugging.
- [ ] Add evaluator workflow patterns.
      Batch evaluation of prompts, agents, or recipes over a fixture dataset
      should use the same component substrate rather than a separate framework.
- [ ] Add regression metrics for quality, latency, and cost.
      The point is not only visibility, but also a stable way to compare recipe
      changes over time.
- [ ] Publish an evaluation harness example.
      A simple benchmark over a conversational tool agent or a retrieval recipe
      is enough to set the pattern.

Exit from this phase when RunicAI users can confidently answer "what happened,
why did it happen, and did this change improve the agent?"

## Phase 8 - Advanced Runtime Adapters And Optimization Hooks

Priority: P2

Outcome: the library can support more ambitious workflows without forcing these
concerns into the early core.

- [ ] Add optional runtime-execution adapters behind the same tool contract.
      Command execution, sandboxed work, background jobs, or external workers
      should remain adapters layered under workflow-visible capabilities.
- [ ] Add long-horizon context-management extensions.
      Persistent summary graphs, context lineage, selective expansion, and other
      long-session features belong here after the simpler memory model is solid
      and should prepare later specialized execution modes rather than becoming
      hidden runtime assumptions.
- [ ] Add candidate/version hooks for recipe evolution.
      This should support side-by-side recipe variants, benchmark runs, and
      promotion decisions without making the serving path self-modifying.
- [ ] Add optimization integration points.
      Reflection loops, prompt/program optimization, and offline tuning systems
      should plug into traces and evaluators rather than reshaping the runtime.
- [ ] Package opinionated recipe bundles and LiveBook examples.
      Once the substrate is stable, curated examples become the fastest way to
      help users build real systems from the library.

Exit from this phase when advanced execution and optimization capabilities can
be added as layers instead of infecting the core abstractions.

## Phase 9 - RLM Execution Mode And Recursive Long-Context Workflows

Priority: P2

Outcome: RunicAI can optionally execute workflows in an RLM-inspired mode that
externalizes large prompt state, recursively delegates over scoped slices, and
composes those recursive calls through the same typed contracts introduced in
earlier phases.

- [ ] Define an RLM execution-mode adapter contract.
      It should describe how a root workflow interacts with an externalized
      prompt/context environment, bounded execution metadata, recursive child
      invocation, and final materialized outputs without changing the base
      public turn, handoff, and child-task contracts.
- [ ] Reuse Phase 4 and Phase 5 contracts as the control surface.
      `Context.Bundle`, `Context.HandoffArtifact`, `Decomposition.Task`,
      `Decomposition.Assignment`, `Decomposition.Result`, and the existing
      control contracts should remain the public vocabulary for scoped
      recursion rather than inventing a disconnected RLM-only type system.
- [ ] Add prompt-as-environment adapters.
      Large documents, corpora, repositories, or other long-context inputs
      should be exposable as externalized state that workflows can inspect by
      reference instead of copying wholesale into the root model window.
- [ ] Add recursive execution primitives and typed combinators.
      Partition, map, reduce, score, select, and similar bounded operators
      should provide the first safe recursive substrate, keeping the initial
      mode closer to a typed lambda-RLM style runtime than to a raw open-ended
      REPL.
- [ ] Add control and budget hooks specific to recursive execution.
      Recursion depth, child-call counts, external-environment access, bounded
      metadata return, waits, and review gates should all remain explicit
      workflow-visible policy points.
- [ ] Publish one RLM-mode reference workflow.
      The milestone recipe should show externalized context, recursive child
      work over scoped slices, deterministic reduction, and final synthesis
      over an input too large or too noisy for a naive single-thread prompt
      path.

Exit from this phase when RunicAI can offer an optional RLM-inspired execution
mode that scales long-context decomposition and recursive delegation without
turning a bespoke recursive runtime into the library's primary abstraction.

## Suggested Sequencing For Implementation Docs

Each future implementation-plan document should answer the same questions:

- What public contracts are introduced or stabilized?
- Which Runic component types are used for the feature?
- What recipe becomes possible when this phase lands?
- What policies are configurable as data?
- What is the smallest reference workflow that proves the design?
- What tests and traces prove the behavior?

That structure should keep the roadmap actionable while preserving the main
architectural idea: RunicAI is a library of composable workflow parts from which
agents are built, not a narrow loop runtime that everything else has to orbit.
