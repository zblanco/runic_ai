# Phase 3 Implementation Plan: Controls, Guards, And Operator Interaction

Status: implemented

Date: 2026-04-15

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`

## Progress

- [x] Implemented the Phase 3 control contracts, control steps, rule helpers,
      controlled wrappers, and the guarded reference recipe.
- [x] Added coverage for budget evaluation, guard routing, review decision
      normalization, resume normalization, retry/fallback wrappers, and guarded
      recipe behavior.
- [x] Updated README and library docs so the control layer is discoverable
      above the conversational and tool kernels.
- [x] Verified the guarded recipe against a real provider in dev on
      2026-04-15. Via Tidewave, after recompiling the recipe module in the dev
      node, `openai:gpt-4.1-mini` produced a guarded pre-tool review request at
      `:pre_tool`. Via `mix run -e`, the same recipe completed an end-to-end
      arithmetic tool call and answered `"42"`.
- [x] End-to-end recipe resumption from `ReviewDecision` and `ResumeSignal`
      now works through `GuardedOperatorToolAgent.react_until_resolution/3`
      using the paused `Agent.State` plus typed review or resume inputs.

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
  `Runic.state_machine/1`, `Runic.process_manager/1`

## Goal

Extend the conversational and tool-using kernels with explicit control
semantics so workflows can govern risky behavior, pause for operator input,
wait for external conditions, and recover from failure without burying those
concerns inside prompts or bespoke runtime loops.

Phase 3 is successful when RunicAI has a clear, composable answer to:

"How do I express budgets, guards, review gates, waits, resumes, retries, and
fallbacks as typed workflow values and reusable Runic components?"

## Current Starting Point

Phase 2 gives us the main behavioral kernel:

- `RunicAI.Agent.State`
- `RunicAI.Agent.TurnRequest`
- `RunicAI.Agent.TurnResult`
- `RunicAI.Agent.ContinueDecision`
- `RunicAI.Tool.*` contracts and execution planning
- `RunicAI.Recipes.ChatAgentKernel`
- `RunicAI.Recipes.ConversationalToolAgent`

Phase 0 also already gave us two important control-shaped contracts:

- `RunicAI.Wait`
- `RunicAI.ReviewRequest`

What is still missing is the connective control layer that makes those values
first-class parts of recipe design rather than isolated payload types:

- budget policy and budget evaluation
- typed guard points around sensitive workflow boundaries
- operator-facing approval and edit loops
- wait/resume contracts that fit the current external-state model
- retry and fallback wrappers around effect boundaries
- a reference recipe that demonstrates governance instead of only capability

## Why This Phase Matters

Phase 2 answered "what work can the agent request and execute?"

Phase 3 needs to answer "under what conditions may the workflow proceed, pause,
retry, escalate, or stop?"

The maintainable shape we want is:

1. policy is data
2. evidence is data
3. evaluation produces a typed decision
4. the workflow branches on that decision explicitly
5. operator actions re-enter through typed resume values

That keeps the system extensible.
Later phases can add retrieval, memory, multi-agent branches, and observability
without having to re-invent the control surface at every boundary.

## Control Composition Model

Phase 3 should treat control as a layer that wraps existing kernels rather than
replacing them.

The intended shape is:

```text
Agent.State + TurnResult + policy/context
  -> BudgetSnapshot
  -> BudgetDecision
  -> GuardDecision at a named guard point
  -> ReviewRequest | Wait | RetryPlan | FallbackPlan | ContinueDecision
  -> next workflow branch
