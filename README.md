# RunicAI

A toolbox of AI components built on top of [Runic](https://hex.pm/packages/runic) workflows
and [ReqLLM](https://hex.pm/packages/req_llm).

RunicAI provides reusable building blocks for constructing AI agent loops, LLM workflow steps,
error-handling control flow, scheduling policies, fallback patterns, and more — all composed
as Runic workflow graphs. Users build their own AI workflows and agents by assembling
the components provided.

## Key Ideas

- **Runic-native** — Every component is a standard Runic `Step`, `Rule`, `StateMachine`, etc.,
  composable into `Runic.Workflow` graphs with full DAG-based dataflow evaluation.
- **Contract-owned** — RunicAI owns the values that move through workflows:
  `RunicAI.Message`, `RunicAI.Prompt`, `RunicAI.Conversation.State`,
  `RunicAI.LLM.Request`, `RunicAI.LLM.Result`, and the Phase 1 kernel contracts
  under `RunicAI.Agent.*`, plus the Phase 2 tool lane contracts under
  `RunicAI.Tool.*`, the Phase 4 context-engineering contracts under
  `RunicAI.Context.*`, `RunicAI.Memory.*`, and `RunicAI.Retrieval.*`, and the
  Phase 5 decomposition contracts under `RunicAI.Decomposition.*`, plus the
  Phase 6 workflow-owned runtime contracts under `RunicAI.Integrated.*`.
- **LLM-agnostic** — LLM access goes through a thin `RunicAI.LLM` behaviour backed by ReqLLM.
  Clients are injected per call as plain modules or functions.
- **No process assumptions** — Components are pure data structures evaluated lazily.
  Bring your own GenServer, GenStage, or bare Task.
- **Operability-first** — Phase 7 adds typed traces, in-memory harness drivers,
  deterministic scripted doubles, replay helpers, and accumulator-backed
  evaluation workflows without collapsing the library into one runtime topology.

## Installation

Add `runic_ai` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:runic_ai, "~> 0.1.0"}
  ]
end
```

## Quick Example

```elixir
require Runic
alias Runic.Workflow
alias RunicAI.LLM.Request
alias RunicAI.LLM.Result

# A step that calls an LLM through the normalized request/result contracts
llm_step =
  Runic.step(
    fn prompt_text ->
      request = Request.new!("anthropic:claude-haiku-4-5", prompt_text)
      {:ok, result} = RunicAI.LLM.generate_text(request)
      Result.text(result)
    end,
    name: :ask_llm
  )

workflow = Runic.workflow(name: :simple_llm, steps: [llm_step])
workflow = Workflow.react_until_satisfied(workflow, "Explain recursion briefly.")

Workflow.raw_productions(workflow)
```

## Testing

LLM calls are injectable out of the box with plain modules or functions:

```elixir
test "generates text" do
  client = fn _model, _prompt, _opts ->
    {:ok, RunicAI.LLM.TestClient.result("mocked response")}
  end

  assert {:ok, result} =
           RunicAI.LLM.generate_text("anthropic:claude-haiku-4-5", "hello", client: client)

  assert RunicAI.LLM.Result.text(result) == "mocked response"
