# Phase 8 Manual Runtime Verification Report

Status: completed

Date: 2026-04-24

## Goal

Run a realistic manual integration test for the Phase 8 runtime layer through
Tidewave `project_eval`, backed by real LLM provider calls, then record the
expected and observed behavior.

This report exercises:

- real provider-backed `RunicAI.LLM` calls
- supervised `RunicAI.Runtime.SessionServer` execution
- in-memory runtime backend execution
- `Runic.Runner`-backed integrated runtime execution
- `Runic.Runner`-backed external-state turn processor execution
- workflow-as-tool execution through `RunicAI.Tool.Adapters.RunnerWorkflow`
- local timer wait scheduling and wake delivery
- candidate assignment at session start
- optimization hooks consuming trajectory artifacts without mutating runtime
  sessions

## Environment

- Project: `runic_ai`
- Eval path: `Tidewave.MCP.Tools.Eval.project_eval/2`
- Provider used: OpenAI
- Model used: `openai:gpt-4.1-mini`
- Other provider keys present: Anthropic and Google

## Practical Note

As in previous manual reports, I used Tidewave's eval tool module directly from
the project node:

```elixir
code = File.read!("/tmp/runic_ai_phase8_runtime_eval.exs")

Tidewave.MCP.Tools.Eval.project_eval(
  %{"code" => code, "timeout" => 180_000},
  %{inspect_opts: [charlists: :as_lists, limit: :infinity, pretty: true]}
)
```

The eval body began with:

```elixir
recompile()
Application.ensure_all_started(:runic_ai)
```

That ensured the running project node had the latest runtime modules loaded.

## Preconceived Expectations

Before running the manual verification, I expected:

1. An in-memory supervised chat session should run one real LLM turn, append one
   output, emit trace events, and return an idle `Harness.Session`.
2. A Runner-backed integrated session should keep workflow-owned
   `Integrated.RuntimeState` across repeated user signals and preserve one
   stable runner workflow id.
3. A Runner-backed turn-processor session should run a model -> tool -> model
   loop, where the tool invokes a child Runic workflow through the
   `RunnerWorkflow` adapter.
4. A `LocalTimer` scheduler should own `Wait.until` wake delivery, submit a wake
   signal back to the session server, and let the guarded session finish without
   sleeps inside workflow code.
5. Candidate selection should assign one candidate at session start, and an
   optimization hook should consume the resulting trajectory without mutating the
   live session.

## Provider Smoke Test

Tidewave input:

```elixir
alias RunicAI.LLM

LLM.generate_text(
  "openai:gpt-4.1-mini",
  "Reply with exactly the single word pong.",
  temperature: 0.0
)
```

Observed output:

```elixir
%{status: :ok, text: "pong", model: "openai:gpt-4.1-mini"}
```

## Integration Findings During Verification

### 1. Candidate assignment visibility

The first pass showed that `Runtime.SessionSpec` stored
`candidate_assignment`, but runtime callers could not see it through the handle
or session metadata.

Resolution:

- Added the selected candidate assignment into `SessionSpec.metadata`.
- Handles now expose it through `handle.metadata.candidate_assignment`.

### 2. Runtime read call timeout during live wake handling

One run hit a `GenServer.call(..., :snapshot, 5000)` timeout while the
local-timer wake was draining a live LLM/tool flow inside the session server.
The runtime was still doing useful work, but the read-side API had the default
5 second timeout.

Resolution:

- Updated `Runtime.SessionServer.handle/1`, `snapshot/1`, `outputs/1`,
  `trajectory/1`, `subscribe/1`, and `unsubscribe/1` to call with `:infinity`.

Residual note:

- The session server still executes backend transitions synchronously. That is
  acceptable for this phase's API, but future runtime work may want an async
  transition worker so reads can observe a `:running` session while long LLM
  calls are in flight.

### 3. Runner projection race

One full run showed the Runner-backed integrated backend occasionally reading
the previous `Harness.Session` immediately after `Runic.Runner.run/4`.
Focused reruns confirmed the runner workflow did eventually produce the correct
second session, so the issue was projection timing, not recipe semantics.