```

For the existing turn-processor recipe family, that means:

- a workflow processes a turn
- control components evaluate the turn outcome and pending action
- the workflow emits typed outputs such as review requests or waits
- the caller persists state however it wants
- a later call resumes the workflow with explicit operator input or resume input

For the future workflow-owned stateful recipe family, the same contracts should
remain usable inside accumulators, state machines, or process-manager style
recipes.

The control contracts should therefore stay persistence-agnostic and runtime-
agnostic.

## Design Principles

### 1. Model control as values, not hidden exceptions

Control flow should travel as explicit values such as budget decisions, review
requests, waits, and retry plans.

Do not make policies disappear inside rescue blocks, prompt wording, or opaque
"middleware" steps.

### 2. Separate policy from evidence

Policies describe what should be enforced.
Evidence describes what happened in the current run.
Evaluation combines them into a decision.

That separation is what lets the same budget or guard policy be reused across
multiple recipes.

### 3. Put gates at named boundaries

Controls should attach to explicit boundaries such as:

- before a tool batch executes
- after a tool batch returns
- before a final answer is emitted
- before a handoff is released
- before another recursive turn begins

This keeps the workflow legible and lets users swap or compose policies without
rewriting the whole recipe.

### 4. Keep operator round-trips typed and resumable

The workflow should not "wait for a human" by depending on a live process.
It should emit a review request or wait request as data, then later accept a
typed operator decision or resume signal as data.

### 5. Wrap effect boundaries instead of duplicating them

Retries and fallbacks should be implemented as wrappers around the existing LLM
and tool execution boundaries, not as replacement versions of those steps that
copy business logic.

### 6. Support both current and future recipe tracks

Phase 3 should work immediately with the current persistence-agnostic
turn-processor model.
It should also leave a clean path for the future additive track where a
workflow owns more of the long-lived state directly.

### 7. Keep advisory and blocking outcomes distinct

Some controls only annotate the run.
Others must block, halt, or escalate.
The contracts should not blur these two meanings together.

### 8. Preserve auditability

Every decision point should produce structured reason data that later phases
can turn into trace events, evaluation fixtures, or operator-visible logs.

## Recommended Contract Layering For Phase 3

### Layer 1: Control policies

These are declarative inputs that say what should happen under which
conditions.

- budget policy
- guard policy
- review policy
- wait policy
- retry policy
- fallback policy

### Layer 2: Control evidence and decisions

These are the values produced from the current workflow state and outcomes.

- budget snapshot
- budget decision
- guard input
- guard decision
- review request
- review decision
- wait
- resume signal
- retry plan or retry decision
- fallback plan or fallback decision

### Layer 3: Gate and wrapper components

These are the reusable Runic-native pieces that perform evaluation and branch
the workflow.

- budget gate rules
- guard evaluation steps and rules
- review gate steps and rules
- wait/resume normalization steps
- retry wrappers
- fallback wrappers

### Layer 4: Controlled recipes

These are reference workflows that make the control layer concrete.

- guarded conversational kernel recipe
- guarded tool agent recipe
- operator-facing resume examples for the external-state model

## Recommended Public Contracts

These should be the minimum new Phase 3 contracts or contract extensions.

### `RunicAI.Control.BudgetPolicy`

Purpose: declare the resource limits that a recipe should enforce.

Suggested fields:

- `:max_turns`
- `:max_model_calls`
- `:max_tool_calls`
- `:max_elapsed_ms`
- `:max_estimated_cost`
- `:max_recursion_depth`
- `:on_exhaustion` - `:halt | :review | :wait`
- `:metadata`

Notes:

- [ ] Keep this purely declarative.
- [ ] Do not hide counters or clocks inside the policy itself.
- [ ] Make partial policies valid so recipes can opt into only the limits they
      care about.

### `RunicAI.Control.BudgetSnapshot`

Purpose: capture the measured usage that a budget policy evaluates.

Suggested fields:

- `:turns`
- `:model_calls`
- `:tool_calls`
- `:elapsed_ms`
- `:estimated_cost`
- `:recursion_depth`
- `:metadata`

Notes:

- [ ] Keep this as evidence, not policy.
- [ ] Derive it from explicit workflow state, result metadata, and caller-
      supplied runtime context where needed.
- [ ] Avoid any design that requires a particular process topology.

### `RunicAI.Control.BudgetDecision`

Purpose: represent the result of budget evaluation.

Suggested fields:

- `:status` - `:within_limits | :soft_limit | :exhausted`
- `:action` - `:continue | :halt | :review | :wait`
- `:reasons`
- `:snapshot`
- `:metadata`

Notes:

- [ ] Keep budget evaluation separate from the final continuation rule.
- [ ] Make the action explicit so different recipes can map the same status in
      different ways when needed.

### `RunicAI.Control.GuardPoint`

Purpose: name the workflow boundary where a guard is applied.

Expected early values:

- `:pre_tool`
- `:post_tool`
- `:pre_answer`
- `:pre_handoff`
- `:pre_continue`

Notes:

- [ ] Keep the set open to later extension.
- [ ] Prefer a narrow named vocabulary over ad hoc string labels.

### `RunicAI.Control.GuardRequest`

Purpose: bundle the candidate action and relevant context for one guard
evaluation.

Suggested fields:

- `:point`
- `:state`
- `:turn_result`
- `:execution_plan`
- `:batch_result`
- `:candidate_message`
- `:policy`
- `:metadata`

Notes:

- [ ] Let fields be optional when a given guard point does not need them.
- [ ] Keep the request contract neutral enough to support pure-function guards,
      policy modules, or later model-based judges.

### `RunicAI.Control.GuardDecision`

Purpose: represent what a guard decided to do with a candidate action.

Suggested fields:

- `:action` - `:allow | :deny | :review | :wait | :rewrite`
- `:reason`
- `:replacement`
- `:details`
- `:metadata`

Notes:

- [ ] Make rewrite/edit outcomes explicit rather than overloading `:allow`.
- [ ] Keep the payload small and focused on the decision itself.

### `RunicAI.ReviewRequest` and `RunicAI.ReviewDecision`

Purpose: represent operator-facing review and the operator's response.

Suggested additions for `RunicAI.ReviewRequest`:

- `:checkpoint`
- `:subject`
- `:resume_key`
- `:options`
- `:metadata`

Suggested fields for `RunicAI.ReviewDecision`:

- `:request_id` or `:resume_key`
- `:status` - `:approved | :rejected | :edited | :cancelled`
- `:edited_value`
- `:actor`
- `:metadata`

Notes:

- [ ] Keep the review request serializable and persistence-agnostic.
- [ ] Make operator edits a first-class path rather than a side channel.

### `RunicAI.Wait` and `RunicAI.ResumeSignal`

Purpose: represent workflow suspension and later resumption.

Suggested additions for `RunicAI.Wait`:

- `:kind` - `:user_input | :external_signal | :scheduled | :review`
- `:reason`
- `:resume_key`
- `:until`
- `:payload`
- `:metadata`

Suggested fields for `RunicAI.ResumeSignal`:

- `:kind`
- `:resume_key`
- `:payload`
- `:metadata`

Notes:

- [ ] Keep scheduled wake-up data as plain data even if no scheduler adapter is
      implemented yet.
- [ ] Do not require a live process or in-memory mailbox to resume a workflow.

### `RunicAI.Control.RetryPolicy` and `RunicAI.Control.FallbackPolicy`

Purpose: describe reusable recovery behavior around effect boundaries.

Suggested fields for `RetryPolicy`:

- `:max_attempts`
- `:backoff`
- `:retry_if`
- `:on_exhausted`
- `:metadata`

Suggested fields for `FallbackPolicy`:

- `:alternates`
- `:fallback_if`
- `:degrade_to`
- `:metadata`

Notes:

- [ ] Reuse `RunicAI.Error.retryable?` where possible rather than inventing a
      second retry taxonomy.
- [ ] Keep fallback policies capable of routing to another model, another tool,
      a review gate, a wait, or a graceful user-visible reply.

## Workstream 1: Budget Gates

This workstream establishes resource accounting and explicit exhaustion
behavior.

Deliverables:

- [x] Add `BudgetPolicy`, `BudgetSnapshot`, and `BudgetDecision` contracts.
- [x] Add helpers that derive budget snapshots from agent state, tool activity,
      and runtime metadata.
- [x] Add one or more budget gate components using small input-bundling steps
      plus explicit `Runic.rule` branches.
- [x] Support turn, model-call, tool-call, elapsed-time, cost, and recursion
      constraints.
- [x] Define default exhaustion actions and recipe-level override hooks.
- [x] Add contract and rule coverage for each supported limit kind.

Implementation notes:

- Start with deterministic, read-only evaluation.
- Keep elapsed time and cost injection explicit through metadata or run context
  rather than hidden globals.
- Treat budget evaluation as its own transformation, not as an incidental check
  inside continuation logic.

## Workstream 2: Guard Components Around Risky Boundaries

This workstream makes policy checks a first-class part of the graph.

Deliverables:

- [x] Add `GuardPoint`, `GuardRequest`, and `GuardDecision` contracts.
- [x] Define the first standard guard points: pre-tool, post-tool, pre-answer,
      pre-handoff, and pre-continue.
- [x] Add guard evaluation components that can consume plain functions, modules,
      or similarly simple policy callbacks.
- [x] Support allow, deny, review, wait, and rewrite outcomes.
- [x] Add guard metadata helpers so later observability work can explain what
      was checked and why.
- [x] Add recipe wiring examples for at least pre-tool and pre-answer guards.

Implementation notes:

- Keep the initial API simple and policy-driven.
- A later phase can add model-based judge recipes on top of the same guard
  contracts.
- Do not bury guard behavior inside the tool executor or model step itself.

## Workstream 3: Review Gates And Operator Decisions

This workstream turns "needs human approval" into a reusable control branch.

Deliverables:

- [x] Extend `RunicAI.ReviewRequest` with checkpoint, subject, options, and
      resume information.
- [x] Add `RunicAI.ReviewDecision`.
- [x] Add review-gate components that turn a candidate tool action or answer
      into a review request based on policy or guard output.
- [x] Add normalization helpers that apply an operator decision back to the
      workflow on resume.
- [x] Support approve, reject, edit, and cancel flows.
- [x] Add tests for review requests, edited approvals, and rejected actions.

Implementation notes:

- For the current turn-processor model, the workflow should end with explicit
  review output plus the latest agent state.
- Resumption should happen by calling the workflow again with typed review
  input, not by depending on in-process pause mechanics.

## Workstream 4: Wait And Resume Primitives

This workstream makes deferred progress a first-class workflow concern.

Deliverables:

- [x] Expand `RunicAI.Wait` so it can express why the workflow paused and how
      it can resume.
- [x] Add `RunicAI.ResumeSignal`.
- [x] Add wait-gate and resume-normalization components.
- [x] Support waiting for user input, external signals, scheduled wake-ups, and
      review release.
- [x] Ensure resume values can be attached cleanly to the current external-
      state recipe family.
- [x] Add tests covering wait emission and resume normalization.

Implementation notes:

- The immediate target is contract stability and recipe composability, not a
  scheduler adapter.
- The same contracts should later fit a workflow-owned stateful recipe built on
  accumulators, state machines, or process managers.

## Workstream 5: Retry And Fallback Wrappers

This workstream gives the kernel reusable recovery semantics around effectful
boundaries.

Deliverables:

- [x] Add retry and fallback policy contracts.
- [x] Add wrapper constructors around the LLM generation boundary.
- [x] Add wrapper constructors around the tool execution boundary.
- [x] Support retry classification from `RunicAI.Error.retryable?` plus custom
      predicates.
- [x] Support ordered fallback routes such as alternate model, alternate tool,
      review, wait, or graceful degradation.
- [x] Add focused coverage for retries, exhaustion, and fallback order.

Implementation notes:

- Prefer higher-order wrappers that compose around existing steps over copying
  the internals of `GenerateTurn` or `ExecuteToolCalls`.
- Keep wrapper outputs explicit so recipe authors can still inspect why a
  fallback path fired.

## Workstream 6: Guarded Operator-Agent Recipe

This workstream proves the control layer fits together in practice.

Deliverables:

- [x] Publish a guarded operator-agent recipe that composes budgets, guards,
      review gates, waits, retries, and fallbacks around the existing tool
      agent kernel.
- [x] Show distinct policy handling for low-risk and high-risk tool classes.
- [x] Show at least one pre-answer review branch and one pre-tool review
      branch.
- [x] Show budget exhaustion behavior that is visible in workflow outputs.
- [x] Document the external-state orchestration pattern for review and resume.
- [x] Add end-to-end tests over fake LLM, fake tools, and explicit operator
      decisions.

Implementation notes:

- The recipe should read like a controlled extension of Phase 2, not like a new
  monolithic runtime.
- This recipe becomes the reference answer for "operator-facing tool agent"
  until later phases add richer memory, retrieval, and multi-agent behavior.

## Verification Plan

Phase 3 implementation should be considered complete only when the following
verification work is done.

- [x] Contract tests for all new policy, snapshot, request, decision, and
      resume types.
- [x] Rule and step tests for budget, guard, review, wait, retry, and fallback
      components.
- [x] Recipe tests covering approve, reject, edit, wait, resume, retry, and
      exhaustion scenarios.
- [x] At least one provider-backed manual Tidewave verification run against a
      real model using the guarded recipe with an explicit review or wait path.
- [x] Documentation updates so users can discover the control layer from the
      roadmap, README, and recipe docs.

## Out Of Scope For This Phase

The plan should stay disciplined about what Phase 3 does not need to solve yet.

- No persistent storage adapter or approval queue service is required yet.
- No operator UI is required yet.
- No full scheduler integration is required yet.
- No multi-agent review tree is required yet.
- No separate "agent runtime" abstraction should be introduced.

## Exit Criteria

Phase 3 is done when RunicAI users can express explicit budgets, waits, review
gates, guard policies, retries, and fallback behavior as composable workflow
concerns using the same typed substrate as the existing conversational and tool
agent recipes.
