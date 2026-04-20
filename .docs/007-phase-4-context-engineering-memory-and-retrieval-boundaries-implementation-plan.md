# Phase 4 Implementation Plan: Context Engineering, Memory, And Retrieval Boundaries

Status: implemented

Date: 2026-04-17

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`

References:
- `.docs/002-workflow-native-agent-roadmap.md`
- `https://papers.voltropy.com/LCM`
- `https://ampcode.com/news/handoff`
- `https://github.com/mssteuer/lossless-hermes-py`

## Progress

- [x] Implemented the Phase 4 context contracts, graph/state substrate,
      context steps, and reference recipes for summary-backed chat, memory-aware
      tool use, and handoff artifact construction.
- [x] Re-centered the roadmap item on context engineering first, memory second,
      retrieval adapters third, keeping retrieval backend-neutral and dependency
      light in the core library.
- [x] Added focused coverage for context graph contracts, pressure evaluation,
      compaction, bundle assembly, memory writes, retrieval wiring, and the new
      Phase 4 recipes.
- [x] Updated the roadmap references, README, and top-level library docs so the
      context layer is discoverable alongside the Phase 1 through Phase 3
      kernels.

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic HexDocs overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic workflow API:
  `https://hexdocs.pm/runic/Runic.Workflow.html`
- Official Runic package README:
  `https://hexdocs.pm/runic/readme.html`
- Tidewave lookup keys:
  `Runic`, `Runic.Workflow`, `Runic.accumulator/3`,
  `Runic.state_machine/1`, `Runic.map/2`, `Runic.reduce/3`, `Multigraph`

## Goal

Build the first workflow-native context-engineering layer on top of the Phase 0
through Phase 3 substrate so users can model long-running agent context as
explicit state, graph rewrites, and typed bundle assembly rather than as one
ever-growing transcript plus hidden truncation.

Phase 4 is successful when RunicAI has a clear, composable answer to:

"How do I keep a long-running workflow coherent under context pressure,
compact or hand off state intentionally, recall prior decisions through typed
memory, and optionally integrate external retrieval without hardwiring vector
stores, search engines, or database choices into the core library?"

## Current Starting Point

Phase 3 gives us a governed single-agent substrate:

- `RunicAI.Agent.State`
- `RunicAI.Agent.TurnRequest`
- `RunicAI.Agent.TurnResult`
- `RunicAI.Agent.ContinueDecision`
- `RunicAI.Tool.*` contracts and execution planning
- `RunicAI.Control.*` policies, waits, reviews, retries, and handoff guard
  points
- `RunicAI.Recipes.ChatAgentKernel`
- `RunicAI.Recipes.ConversationalToolAgent`
- `RunicAI.Recipes.GuardedOperatorToolAgent`

What is still missing is the context layer that sits between raw transcript
history and model prompt assembly:

- a durable context state distinct from transcript history
- focus and salience contracts that make "what matters now?" explicit data
- context-window pressure evaluation and explicit relief strategies
- compaction as a typed workflow operation rather than hidden truncation
- handoff artifacts that concretize `TurnResult.kind == :handoff`
- memory models with provenance and typed recall
- retrieval seams that stay backend-neutral and dependency-light
- lineage metadata strong enough to support replay, inspection, and selective
  expansion later

## Why This Phase Matters

Phase 3 answered "under what conditions may the workflow proceed?"

Phase 4 needs to answer "what should the workflow remember, what should it keep
in the active window, what should it compact, what should it surface for the
next turn, and when should it stop stretching one thread and instead emit a
focused handoff?"

That answer is where context engineering belongs.
Retrieval is part of it, but it is not the center of gravity.

The maintainable shape we want is:

1. the transcript remains immutable source-of-truth state
2. the active context is a derived state with explicit lineage
3. focus is a first-class value that guides selection and summarization
4. compaction and handoff are explicit state transitions
5. memory writes and recalls are typed transformations with provenance
6. retrieval is an adapter-fed input into context assembly, not the library's
   hidden runtime
7. prompt construction is the final projection of selected context, not the
   storage model itself

