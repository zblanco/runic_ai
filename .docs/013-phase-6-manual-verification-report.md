# Phase 6 Manual Verification Report

Status: completed

Date: 2026-04-21

Follow-up note:
The `tool_choice: :required` sharp edge described in this report was later
addressed by replacing recipe-level raw tool choice with
`RunicAI.Tool.RequirementPolicy`. The findings below reflect the pre-fix
behavior observed during the original manual verification run.

## Goal

Run a realistic manual verification pass for the Phase 6 integrated stateful
agent workflows against real LLM providers, then compare expected behavior to
actual behavior and record any issues or edge cases worth fixing.

This report exercises:

- real provider-backed `RunicAI.LLM` generation inside integrated workflows
- workflow-owned chat state carried across repeated external signals
- workflow-owned tool execution to quiescence
- typed review pause and resume inside the same integrated runtime
- typed wait and wake across multiple agent lanes
- edge-case behavior when `tool_choice: :required` is used in a looping
  stateful tool workflow

## Environment

- Project: `runic_ai`
- Live node: `runicai@boops`
- Eval path: Tidewave `project_eval`
- Transport detail:
  Tidewave's normal HTTP transport was not reachable from my sandbox network
  namespace, so I attached to the live node via remote IEx and invoked
  `Tidewave.MCP.Tools.Eval.project_eval/2` directly inside that node.
  This still used Tidewave's real eval path and the project IEx context.
- IEx helper used: `recompile/0`
- Providers used: OpenAI and Anthropic
- Models used:
  - `openai:gpt-4.1-mini`
  - `anthropic:claude-sonnet-4-5-20250929`

## Practical Note

I attached to the user-provided live node with:

```bash
iex --sname codexattach --remsh runicai@boops
```

Then I recompiled inside the live node and used Tidewave's eval tool module
directly:

```elixir
recompile()

eval = fn code ->
  Tidewave.MCP.Tools.Eval.project_eval(
    %{"code" => code, "timeout" => 120_000},
    %{inspect_opts: [charlists: :as_lists, limit: :infinity, pretty: true]}
  )
end
```

That gave me the same IEx-backed evaluation behavior as the prior Tidewave
manual reports without relying on the local HTTP port from inside the sandbox.

## Preconceived Expectations

Before running anything, I expected the following:

1. `IntegratedChatAgent` should preserve conversation state inside the workflow
   across repeated external signals without the caller re-supplying
   `Agent.State`.
2. `IntegratedToolAgent` should drive a real model -> tool -> model loop to
   quiescence and emit a final reply when no review or wait is involved.
3. A `:review` decision at `:pre_tool` should pause the integrated lane, accept
   a typed `ReviewDecision`, and then continue to an emitted reply in the same
   workflow runtime.
4. A `:wait` decision at `:pre_tool` should pause only the targeted lane,
   allow other agent lanes to continue, and later resume correctly from a typed
   wake signal.
5. `tool_choice: :required` might be dangerous in a looping integrated tool
   recipe, because a workflow that expects a final assistant answer after tool
   observations may never become eligible to answer without another tool call.

## Provider Smoke Test

### Tidewave Input

```elixir
recompile()
alias RunicAI.LLM

models = [
  "openai:gpt-4.1-mini",
  "anthropic:claude-sonnet-4-5-20250929"
]

Enum.map(models, fn model ->
  case LLM.generate_text(model, "Reply with exactly the single word pong.", temperature: 0.0) do
    {:ok, result} -> %{model: model, status: :ok, text: RunicAI.LLM.Result.text(result)}
    {:retry, error} -> %{model: model, status: :retry, error: inspect(error)}
    {:error, error} -> %{model: model, status: :error, error: inspect(error)}
  end
end)
```

### Observed Output

```elixir
[
  %{status: :ok, text: "pong", model: "openai:gpt-4.1-mini"},
  %{status: :ok, text: "pong", model: "anthropic:claude-sonnet-4-5-20250929"}
]
```

### Assessment

- Matched expectation.
- Both providers were healthy before the Phase 6 workflow scenarios.

## Scenario 1: Stateful Chat Memory Across Signals

### Expectation

- First turn should reply with exactly `ACK`
- Second turn should recall the earlier codename from workflow-owned state
- Session should end `:idle`
- Conversation should show 2 turns
- Emissions should contain two reply events

### Tidewave Input

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.IntegratedChatAgent

model = "anthropic:claude-sonnet-4-5-20250929"