end
```

## Core Contracts

- `RunicAI.Message` — canonical workflow message
- `RunicAI.Prompt` — provider-neutral prompt bundle
- `RunicAI.Conversation.State` — reducer state for conversation flows
- `RunicAI.LLM.Request` — normalized text-generation request
- `RunicAI.LLM.Result` — normalized text-generation result
- `RunicAI.Agent.State` — durable conversational agent state
- `RunicAI.Agent.TurnRequest` — one conversational turn input
- `RunicAI.Agent.TurnResult` — one interpreted conversational turn output
- `RunicAI.Agent.ContinueDecision` — explicit loop-control decision
- `RunicAI.Tool.Definition` — canonical tool definition and executor boundary
- `RunicAI.Tool.Registry` — validated available-tool registry
- `RunicAI.Tool.Selection` — per-turn visible tool set
- `RunicAI.Tool.RequirementPolicy` — semantic recipe-level tool-use policy,
  such as optional vs required-before-answer
- `RunicAI.Tool.CallRequest` — normalized one-shot tool invocation request
- `RunicAI.Tool.ExecutionPolicy` — explicit execution and failure policy
- `RunicAI.Tool.ExecutionPlan` — deterministic batch execution plan
- `RunicAI.Tool.BatchResult` — workflow-stable wrapper for tool call batches
- `RunicAI.Tool.CallResult` — normalized tool invocation outcome
- `RunicAI.Tool.Observation` — model-ready tool observation message
- `RunicAI.Control.BudgetPolicy` — declarative turn, model, tool, time, cost,
  and recursion limits
- `RunicAI.Control.GuardRequest` — typed guard input at named workflow
  boundaries
- `RunicAI.Control.GuardDecision` — allow, deny, review, wait, or rewrite
  outcome
- `RunicAI.ReviewRequest` / `RunicAI.ReviewDecision` — typed operator approval
  round-trips
- `RunicAI.Wait` / `RunicAI.ResumeSignal` — typed deferred-progress and resume
  contracts
- `RunicAI.Context.Ref` — stable context graph reference with provenance labels
- `RunicAI.Context.Node` — typed graph node for messages, summaries, memory,
  retrieval, and handoff artifacts
- `RunicAI.Context.Graph` — wrapped multigraph substrate for context lineage
- `RunicAI.Context.State` — durable derived context state carried with agent
  state
- `RunicAI.Context.Focus` — explicit current goal, entities, constraints, and
  salience hints
- `RunicAI.Context.Bundle` — assembled active window just before prompt
  projection
- `RunicAI.Context.WindowPolicy` / `RunicAI.Context.CompactionPolicy` —
  explicit window and compaction policy data
- `RunicAI.Context.PressureSnapshot` / `RunicAI.Context.PressureDecision` —
  typed context-window pressure evaluation
- `RunicAI.Context.HandoffRequest` / `RunicAI.Context.HandoffArtifact` —
  typed thread-handoff input and output
- `RunicAI.Memory.Entry` / `RunicAI.Memory.Query` / `RunicAI.Memory.ReadResult`
  / `RunicAI.Memory.Store` — provenance-first memory contracts and adapter seam
- `RunicAI.Retrieval.Query` / `RunicAI.Retrieval.Document` /
  `RunicAI.Retrieval.Result` / `RunicAI.Retrieval.Provider` —
  backend-neutral retrieval contracts and adapter seam
- `RunicAI.Decomposition.Role` / `RunicAI.Decomposition.Registry` — reusable
  delegate profiles and validated role catalogs
- `RunicAI.Decomposition.InheritancePolicy` / `RunicAI.Decomposition.Task` /
  `RunicAI.Decomposition.TaskPlan` / `RunicAI.Decomposition.Assignment` —
  typed child planning and materialized assignment contracts
- `RunicAI.Decomposition.Result` / `RunicAI.Decomposition.JoinPolicy` /
  `RunicAI.Decomposition.Evaluation` — normalized child outcomes, deterministic
  joins, and judge/jury assessment data
- `RunicAI.Integrated.AgentRef` / `RunicAI.Integrated.SessionState` —
  workflow-owned identity and per-lane live agent state
- `RunicAI.Integrated.Signal` / `RunicAI.Integrated.Emission` — typed inbound
  runtime events and identity-carrying outbound values
- `RunicAI.Integrated.PendingWork` / `RunicAI.Integrated.RuntimeState` —
  durable pause metadata and the authoritative accumulator state for one or
  many integrated agent lanes
- `RunicAI.Trace.Event` / `RunicAI.Trace.CapturePolicy` /
  `RunicAI.Trace.Trajectory` — semantic trace events, redaction-aware payload
  capture, and replayable execution artifacts
- `RunicAI.Harness.Policy` / `RunicAI.Harness.Session` — process-agnostic
  operational policy and serializable session state for harness-driven runs
- `RunicAI.Evaluation.Case` / `RunicAI.Evaluation.Expectation` /
  `RunicAI.Evaluation.Result` / `RunicAI.Evaluation.Run` — typed evaluation
  fixtures, scoring predicates, case results, and aggregate run artifacts

## Conversational Kernel

Phase 1 adds a reference conversational kernel workflow in
`RunicAI.Recipes.ChatAgentKernel`.

The kernel path is:

```text
Agent.State + input
  -> TurnRequest
  -> Prompt
  -> LLM.Result
  -> TurnResult
  -> Agent.State
  -> ContinueDecision
```

Example:

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.ChatAgentKernel

workflow =
  ChatAgentKernel.new(
    model: "openai:gpt-4.1-mini",
    system: "You are concise"
  )

workflow =
  Workflow.react_until_satisfied(workflow, %{
    user: "Reply with exactly hello."
  })

state = ChatAgentKernel.latest_state(workflow)
reply = ChatAgentKernel.latest_reply_text(workflow)
decision = ChatAgentKernel.latest_continue_decision(workflow)
```

## Tool-Calling Kernel

Phase 2 adds a reference conversational tool agent workflow in
`RunicAI.Recipes.ConversationalToolAgent`.