This is also where Runic and LCM fit together unusually well.
LCM's core move is to replace naive truncation and opaque prompt stuffing with
deterministic engine-managed operators such as summary DAG compaction,
selective expansion, and explicit active-window assembly.
That is philosophically close to Runic already: keep state and control flow
explicit, move orchestration into inspectable dataflow, and isolate effectful
model calls inside a larger deterministic graph.

In category-theoretic terms, Phase 4 should preserve composition by making
context work a sequence of explicit morphisms over typed state:

`transcript -> context state -> selected bundle -> prompt`

The stochastic summarizer remains one effect boundary inside that chain, but
graph rewrites, lineage maintenance, pressure decisions, and bundle assembly
remain deterministic and inspectable.

## Context Composition Model

Phase 4 should make context management readable as a chain of named
transformations:

```text
Agent.State + latest turn/tool outputs
  -> Context ingest
  -> Context.State
  -> Focus
  -> MemoryWrite[]
  -> Context.State'
  -> PressureSnapshot
  -> PressureDecision
  -> CompactionPlan | HandoffRequest | Continue
  -> Context.State''
  -> MemoryRecallResult
  -> RetrievalResult
  -> Context.Bundle
  -> Prompt
  -> LLM.Request
```

The companion handoff path should be equally explicit:

```text
Context.State + Focus(next goal)
  -> HandoffRequest
  -> HandoffArtifact
  -> new-thread seed prompt/messages + references + open questions
```

The key design rule is that active context is not the same thing as transcript
history, and retrieval is not the same thing as memory.

- Transcript history is the durable event log.
- Context state is a derived navigational structure over that history.
- Memory is distilled state written with provenance.
- Retrieval is context imported from outside the current conversation boundary.

All four must compose without collapsing into one giant map or one giant prompt
string.

## Design Principles

### 1. Keep transcript truth separate from derived context

`RunicAI.Conversation.State` remains the immutable conversational truth.
Context engineering operates on top of that truth and never replaces it.

### 2. Treat active context as state, not as prompt text

The prompt is an output projection.
The real Phase 4 state is the context graph, selected refs, summaries, memory
entries, and retrieval evidence that can be reassembled differently on later
turns.

### 3. Make focus and salience explicit data

The current goal, unresolved questions, task constraints, and optional guidance
for salience should travel as typed values.
Do not bury "what matters now" only inside prompt prose.

### 4. Define losslessness precisely

"Lossless" should mean recoverable provenance to original content, not that any
one summary text literally contains every detail.
Compaction may compress representation, but the system should retain stable
refs back to original transcript items, tool observations, or artifacts.

### 5. Isolate stochastic summarization inside deterministic graph updates

Summary generation is effectful and probabilistic.
Chunk selection, threshold evaluation, graph insertion, lineage edges, and
bundle assembly should remain deterministic around that boundary.

### 6. Prefer graph-shaped context state over flat history slices

Long-running sessions are not just a list.
They include temporal order, summary ancestry, memory provenance, tool output
lineage, and handoff ancestry.
`Multigraph` is a good internal substrate for this as long as public contracts
wrap it cleanly.

### 7. Keep retrieval backend-neutral and dependency-light

RunicAI should own retrieval query and result contracts, not a specific vector
store, embedding provider, or search server.
Core retrieval support should stop at contracts, adapters, normalization steps,
and examples.

### 8. Keep memory provenance-first and type-aware

Episodic, semantic, and temporal memory should be represented explicitly.
Each memory entry should say what source content justified it and how long it
should be trusted.

### 9. Treat handoff as a first-class context transform

Handoff is not just a special summary string.
It is a goal-conditioned projection from one context state into a new scoped
starting bundle for another thread or child workflow.

### 10. Fit both recipe tracks

The new contracts should work with the current external-state turn-processor
model and with the later workflow-owned stateful recipe family.
Nothing in this phase should require a particular process topology.

## Recommended Contract Layering For Phase 4

### Layer 1: Immutable transcript and source events

These remain the truth layer.

- `RunicAI.Conversation.State`
- `RunicAI.Message`
- tool observations, reviews, waits, and resume events already introduced in
  earlier phases

### Layer 2: Derived context state and lineage

These describe the context engine's durable view over that truth.