workflow =
  IntegratedChatAgent.new(
    default_agent_id: "chat",
    model: model,
    system: "You are a precise verification assistant. Follow exact output instructions.",
    llm_opts: [temperature: 0.0]
  )
  |> Workflow.react_until_satisfied(%{
    user: "The verification codename is saffron-orbit. Reply with exactly ACK."
  })

first_reply = IntegratedChatAgent.latest_reply_text(workflow, "chat")

workflow =
  Workflow.react_until_satisfied(
    workflow,
    %{user: "What is the verification codename? Reply with exactly the codename and nothing else."}
  )

session = IntegratedChatAgent.session(workflow, "chat")

%{
  model: model,
  first_reply: first_reply,
  second_reply: IntegratedChatAgent.latest_reply_text(workflow, "chat"),
  turns: session.agent_state.conversation.turns,
  status: session.status,
  emission_kinds: Enum.map(IntegratedChatAgent.emissions(workflow), & &1.kind),
  messages:
    Enum.map(session.agent_state.conversation.messages, fn message ->
      %{role: message.role, content: message.content}
    end)
}
```

### Observed Output

```elixir
%{
  messages: [
    %{
      role: :system,
      content: "You are a precise verification assistant. Follow exact output instructions."
    },
    %{
      role: :user,
      content: "The verification codename is saffron-orbit. Reply with exactly ACK."
    },
    %{role: :assistant, content: "ACK"},
    %{
      role: :user,
      content: "What is the verification codename? Reply with exactly the codename and nothing else."
    },
    %{role: :assistant, content: "saffron-orbit"}
  ],
  status: :idle,
  model: "anthropic:claude-sonnet-4-5-20250929",
  first_reply: "ACK",
  second_reply: "saffron-orbit",
  turns: 2,
  emission_kinds: [:reply, :reply]
}
```

### Assessment

- Matched expectation exactly.
- This was a strong confirmation that the Phase 6 workflow-owned runtime is
  correctly carrying forward conversational state between separate signals.

## Scenario 2: Tool Loop To Quiescence

### Expectation

- Real model should call the tool once
- Integrated runtime should complete the tool loop and emit a final reply
- Session should end `:idle`
- Final reply should be exactly `GREEN`

### Tidewave Input

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.IntegratedToolAgent
alias RunicAI.Tool.Definition

model = "openai:gpt-4.1-mini"

tool =
  Definition.new!(
    name: "get_release_status",
    description: "Get the release status for a named service",
    parameter_schema: [service: [type: :string, required: true]],
    executor: fn %{service: service} ->
      {:ok, %{service: service, status: "green", open_incidents: 0}}
    end
  )

workflow =
  IntegratedToolAgent.new(
    default_agent_id: "ops",
    model: model,
    system: "You are a release verifier. Use the get_release_status tool when the user asks for service status. After using tools, reply with exactly GREEN if the service status is green, otherwise RED.",
    registry: [tool],
    llm_opts: [temperature: 0.0],
    budget_policy: [max_model_calls: 3, on_exhaustion: :halt]
  )
  |> Workflow.react_until_satisfied(%{
    user: "Check release status for payments_api using the available tool."
  })

session = IntegratedToolAgent.session(workflow, "ops")

%{
  model: model,
  final_status: session.status,
  pending_action: session.agent_state.pending_action,
  final_reply: IntegratedToolAgent.latest_reply_text(workflow, "ops"),
  turns: session.agent_state.conversation.turns,
  message_roles: Enum.map(session.agent_state.conversation.messages, & &1.role),
  emission_kinds: Enum.map(IntegratedToolAgent.emissions(workflow), & &1.kind)
}
```

### Observed Output

```elixir
%{
  model: "openai:gpt-4.1-mini",
  turns: 2,
  emission_kinds: [:reply],
  pending_action: nil,
  final_status: :idle,
  final_reply: "GREEN",
  message_roles: [:system, :user, :assistant, :tool, :assistant]
}
```

### Assessment

- Matched expectation.
- The base integrated tool lane behaved correctly with a real provider and a
  real tool selection/execution path.

## Scenario 3: Review Pause And Resume In The Same Runtime

### Expectation

- Initial run should stop in `:review`
- Review request checkpoint should be `:pre_tool`
- After an approved `ReviewDecision`, the same workflow runtime should resume
  and emit the final reply
- Final session should end `:idle`

### Tidewave Input

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.IntegratedToolAgent
alias RunicAI.Tool.Definition

model = "openai:gpt-4.1-mini"

tool =
  Definition.new!(
    name: "get_release_status",
    description: "Get the release status for a named service",
    parameter_schema: [service: [type: :string, required: true]],
    executor: fn %{service: service} ->
      {:ok, %{service: service, status: "green", open_incidents: 0}}
    end
  )

