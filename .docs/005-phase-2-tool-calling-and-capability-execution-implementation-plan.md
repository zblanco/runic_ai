# Phase 2 Implementation Plan: Tool Calling And Capability Execution

Status: implemented

Date: 2026-04-14

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`

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
  `Runic.rule/1`, `Runic.state_machine/1`

## Progress

- [x] Implemented the Phase 2 tool contracts, execution substrate, Runic steps,
      and reference recipe.
- [x] Added `RunicAI.Tool.BatchResult` so tool batches move through the workflow
      as one explicit value instead of relying on ambiguous raw lists.
- [x] Added contract, step, and recipe coverage for tool selection, request
      interpretation, execution planning, execution, and observation shaping.
- [x] Updated README and library docs so the tool-calling kernel sits clearly
      above the conversational kernel.
- [x] Verified the provider-backed tool loop manually via Tidewave against
      `openai:gpt-4.1-mini`, including a re-check on 2026-04-15 after the
      Runic rule/map-reduce refactor: the first turn requested the local
      `get_weather` tool, the workflow executed it and appended a normalized
      tool observation, and the second turn answered
      `"The weather in Paris is currently sunny."`
- [x] Refined the execution boundary so the parallel tool batch path is
      expressed through an internal Runic `map` + `reduce` workflow rather than
      ad hoc task orchestration alone.

Current note:

- All in-scope Phase 2 work below has been implemented and verified with tests.
- The main follow-up inside this phase would be deciding whether
  `react_until_resolution/3` should preserve cross-cycle intermediate workflow
  artifacts such as earlier batch results, or remain focused on returning the
  final resolved workflow state.

## Goal

Extend the Phase 1 conversational kernel so users can build a conventional
tool-using assistant from typed RunicAI components and Runic workflows, without
introducing a bespoke agent runtime.

Phase 2 is successful when RunicAI has a clear, composable answer to:

"How do I let a stateful conversational agent expose tools, execute requested
capabilities with explicit policy, feed normalized observations back into the
loop, and keep the whole flow inspectable as workflow data?"

## Current Starting Point

Phase 1 gives us the reusable conversational kernel:

- `RunicAI.Agent.State`
- `RunicAI.Agent.TurnRequest`
- `RunicAI.Agent.TurnResult`
- `RunicAI.Agent.ContinueDecision`
- `RunicAI.Recipes.ChatAgentKernel`

It also gives us the most important structural seam for this phase:

- `TurnResult.kind` already leaves room for `:tool_requests`
- `Agent.State.pending_action` exists as a typed place for next-step intent
- prompt assembly, turn generation, interpretation, and continuation are
  already separate transformations

What is still missing is the tool lane itself:

- model-visible tool definitions
- explicit tool visibility and selection
- typed tool call requests
- execution planning for batches and ordering
- normalized tool results and observations
- integration of tool results back into agent state
- an iterative model -> tool -> model recipe

## Why This Phase Matters

Phase 1 answered "what is one conversational turn?"

Phase 2 needs to answer "what happens when a turn asks the workflow to do work
outside the model?"

That answer has to stay composable.

We do not want one giant "agent loop with tools" module that hides:

- which tools were visible
- which tool calls were requested
- which calls ran in parallel
- which calls were serialized
- which failures were retried or converted into observations
- why the loop continued or halted

The maintainable shape we want is:

1. tool exposure is one value
2. tool requests are one value
3. capability execution policy is one value
4. tool execution results are one value
5. tool observations are one value
6. state reduction and continuation remain explicit

That lets later phases add guards, budgets, review gates, waits, retrieval, and
multi-agent branches by extending the loop instead of replacing it.

## Tool Composition Model

Phase 2 should make the tool path readable as a chain of small, named
transformations:

```text
Agent.State + turn input
  -> TurnRequest
  -> ToolSelection
  -> Prompt + visible tools
  -> LLM.Request
  -> LLM.Result
  -> TurnResult
  -> ToolExecutionPlan
  -> ToolCallResult[]
  -> ToolObservation[]
  -> Agent.State'
  -> ContinueDecision