- `RunicAI.Context.State`
- `RunicAI.Context.Node`
- `RunicAI.Context.Ref`
- `RunicAI.Context.Focus`

### Layer 3: Window control and active-bundle assembly

These describe how context becomes model-ready under a budget.

- `RunicAI.Context.Bundle`
- `RunicAI.Context.WindowPolicy`
- `RunicAI.Context.PressureSnapshot`
- `RunicAI.Context.PressureDecision`
- `RunicAI.Context.CompactionPolicy`
- `RunicAI.Context.HandoffRequest`
- `RunicAI.Context.HandoffArtifact`

### Layer 4: Memory and retrieval boundaries

These supply additional context sources without redefining the whole model.

- `RunicAI.Memory.Entry`
- `RunicAI.Memory.Query`
- `RunicAI.Memory.ReadResult`
- `RunicAI.Retrieval.Query`
- `RunicAI.Retrieval.Document`
- `RunicAI.Retrieval.Result`
- small adapter behaviours for memory stores and retrieval providers

### Layer 5: Context-native steps and recipes

These are the reusable Runic pieces that make the layer practical.

- context ingest
- focus inference
- pressure evaluation
- compaction and selective expansion
- memory write and recall
- retrieval normalization
- bundle assembly
- handoff generation
- reference recipes proving the layer fits the existing kernels

## Recommended Public Contracts

These should be the minimum new Phase 4 contracts or contract extensions.

### `RunicAI.Context.State`

Purpose: durable derived context state carried alongside transcript state.

Suggested fields:

- `:graph` - `Multigraph.t()`
- `:root_refs` - stable refs for transcript roots or major context roots
- `:active_refs` - refs currently considered in the working set
- `:tail_refs` - refs protected as fresh context
- `:last_focus` - optional `RunicAI.Context.Focus`
- `:stats` - token and structural counters
- `:metadata`

Notes:

- [ ] Keep the raw transcript in `Conversation.State`; do not duplicate it as
      the context engine's own source of truth.
- [ ] Wrap `Multigraph` inside a public struct with helper APIs rather than
      making recipes manipulate graph internals directly.
- [ ] Keep the state serializable as plain Elixir data for the current
      external-state recipe family.

### `RunicAI.Context.Node` and `RunicAI.Context.Ref`

Purpose: represent graph vertices and stable lineage pointers.

Suggested fields for `Context.Node`:

- `:id`
- `:kind` - `:message | :summary | :memory | :retrieval | :observation |
  :handoff | :artifact`
- `:content`
- `:token_count`
- `:created_at`
- `:metadata`

Suggested fields for `Context.Ref`:

- `:kind`
- `:target_id`
- `:label`
- `:provenance`
- `:metadata`

Notes:

- [ ] Keep ids stable enough for selective expansion, replay, and handoff.
- [ ] Standardize early edge labels or partitions such as `:next`,
      `:summarizes`, `:derived_from`, `:supports`, `:references`,
      `:memory_source`, and `:handoff_source`.
- [ ] Make it possible to refer to original transcript items without dragging
      them into every prompt.

### `RunicAI.Context.Focus`

Purpose: express what the next context assembly or summary should optimize for.

Suggested fields:

- `:goal`
- `:questions`
- `:entities`
- `:constraints`
- `:time_scope`
- `:salience_prompt`
- `:metadata`

Notes:

- [ ] Support both caller-supplied focus and model- or rule-derived focus.
- [ ] Keep the optional `:salience_prompt` as a guidance input, not as the only
      source of salience semantics.
- [ ] Let handoff, compaction, retrieval, and memory recall all consume the
      same focus value where possible.

### `RunicAI.Context.Bundle`

Purpose: the canonical assembled active context just before prompt projection.

Suggested fields:

- `:entries`
- `:messages`
- `:refs`
- `:focus`
- `:token_estimate`
- `:coverage`
- `:metadata`

Notes:

- [ ] The bundle should be richer than `RunicAI.Prompt`.
- [ ] `RunicAI.Prompt` should remain the final provider-neutral message list,
      derived from `Context.Bundle`.