workflow =
  IntegratedToolAgent.new(
    default_agent_id: "ops",
    model: model,
    system: "You are a release verifier. Use the get_release_status tool when the user asks for service status. After using tools, reply with exactly GREEN if the service status is green, otherwise RED.",
    registry: [tool],
    llm_opts: [temperature: 0.0],
    budget_policy: [max_model_calls: 3, on_exhaustion: :halt],
    pre_tool_guard: fn _request -> :review end
  )
  |> Workflow.react_until_satisfied(%{
    user: "Check release status for payments_api using the available tool."
  })

review_request = IntegratedToolAgent.latest_review_request(workflow, "ops")
review_session = IntegratedToolAgent.session(workflow, "ops")

workflow =
  Workflow.react_until_satisfied(
    workflow,
    %{review_decision: %{resume_key: review_request.resume_key, status: :approved}}
  )

final_session = IntegratedToolAgent.session(workflow, "ops")

%{
  model: model,
  initial_status: review_session.status,
  review_checkpoint: review_request.checkpoint,
  final_status: final_session.status,
  pending_action: final_session.agent_state.pending_action,
  final_reply: IntegratedToolAgent.latest_reply_text(workflow, "ops"),
  turns: final_session.agent_state.conversation.turns,
  message_roles: Enum.map(final_session.agent_state.conversation.messages, & &1.role),
  emission_kinds: Enum.map(IntegratedToolAgent.emissions(workflow), & &1.kind)
}
```

### Observed Output

```elixir
%{
  model: "openai:gpt-4.1-mini",
  turns: 2,
  emission_kinds: [:review, :reply],
  pending_action: nil,
  initial_status: :review,
  review_checkpoint: :pre_tool,
  final_status: :idle,
  final_reply: "GREEN",
  message_roles: [:system, :user, :assistant, :tool, :assistant]
}
```

### Assessment

- Matched expectation.
- This confirmed the main review/resume path is working correctly in a real
  provider-backed integrated workflow.

## Scenario 4: Multi-Agent Wait And Wake

### Expectation

- `alpha` should be paused in `:waiting`
- `beta` should continue independently and finish with `GREEN`
- A typed wake signal should resume only `alpha`
- `alpha` should then finish with `RED`
- Runtime ready queue should be empty at the end

### Tidewave Input

```elixir
alias Runic.Workflow
alias RunicAI.Control.GuardDecision
alias RunicAI.Recipes.IntegratedToolAgent
alias RunicAI.Tool.Definition

model = "openai:gpt-4.1-mini"

tool =
  Definition.new!(
    name: "get_release_status",
    description: "Get the release status for a named service",
    parameter_schema: [service: [type: :string, required: true]],
    executor: fn %{service: service} ->
      status = if service == "alpha_service", do: "red", else: "green"
      {:ok, %{service: service, status: status, open_incidents: if(status == "red", do: 2, else: 0)}}
    end
  )

wait_guard = fn request ->
  service =
    request.execution_plan.calls
    |> List.first()
    |> Map.get(:arguments)
    |> Map.get(:service)

  if service == "alpha_service" do
    GuardDecision.wait!(:hold, metadata: %{until: DateTime.add(DateTime.utc_now(), 60, :second)})
  else
    :allow
  end
end

workflow =
  IntegratedToolAgent.new(
    model: model,
    system: "You are a release verifier. Use the get_release_status tool when the user asks for service status. After using tools, reply with exactly GREEN if the service status is green, otherwise RED.",
    registry: [tool],
    llm_opts: [temperature: 0.0],
    budget_policy: [max_model_calls: 3, on_exhaustion: :halt],
    agents: [[id: "alpha"], [id: "beta"]],
    pre_tool_guard: wait_guard
  )
  |> Workflow.react_until_satisfied(%{agent_id: "alpha", user: "Check release status for alpha_service using the available tool."})

alpha_wait = IntegratedToolAgent.latest_wait(workflow, "alpha")
alpha_waiting = IntegratedToolAgent.session(workflow, "alpha")

workflow =
  Workflow.react_until_satisfied(
    workflow,
    %{agent_id: "beta", user: "Check release status for beta_service using the available tool."}
  )

beta_done = IntegratedToolAgent.session(workflow, "beta")

workflow =
  Workflow.react_until_satisfied(
    workflow,
    %{wake: %{resume_key: alpha_wait.resume_key}}
  )

alpha_done = IntegratedToolAgent.session(workflow, "alpha")

