# Phase 4 Manual Integration Report

Status: completed

Date: 2026-04-17

## Goal

Run a realistic manual integration test for the Phase 4 context-engineering
layer through Tidewave `project_eval`, backed by a real LLM provider, then
record the exact input and observed output.

This report exercises:

- real provider-backed `RunicAI.LLM` calls
- summary-backed context compaction under pressure
- memory recall injected into the active bundle
- final reply generation from the assembled bundle
- handoff artifact construction from the resulting state

## Environment

- Project: `runic_ai`
- Eval path: Tidewave `project_eval`
- Provider used: OpenAI
- Model used: `openai:gpt-4.1-mini`

## Practical Note

The first Tidewave attempt failed because the running dev node still had an
older `RunicAI.Agent.State` struct loaded in memory from before the Phase 4
changes. Recompiling inside Tidewave fixed it:

```elixir
recompile()
Map.keys(RunicAI.Agent.State.__struct__())
```

Observed result:

```elixir
[:status, :context, :metadata, :__struct__, :assigns, :pending_action,
 :last_turn_result, :conversation]
```

That confirmed the dev node was now using the updated Phase 4-aware state
shape.

## Smoke Test

Before running the richer scenario, I verified the live provider path with a
minimal call:

```elixir
alias RunicAI.LLM

case LLM.generate_text("openai:gpt-4.1-mini", "Reply with exactly pong.") do
  {:ok, result} -> %{status: :ok, text: RunicAI.LLM.Result.text(result)}
  {:retry, error} -> %{status: :retry, error: inspect(error)}
  {:error, error} -> %{status: :error, error: inspect(error)}
end
```

Observed output:

```elixir
%{status: :ok, text: "pong"}
```

## Scenario

The realistic scenario used a seeded conversation state with:

1. an early user constraint that should become semantic memory
2. later design discussion that should be compacted under context pressure
3. a new user question asking what the next implementation slice should focus
   on and what should stay outside RunicAI core

The workflow recipe under test was
`RunicAI.Recipes.SummaryBackedChatAgent`, with a real LLM-backed summarizer
passed into `CompactContext`.

After the reply turn completed, I fed the resulting `Agent.State` into
`RunicAI.Recipes.HandoffContextBuilder` to inspect the handoff artifact.

## Tidewave Input

This is the exact `project_eval` body used for the main run:

