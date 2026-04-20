# Phase 1 Implementation Plan: Conversational Loop Kernel

Status: implemented

Date: 2026-04-14

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic HexDocs overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic workflow API:
  `https://hexdocs.pm/runic/Runic.Workflow.html`
- Official Runic package README:
  `https://hexdocs.pm/runic/readme.html`
- Tidewave lookup keys:
  `Runic`, `Runic.Workflow`, `Runic.rule/1`, `Runic.accumulator/3`,
  `Runic.state_machine/1`

## Progress

- [x] Implemented the Phase 1 agent contracts, steps, rules, and reference
      recipe.
- [x] Added contract, component, rule, and end-to-end kernel tests.
- [x] Updated README and library docs so the conversational kernel layer is
      discoverable.
- [x] Verified the kernel manually via Tidewave `project_eval` against
      `openai:gpt-4.1-mini` on 2026-04-14:
      first turn replied with an acknowledgment of the user's favorite color,
      and the second turn correctly recalled `Vermilion` from carried state.
- [x] Fixed the provider-boundary regression discovered during manual
      verification so state-assembly options no longer leak into ReqLLM opts.
- [x] Refined continuation control so the kernel recipe now uses explicit
      Runic `rule` components fed by a small bundling step instead of one
      monolithic continuation step.

## Goal

Build the first reusable conversation-driven agent kernel on top of the Phase 0
contract layer so users can assemble a stateful assistant without writing a
custom loop each time.

Phase 1 is successful when RunicAI has a clear, composable answer to:

"How do I build a stateful conversational assistant from Runic components,
using typed state transitions and explicit stop rules, before tool calling is
added?"

## Current Starting Point

Phase 0 gives us the low-level substrate:

- `RunicAI.Message`
- `RunicAI.Prompt`
- `RunicAI.Conversation.State`
- `RunicAI.LLM.Request`
- `RunicAI.LLM.Result`
- `RunicAI.Error`
- `RunicAI.Wait`
- `RunicAI.ReviewRequest`

It also gives us low-level components that already compose:

- `RunicAI.Steps.PromptBuilder`
- `RunicAI.Steps.LLMGenerate`
- `RunicAI.Steps.TextToConversation`
- `RunicAI.Conversation`

What is still missing is the actual kernel shape:

- agent-level state
- per-turn request assembly
- per-turn result interpretation
- explicit continuation and termination semantics
- history repair
- a reference workflow that reads like an agent loop rather than a pile of
  disconnected steps

## Why This Phase Matters

Phase 0 answered "what values move through the graph?"

Phase 1 needs to answer "what is one turn of an agent, and how do repeated
turns compose into a stable loop?"

The maintainable shape we want is:

1. durable agent state is one value
2. a turn request is one value
3. model generation is one effect boundary
4. a turn result is one value
5. continuation is an explicit decision, not an accidental side effect

That lets later phases extend the kernel with tools, retrieval, memory,
multi-agent handoffs, and guards without having to replace the loop model.

## Kernel Composition Model

Phase 1 should make the loop readable as a chain of small, named
transformations:

```text
Agent.State + turn input
  -> TurnRequest
  -> Prompt
  -> LLM.Request
  -> LLM.Result
  -> TurnResult
  -> Agent.State'
  -> ContinueDecision
```

The important constraint is that each arrow should be one component or one very
small pair of components, not a monolithic "agent step" that hides state
assembly, generation, interpretation, and control flow in one place.

## Design Principles

### 1. Treat the loop as repeated state reduction

The kernel should behave like a fold over turns:

- take the current state
- assemble one turn request
- generate one model result
- interpret it
- reduce it back into state
- decide whether to continue

That makes the loop easier to test, replay, and extend.

### 2. Keep durable state separate from transient turn material

Agent state is long-lived.
Turn requests and turn results are short-lived.
Do not blur them into one generic map.

### 3. Add an agent layer without replacing the conversation layer

`RunicAI.Conversation.State` should remain the transcript/history reducer.
Phase 1 should add an `Agent.State` wrapper around it rather than turning
`Conversation.State` into a giant agent-state bucket.

### 4. Keep turn interpretation explicit

A model response should not implicitly become "the next thing to do" just
because it is text. There should be an explicit interpretation step that turns
`RunicAI.LLM.Result` into a typed `TurnResult`.

### 5. Future-proof result kinds without pretending Phase 2 is already built