Resolution:

- Added a projection wait in `RunicAI.Runtime.Backends.RunnerSupport`.
- After `Runner.run/4`, the backend now waits until `Runner.get_results/2`
  returns a projected session whose outputs or trajectory have advanced beyond
  the submitted session.

## Tidewave Scenario Body

The full Tidewave eval built five cases. The essential shape was:

```elixir
recompile()
Application.ensure_all_started(:runic_ai)

require Runic

alias Runic.Workflow
alias RunicAI.Candidate.{Registry, SelectionPolicy}
alias RunicAI.Control.GuardDecision
alias RunicAI.Harness.Policy
alias RunicAI.LLM
alias RunicAI.Optimization.{Hook, Suggestion}
alias RunicAI.Recipes.{
  ChatAgentKernel,
  ConversationalToolAgent,
  GuardedOperatorToolAgent,
  IntegratedChatAgent
}
alias RunicAI.Runtime
alias RunicAI.Tool.Adapters.RunnerWorkflow
alias RunicAI.Tool.{Definition, ExecutionAdapter}

model = "openai:gpt-4.1-mini"

# Case 1: Runtime.start_session/1 over InMemory + ChatAgentKernel.
# Case 2: Runtime.start_session/1 over RunnerIntegrated + IntegratedChatAgent.
# Case 3: RunnerTurnProcessor + ConversationalToolAgent + RunnerWorkflow tool.
# Case 4: LocalTimer + GuardedOperatorToolAgent wait/wake.
# Case 5: Candidate registry/selection + Optimization.Hook over trajectory.
```

The workflow-as-tool case used a child workflow as the tool executor:

```elixir
child_workflow =
  Workflow.new(name: :runtime_echo_child)
  |> Workflow.add(
    Runic.step(fn %{text: text} -> String.upcase(text) end, name: :upcase_text)
  )

runtime_echo_tool =
  Definition.new!(
    name: "runtime_echo",
    description: "Echo a supplied runtime token through a child workflow.",
    parameter_schema: [text: [type: :string, required: true]],
    executor:
      ExecutionAdapter.to_executor(RunnerWorkflow,
        workflow_builder: fn _arguments -> child_workflow end,
        component: :upcase_text
      )
  )
```

The local scheduler case used a real guarded pause:

```elixir
pre_tool_guard: fn _request ->
  GuardDecision.wait!(:runtime_timer,
    metadata: %{until: DateTime.add(DateTime.utc_now(), 150, :millisecond)}
  )
end
```

## Final Observed Output

The final Tidewave run after fixes returned all cases with `status: :ok`.

### 1. In-memory supervised chat

Expected:

- one real LLM turn
- one output
- idle session
- one `:turn_completed` event

Observed:

```elixir
%{
  name: "in_memory_supervised_chat",
  status: :ok,
  result: %{
    session: %{
      status: :idle,
      kind: :turn_processor,
      output_count: 1,
      last_reply_text: "phase8-runtime-ok",
      measurements: %{runs: 1, llm_calls: 1, turns: 1, tool_calls: 0},
      trace_event_count: 5,
      trace_kinds: [
        :llm_request,
        :turn_started,
        :turn_completed,
        :llm_result,
        :workflow_quiesced
      ]
    },
    queued_status: :queued,
    turn_completed_events: 1
  }
}
```

Conclusion:

- Matches expectation.

### 2. Runner-backed integrated two-turn memory

Expected:

- one stable runner workflow id
- first turn replies `stored`
- second turn recalls `heliotrope`
- lane turn count reaches 2
- two integrated emissions

Observed:

```elixir
%{
  name: "runner_integrated_two_turn_memory",
  status: :ok,
  result: %{
    handle: %{
      backend: "RunicAI.Runtime.Backends.RunnerIntegrated",
      runner_workflow_id:
        "{RunicAI.Runtime, \"manual-phase8-integrated-2563\", :integrated}"
    },
    first: %{
      status: :idle,
      output_count: 1,
      last_reply_text: "stored",
      measurements: %{runs: 1, llm_calls: 1, turns: 1, emissions: 1}
    },
    second: %{
      status: :idle,
      output_count: 2,
      last_reply_text: "heliotrope",
      measurements: %{runs: 2, llm_calls: 2, turns: 2, emissions: 2}
    },
    lane_status: :idle,
    lane_turns: 2,
    emission_events: 2
  }
}
```