%{
  model: model,
  alpha_wait_status: alpha_waiting.status,
  alpha_wait_resume_key_present?: is_binary(alpha_wait.resume_key),
  beta_status: beta_done.status,
  beta_reply: IntegratedToolAgent.latest_reply_text(workflow, "beta"),
  alpha_final_status: alpha_done.status,
  alpha_reply: IntegratedToolAgent.latest_reply_text(workflow, "alpha"),
  runtime_ready_queue: IntegratedToolAgent.runtime_state(workflow).ready_queue,
  emissions:
    Enum.map(IntegratedToolAgent.emissions(workflow), fn emission ->
      %{agent_id: emission.agent_id, kind: emission.kind}
    end)
}
```

### Observed Output

```elixir
%{
  model: "openai:gpt-4.1-mini",
  emissions: [
    %{kind: :wait, agent_id: "alpha"},
    %{kind: :reply, agent_id: "beta"},
    %{kind: :reply, agent_id: "alpha"}
  ],
  alpha_wait_status: :waiting,
  alpha_wait_resume_key_present?: true,
  beta_status: :idle,
  beta_reply: "GREEN",
  alpha_final_status: :idle,
  alpha_reply: "RED",
  runtime_ready_queue: []
}
```

### Assessment

- Matched expectation.
- This was the strongest integrated-runtime-specific success case in the whole
  verification pass: one lane waited, a second lane completed, and the first
  lane resumed correctly from a wake signal.

## Edge Case 1: `tool_choice: :required` Causes Non-Quiescent Tool Cycling

### Expectation

I already suspected this might be risky. If the recipe requires a tool call on
every model invocation, a tool workflow that expects to end with a plain final
assistant answer may never become eligible to stop naturally.

### Tidewave Input

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.IntegratedToolAgent
alias RunicAI.Tool.Definition

model = "openai:gpt-4.1-mini"

tool =
  Definition.new!(
    name: "get_release_status",
    description: "Get the release status for a named service",
    parameter_schema: [service: [type: :string, required: true]],
    executor: fn %{service: service} ->
      {:ok, %{service: service, status: "green", open_incidents: 0}}
    end
  )

workflow =
  IntegratedToolAgent.new(
    default_agent_id: "ops",
    model: model,
    system: "You are a release verifier. You must use tools when available. After using tools, reply with exactly GREEN if the service status is green, otherwise RED.",
    registry: [tool],
    tool_choice: :required,
    llm_opts: [temperature: 0.0]
  )
  |> Workflow.react_until_satisfied(%{
    user: "Check release status for payments_api."
  })

session = IntegratedToolAgent.session(workflow, "ops")

%{
  model: model,
  final_status: session.status,
  final_reply: IntegratedToolAgent.latest_reply_text(workflow, "ops"),
  turns: session.agent_state.conversation.turns,
  message_roles: Enum.map(session.agent_state.conversation.messages, & &1.role),
  emission_kinds: Enum.map(IntegratedToolAgent.emissions(workflow), & &1.kind)
}
```

### Observed Output

```elixir
%{
  model: "openai:gpt-4.1-mini",
  turns: 23,
  emission_kinds: [:status],
  final_status: :halted,
  final_reply: nil,
  message_roles: [:system, :user, :assistant, :tool, :assistant, :tool,
   :assistant, :tool, :assistant, :tool, :assistant, :tool, :assistant, :tool,
   :assistant, :tool, :assistant, :tool, :assistant, :tool, :assistant, :tool,
   :assistant, :tool, :assistant, :tool, :assistant, :tool, :assistant, :tool,
   :assistant, :tool, :assistant, :tool, :assistant, :tool, :assistant, :tool,
   :assistant, :tool, :assistant, :tool, :assistant, :tool, :assistant, :tool,
   :assistant, :tool]
}
```

### Assessment

- This did not behave as a normal "check once, then answer" flow.
- The workflow repeatedly cycled through assistant/tool turns until it halted.
- This looks much more like a configuration trap than a Phase 6 state bug:
  `tool_choice: :required` is semantically asking the model to keep producing
  tool use instead of a plain terminal answer.
- Still, the integrated recipe family would benefit from clearer guardrails or
  documentation here, because the failure mode is easy to trigger and very
  expensive when real providers are involved.

## Edge Case 2: `tool_choice: :required` Plus `:pre_tool` Review Re-Requests Review

### Expectation

I expected this combination to be awkward for the same reason as Edge Case 1,
but I wanted to see whether the integrated runtime would at least emit the
approved reply after resuming.

### Tidewave Input