`TurnResult` should reserve room for later variants such as tool requests,
waits, and handoffs, but Phase 1 only needs to fully support the conversational
path.

### 6. Put termination semantics in rules, not in prompts

Prompt instructions can influence behavior, but stopping the loop should still
be decided by workflow-visible rules such as:

- max turns
- explicit final-answer kind
- stop pattern
- invalid turn
- user-supplied predicate

### 7. Preserve low-level building blocks

Phase 1 should add a kernel layer above the Phase 0 steps, not make the lower
level components obsolete. Users still need the smaller pieces for custom
recipes.

## Recommended Contract Layering For Phase 1

### Layer 1: Durable state

- `RunicAI.Conversation.State`
- `RunicAI.Agent.State`

### Layer 2: Per-turn contracts

- `RunicAI.Agent.TurnRequest`
- `RunicAI.Agent.TurnResult`
- `RunicAI.Agent.ContinueDecision`

### Layer 3: Assembly and interpretation components

- turn request assembly
- turn prompt assembly
- turn generation
- turn interpretation
- history repair
- state transition helpers

### Layer 4: Kernel recipe

- reference chat agent kernel workflow
- default continuation rules

## Recommended Public Contracts

These should be the minimum new Phase 1 contracts.

### `RunicAI.Agent.State`

Purpose: the durable state for a conversational agent kernel.

Suggested fields:

- `:conversation` - `RunicAI.Conversation.State`
- `:status` - `:running | :completed | :halted`
- `:pending_action` - optional next-action marker or placeholder
- `:last_turn_result` - optional `RunicAI.Agent.TurnResult`
- `:assigns` - recipe-local scratch state
- `:metadata` - optional metadata

Notes:

- [x] Keep transcript history nested under `:conversation` rather than
      duplicating message storage in two places.
- [x] Let `conversation.turns` remain the canonical turn counter.
- [x] Add helpers for transition-oriented updates instead of encouraging direct
      struct mutation at call sites.

### `RunicAI.Agent.TurnRequest`

Purpose: the canonical input for one model-facing conversational turn.

Suggested fields:

- `:state` - `RunicAI.Agent.State`
- `:input_message` - optional current user message
- `:history_window` - `:all | non_neg_integer()`
- `:pinned_messages` - optional extra instructions or pinned context
- `:observations` - optional extra messages to include for the turn
- `:model` - model specification
- `:llm_opts` - per-turn LLM opts
- `:metadata` - optional metadata

Notes:

- [x] Keep the ingredients for prompt assembly distinct instead of flattening
      them into one generic list too early.
- [x] Make `history_window` explicit so windowing remains a policy decision
      rather than implicit slicing buried in one component.

### `RunicAI.Agent.TurnResult`

Purpose: the typed interpretation of one generated turn.

Suggested fields:

- `:kind` - `:reply | :final | :wait | :handoff | :tool_requests | :error`
- `:message` - optional assistant `RunicAI.Message`
- `:details` - machine-readable result details
- `:raw` - original `RunicAI.LLM.Result` or interpretation input
- `:metadata` - optional metadata

Notes:

- [x] Phase 1 should fully implement `:reply` and `:final`.
- [x] Phase 1 may reserve the other kinds without enabling the corresponding
      runtime behavior yet.
- [x] Keep the assistant message normalized even when the result kind is not a
      simple reply.

### `RunicAI.Agent.ContinueDecision`

Purpose: the explicit control decision for whether the loop continues.

Suggested fields:

- `:action` - `:continue | :stop | :halt`
- `:reason` - atom or string describing why
- `:metadata` - optional metadata

Notes:

- [x] Keep continuation decisions separate from `Agent.State.status`.
- [x] The state stores what the agent is; the decision stores what the workflow
      should do next.

## Recommended Module And File Layout

```text
lib/runic_ai/
  agent/
    state.ex
    turn_request.ex
    turn_result.ex
    continue_decision.ex
  steps/
    assemble_turn_request.ex
    assemble_turn_prompt.ex
    generate_turn.ex
    interpret_turn.ex
    repair_history.ex
  rules/
    continue_chat.ex
  recipes/
    chat_agent_kernel.ex
```

Notes:

- [x] Keep Phase 1 contracts under `RunicAI.Agent`.
- [x] Keep component modules small and transformation-oriented.
- [x] Introduce a `recipes/` namespace only for assembled reference workflows,
      not for low-level components.