- [ ] Preserve ordering and token accounting explicitly so pressure logic stays
      inspectable.

### `RunicAI.Context.WindowPolicy`

Purpose: declare how much active context is allowed and which relief strategies
are preferred.

Suggested fields:

- `:max_input_tokens`
- `:reserve_output_tokens`
- `:soft_pressure_tokens`
- `:hard_pressure_tokens`
- `:fresh_tail_messages`
- `:fresh_tail_tokens`
- `:preferred_relief` - `:compact | :handoff | :retrieve | :review`
- `:metadata`

Notes:

- [ ] Keep this separate from Phase 3 budget policy even though the two may be
      evaluated together in recipes.
- [ ] Allow recipe authors to choose different relief defaults for different
      workloads.
- [ ] Do not bury fresh-tail behavior inside one summarizer step.

### `RunicAI.Context.PressureSnapshot` and `RunicAI.Context.PressureDecision`

Purpose: measure context pressure and turn it into an explicit workflow branch.

Suggested fields for `PressureSnapshot`:

- `:current_tokens`
- `:tail_tokens`
- `:summary_tokens`
- `:memory_tokens`
- `:retrieval_tokens`
- `:compactable_refs`
- `:metadata`

Suggested fields for `PressureDecision`:

- `:action` - `:none | :compact | :handoff | :retrieve | :review`
- `:reason`
- `:snapshot`
- `:metadata`

Notes:

- [ ] Keep pressure evaluation deterministic and independent of the final
      summarization call.
- [ ] Make it possible for recipes to branch to handoff instead of always
      compacting in place.

### `RunicAI.Context.CompactionPolicy`

Purpose: declare how compaction should happen when pressure requires it.

Suggested fields:

- `:strategy` - `:summary_dag | :rolling_summary | :none`
- `:leaf_target_tokens`
- `:condensed_target_tokens`
- `:max_depth_per_pass`
- `:summary_style`
- `:salience_prompt`
- `:fallback_mode`
- `:metadata`

Notes:

- [ ] Make `:summary_dag` the intended default strategy for this phase.
- [ ] Support a multi-level escalation path so compaction always converges.
- [ ] Keep compaction policy separate from retrieval or memory policy.

### `RunicAI.Context.HandoffRequest` and `RunicAI.Context.HandoffArtifact`

Purpose: capture goal-conditioned context transfer into another thread or child
workflow.

Suggested fields for `HandoffRequest`:

- `:goal`
- `:audience`
- `:max_seed_tokens`
- `:include_refs?`
- `:style_prompt`
- `:metadata`

Suggested fields for `HandoffArtifact`:

- `:brief`
- `:seed_messages`
- `:references`
- `:open_questions`
- `:next_actions`
- `:constraints`
- `:metadata`

Notes:

- [ ] `HandoffArtifact` should be editable by the caller or operator before a
      new thread starts.
- [ ] Keep the artifact general enough for coding, research, or operator-facing
      workflows.
- [ ] Reuse this contract later in Phase 5 child-task spawning rather than
      inventing a second handoff vocabulary.

### `RunicAI.Memory.Entry`, `RunicAI.Memory.Query`, and `RunicAI.Memory.ReadResult`

Purpose: represent internal memory without depending on a particular storage
technology.

Suggested fields for `Memory.Entry`:

- `:id`
- `:kind` - `:episodic | :semantic | :temporal`
- `:content`
- `:summary`
- `:refs`
- `:valid_from`
- `:valid_until`
- `:salience`
- `:metadata`

Suggested fields for `Memory.Query`:

- `:focus`
- `:kinds`
- `:limit`
- `:predicate`
- `:metadata`

Suggested fields for `Memory.ReadResult`:

- `:entries`
- `:refs`
- `:metadata`

Notes:

- [ ] Keep semantic memory in Phase 4 focused on extracted facts and decisions,
      not on bundling an embeddings stack.
- [ ] Episodic memory should capture noteworthy events such as tool outcomes,
      reviews, decisions, failures, and handoffs.
- [ ] Temporal memory should allow expiry and recency-sensitive filtering.

### `RunicAI.Retrieval.Query`, `RunicAI.Retrieval.Document`, and `RunicAI.Retrieval.Result`