The tool path is:

```text
Agent.State + input
  -> TurnRequest
  -> Tool.Selection
  -> Prompt + visible tools
  -> LLM.Result
  -> TurnResult
  -> Tool.ExecutionPlan
  -> Tool.BatchResult
  -> Tool.Observation[]
  -> Agent.State
  -> ContinueDecision
```

Example:

```elixir
alias RunicAI.Recipes.ConversationalToolAgent
alias RunicAI.Tool.Definition

weather_tool =
  Definition.new!(
    name: "get_weather",
    description: "Get the weather for a city",
    parameter_schema: [location: [type: :string, required: true]],
    executor: fn %{location: location} ->
      {:ok, %{location: location, forecast: "sunny"}}
    end
  )

workflow =
  ConversationalToolAgent.react_until_resolution(
    [
      model: "openai:gpt-4.1-mini",
      system: "Call tools before answering when the request depends on them.",
      registry: [weather_tool],
      llm_opts: [temperature: 0.0]
    ],
    %{user: "What's the weather in Paris?"}
  )

reply = ConversationalToolAgent.latest_reply_text(workflow)
tool_results = ConversationalToolAgent.latest_tool_results(workflow)
```

## Decomposition Workflows

Phase 5 adds typed delegation and fan-out/fan-in recipes on top of the earlier
single-thread kernels.

The decomposition path is:

```text
TaskPlan
  -> Assignment[]
  -> child execution
  -> Result[]
  -> JoinPolicy
  -> reduced Result
```

Example:

```elixir
alias RunicAI.Decomposition.Role
alias RunicAI.Decomposition.Task
alias RunicAI.Decomposition.TaskPlan
alias RunicAI.Recipes.PlannerExecutorWorkflow

worker_role =
  Role.new!(
    name: "worker",
    kind: :workflow,
    description: "Produce one keyed payload",
    builder: fn assignment ->
      payload = assignment.input.input
      %{payload[:key] => payload[:value]}
    end
  )

task_plan =
  TaskPlan.new!(
    [
      Task.new!(id: "alpha", goal: "Produce alpha", role: "worker", input: %{key: :alpha, value: 1}),
      Task.new!(id: "beta", goal: "Produce beta", role: "worker", input: %{key: :beta, value: 2})
    ],
    join_policy: [mode: :merge]
  )

workflow =
  PlannerExecutorWorkflow.react_until_resolution(
    [registry: [worker_role]],
    %{task_plan: task_plan}
  )

result = PlannerExecutorWorkflow.latest_result(workflow)
```

The Phase 5 reference recipes are:

- `RunicAI.Recipes.PlannerExecutorWorkflow`
- `RunicAI.Recipes.ParallelResearchSynthesizer`
- `RunicAI.Recipes.ReviewerEditorJury`

Two useful Phase 5 details:

- `RunicAI.Decomposition.JoinPolicy` `:merge` mode supports
  `merge_conflicts: :error | :first_wins | :last_wins | :nest_by_task`
  so overlapping child outputs are explicit rather than silently order-dependent.
- `RunicAI.Recipes.ParallelResearchSynthesizer` returns namespaced
  `findings_by_task` and `findings_by_topic` in its deterministic output, and
  can optionally run a `:synthesizer_role` child for a final synthesis pass
  while keeping the deterministic reduction as a fallback.

## Controlled Tool Agent

Phase 3 adds the guarded reference recipe in
`RunicAI.Recipes.GuardedOperatorToolAgent`.

This recipe wraps the Phase 2 tool lane with:

- budget evaluation
- guard points before tool execution and before answer emission
- typed review and wait outputs
- retry and fallback wrappers around LLM and tool boundaries

The controlled path is:

```text
Agent.State + input
  -> TurnRequest
  -> Tool.Selection
  -> Prompt + visible tools
  -> LLM.Result
  -> TurnResult
  -> BudgetDecision / GuardDecision
  -> ReviewRequest | Wait | Tool.ExecutionPlan | Agent.State
  -> Tool.BatchResult
  -> Agent.State
  -> ContinueDecision
```

Example:

```elixir
alias RunicAI.Recipes.GuardedOperatorToolAgent
alias RunicAI.Tool.Definition

transfer_tool =
  Definition.new!(
    name: "initiate_transfer",
    description: "Initiate a bank transfer",
    parameter_schema: [
      account_id: [type: :string, required: true],
      amount_cents: [type: :integer, required: true]
    ],
    executor: fn args -> {:ok, %{accepted: true, args: args}} end
  )

workflow =
  GuardedOperatorToolAgent.new(
    model: "openai:gpt-4.1-mini",
    registry: [transfer_tool],
    budget_policy: [max_tool_calls: 1, on_exhaustion: :review],
    pre_tool_guard: fn request ->
      requested_tools = Enum.map(request.execution_plan.calls, & &1.tool_name)

      if "initiate_transfer" in requested_tools do
        :review
      else
        :allow
      end
    end
  )
  |> Runic.Workflow.react_until_satisfied(%{user: "Transfer $25 to acct_123."})

pending_review = GuardedOperatorToolAgent.latest_review_request(workflow)
state = GuardedOperatorToolAgent.latest_state(workflow)
```

### External-State Pause And Resume

The guarded recipe is intentionally persistence-agnostic.

When a turn pauses, persist the returned `Agent.State` and inspect
`state.pending_action`:

- `RunicAI.ReviewRequest` means the caller should collect a
  `RunicAI.ReviewDecision`
- `RunicAI.Wait` means the caller should collect a `RunicAI.ResumeSignal`

Phase 3 ships the normalization steps that let your runtime handle that
re-entry explicitly:

```elixir
alias RunicAI.Steps.ApplyReviewDecision
alias RunicAI.Steps.NormalizeResumeSignal

approved_subject =
  ApplyReviewDecision.apply_decision!(review_request, review_decision)

resume_payload =
  NormalizeResumeSignal.normalize!(wait, resume_signal)
```

The guarded recipe helper also accepts those typed values directly on the next
turn:

```elixir
resumed_workflow =
  GuardedOperatorToolAgent.react_until_resolution(
    [model: "openai:gpt-4.1-mini", registry: [transfer_tool]],
    %{
      state: state,
      review_decision: %{resume_key: pending_review.resume_key, status: :approved}
    }
  )
```

That keeps the workflow contracts typed and serializable without requiring a
live in-memory pause process.

## Context Engineering Layer

Phase 4 adds an explicit context layer on top of transcript history instead of
stretching one ever-growing prompt window forever.

The intended shape is:

```text
Conversation.State
  -> Context.State
  -> Focus
  -> Memory recall / Retrieval input
  -> PressureDecision
  -> Compaction
  -> Context.Bundle
  -> Prompt
```

The core design rule is that transcript history remains source-of-truth state,
while active context is a derived graph with stable refs back to original
messages, tool observations, summaries, memory entries, and handoff artifacts.

Phase 4 ships three reference recipes:

- `RunicAI.Recipes.SummaryBackedChatAgent` — chat workflow with focus
  inference, pressure evaluation, summary compaction, memory recall, and
  retrieval-aware bundle assembly
- `RunicAI.Recipes.MemoryAwareToolAgent` — tool-calling workflow extended with
  the same context-engineering path plus post-turn and post-tool memory writes
- `RunicAI.Recipes.HandoffContextBuilder` — focused handoff artifact builder
  for starting a new thread from an existing `RunicAI.Agent.State`

Example:

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.SummaryBackedChatAgent

workflow =
  SummaryBackedChatAgent.new(
    model: "openai:gpt-4.1-mini",
    system: "You keep track of long-running work carefully.",
    window_policy: [soft_pressure_tokens: 1_200, hard_pressure_tokens: 1_800],
    summarizer: fn _prompt, _opts ->
      {:ok, RunicAI.LLM.TestClient.result("Summary: the user is debugging the payment flow.")}
    end
  )
  |> Workflow.react_until_satisfied(%{user: "We fixed auth yesterday. Focus on payment retries now."})

reply = SummaryBackedChatAgent.latest_reply_text(workflow)
focus = SummaryBackedChatAgent.latest_focus(workflow)
pressure = SummaryBackedChatAgent.latest_pressure_decision(workflow)
bundle = SummaryBackedChatAgent.latest_bundle(workflow)
```

Retrieval stays intentionally light in the core library. RunicAI owns the
contracts, normalization, and recipe wiring, while storage, search, embeddings,
and indexing stay behind user-supplied adapters.

## Integrated Stateful Recipes

Phase 6 adds a workflow-owned state track on top of the earlier external-state
recipes.

The key difference is where the live loop state sits:

- `RunicAI.Recipes.ChatAgentKernel`,
  `RunicAI.Recipes.ConversationalToolAgent`, and
  `RunicAI.Recipes.GuardedOperatorToolAgent` keep `RunicAI.Agent.State`
  persistence-agnostic so a caller can store it and decide when to re-enter.
- `RunicAI.Recipes.IntegratedChatAgent` and
  `RunicAI.Recipes.IntegratedToolAgent` keep that state inside the workflow
  itself under an authoritative `RunicAI.Integrated.RuntimeState`,
  maintained by a `Runic.accumulator`, with routing decisions driven by
  `state_of/1`.

The integrated path is:

```text
Integrated.Signal
  -> Integrated.RuntimeState accumulator
  -> state_of(:integrated_runtime) routing rule
  -> Integrated.SessionState for one agent_id
  -> existing turn/tool/control contracts
  -> updated Integrated.SessionState
  -> Integrated.Emission | more Integrated.Signal | quiescence