```elixir
alias Runic.Workflow
alias RunicAI.Recipes.IntegratedToolAgent
alias RunicAI.Tool.Definition

model = "openai:gpt-4.1-mini"

tool =
  Definition.new!(
    name: "get_release_status",
    description: "Get the release status for a named service",
    parameter_schema: [service: [type: :string, required: true]],
    executor: fn %{service: service} ->
      {:ok, %{service: service, status: "green", open_incidents: 0}}
    end
  )

workflow =
  IntegratedToolAgent.new(
    default_agent_id: "ops",
    model: model,
    system: "You are a release verifier. Use the get_release_status tool when the user asks for service status. After using tools, reply with exactly GREEN if the service status is green, otherwise RED.",
    registry: [tool],
    tool_choice: :required,
    llm_opts: [temperature: 0.0],
    budget_policy: [max_model_calls: 3, on_exhaustion: :halt],
    pre_tool_guard: fn _request -> :review end
  )
  |> Workflow.react_until_satisfied(%{
    user: "Check release status for payments_api using the available tool."
  })

first_review = IntegratedToolAgent.latest_review_request(workflow, "ops")

workflow =
  Workflow.react_until_satisfied(
    workflow,
    %{review_decision: %{resume_key: first_review.resume_key, status: :approved}}
  )

session = IntegratedToolAgent.session(workflow, "ops")
last_review = IntegratedToolAgent.latest_review_request(workflow, "ops")

%{
  model: model,
  final_status: session.status,
  pending_action_type: if(session.agent_state.pending_action, do: session.agent_state.pending_action.__struct__, else: nil),
  last_review_checkpoint: if(last_review, do: last_review.checkpoint, else: nil),
  final_reply: IntegratedToolAgent.latest_reply_text(workflow, "ops"),
  turns: session.agent_state.conversation.turns,
  emission_kinds: Enum.map(IntegratedToolAgent.emissions(workflow), & &1.kind),
  message_roles: Enum.map(session.agent_state.conversation.messages, & &1.role)
}
```

### Observed Output

```elixir
%{
  model: "openai:gpt-4.1-mini",
  turns: 2,
  emission_kinds: [:review, :review],
  final_status: :review,
  final_reply: nil,
  message_roles: [:system, :user, :assistant, :tool, :assistant],
  pending_action_type: RunicAI.ReviewRequest,
  last_review_checkpoint: :pre_tool
}
```

### Assessment

- This did not resume to a reply.
- Instead, the lane immediately ended back in `:review` at `:pre_tool`.
- Given the behavior in Edge Case 1, this is likely the same underlying issue
  surfacing through the review gate: forcing tool use on every turn means the
  resumed lane is still trying to plan another tool batch instead of settling
  into a terminal answer.
- Even if this is logically consistent with `tool_choice: :required`, it is
  worth calling out explicitly because it is not an intuitive operational mode
  for an integrated human-approval workflow.

## Findings

### 1. The main Phase 6 integrated success paths are working with real providers

- `IntegratedChatAgent` preserved state across repeated external signals.
- `IntegratedToolAgent` completed a real tool loop to quiescence.
- Review/resume worked correctly when the workflow was allowed to return to a
  normal answer turn.
- Multi-agent wait/wake behaved correctly, with one lane paused and another
  lane progressing independently.

### 2. `tool_choice: :required` is a sharp edge for workflow-owned looping agents

- In a loop that expects a final assistant answer after tool observations,
  `tool_choice: :required` pushed the runtime into repeated tool planning and
  eventual halt.
- The same configuration combined with `:pre_tool` review led to repeated
  review requests instead of a final reply emission.
- This does not look like a failure of the Phase 6 state substrate itself.
  It looks like the integrated runtime is faithfully honoring a tool-choice
  policy that is a poor fit for quiescent answer-oriented loops.

### 3. The library should probably protect users from this configuration

Likely follow-up options:

- document clearly that `tool_choice: :required` is not appropriate for
  answer-terminating integrated tool loops unless paired with a strict budget
  or a custom stop policy
- add validation or a warning when `tool_choice: :required` is used with
  `IntegratedToolAgent`
- consider a higher-level mode that requires tool use only on the first
  model turn, then falls back to `:auto` after tool observations

## Overall Assessment

Phase 6's core promise is now verified against real provider-backed scenarios:
the workflow-owned runtime can carry durable agent state, route work by
`agent_id`, pause and resume via typed review/wait contracts, and let multiple
lanes progress independently inside one workflow.

The main issue uncovered in manual verification was not a failure of the
integrated runtime contracts or reducers. It was a configuration edge around
`tool_choice: :required` in a looping agent recipe. That edge is important
enough that it should be addressed in docs or guardrails before users run into
it expensively in production.