Conclusion:

- Matches expectation after the Runner projection wait fix.

### 3. Runner turn processor with workflow-as-tool adapter

Expected:

- real model calls tool first
- tool invokes a child workflow through `RunnerWorkflow`
- final model answer includes the child workflow output
- trace records one tool result

Observed:

```elixir
%{
  name: "runner_turn_processor_workflow_tool_adapter",
  status: :ok,
  result: %{
    session: %{
      status: :idle,
      kind: :turn_processor,
      output_count: 1,
      last_reply_text: "Echo lane: ECHO-LANE",
      measurements: %{runs: 1, llm_calls: 2, turns: 2, tool_calls: 1},
      trace_event_count: 12
    },
    tool_messages: ["{\"ok\":true,\"result\":\"ECHO-LANE\"}"],
    tool_result_events: 1
  }
}
```

Conclusion:

- Matches expectation.
- The final recursive output bundle does not retain `tool_results`, because the
  final answer workflow is the last recursive turn. The semantic trace and tool
  message preserve the tool result.

### 4. Local timer wait and wake delivery

Expected:

- first drain pauses with `status: :waiting`
- local timer submits a wake signal
- session finishes after wake
- final answer uses tool observation
- trace records one wait and one tool result

Observed:

```elixir
%{
  name: "local_timer_wait_wake_delivery",
  status: :ok,
  result: %{
    waiting: %{
      status: :waiting,
      output_count: 1,
      last_reply_text: "",
      measurements: %{runs: 1, llm_calls: 1, waits: 1, tool_calls: 0}
    },
    final: %{
      status: :idle,
      output_count: 2,
      last_reply_text: "Paris runtime weather: scheduler rain",
      measurements: %{runs: 2, llm_calls: 3, waits: 1, tool_calls: 1}
    },
    wait_events: 1,
    tool_events: 1
  }
}
```

Conclusion:

- Matches expectation after changing runtime read calls to use `:infinity`.

### 5. Candidate assignment and optimization hook

Expected:

- explicit candidate is assigned at session start
- real LLM turn runs through assigned candidate
- optimization hook emits a suggestion from the trajectory
- live session is not mutated by the hook

Observed:

```elixir
%{
  name: "candidate_assignment_and_optimization_hook",
  status: :ok,
  result: %{
    handle: %{
      candidate_id: "phase8-openai-concise",
      candidate_recipe: "RunicAI.Recipes.ChatAgentKernel"
    },
    session: %{
      status: :idle,
      output_count: 1,
      last_reply_text: "candidate-runtime-ok",
      measurements: %{runs: 1, llm_calls: 1, turns: 1}
    },
    suggestions: [
      %{
        kind: :candidate_promotion,
        summary: "Candidate completed 1 runtime turn(s).",
        confidence: 0.8,
        details: %{session_id: "manual-phase8-candidate-3139", turns: 1}
      }
    ]
  }
}
```

Conclusion:

- Matches expectation.

## Verification Commands

After implementing the fixes discovered during manual verification, I ran:

```bash
mix test test/runic_ai/runtime
mix test
```

Observed:

```text
7 tests, 0 failures
187 tests, 0 failures
```

## Final Assessment

Phase 8's runtime layer now passes a real provider-backed manual integration
run through Tidewave `project_eval`.

The most important integration result is that the same `Harness.Session`
snapshot and `Trace.Trajectory` artifacts survive all tested runtime modes:

1. supervised in-memory execution
2. Runner-backed integrated execution
3. Runner-backed external-state execution
4. scheduled wait/wake execution
5. candidate-routed execution with observational optimization hooks

The manual run also clarified two important runtime hardening points:

- Runner-backed backends must wait for session projection after `Runner.run/4`.
- Public read calls should not use short default GenServer timeouts while live
  LLM transitions may be in progress.

Both were addressed during this verification pass.