```

This lets one or many agent lanes share a workflow while still reusing the
Phase 1-5 contracts for turns, tool plans, budgets, waits, reviews, and
resume signals.

Phase 6 ships three reference recipes:

- `RunicAI.Recipes.IntegratedAgentKernel` — generic workflow-owned runtime
  kernel for typed integrated signals and emissions
- `RunicAI.Recipes.IntegratedChatAgent` — stateful chat recipe that keeps
  conversation state inside the workflow across repeated signals
- `RunicAI.Recipes.IntegratedToolAgent` — stateful tool recipe with scoped
  review, wait, wake, and resume handling inside the same workflow runtime

Example:

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.IntegratedChatAgent

workflow =
  IntegratedChatAgent.new(
    default_agent_id: "chat",
    model: "openai:gpt-4.1-mini",
    system: "You are concise"
  )
  |> Workflow.react_until_satisfied(%{
    user: "My favorite color is vermilion. Reply only with noted."
  })

workflow =
  Workflow.react_until_satisfied(
    workflow,
    %{user: "What color did I say was my favorite? Reply with one word."}
  )

reply = IntegratedChatAgent.latest_reply_text(workflow, "chat")
session = IntegratedChatAgent.session(workflow, "chat")
```

`RunicAI.Recipes.IntegratedToolAgent` extends the same runtime with tool loops,
budget checks, guard pauses, typed review requests, typed waits, and wake or
resume signals, all scoped back to the correct `agent_id`.

## Observability, Testing, And Evaluation

Phase 7 adds a process-agnostic operability layer over both recipe families.

- `RunicAI.Trace.Event` gives a stable semantic event vocabulary for turns,
  tool plans, tool calls, tool results, reviews, waits, emissions, and final
  workflow quiescence
- `RunicAI.Trace.CapturePolicy` and `RunicAI.Trace.Trajectory` let callers
  choose summary, full, or replay-grade payload capture without changing the
  recipes themselves
- `RunicAI.Harness.TurnProcessor` and `RunicAI.Harness.Integrated` provide
  in-memory drivers that can submit inputs, drain until quiescence, preserve
  snapshots, and attach sinks without committing to a GenServer or
  `Runic.Runner` runtime yet
- `RunicAI.Testing.ScriptedLLM`, `RunicAI.Testing.ScriptedToolExecutor`,
  `RunicAI.Testing.ScriptedRetrieval`, and `RunicAI.Testing.Replay` turn
  trajectories into deterministic doubles for regression work
- `RunicAI.Recipes.EvaluationHarness` runs `RunicAI.Evaluation.Case` fixtures
  through either recipe track and keeps running metrics under `Runic.accumulator`

Harness example:

```elixir
alias RunicAI.Harness.Policy
alias RunicAI.Harness.TurnProcessor
alias RunicAI.Recipes.GuardedOperatorToolAgent
alias RunicAI.Trace.Sinks.InMemory

policy =
  Policy.new!(
    capture_policy: [mode: :summary],
    sinks: [InMemory]
  )

session =
  TurnProcessor.new_session(GuardedOperatorToolAgent,
    recipe_opts: [
      model: "openai:gpt-4.1-mini",
      registry: [weather_tool],
      client: weather_client
    ],
    policy: policy
  )
  |> TurnProcessor.submit(%{user: "What's the weather in Paris?"})
  |> TurnProcessor.drain(policy)

trajectory = session.trajectory
latest = List.last(session.outputs)
```

Evaluation example:

```elixir
alias RunicAI.Evaluation.Case
alias RunicAI.Harness.Policy
alias RunicAI.Recipes.ChatAgentKernel
alias RunicAI.Recipes.EvaluationHarness

run =
  EvaluationHarness.run(
    [
      Case.new!(
        id: "hello-case",
        input: %{user: "say hello"},
        expected: [{:contains_text, "hello"}]
      )
    ],
    recipe: ChatAgentKernel,
    recipe_opts: [model: "openai:gpt-4.1-mini", client: client],
    policy: Policy.new!(capture_policy: [mode: :summary])
  )

run.aggregate
run.results
```