## Recommended Kernel Path

This should be the canonical conversational path by the end of the phase.

1. input message and current state become `RunicAI.Agent.TurnRequest`
2. turn request becomes a prompt
3. prompt and model policy become `RunicAI.LLM.Request`
4. LLM request becomes `RunicAI.LLM.Result`
5. LLM result becomes `RunicAI.Agent.TurnResult`
6. turn result reduces into `RunicAI.Agent.State`
7. continuation rules emit `RunicAI.Agent.ContinueDecision`

That path is the kernel. Everything else in the phase should make that path
clearer, safer, or more reusable.

## Implementation Workstreams

### Workstream 1 - Freeze The Phase 1 Contracts

Outcome: the new kernel layer has explicit public nouns before component work
starts.

- [x] Write and agree final field lists and typespecs for:
      `RunicAI.Agent.State`, `RunicAI.Agent.TurnRequest`,
      `RunicAI.Agent.TurnResult`, and `RunicAI.Agent.ContinueDecision`.
- [x] Decide which result kinds are reserved in Phase 1 versus fully supported.
- [x] Decide how system instructions and pinned context are represented:
      inside transcript history, inside pinned messages, or both with a single
      canonical assembly rule.
- [x] Decide whether the kernel reducer is best expressed as an accumulator,
      state machine, or a small recipe using both. Prefer the lightest shape
      that keeps transitions explicit.
- [x] Document invariants directly in module docs and typespecs.

### Workstream 2 - Implement Agent-State And Turn Contracts

Outcome: the library owns the kernel values needed for one full conversation
turn.

- [x] Add `RunicAI.Agent.State` with constructors and transition helpers.
- [x] Add `RunicAI.Agent.TurnRequest` with validation and normalization helpers.
- [x] Add `RunicAI.Agent.TurnResult` with constructor helpers for `:reply` and
      `:final`.
- [x] Add `RunicAI.Agent.ContinueDecision` with convenience constructors for
      `:continue`, `:stop`, and `:halt`.
- [x] Add helper functions that apply a turn result to agent state without
      forcing call sites to manually stitch together nested updates.

### Workstream 3 - Add Turn Request And Prompt Assembly Components

Outcome: one turn can be assembled deterministically from agent state plus input.

- [x] Add a component that assembles `RunicAI.Agent.TurnRequest` from current
      state, optional user input, model policy, and per-turn options.
- [x] Add a component that assembles a prompt from `RunicAI.Agent.TurnRequest`.
- [x] Support conversation-window policies such as `:all` and fixed last-`n`
      messages.
- [x] Support pinned messages and turn-local observations in the assembly path.
- [x] Reuse Phase 0 prompt-building behavior where it helps, but keep the
      public Phase 1 input/output shapes agent-oriented.

### Workstream 4 - Add Structured Turn Generation And Interpretation

Outcome: a model response becomes a typed conversational turn result.

- [x] Add a `GenerateTurn` step that turns `RunicAI.Agent.TurnRequest` into
      `RunicAI.LLM.Request`, calls the LLM, and forwards the normalized result.
- [x] Add an `InterpretTurn` step that turns `RunicAI.LLM.Result` into
      `RunicAI.Agent.TurnResult`.
- [x] Make the default interpretation path produce `:reply` for normal
      assistant output.
- [x] Add a configurable path for interpreting a result as `:final`, such as a
      stop pattern, explicit classifier callback, or user-supplied predicate.
- [x] Preserve the raw `RunicAI.LLM.Result` on the interpreted turn result for
      observability and later extensions.

### Workstream 5 - Add Explicit Continuation And Termination Rules

Outcome: loop control becomes workflow-visible and composable.

- [x] Add rules or helper components that emit `RunicAI.Agent.ContinueDecision`
      from `Agent.State` and `TurnResult`.
- [x] Support max-turn termination.
- [x] Support explicit final-result termination.
- [x] Support stop-pattern termination.
- [x] Support invalid-turn halt behavior.
- [x] Support user-supplied continuation predicates without requiring users to
      fork the whole recipe.

### Workstream 6 - Add History Repair And Turn Normalization

Outcome: the kernel has one place to keep transcript and turn invariants clean.

- [x] Add a `RepairHistory` component or helper module that normalizes message
      sequences before prompt assembly.