Purpose: let external retrieval become one more context source without forcing
RunicAI to own the external infrastructure.

Suggested fields for `Retrieval.Query`:

- `:text`
- `:filters`
- `:scope`
- `:top_k`
- `:metadata`

Suggested fields for `Retrieval.Document`:

- `:id`
- `:content`
- `:uri`
- `:score`
- `:metadata`

Suggested fields for `Retrieval.Result`:

- `:documents`
- `:query`
- `:provider`
- `:metadata`

Notes:

- [ ] Retrieval documents should normalize into provenance-bearing context
      entries before they are added to a bundle.
- [ ] Keep the provider behaviour thin so users can adapt lexical search,
      vector search, graph lookup, or plain tool-backed retrieval.
- [ ] Do not make embeddings or vector indexes mandatory for this phase.

## Recommended Module And File Layout

Phase 4 should add a context namespace rather than smearing these concerns
across `Agent.State`, prompt assembly, and ad hoc recipe maps.

```text
lib/runic_ai/
  context/
    state.ex
    node.ex
    ref.ex
    focus.ex
    bundle.ex
    window_policy.ex
    pressure_snapshot.ex
    pressure_decision.ex
    compaction_policy.ex
    handoff_request.ex
    handoff_artifact.ex
    graph.ex
  memory/
    entry.ex
    query.ex
    read_result.ex
    store.ex
  retrieval/
    query.ex
    document.ex
    result.ex
    provider.ex
  steps/
    ingest_context_turn.ex
    infer_focus.ex
    evaluate_context_pressure.ex
    compact_context.ex
    recall_memory.ex
    retrieve_context.ex
    assemble_context_bundle.ex
    build_handoff.ex
  recipes/
    summary_backed_chat_agent.ex
    memory_aware_tool_agent.ex
    handoff_context_builder.ex
```

Recommended contract extensions in place:

- `RunicAI.Agent.State` should gain an optional `:context` field rather than
  hiding core Phase 4 state inside `:assigns`.
- `RunicAI.Steps.AssembleTurnPrompt` should remain as the final projection
  stage, but Phase 4 recipes should feed it from `Context.Bundle` rather than
  appending everything directly into `TurnRequest.observations`.

## Workstream 1: Context Substrate And Graph Wrapper

This workstream establishes the durable context state that later workstreams
operate on.

Deliverables:

- [ ] Add `RunicAI.Context.State`, `RunicAI.Context.Node`, and
      `RunicAI.Context.Ref`.
- [ ] Add a `RunicAI.Context.Graph` helper layer wrapping `Multigraph`
      construction and graph rewrites.
- [ ] Extend `RunicAI.Agent.State` with optional context state.
- [ ] Define the first stable relation partitions or labels:
      `:next`, `:summarizes`, `:derived_from`, `:supports`, `:references`,
      `:memory_source`, and `:handoff_source`.
- [ ] Add an ingest step that turns new transcript material, tool observations,
      and other notable artifacts into context nodes and edges.
- [ ] Add focused contract and graph-behavior tests for deterministic insertion,
      ordering, and lineage.

Implementation notes:

- Keep graph rewrites pure where possible.
- Prefer stable ids or content-derived identities over opaque ephemeral
  ordering-only ids.
- Expose graph queries through helper functions, not ad hoc `Multigraph`
  traversals at every recipe call site.

## Workstream 2: Focus And Context-Bundle Assembly

This workstream answers "what matters now?" and turns that answer into a typed
active bundle.

Deliverables:

- [ ] Add `RunicAI.Context.Focus` and `RunicAI.Context.Bundle`.
- [ ] Add a focus-inference step that can derive a first-pass focus from the
      latest user message, pending action, or caller-supplied goal.
- [ ] Add a bundle-assembly step that merges fresh tail, pinned instructions,
      summaries, memory recall, retrieval results, and tool observations.
- [ ] Define deterministic ordering and precedence rules for bundle assembly.
- [ ] Track bundle token estimates, coverage, and included refs in metadata.
- [ ] Add tests proving that equivalent inputs assemble equivalent bundles.

Implementation notes:

- The focus value should guide both selection and summarization.
- Keep bundle assembly as its own transformation rather than hiding it inside
  one prompt-builder function.
- The final bundle should project cleanly into `RunicAI.Prompt` and continue to
  reuse existing LLM request contracts.

## Workstream 3: Window Pressure, Compaction, And Summary DAGs

This workstream makes context-window control an explicit workflow concern.

Deliverables:

- [ ] Add `WindowPolicy`, `PressureSnapshot`, `PressureDecision`, and
      `CompactionPolicy`.
- [ ] Add pressure-evaluation components that branch to continue, compact,
      handoff, retrieve, or review.
- [ ] Implement fresh-tail protection and explicit compactable-region
      selection.
- [ ] Implement DAG-style compaction where older nodes are summarized into
      summary nodes with lineage refs back to originals.
- [ ] Support goal-conditioned summarization with an optional salience prompt.
- [ ] Support a multi-level escalation path so compaction converges even when
      summarization fails to shrink content.

Implementation notes:

- The LCM paper's dual-state model is the right inspiration here: immutable
  source state plus an active context assembled from recent raw items and
  summary nodes.
- Keep "lossless" scoped to recoverability and lineage, not to any claim that
  a summary itself is complete.
- Phase 4 only needs a clean synchronous or explicit-step compaction path.
  Durable background compaction can come later.

## Workstream 4: Memory Models And Recall

This workstream turns memory into a first-class substrate instead of a prompt
hack.

Deliverables:

- [ ] Add `Memory.Entry`, `Memory.Query`, and `Memory.ReadResult`.
- [ ] Add memory-write components for episodic memory from turns, tool batches,
      reviews, and handoffs.
- [ ] Add memory-write components for semantic memory from extracted facts,
      decisions, or stable preferences.
- [ ] Add temporal-memory support with validity windows and recency-aware
      recall.
- [ ] Add memory-recall components that select entries by focus and policy.
- [ ] Add tests covering provenance, expiry, and recall ranking or filtering.

Implementation notes:

- The initial store can remain plain data or a small behaviour with an in-memory
  implementation.
- Avoid bundling embeddings or vector dependencies into semantic memory.
- Memory entries should cite source refs so later recipes can expand or audit
  them.

## Workstream 5: Retrieval Boundaries And Tool-Mediated Retrieval

This workstream keeps RAG possible without making RunicAI own the whole storage
stack.

Deliverables:

- [ ] Add `Retrieval.Query`, `Retrieval.Document`, `Retrieval.Result`, and a
      thin provider behaviour.
- [ ] Add retrieval steps that normalize external documents into context-entry
      form.
- [ ] Show how retrieval can be injected either through a provider adapter or
      through existing Phase 2 tool-calling paths.
- [ ] Publish at least one retrieval-aware example that retrieves before answer
      generation.
- [ ] Publish at least one tool-agent example that uses retrieval as a tool-fed
      context source before acting.

Implementation notes:

- Treat retrieval as external context import, not as the canonical memory model.
- Examples should demonstrate lexical search, vector search, or tool-backed
  retrieval without forcing a bundled dependency decision.
- Retrieval documents should preserve provenance and scoring metadata when they
  enter `Context.Bundle`.

## Workstream 6: Handoff Artifacts And Thread Seeding

This workstream turns handoff from a reserved turn-result kind into a concrete
context-engineering capability.

Deliverables:

- [ ] Add `HandoffRequest` and `HandoffArtifact`.
- [ ] Add a handoff-builder step that creates a focused seed from current
      context state and a next-goal focus.
- [ ] Include references, unresolved questions, constraints, and suggested next
      actions in the artifact.
- [ ] Wire handoff generation into `TurnResult.kind == :handoff` and the
      existing `:pre_handoff` guard point from Phase 3.
- [ ] Add tests covering goal-conditioned handoff shape, ref preservation, and
      artifact editability.

Implementation notes:

- Handoff should prefer starting a new focused thread over endlessly stacking
  compactions in one thread when the work meaningfully changes.
- This phase only needs to generate the handoff artifact.
  Child workflow spawning and join behavior remain Phase 5 concerns.

## Workstream 7: Reference Recipes And Documentation