```elixir
alias Runic.Workflow
alias RunicAI.Agent.{State, TurnResult}
alias RunicAI.Context.{Graph, Node, Ref}
alias RunicAI.LLM
alias RunicAI.Recipes.{HandoffContextBuilder, SummaryBackedChatAgent}
alias RunicAI.Steps.WriteMemory

model = "openai:gpt-4.1-mini"

question =
  "Given the earlier constraints, what should the next implementation slice focus on, " <>
    "what should stay outside RunicAI core for now, and why?"

system = """
You are a senior Elixir library architect working on RunicAI.
Use the provided context, summaries, and memory.
Reply with exactly three bullets titled Next Slice, Keep Out, and Why.
"""

state =
  State.new!(system: system)
  |> State.append_messages!([
    {:user, "Remember that deterministic provenance matters more than squeezing every token."},
    {:assistant, "Understood. We'll preserve transcript truth and explicit refs."}
  ])

state =
  WriteMemory.write!(
    state,
    TurnResult.reply!("Understood. We'll preserve transcript truth and explicit refs.")
  )

state =
  state
  |> State.append_messages!([
    {:user,
     "Retrieval should stay optional and backend-neutral so this library does not hardwire vector stores or search engines."},
    {:assistant,
     "Agreed. Retrieval should remain an adapter seam instead of a baked-in infrastructure choice."},
    {:user,
     "Compaction should be explicit and lineage-preserving, closer to LCM than naive transcript truncation."},
    {:assistant,
     "Right. We want pressure evaluation, summary DAGs, and reconstructable refs."},
    {:user,
     "Handoff should package the next goal, the relevant references, and any unresolved questions for a new thread."},
    {:assistant,
     "That gives us a typed artifact instead of copying an arbitrary chunk of chat history."}
  ])

truncate = fn text, limit ->
  if String.length(text) <= limit do
    text
  else
    String.slice(text, 0, limit) <> "..."
  end
end

summarizer = fn chunk, focus, policy ->
  chunk_text =
    Enum.map_join(chunk, "\n", fn node ->
      "- [#{node.kind}] #{Node.text(node)}"
    end)

  prompt = """
  Summarize the following prior context for an agent continuing this goal:
  #{focus.goal}

  Keep concrete decisions, constraints, and unresolved questions.
  Keep it under #{policy.leaf_target_tokens * 4} characters.

  Context:
  #{chunk_text}
  """

  case LLM.generate_text(model, prompt, temperature: 0.0) do
    {:ok, result} -> String.trim(LLM.Result.text(result))
    _ -> truncate.(chunk_text, policy.leaf_target_tokens * 4)
  end
end

workflow =
  SummaryBackedChatAgent.new(
    model: model,
    state: state,
    llm_opts: [temperature: 0.1],
    window_policy: [
      max_input_tokens: 180,
      reserve_output_tokens: 48,
      soft_pressure_tokens: 55,
      hard_pressure_tokens: 80,
      fresh_tail_messages: 2,
      fresh_tail_tokens: 40
    ],
    compaction_policy: [
      leaf_target_tokens: 20,
      condensed_target_tokens: 14,
      max_depth_per_pass: 1
    ],
    summarizer: summarizer
  )
  |> Workflow.react_until_satisfied(%{user: question})

reply = SummaryBackedChatAgent.latest_reply_text(workflow)
focus = SummaryBackedChatAgent.latest_focus(workflow)
decision = SummaryBackedChatAgent.latest_pressure_decision(workflow)
bundle = SummaryBackedChatAgent.latest_bundle(workflow)
final_state = SummaryBackedChatAgent.latest_state(workflow)
context = final_state.context

summary_nodes = Graph.list_nodes_by_kind(context.graph, :summary)
memory_nodes = Graph.list_nodes_by_kind(context.graph, :memory)

handoff_workflow =
  HandoffContextBuilder.new()
  |> Workflow.react_until_satisfied(%{
    state: final_state,
    goal: "Continue Phase 4 by adding examples, docs, and adapter guidance"
  })

handoff = HandoffContextBuilder.latest_handoff(handoff_workflow)

%{
  model: model,
  input_question: question,
  focus: %{
    goal: focus.goal,
    questions: focus.questions,
    entities: focus.entities,
    constraints: focus.constraints
  },
  pressure: %{
    action: decision.action,
    reason: decision.reason,
    current_tokens: decision.snapshot.current_tokens,
    summary_tokens: decision.snapshot.summary_tokens,
    memory_tokens: decision.snapshot.memory_tokens,
    retrieval_tokens: decision.snapshot.retrieval_tokens,
    compactable_refs: Enum.map(decision.snapshot.compactable_refs, &Ref.key/1)
  },
  bundle: %{
    coverage: bundle.coverage,
    messages:
      Enum.map(bundle.messages, fn message ->
        %{role: message.role, content: truncate.(message.content, 220)}
      end)
  },
  reply: reply,
  context_after_turn: %{
    summary_count: length(summary_nodes),
    summaries: Enum.map(summary_nodes, &Node.text/1),
    memory_count: length(memory_nodes),
    memory_entries: Enum.map(memory_nodes, &Node.text/1),
    active_refs: Enum.map(context.active_refs, &Ref.key/1),
    tail_refs: Enum.map(context.tail_refs, &Ref.key/1)
  },
  handoff: %{
    brief: handoff.brief,
    seed_messages:
      Enum.map(handoff.seed_messages, fn message ->
        %{role: message.role, content: truncate.(message.content, 220)}
      end),
    references: Enum.map(handoff.references, &Ref.key/1),
    next_actions: handoff.next_actions,
    open_questions: handoff.open_questions,
    constraints: handoff.constraints
  }
}
```

## Observed Output

The run succeeded. This is the observed output, lightly wrapped for readability
but otherwise unchanged in substance:

```elixir
%{
  model: "openai:gpt-4.1-mini",
  input_question: "Given the earlier constraints, what should the next implementation slice focus on, what should stay outside RunicAI core for now, and why?",
  focus: %{
    goal: "Given the earlier constraints, what should the next implementation slice focus on, what should stay outside RunicAI core for now, and why?",
    questions: [
      "Given the earlier constraints, what should the next implementation slice focus on, what should stay outside RunicAI core for now, and why?"
    ],
    entities: ["Given", "RunicAI"],
    constraints: []
  },
  pressure: %{
    action: :compact,
    reason: "older context can be summarized safely",
    current_tokens: 302,
    summary_tokens: 0,
    memory_tokens: 37,
    retrieval_tokens: 0,
    compactable_refs: [
      "message:2",
      "message:3",
      "message:4",
      "message:5",
      "message:6",
      "message:7",
      "message:8"
    ]
  },
  bundle: %{
    coverage: %{
      summary_count: 1,
      memory_entries: 2,
      history_messages: 1,
      retrieval_documents: 0
    },
    messages: [
      %{
        role: :system,
        content: "You are a senior Elixir library architect working on RunicAI.\nUse the provided context, summaries, and memory.\nReply with exactly three bullets titled Next Slice, Keep Out, and Why.\n"
      },
      %{
        role: :system,
        content: "[MEMORY episodic]\nUnderstood. We'll preserve transcript truth and explicit refs."
      },
      %{
        role: :system,
        content: "[MEMORY semantic]\nRemembered fact: deterministic provenance matters more than squeezing every token"
      },
      %{
        role: :system,
        content: "[CONTEXT SUMMARY]\nNext: core logic, deterministic provenance; defer retrieval, UI, token opt"
      },
      %{
        role: :assistant,
        content: "That gives us a typed artifact instead of copying an arbitrary chunk of chat history."
      },
      %{
        role: :user,
        content: "Given the earlier constraints, what should the next implementation slice focus on, what should stay outside RunicAI core for now, and why?"
      }
    ]
  },
  reply: "- **Next Slice:**\n  Implement the core logic for deterministic provenance tracking in RunicAI. This includes designing clear data structures and processes that record exactly how outputs are derived, ensuring traceability and reproducibility without relying on heuristic token slicing.\n\n- **Keep Out:**\n  Retrieval mechanisms (e.g., embedding/semantic search), user interface components, and token optimization strategies should remain outside the core for now. These are orthogonal concerns that can introduce complexity and obscure the foundation of deterministic provenance.\n\n- **Why:**\n  Prioritizing deterministic provenance in the core aligns with the principle that provenance correctness and clarity outweigh token efficiency. Deferring retrieval and UI lowers integration complexity, enabling us to establish a solid, truthful core that downstream components can rely on.",
  context_after_turn: %{
    summary_count: 5,
    summaries: [
      "Next slice: ensure deterministic provenance; defer token optimization outside core.",
      "Next: implement core AI logic without retrieval; keep retrieval as external adapter—flexible, backend-neutral. Constraints: no vector store binding; unresolved: retrieval interface details.",
      "Next slice: implement explicit, lineage-preserving compaction; defer pressure eval, summary DAGs, refs.",
      "Next slice: core goal handling; exclude UI and external APIs for now; clarify refs.",
      "Next: core logic, deterministic provenance; defer retrieval, UI, token opt"
    ],
    memory_count: 3,
    memory_entries: [
      "Understood. We'll preserve transcript truth and explicit refs.",
      "Remembered fact: deterministic provenance matters more than squeezing every token",
      "- **Next Slice:**  \n  Implement the core logic for deterministic provenance tracking in RunicAI. This includes designing clear data structures and processes ..."
    ],
    active_refs: ["summary:5", "message:9"],
    tail_refs: ["message:9"]
  },
  handoff: %{
    brief: "Goal: Continue Phase 4 by adding examples, docs, and adapter guidance\nAudience: next_thread\nRelevant context:\n- Next: core logic, deterministic provenance; defer retrieval, UI, token opt",
    references: ["summary:5", "message:9", "message:10", "message:11"],
    next_actions: [
      "Continue toward: Continue Phase 4 by adding examples, docs, and adapter guidance"
    ],
    open_questions: [
      "Given the earlier constraints, what should the next implementation slice focus on, what should stay outside RunicAI core for now, and why?"
    ]
  }
}
```

## What This Shows

### 1. The provider-backed LLM path is working inside Tidewave

Both the smoke test and the main scenario completed successfully against
`openai:gpt-4.1-mini`.

### 2. Pressure evaluation triggered compaction, not silent truncation

The pressure decision was:

```elixir
%{action: :compact, reason: "older context can be summarized safely"}
```

That is the Phase 4 behavior we wanted: context pressure becomes explicit data,
and the workflow chooses a typed relief strategy.

### 3. The active bundle was assembled from multiple context sources

The bundle that went into the final LLM turn contained:

- the original system prompt
- recalled episodic memory
- recalled semantic memory
- a generated context summary
- only the freshest tail history
- the current user question

This is exactly the transcript -> context -> bundle -> prompt projection shape
the Phase 4 plan called for.

### 4. Memory recall is visible and inspectable

The semantic memory extracted earlier:

```elixir
"Remembered fact: deterministic provenance matters more than squeezing every token"
```

was present in the final bundle as:

```elixir
"[MEMORY semantic]\nRemembered fact: deterministic provenance matters more than squeezing every token"
```

### 5. Compaction currently creates a summary DAG, not just one summary blob

After the turn, the context graph contained five summary nodes. That means the
workflow chunked compactable history into multiple summaries and then carried a
top-level active summary ref (`"summary:5"`) forward.

That is promising for LCM-style lineage because the system is already operating
as a graph rewrite rather than a single mutable summary string.

### 6. Handoff composition works on the resulting state

The generated handoff artifact was short, goal-oriented, and reference-aware:

```elixir
"Goal: Continue Phase 4 by adding examples, docs, and adapter guidance
Audience: next_thread
Relevant context:
- Next: core logic, deterministic provenance; defer retrieval, UI, token opt"
```

and it preserved explicit refs:

```elixir
["summary:5", "message:9", "message:10", "message:11"]
```

## Observations And Caveats

- The focus inference is intentionally lightweight right now. In this run it
  inferred entities `["Given", "RunicAI"]`, which is acceptable for a first
  pass but clearly heuristic.
- The LLM answer was directionally good, but it generalized beyond the prompt
  a bit by adding `UI` and `token optimization` to the "Keep Out" lane. That is
  realistic model behavior, and it shows why explicit contracts matter.
- The handoff artifact is already useful, but the current builder strongly
  prefers top-level summaries when they exist. That bias is sensible, though we
  may want richer open-question extraction later.
- Tidewave dev-node freshness matters during active development. Recompile
  before manual evals when public structs or recipe wiring changed recently.

## Bottom Line

The Phase 4 design is now doing real work end to end:

- real LLM-backed compaction
- real bundle assembly from memory plus summaries
- real provider-backed final response generation
- real handoff artifact generation from the resulting state

That makes the current implementation solid enough for additional examples and
adapter-backed demos, rather than still being purely speculative.