```

The key design rule is that model-visible intent and workflow-visible execution
should not be the same value.

The model asks for tools.
The workflow decides how those requests become executable work.

That split is what lets us use Runic's branching, scheduling, and reduction
capabilities without baking provider quirks directly into the loop.

## Execution Strategy Model

Tool calling often arrives as a batch, and Runic's dataflow model should be the
default fit for that case.

### 1. Parallel-by-default batch execution

When tool calls are independent, the default execution path should be:

- interpret tool requests
- build an execution plan
- fan out one branch per tool call
- execute with `Runic.map` or equivalent parallel branch structure
- reduce results into one deterministic batch outcome

This is the happy path for:

- read-only tools
- fetch-style API calls
- lookup tools
- pure transformations
- tool sets where order does not matter

### 2. Ordered or staged execution

Some tool requests are not safely parallel:

- the second call depends on the first result
- the calls mutate the same external system
- a policy requires serialization
- the tool definition declares side effects or a concurrency key

For those cases, Phase 2 should support explicit execution modes such as:

- `:parallel`
- `:serial`
- `{:staged, [[call_id]] | [[ToolCallRequest.t()]]}`

The workflow should decide the execution strategy from typed policy and tool
metadata, not from prompt wording alone.

### 3. Durable and scheduled execution hints

Runic gives us a path toward durable execution and scheduling, so Phase 2
should shape the contracts to allow that from the start.

The initial implementation does not need the full Phase 3 wait/review surface,
but tool execution policy should already have room for:

- timeout behavior
- retry/backoff hints
- concurrency limits
- scheduling or dispatch hints
- long-running or deferred execution markers

That keeps the core tool contracts stable when we later add richer operator and
runtime controls.

## Design Principles

### 1. Separate tool visibility from tool execution

What the model can see is not the same as what the workflow may execute.

Tool visibility is a capability-selection problem.
Execution is a policy and orchestration problem.

### 2. Treat tool batches as values before they become effects

Before any tool runs, the workflow should have a typed plan describing:

- which calls exist
- which tools they target
- the normalized arguments
- whether they run in parallel or serially
- which policy applies

That makes execution inspectable and testable.

### 3. Keep one effect boundary per tool invocation

Planning, validation, reduction, and observation shaping should stay separate
from the actual execution callback.

That keeps retries, fallback, tracing, and failure handling local to a clear
boundary.

### 4. Normalize every tool outcome

A tool result should not be an arbitrary callback return leaking into the agent
state.

Every tool invocation should reduce into a stable result contract with explicit
status and normalized payload.

### 5. Preserve deterministic reduction

Parallel execution is useful only if the merged outcome is predictable.

Reduction should preserve a stable order, ideally request order, even when tool
branches complete out of order.

### 6. Keep the conversational kernel intact

Phase 2 should extend the Phase 1 kernel.
It should not replace it with a monolithic "tool agent" loop that bypasses
existing contracts.

### 7. Let policy live in data

Timeouts, parallelism, retry behavior, fallback behavior, and side-effect rules
should be explicit policy values and tool metadata, not hidden in the executor.

## Recommended Contract Layering For Phase 2

### Layer 1: Durable state

- `RunicAI.Conversation.State`
- `RunicAI.Agent.State`

### Layer 2: Model-visible capability surface

- `RunicAI.Tool.Definition`
- `RunicAI.Tool.Registry`
- `RunicAI.Tool.Selection`

### Layer 3: Executable work contracts

- `RunicAI.Tool.CallRequest`
- `RunicAI.Tool.ExecutionPlan`
- `RunicAI.Tool.ExecutionPolicy`
- `RunicAI.Tool.BatchResult`
- `RunicAI.Tool.CallResult`
- `RunicAI.Tool.Observation`

### Layer 4: Assembly and execution components

- tool selection
- prompt/tool exposure
- tool-request interpretation
- execution planning
- tool execution
- result reduction
- observation shaping
- state transition helpers

### Layer 5: Kernel recipe

- reference conversational tool agent workflow
- default execution and failure policies

## Recommended Public Contracts

These should be the minimum new Phase 2 contracts.

### `RunicAI.Tool.Definition`

Purpose: the canonical model-visible and workflow-executable definition of one
tool.

Suggested fields:

- `:name` - stable model-visible tool name
- `:description` - model-visible description
- `:parameter_schema` - validated input schema
- `:executor` - callback module/function or adapter reference
- `:execution_policy` - default execution policy for this tool
- `:metadata` - optional metadata

Notes:

- [x] Keep model-facing description and workflow-facing execution policy in the
      same contract, but as separate fields.
- [x] Make the executor reference explicit and injectable.
- [x] Keep schema validation at the boundary instead of inside arbitrary
      callbacks.

### `RunicAI.Tool.Registry`

Purpose: a validated registry of available tools and lookup helpers.

Suggested fields:

- `:tools` - ordered collection or map of `Tool.Definition`
- `:metadata` - optional registry metadata

Notes:

- [x] Keep registry shape deterministic and easy to filter.
- [x] Add lookup helpers by tool name.
- [x] Avoid making the registry itself responsible for visibility policy.

### `RunicAI.Tool.Selection`

Purpose: the selected visible tool set for one turn.

Suggested fields:

- `:registry` - source tool registry
- `:visible_tools` - ordered list of exposed `Tool.Definition`
- `:hidden_tools` - optional omitted names or tools
- `:reason` - optional reason or policy marker
- `:metadata` - optional metadata

Notes:

- [x] Keep selection per-turn so visibility can vary by state and policy.
- [x] Preserve explicit ordering for stable prompt exposure.
- [x] Make it easy for workflows to expose zero tools on a turn.

### `RunicAI.Tool.CallRequest`

Purpose: the normalized request to invoke one tool once.

Suggested fields:

- `:id` - stable call id
- `:tool_name` - target tool name
- `:arguments` - normalized validated arguments
- `:request_index` - original position in the requested batch
- `:raw` - original provider/model tool-call payload
- `:metadata` - optional metadata

Notes:

- [x] Preserve the original provider payload for observability.
- [x] Keep argument normalization separate from execution.
- [x] Make request order explicit so reductions stay deterministic.

### `RunicAI.Tool.ExecutionPolicy`

Purpose: workflow-visible execution constraints and defaults for one tool or
one batch.

Suggested fields:

- `:mode` - `:parallel | :serial | {:staged, term()}`
- `:timeout` - timeout policy
- `:max_concurrency` - optional concurrency cap
- `:retry` - retry/backoff hint or policy struct
- `:dispatch` - immediate, async, scheduled, or runtime hint
- `:stop_on_error` - boolean or strategy
- `:metadata` - optional metadata

Notes:

- [x] Keep execution mode explicit rather than inferred from implementation
      detail.
- [x] Let tool definitions provide defaults while recipes or turns override
      them.
- [x] Shape dispatch and scheduling as hints so Phase 3 can extend them without
      changing the contract.

### `RunicAI.Tool.ExecutionPlan`

Purpose: the executable plan for one requested tool batch.

Suggested fields:

- `:calls` - ordered list of `Tool.CallRequest`
- `:policy` - effective execution policy for the batch
- `:groups` - optional staged or grouped execution structure
- `:metadata` - optional metadata

Notes:

- [x] Build the plan after tool selection and request interpretation but before
      execution.
- [x] Make parallel, serial, and staged execution all expressible as one value.
- [x] Keep planning deterministic and side-effect free.

### `RunicAI.Tool.BatchResult`

Purpose: a workflow-stable wrapper around one reduced batch of tool execution
results.

Suggested fields:

- `:results` - ordered list of `Tool.CallResult`
- `:metadata` - optional metadata

Notes:

- [x] Carry tool batches through Runic as one explicit value instead of a bare
      list.
- [x] Preserve deterministic ordering after execution and reduction.
- [x] Keep the wrapper intentionally small so later phases can attach tracing or
      aggregate metadata without changing every step signature.

### `RunicAI.Tool.CallResult`

Purpose: the normalized outcome of one tool invocation.

Suggested fields:

- `:request` - original `Tool.CallRequest`
- `:status` - `:ok | :error | :retry | :skipped`
- `:output` - normalized successful payload
- `:error` - optional normalized error
- `:started_at` - optional timestamp
- `:completed_at` - optional timestamp
- `:metadata` - optional metadata

Notes:

- [x] Do not let arbitrary callback return values leak past this boundary.
- [x] Keep timing and status explicit for later observability work.
- [x] Make retryability a first-class outcome, not an exception side channel.

### `RunicAI.Tool.Observation`

Purpose: the normalized record fed back into prompt assembly and agent state
after tool execution.

Suggested fields:

- `:call_id` - related tool call id
- `:tool_name` - tool name
- `:message` - normalized observation message
- `:result` - optional `Tool.CallResult`
- `:metadata` - optional metadata

Notes:

- [x] Keep observations model-ready without losing machine-readable detail.
- [x] Preserve the connection between observation and underlying tool result.
- [x] Support both successful and failed tool observations.

## Recommended Module And File Layout

```text
lib/runic_ai/
  tool/
    definition.ex
    registry.ex
    selection.ex
    call_request.ex
    execution_policy.ex
    execution_plan.ex
    batch_result.ex
    call_result.ex
    observation.ex
    executor.ex
  steps/
    select_tools.ex
    attach_visible_tools.ex
    interpret_tool_requests.ex
    plan_tool_execution.ex
    execute_tool_calls.ex
    reduce_tool_results.ex
    append_tool_observations.ex
  recipes/
    conversational_tool_agent.ex