This workstream proves the context layer fits the existing kernels.

Deliverables:

- [ ] Publish a summary-backed chat recipe using explicit pressure evaluation
      and compaction.
- [ ] Publish a memory-aware tool agent recipe that recalls episodic and
      semantic memory before acting.
- [ ] Publish a handoff-builder recipe showing how to seed a new focused
      conversation or child task.
- [ ] Update README and docs so context engineering is discoverable as a core
      library lane rather than a footnote under retrieval.
- [ ] Add examples documenting tool-mediated retrieval as an integration path.

Implementation notes:

- The recipes should read like controlled extensions of Phases 1 through 3, not
  like a new bespoke runtime.
- Each recipe should make the transcript/context/memory distinction concrete.

## Recommended Implementation Sequence

1. Land the context contracts and graph wrapper first.
   This is the substrate every other workstream depends on.
2. Land focus inference and bundle assembly next.
   That gives the phase a usable prompt path before full compaction exists.
3. Add pressure evaluation and compaction.
   Once the bundle path exists, window control becomes measurable and testable.
4. Add memory write and recall.
   This should plug into the same bundle assembly path instead of inventing a
   separate prompt assembly track.
5. Add retrieval provider contracts and examples.
   Retrieval should attach cleanly once bundle assembly is stable.
6. Add handoff artifacts.
   Handoff should build on stabilized focus, refs, and bundle metadata.
7. Finish with recipes, docs, and provider-backed manual verification.

## Recommended Early Decisions

These decisions are worth making before implementation starts so the phase does
not sprawl.

1. `Agent.State` should gain an explicit optional `:context` field.
   Core Phase 4 state is too important to hide in `:assigns`.
2. `Context.Bundle` should become the assembly target, and `Prompt` should stay
   the final projection.
   That keeps provenance and token accounting visible.
3. `Multigraph` should be the internal graph engine, wrapped by
   `RunicAI.Context.Graph`.
   Recipes should depend on typed helpers, not raw graph mutation.
4. Phase 4 should implement retrieval contracts and examples, not a bundled
   vector stack.
   External stores and embeddings remain integration concerns.
5. Handoff generation belongs in Phase 4; child workflow execution belongs in
   Phase 5.
   That keeps context transfer separate from multi-agent orchestration.
6. "Lossless" in docs should always mean recoverable originals through refs,
   not "the model will never forget unless it chooses badly."

## Verification Plan

Phase 4 implementation should be considered complete only when the following
verification work is done.

- [ ] Contract tests for context, memory, retrieval, pressure, compaction, and
      handoff contracts.
- [ ] Graph and lineage tests proving deterministic insertion, ancestry, and
      selective expansion behavior.
- [ ] Bundle-assembly tests covering ordering, token accounting, focus changes,
      and provenance retention.
- [ ] Compaction tests covering fresh-tail protection, threshold decisions,
      summary insertion, and escalation fallback.
- [ ] Memory tests covering episodic writes, semantic extraction, temporal
      expiry, and recall behavior.
- [ ] Retrieval-adapter tests covering provider normalization and tool-mediated
      retrieval integration.
- [ ] Handoff tests covering goal-conditioned artifact generation and
      edit-and-resume behavior.
- [ ] At least one provider-backed manual verification run showing a long enough
      session to trigger compaction or handoff with a real model.
- [ ] Documentation updates so users can discover context engineering from the
      roadmap, README, and recipe docs.

## Out Of Scope For This Phase

The plan should stay disciplined about what Phase 4 does not need to solve yet.

- No bundled vector database, search engine, or embeddings stack.
- No full external persistence system for context graphs is required yet.
- No background job system for asynchronous compaction is required yet.
- No automatic child-workflow spawning or multi-agent join logic is required
  yet.
- No promise that every model will always choose to expand the right summary at
  the right time.
- No separate bespoke "agent memory runtime" should be introduced.

## Exit Criteria

Phase 4 is done when RunicAI users can choose among plain history,
summary-backed context, memory-backed recall, explicit handoff generation, and
light retrieval-aware context assembly using the same typed workflow model and
without dragging external storage assumptions into the core library.