- [x] Define exactly which repairs are in scope for Phase 1.
      Good candidates: remove invalid empties, normalize nil content, avoid
      duplicate system prefixes, and preserve only valid message roles.
- [x] Add turn-level normalization helpers that keep interpreted assistant
      messages well-formed before they are reduced into state.
- [x] Keep repairs deterministic and local.
      Do not summarize, reorder semantically meaningful turns, or silently
      invent new content in this phase.

### Workstream 7 - Build The Reference Chat Agent Kernel Recipe

Outcome: there is one obvious assembled workflow users can start from.

- [x] Build a `RunicAI.Recipes.ChatAgentKernel` workflow or equivalent reference
      module.
- [x] Make the recipe read as the canonical kernel path:
      assemble request -> assemble prompt -> generate -> interpret -> update
      state -> decide continue/stop.
- [x] Expose configuration points for model, turn limit, history window, and
      final-answer detection.
- [x] Keep the recipe thin enough that users can replace individual parts
      without throwing away the whole workflow.

### Workstream 8 - Docs And Test Matrix

Outcome: the kernel is teachable and safe to extend.

- [x] Add unit tests for all new Phase 1 contracts and transition helpers.
- [x] Add tests for prompt assembly with different window sizes and pinned
      messages.
- [x] Add tests for turn interpretation into `:reply` and `:final`.
- [x] Add tests for continuation decisions under max-turn, explicit-final, and
      stop-pattern cases.
- [x] Add tests for history repair behavior and invariants.
- [x] Add an end-to-end multi-turn kernel workflow test.
- [x] Update README and phase docs so the new kernel path is discoverable.

## Recommended Implementation Sequence

- [x] Step 1: freeze the Phase 1 contracts and invariants first.
- [x] Step 2: implement agent-state and turn contracts second.
- [x] Step 3: implement turn assembly components third.
- [x] Step 4: implement turn generation and interpretation fourth.
- [x] Step 5: add continuation rules and history repair fifth.
- [x] Step 6: build the reference kernel recipe sixth.
- [x] Step 7: finish with docs and the full test matrix.

## Recommended Early Decisions

These should be decided near the start and then kept stable for the rest of the
phase unless a real contradiction appears.

- [x] Add `RunicAI.Agent.State` as a wrapper around `RunicAI.Conversation.State`
      instead of expanding `Conversation.State` into a general agent-state bag.
- [x] Make `RunicAI.Agent.TurnRequest` the main input contract for turn-level
      assembly and generation components.
- [x] Keep `RunicAI.Agent.TurnResult.kind` broad enough for future kinds, but
      fully implement only the conversational path in this phase.
- [x] Make continuation decisions explicit values, not booleans hidden in
      recipe-local conditionals.
- [x] Keep history repair deterministic and conservative.
- [x] Build the kernel by composing Phase 0 components where that composition is
      clear, instead of bypassing them with a new monolithic agent step.

## Acceptance Criteria

Phase 1 is complete when all of the following are true.

- [x] RunicAI has a public `Agent.State` contract layered cleanly on top of
      `Conversation.State`.
- [x] One full conversational turn can be represented as:
      `TurnRequest -> Prompt -> LLM.Result -> TurnResult -> Agent.State`.
- [x] The loop has explicit continuation and termination rules that users can
      configure without rewriting the recipe.
- [x] History repair and turn normalization exist as explicit components or
      helpers rather than ad hoc patches in the workflow.
- [x] A reference chat agent kernel workflow exists and passes end-to-end tests.
- [x] README and docs show the conversational kernel as the next layer above the
      Phase 0 substrate.

## Explicitly Out Of Scope

Keep these out of Phase 1 so the kernel settles before the feature surface
widens.

- [ ] Tool calling and tool execution
- [ ] Retrieval and RAG backends
- [ ] Long-term memory systems
- [ ] Multi-agent spawning and handoff execution
- [ ] Human review gates and durable wait/resume behavior
- [ ] Cost/spend budgets and advanced policy gates
- [ ] Sandbox execution
- [ ] Optimizer or evaluator frameworks beyond basic kernel tests

## Notes For The Follow-On Phase

If Phase 1 lands well, Phase 2 should be able to add tool visibility and tool
execution by extending `TurnResult`, `Agent.State`, and the kernel recipe rather
than replacing the loop model. That is the real test of this design: Phase 2
should feel like extension, not reinvention.