```

Notes:

- [x] Keep the new tool contracts under `RunicAI.Tool`.
- [x] Keep execution adapters and policy contracts distinct from steps.
- [x] Keep the recipe namespace for assembled workflows, not low-level helpers.

## Recommended Kernel Path

This should be the canonical tool-using conversational path by the end of the
phase.

1. input message and current state become `RunicAI.Agent.TurnRequest`
2. current state and policy become `RunicAI.Tool.Selection`
3. turn request plus tool selection become a prompt and tool-visible model turn
4. model generation becomes `RunicAI.LLM.Result`
5. result interpretation becomes either:
   - conversational `TurnResult`
   - tool-requesting `TurnResult`
6. tool-requesting turns become `RunicAI.Tool.ExecutionPlan`
7. execution plan becomes one or more `RunicAI.Tool.CallResult`
8. call results become `RunicAI.Tool.Observation`
9. observations reduce into `RunicAI.Agent.State`
10. continuation rules decide whether to return to generation or stop

That path is the tool kernel.
Everything else in the phase should make that path clearer, safer, or more
reusable.

## Recommended Tool Loop Shape

The assembled loop should read like this:

```text
assemble turn request
  -> select visible tools
  -> assemble prompt and tool exposure
  -> generate turn
  -> interpret turn
  -> if conversational reply/final:
       update state
       decide continue/stop
     if tool requests:
       plan execution
       execute tool batch
       reduce tool results
       append observations
       continue
```

The model should never directly "run a tool."
It should only produce a typed request for the workflow to evaluate.

## Implementation Workstreams

### Workstream 1 - Freeze The Tool And Execution Contracts

Outcome: the tool lane has stable public nouns before recipe assembly begins.

- [x] Write and agree final field lists and typespecs for:
      `RunicAI.Tool.Definition`, `RunicAI.Tool.Registry`,
      `RunicAI.Tool.Selection`, `RunicAI.Tool.CallRequest`,
      `RunicAI.Tool.ExecutionPolicy`, `RunicAI.Tool.ExecutionPlan`,
      `RunicAI.Tool.BatchResult`, `RunicAI.Tool.CallResult`, and
      `RunicAI.Tool.Observation`.
- [x] Decide how tool-requesting turns are represented in
      `RunicAI.Agent.TurnResult.details`.
- [x] Decide how much provider-native tool payload to preserve on normalized
      tool request/result contracts.
- [x] Decide the minimal execution modes Phase 2 fully supports:
      `:parallel`, `:serial`, and staged execution if the plan supports it.
- [x] Document invariants directly in module docs and typespecs.

### Workstream 2 - Implement Tool Definitions, Registry, And Visibility

Outcome: the workflow can reason about what capabilities exist before it tries
to execute any of them.

- [x] Add `RunicAI.Tool.Definition` with validation helpers and executor
      references.
- [x] Add `RunicAI.Tool.Registry` with construction and lookup helpers.
- [x] Add `RunicAI.Tool.Selection` as the per-turn visible tool set.
- [x] Add a tool-selection component that filters tools by agent state, recipe
      opts, or user-supplied policy.
- [x] Add prompt/tool exposure helpers so selected tools are exposed to the LLM
      through one consistent adapter path.

### Workstream 3 - Interpret Tool Requests From Model Turns

Outcome: model-originated tool requests become typed workflow inputs.

- [x] Extend turn interpretation so Phase 1's reserved `:tool_requests` path is
      fully implemented.
- [x] Add a normalization layer from provider-native tool call payloads into
      `RunicAI.Tool.CallRequest`.
- [x] Validate tool names against the visible tool selection or registry.
- [x] Validate call arguments against tool schemas before execution planning.
- [x] Keep malformed or unknown tool calls as explicit typed failures or
      observations rather than silently dropping them.

### Workstream 4 - Add Tool Execution Planning

Outcome: requested tool batches become explicit executable plans.

- [x] Add `RunicAI.Tool.ExecutionPolicy` with batch and per-tool override rules.
- [x] Add `RunicAI.Tool.ExecutionPlan` and helpers that compute the effective
      plan from tool requests, tool metadata, and recipe policy.
- [x] Support a default parallel execution path for independent calls.
- [x] Support serial execution for side-effectful or ordered tools.
- [x] Support staged execution only if it stays clear and deterministic at the
      contract level.

### Workstream 5 - Add Tool Execution Components

Outcome: the workflow can execute normalized tool batches through one adapter
path.

- [x] Add a tool executor adapter that invokes one `Tool.CallRequest` against a
      `Tool.Definition`.
- [x] Add a batch execution component that runs planned calls using the
      configured execution mode.
- [x] Use Runic-native fan-out/fan-in or `map`/`reduce` style composition for
      the default parallel path.
- [x] Preserve stable batch result ordering even when execution happens in
      parallel.
- [x] Normalize successful, retryable, skipped, and failed tool outcomes into
      `RunicAI.Tool.CallResult`.

### Workstream 6 - Add Tool Result Reduction And Observation Shaping

Outcome: tool outputs become clean workflow-visible observations instead of
arbitrary callback returns.

- [x] Add a reduction step that merges one batch of `Tool.CallResult` into a
      deterministic grouped outcome.
- [x] Add `RunicAI.Tool.Observation` and observation-building helpers.
- [x] Append tool observations back into agent state in a reusable way.
- [x] Ensure prompt assembly can include tool observations without special-case
      recipe code.
- [x] Keep tool-result and observation normalization deterministic and local.

### Workstream 7 - Add Failure, Retry, And Fallback Semantics

Outcome: tool failures become explicit workflow behavior instead of ad hoc loop
breakage.

- [x] Define how retryable tool failures are represented and surfaced.
- [x] Add default policies for tool timeout, execution error, validation error,
      and unknown tool name.
- [x] Support fallback behavior such as:
      retry, convert-to-observation, stop, or halt.
- [x] Keep these policies composable and data-driven instead of baking them
      into one recipe branch.
- [x] Reserve room for richer Phase 3 operator review and budget gates without
      forcing contract rewrites.

### Workstream 8 - Build The Reference Conversational Tool Agent Recipe

Outcome: there is one obvious assembled workflow users can start from.

- [x] Build a `RunicAI.Recipes.ConversationalToolAgent` workflow or equivalent
      reference module.
- [x] Make the recipe read as the canonical tool path:
      assemble request -> select tools -> generate -> interpret -> plan ->
      execute -> reduce -> observe -> continue.
- [x] Expose configuration points for tool registry, visibility policy,
      execution policy, history window, final-answer detection, and failure
      behavior.
- [x] Keep the recipe thin enough that users can replace individual parts
      without throwing away the whole workflow.

### Workstream 9 - Docs, Tests, And Manual Verification

Outcome: the tool lane is teachable and safe to extend.

- [x] Add unit tests for all new tool contracts and validation helpers.
- [x] Add tests for tool visibility and selection policy.
- [x] Add tests for tool-request normalization and schema validation.
- [x] Add tests for parallel and serial execution planning.
- [x] Add tests for normalized call-result and observation shaping.
- [x] Add an end-to-end conversational tool-agent workflow test with iterative
      tool use.
- [x] Perform a manual provider-backed smoke test through Tidewave with a real
      ReqLLM provider and one or more local tools.
- [x] Update README and phase docs so the tool kernel is discoverable.

## Recommended Implementation Sequence

- [x] Step 1: freeze the tool and execution contracts first.
- [x] Step 2: implement tool definitions, registry, and selection second.
- [x] Step 3: implement tool-request interpretation third.
- [x] Step 4: implement execution policy and planning fourth.
- [x] Step 5: implement tool execution and batch reduction fifth.
- [x] Step 6: append observations back into state sixth.
- [x] Step 7: add failure and fallback behavior seventh.
- [x] Step 8: build the reference recipe eighth.
- [x] Step 9: finish with docs, tests, and manual verification.

## Recommended Early Decisions

These should be decided near the start and then kept stable for the rest of the
phase unless a real contradiction appears.

- [x] Treat a tool call as a model-originated capability request, not direct
      execution.
- [x] Keep tool visibility separate from tool execution permission.
- [x] Make batch planning explicit with a `Tool.ExecutionPlan` instead of
      burying orchestration logic in the executor.
- [x] Default to parallel execution for independent tool batches, but preserve
      explicit serial and staged policies.
- [x] Preserve deterministic result ordering even when execution is parallel.
- [x] Shape dispatch and scheduling as policy hints now so later durable
      execution work extends the same contracts.
- [x] Extend the Phase 1 kernel rather than building a second unrelated loop
      model for tool agents.

## Acceptance Criteria

Phase 2 is complete when all of the following are true.

- [x] RunicAI has public tool contracts layered cleanly on top of the Phase 1
      kernel contracts.
- [x] A model turn can expose a selected tool set and interpret tool requests
      into typed `Tool.CallRequest` values.
- [x] Tool batches can execute through a normalized adapter path with explicit
      execution policy.
- [x] Parallel tool execution is supported with deterministic reduction.
- [x] Serial execution is supported for ordered or side-effectful tools.
- [x] Tool results reduce into normalized observations that feed back into
      `Agent.State`.
- [x] A reference conversational tool-agent workflow exists and passes
      end-to-end tests.
- [x] README and docs show the tool-calling kernel as the next layer above the
      conversational kernel.

## Explicitly Out Of Scope

Keep these out of Phase 2 so the tool lane settles before the surface widens.

- [ ] Human approval gates before tool execution
- [ ] Rich wait/resume operator flows for long-running tool calls
- [ ] Spend budgets and advanced policy gates beyond basic execution policy
- [ ] Retrieval and RAG as a first-class context system
- [ ] Long-term memory systems
- [ ] Multi-agent spawning or handoff execution
- [ ] Sandbox or capability-specific permission brokering
- [ ] Evaluator/judge loops beyond basic recipe and contract verification

## Notes For The Follow-On Phase

If Phase 2 lands well, Phase 3 should be able to add guards, review gates,
budgets, and durable wait/resume controls around the same tool contracts and
execution plans rather than replacing the tool loop model.

That is the real test of this design:

- tool selection should remain a separate concern from policy gates
- execution planning should remain a separate concern from review and budgets
- observations should remain a stable input back into the conversational kernel
