# Phase 5 Manual Verification Report

Status: completed

Date: 2026-04-19

## Goal

Run a realistic manual verification pass for the Phase 5 decomposition layer
through Tidewave `project_eval` in the project IEx context, backed by real LLM
providers, then compare expected behavior against actual behavior.

This report exercises:

- real provider-backed `RunicAI.LLM` text and structured generation
- planner/executor decomposition with workflow-backed child delegates
- parallel research/synthesis with handoff-scoped child inheritance
- reviewer/editor/jury coordination with live judge models
- non-`:completed` child control bubbling through `:handoff`
- troubleshooting and fixing deterministic failures discovered during manual
  verification

## Environment

- Project: `runic_ai`
- Eval path: Tidewave `project_eval` in project IEx context
- IEx helper used: `recompile/0`
- Providers used: OpenAI and Anthropic
- Models used:
  - `openai:gpt-4.1-mini`
  - `anthropic:claude-sonnet-4-5-20250929`

## Preconceived Expectations

Before running anything, I expected the following behaviors:

1. `PlannerExecutorWorkflow` should materialize one assignment per task, apply
   inheritance deterministically, execute two child delegates, and reduce them
   into one merged result.
2. `ParallelResearchSynthesizer` should build handoff-backed child assignments,
   execute one child per topic, and return a synthesis that at least mentions
   all requested topics.
3. `ReviewerEditorJury` should produce two candidate outputs, four judge
   evaluations, and a completed winning result favoring the fuller candidate.
4. `RunicAI.LLM.generate_object/4` should return a plain map, because that is
   the public contract advertised by `RunicAI.LLM`.
5. A child returning `{:handoff, artifact}` should surface as a normalized
   `RunicAI.Decomposition.Result` with `status: :handoff`.

## Practical Note

As in the Phase 4 manual run, I treated Tidewave as an IEx-backed live node.
After local code changes during troubleshooting, I reran:

```elixir
recompile()
```

That ensured the Tidewave node had the fixed modules loaded before rerunning the
verification scenarios.

## Provider Smoke Tests

### Text generation smoke test

Tidewave input:

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

Observed output:

```elixir
[
  %{status: :ok, text: "pong", model: "openai:gpt-4.1-mini"},
  %{status: :ok, text: "pong", model: "anthropic:claude-sonnet-4-5-20250929"}
]
```

Assessment:

- Matched expectation.
- Both providers were healthy before the richer Phase 5 scenarios.

### Structured generation smoke test

Post-fix Tidewave input:

```elixir
alias RunicAI.LLM

schema = [
  answer: [type: :string, required: true],
  score: [type: :float, required: true]
]

Enum.map(["openai:gpt-4.1-mini", "anthropic:claude-sonnet-4-5-20250929"], fn model ->
  case LLM.generate_object(model, "Return answer='ok' and score=1.0", schema, temperature: 0.0) do
    {:ok, value} -> %{model: model, type: Map.get(value, :__struct__, :plain_map), value: value}
    {:error, error} -> %{model: model, error: inspect(error)}
  end
end)
```

Observed output:

```elixir
[
  %{
    type: :plain_map,
    value: %{"answer" => "ok", "score" => 1.0},
    model: "openai:gpt-4.1-mini"
  },
  %{
    type: :plain_map,
    value: %{"answer" => "ok", "score" => 1.0},
    model: "anthropic:claude-sonnet-4-5-20250929"
  }
]
```

Assessment:

- Matched expectation after the fix described in Findings 1 below.

## Scenario 1: Planner/Executor With Workflow-Backed Child Delegates

### Expectation

- 2 assignments
- both assignments inherit a `Context.Bundle`
- both assignments get seed state
- both child results complete
- merged output contains contract and recipe summaries

### Tidewave input

```elixir
require Runic
alias Runic.Workflow
alias RunicAI.Agent.State
alias RunicAI.Decomposition.{InheritancePolicy, Role, Task, TaskPlan}
alias RunicAI.LLM
alias RunicAI.Recipes.PlannerExecutorWorkflow

truncate = fn text, limit ->
  if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "..."
end

parent_state =
  State.new!(system: "You are coordinating Phase 5 verification for RunicAI.")
  |> State.append_messages!([
    {:user, "Phase 5 should model decomposition as typed workflow data rather than prompt-only conventions."},
    {:assistant, "That means roles, tasks, assignments, results, and join policies should be explicit values."},
    {:user, "Children should inherit only scoped context, tools, budgets, and memory slices."},
    {:assistant, "And the reference recipes are planner/executor, researcher/synthesizer, and reviewer/editor/jury."}
  ])

extractor = fn %{workflow: workflow} ->
  workflow
  |> Workflow.raw_productions(:delegate_reply)
  |> List.last()
end

make_role = fn name, model, response_key ->
  Role.new!(
    name: name,
    kind: :workflow,
    description: "Workflow-backed verification delegate for #{name}",
    builder: fn _assignment ->
      Workflow.new(name: String.to_atom("child_" <> name))
      |> Workflow.add(
        Runic.step(
          fn input ->
            bundle_messages =
              case input.context_bundle do
                %RunicAI.Context.Bundle{} = bundle ->
                  Enum.map_join(bundle.messages, "\n", fn message ->
                    "#{message.role}: #{message.content}"
                  end)

                _ ->
                  ""
              end

            prompt = """
            You are a specialized child delegate.
            Goal: #{input.goal}
            Instructions: #{input.instructions}

            Parent context:
            #{bundle_messages}

            Return a concise paragraph with the most important technical points.
            """

            case LLM.generate_text(model, prompt, temperature: 0.1) do
              {:ok, result} ->
                %{response_key => String.trim(LLM.Result.text(result)), model: model}

              {:retry, error} ->
                {:error, error}

              {:error, error} ->
                {:error, error}
            end
          end,
          name: :delegate_reply
        )
      )
    end,
    defaults: %{
      result_extractor: extractor,
      inheritance_policy:
        InheritancePolicy.new!(
          context_mode: :bundle,
          tool_mode: :none,
          budget_mode: :copy,
          max_context_refs: 4
        )
    }
  )
end

roles = [
  make_role.("contracts_openai", "openai:gpt-4.1-mini", :contracts),
  make_role.("recipes_anthropic", "anthropic:claude-sonnet-4-5-20250929", :recipes)
]

task_plan =
  TaskPlan.new!(
    [
      Task.new!(
        id: "delegate:contracts",
        goal: "Summarize the core decomposition contracts added in Phase 5.",
        role: "contracts_openai",
        instructions: "Focus on contract names and how they coordinate child work."
      ),
      Task.new!(
        id: "delegate:recipes",
        goal: "Summarize the reference Phase 5 recipes and why they matter.",
        role: "recipes_anthropic",
        instructions: "Focus on planner/executor, research/synthesis, and reviewer/jury composition."
      )
    ],
    groups: [["delegate:contracts", "delegate:recipes"]],
    join_policy: [mode: :merge]
  )

workflow =
  PlannerExecutorWorkflow.react_until_resolution(
    [registry: roles, budget_policy: [max_turns: 2]],
    %{task_plan: task_plan, state: parent_state}
  )

assignments = PlannerExecutorWorkflow.latest_assignments(workflow)
child_results = PlannerExecutorWorkflow.latest_child_results(workflow)
result = PlannerExecutorWorkflow.latest_result(workflow)

%{
  expectations: %{
    assignment_count: 2,
    all_assignments_have_context_bundle: true,
    all_assignments_have_seed_state: true,
    child_statuses: [:completed, :completed],
    join_mode: :merge,
    output_keys: [:contracts, :recipes]
  },
  actual: %{
    assignment_count: length(assignments),
    assignments:
      Enum.map(assignments, fn assignment ->
        %{
          task_id: assignment.task.id,
          role: assignment.role.name,
          context_mode: assignment.metadata.context_mode,
          has_context_bundle?: match?(%RunicAI.Context.Bundle{}, assignment.input.context_bundle),
          has_seed_state?: match?(%RunicAI.Agent.State{}, assignment.seed_state),
          visible_tools: Enum.map(assignment.input.visible_tools || [], & &1.name)
        }
      end),
    child_results:
      Enum.map(child_results, fn child_result ->
        %{
          task_id: child_result.task_id,
          status: child_result.status,
          output:
            child_result.output
            |> inspect(limit: :infinity)
            |> truncate.(260)
        }
      end),
    reduced_result: %{
      status: result.status,
      output: result.output,
      metadata: result.metadata
    }
  }
}
```

Observed output:

```elixir
%{
  actual: %{
    assignments: [
      %{
        role: "contracts_openai",
        context_mode: :bundle,
        task_id: "delegate:contracts",
        has_context_bundle?: true,
        has_seed_state?: true,
        visible_tools: []
      },
      %{
        role: "recipes_anthropic",
        context_mode: :bundle,
        task_id: "delegate:recipes",
        has_context_bundle?: true,
        has_seed_state?: true,
        visible_tools: []
      }
    ],
    child_results: [
      %{status: :completed, task_id: "delegate:contracts", output: "%{model: ... contracts: ...}"},
      %{status: :completed, task_id: "delegate:recipes", output: "%{model: ... recipes: ...}"}
    ],
    assignment_count: 2,
    reduced_result: %{
      status: :completed,
      metadata: %{mode: :merge, task_ids: ["delegate:contracts", "delegate:recipes"]}
    }
  }
}
```

Assessment:

- Structural expectations were met.
- The child workflow path worked with real providers.
- One deterministic design flaw surfaced: `:merge` is lossy for overlapping keys.
  Both child outputs included `:model`, and one child's value won silently.

## Scenario 2: Parallel Research/Synthesizer With Handoff-Scoped Inheritance

### Expectation

- 3 assignments
- all assignments inherit handoff context
- all child results complete
- synthesized summary mentions all requested topics

### Tidewave input

```elixir
require Runic
alias RunicAI.Agent.State
alias RunicAI.Decomposition.{InheritancePolicy, Role}
alias RunicAI.LLM
alias RunicAI.Recipes.ParallelResearchSynthesizer

truncate = fn text, limit ->
  if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "..."
end

parent_state =
  State.new!(system: "You are coordinating research for the RunicAI roadmap.")
  |> State.append_messages!([
    {:user, "Phase 5 should keep decomposition typed and inspectable instead of hiding coordination in prompts."},
    {:assistant, "So parent-child delegation has to move through roles, tasks, assignments, and normalized results."},
    {:user, "The main recipe family should make planner/executor, research/synthesis, and reviewer/jury easy to compose."},
    {:assistant, "And child context inheritance should stay least-privilege by default."}
  ])

researcher_role =
  Role.new!(
    name: "researcher",
    kind: :workflow,
    description: "Research one Phase 5 subtopic using a real model",
    builder: fn assignment ->
      topic = assignment.input.input[:topic] || assignment.input.input["topic"]
      query = assignment.input.input[:query] || assignment.input.input["query"]

      context_text =
        case assignment.input.handoff do
          %RunicAI.Context.HandoffArtifact{} = handoff -> handoff.brief
          _ -> ""
        end

      prompt = """
      Topic: #{topic}
      Query: #{query}

      Parent handoff:
      #{context_text}

      Produce 3-4 sentences with concrete findings and implementation implications.
      """

      case LLM.generate_text("openai:gpt-4.1-mini", prompt, temperature: 0.1) do
        {:ok, result} ->
          %{
            topic: topic,
            notes: String.trim(LLM.Result.text(result)),
            provider_model: "openai:gpt-4.1-mini"
          }

        {:retry, error} -> {:error, error}
        {:error, error} -> {:error, error}
      end
    end,
    defaults: %{
      inheritance_policy:
        InheritancePolicy.new!(
          context_mode: :handoff,
          tool_mode: :none,
          budget_mode: :copy,
          max_context_refs: 4
        )
    }
  )

workflow =
  ParallelResearchSynthesizer.react_until_resolution(
    [registry: [researcher_role], researcher_role: "researcher", budget_policy: [max_turns: 2]],
    %{
      state: parent_state,
      query: "What Phase 5 choices matter most for real workflow-native multi-agent composition?",
      topics: ["typed contracts", "reference recipes", "least-privilege inheritance"]
    }
  )

assignments = ParallelResearchSynthesizer.latest_assignments(workflow)
child_results = ParallelResearchSynthesizer.latest_child_results(workflow)
result = ParallelResearchSynthesizer.latest_result(workflow)
summary = result.output.summary

%{
  expectations: %{
    assignment_count: 3,
    all_assignments_use_handoff: true,
    child_statuses: [:completed, :completed, :completed],
    synthesized_summary_mentions_topics: ["typed contracts", "reference recipes", "least-privilege inheritance"]
  },
  actual: %{
    assignment_count: length(assignments),
    assignments:
      Enum.map(assignments, fn assignment ->
        %{
          task_id: assignment.task.id,
          context_mode: assignment.metadata.context_mode,
          has_handoff?: match?(%RunicAI.Context.HandoffArtifact{}, assignment.input.handoff)
        }
      end),
    child_results:
      Enum.map(child_results, fn child_result ->
        %{task_id: child_result.task_id, status: child_result.status}
      end),
    synthesis: %{
      status: result.status,
      findings_count: length(result.output.findings),
      topic_mentions: %{
        typed_contracts?: String.contains?(String.downcase(summary), "typed contracts"),
        reference_recipes?: String.contains?(String.downcase(summary), "reference recipes"),
        least_privilege_inheritance?:
          String.contains?(String.downcase(summary), "least-privilege inheritance") or
            String.contains?(String.downcase(summary), "least privilege inheritance")
      }
    }
  }
}
```

Observed output:

```elixir
%{
  actual: %{
    assignment_count: 3,
    assignments: [
      %{context_mode: :handoff, task_id: "research:1", has_handoff?: true},
      %{context_mode: :handoff, task_id: "research:2", has_handoff?: true},
      %{context_mode: :handoff, task_id: "research:3", has_handoff?: true}
    ],
    child_results: [
      %{status: :completed, task_id: "research:1"},
      %{status: :completed, task_id: "research:2"},
      %{status: :completed, task_id: "research:3"}
    ],
    synthesis: %{
      status: :completed,
      findings_count: 3,
      topic_mentions: %{
        typed_contracts?: true,
        reference_recipes?: true,
        least_privilege_inheritance?: true
      }
    }
  }
}
```

Assessment:

- Structural expectations were met.
- The recipe exercised handoff-based inheritance successfully.
- The default synthesizer is deterministic but shallow: it concatenates child
  outputs instead of performing a true integrated synthesis.

## Scenario 3: Reviewer/Editor/Jury With Live Judge Models

### Initial expectation

- 2 completed candidate results
- 4 completed evaluations
- candidate 2 should win because its prompt asked for a fuller answer
- judge names should be stable and derived from workflow roles

### Initial failure

The first live run did not meet the expectation. `ReviewerEditorJury` produced
completed candidates, but the judge/evaluation lane failed. The critical
intermediate output looked like this:

```elixir
%{
  judge_results: [
    %RunicAI.Decomposition.Result{
      task_id: "judge:candidate:1:judge_openai",
      status: :failed,
      error: %RunicAI.Error{
        message: "decomposition evaluation subject_id must be a non-empty string"
      }
    },
    ...
  ],
  evaluations: [],
  final_result: %RunicAI.Decomposition.Result{status: :review, ...}
}
```

This was not nondeterminism. It was a deterministic contract mismatch.

### Root causes found during troubleshooting

1. `RunicAI.LLM.generate_object/4` was returning `%ReqLLM.Response{}` for real
   providers instead of the plain map promised by the `RunicAI.LLM` spec.
2. `ExecuteChildAssignments` was eagerly coercing any evaluation-like map into
   `RunicAI.Decomposition.Evaluation` before supplying `subject_id` defaults
   from task metadata.
3. Child result metadata did not preserve task metadata, so downstream judge
   normalization had no stable workflow-derived `subject_id` or `judge`
   fallback.

### Fixes implemented during verification

- Normalized `generate_object` responses at the LLM boundary:
  - `lib/runic_ai/llm.ex`
  - `lib/runic_ai/llm/req_llm_client.ex`
- Propagated task and assignment metadata into normalized child results:
  - `lib/runic_ai/steps/execute_child_assignments.ex`
- Filled evaluation defaults from task metadata before coercing
  evaluation-shaped maps:
  - `lib/runic_ai/steps/execute_child_assignments.ex`
- Added regression coverage:
  - `test/runic_ai/llm_test.exs`
  - `test/runic_ai/steps/decomposition_steps_test.exs`

### Post-fix Tidewave input

```elixir
recompile()

alias RunicAI.Decomposition.{Role, Task, TaskPlan}
alias RunicAI.LLM
alias RunicAI.Recipes.ReviewerEditorJury

truncate = fn text, limit ->
  if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "..."
end

writer_openai =
  Role.new!(
    name: "writer_openai",
    kind: :workflow,
    description: "Draft a deliberately terse candidate",
    builder: fn assignment ->
      brief = assignment.input.input[:brief] || assignment.input.input["brief"]

      prompt = """
      Write one short sentence explaining what Phase 5 adds to RunicAI.
      Keep it intentionally terse and avoid lists.
      Briefing: #{brief}
      """

      case LLM.generate_text("openai:gpt-4.1-mini", prompt, temperature: 0.2) do
        {:ok, result} -> String.trim(LLM.Result.text(result))
        {:retry, error} -> {:error, error}
        {:error, error} -> {:error, error}
      end
    end,
    defaults: %{}
  )

writer_anthropic =
  Role.new!(
    name: "writer_anthropic",
    kind: :workflow,
    description: "Draft a fuller candidate",
    builder: fn assignment ->
      brief = assignment.input.input[:brief] || assignment.input.input["brief"]

      prompt = """
      Explain what Phase 5 adds to RunicAI in exactly three compact bullets.
      Cover decomposition contracts, child coordination, and reference recipes.
      Briefing: #{brief}
      """

      case LLM.generate_text("anthropic:claude-sonnet-4-5-20250929", prompt, temperature: 0.1) do
        {:ok, result} -> String.trim(LLM.Result.text(result))
        {:retry, error} -> {:error, error}
        {:error, error} -> {:error, error}
      end
    end,
    defaults: %{}
  )

judge_schema = [
  score: [type: :float, required: true],
  verdict: [type: :string, required: true],
  reason: [type: :string, required: true]
]

judge_role = fn role_name, model ->
  Role.new!(
    name: role_name,
    kind: :workflow,
    description: "Judge one candidate draft",
    builder: fn assignment ->
      subject_id = assignment.input.input[:subject_id] || assignment.input.input["subject_id"]
      candidate_output = assignment.input.input[:candidate_output] || assignment.input.input["candidate_output"]

      prompt = """
      Evaluate the candidate explanation of what Phase 5 adds to RunicAI.
      Score from 0.0 to 10.0.
      Prefer answers that mention typed decomposition contracts, scoped child coordination, and the reference recipes.

      Candidate subject id: #{subject_id}
      Candidate output:
      #{candidate_output}
      """

      case LLM.generate_object(model, prompt, judge_schema, temperature: 0.0) do
        {:ok, evaluation} -> evaluation
        {:error, error} -> {:error, error}
      end
    end,
    defaults: %{}
  )
end

registry = [
  writer_openai,
  writer_anthropic,
  judge_role.("judge_openai", "openai:gpt-4.1-mini"),
  judge_role.("judge_anthropic", "anthropic:claude-sonnet-4-5-20250929")
]

brief =
  "Phase 5 introduced RunicAI.Decomposition contracts, child assignment execution, deterministic joins, and the planner/executor, research/synthesis, and reviewer/jury reference recipes."

task_plan =
  TaskPlan.new!([
    Task.new!(id: "candidate:1", goal: "Write terse Phase 5 explanation", role: "writer_openai", input: %{brief: brief}),
    Task.new!(id: "candidate:2", goal: "Write complete Phase 5 explanation", role: "writer_anthropic", input: %{brief: brief})
  ])

workflow =
  ReviewerEditorJury.react_until_resolution(
    [registry: registry, judge_roles: ["judge_openai", "judge_anthropic"]],
    %{task_plan: task_plan}
  )

candidate_results = ReviewerEditorJury.latest_candidate_results(workflow)
evaluations = ReviewerEditorJury.latest_evaluations(workflow)
result = ReviewerEditorJury.latest_result(workflow)

scoreboard =
  evaluations
  |> Enum.group_by(& &1.subject_id)
  |> Enum.map(fn {subject_id, evals} ->
    average = Enum.sum(Enum.map(evals, & &1.score)) / length(evals)
    %{subject_id: subject_id, average_score: average, judges: Enum.map(evals, &{&1.judge, &1.score})}
  end)
  |> Enum.sort_by(& &1.subject_id)

%{
  expectations: %{
    candidate_count: 2,
    evaluation_count: 4,
    expected_winner: "candidate:2",
    final_status: :completed,
    judge_names: ["judge_openai", "judge_anthropic"]
  },
  actual: %{
    candidates:
      Enum.map(candidate_results, fn candidate ->
        %{
          task_id: candidate.task_id,
          status: candidate.status,
          output: candidate.output |> to_string() |> truncate.(320)
        }
      end),
    evaluations:
      Enum.map(evaluations, fn evaluation ->
        %{
          subject_id: evaluation.subject_id,
          judge: evaluation.judge,
          score: evaluation.score,
          verdict: evaluation.verdict,
          reason: truncate.(evaluation.reason || "", 180)
        }
      end),
    scoreboard: scoreboard,
    final_result: %{
      status: result.status,
      winner_task_id: result.metadata[:winner_task_id],
      winner_score: result.metadata[:winner_score],
      output: result.output |> to_string() |> truncate.(320)
    }
  }
}
```

Observed output:

```elixir
%{
  actual: %{
    candidates: [
      %{status: :completed, task_id: "candidate:1", output: "Phase 5 adds advanced contract structures with coordinated execution and integrated reference workflows."},
      %{status: :completed, task_id: "candidate:2", output: "- **Decomposition contracts**: Formal interfaces ..."}
    ],
    evaluations: [
      %{subject_id: "candidate:1", judge: "judge_openai", score: 5.5, verdict: "Partially accurate"},
      %{subject_id: "candidate:1", judge: "judge_anthropic", score: 4.5, verdict: "PARTIAL"},
      %{subject_id: "candidate:2", judge: "judge_openai", score: 9.0, verdict: "Strong"},
      %{subject_id: "candidate:2", judge: "judge_anthropic", score: 9.5, verdict: "Excellent"}
    ],
    scoreboard: [
      %{subject_id: "candidate:1", average_score: 5.0, judges: [{"judge_openai", 5.5}, {"judge_anthropic", 4.5}]},
      %{subject_id: "candidate:2", average_score: 9.25, judges: [{"judge_openai", 9.0}, {"judge_anthropic", 9.5}]}
    ],
    final_result: %{status: :completed, winner_task_id: "candidate:2", winner_score: 9.25}
  }
}
```

Assessment:

- Matched expectation after the fixes.
- This scenario exercised the most Phase 5 surface area and was the most useful
  manual verification target.

## Scenario 4: Live `:handoff` Child Outcome

### Expectation

- the child returns `status: :handoff`
- the artifact brief is populated
- open questions remain present

### Tidewave input

```elixir
alias RunicAI.Decomposition.{Assignment, InheritancePolicy, Role, Task, TaskPlan}
alias RunicAI.Context.HandoffArtifact
alias RunicAI.LLM
alias RunicAI.Steps.ExecuteChildAssignments

truncate = fn text, limit ->
  if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "..."
end

handoff_role =
  Role.new!(
    name: "handoff_writer",
    kind: :workflow,
    description: "Turns a delegated task into a typed handoff artifact",
    builder: fn assignment ->
      prompt = """
      Write a concise brief for handing off this delegated RunicAI task.
      Goal: #{assignment.task.goal}
      Input: #{inspect(assignment.input.input)}
      """

      case LLM.generate_text("openai:gpt-4.1-mini", prompt, temperature: 0.1) do
        {:ok, result} ->
          brief = String.trim(LLM.Result.text(result))

          {:handoff,
           HandoffArtifact.new!(
             brief: brief,
             seed_messages: [{:system, brief}],
             references: [],
             open_questions: ["What should the receiving thread validate first?"],
             next_actions: ["Continue the delegated investigation"],
             constraints: ["Preserve explicit decomposition contracts"]
           )}

        {:retry, error} -> {:error, error}
        {:error, error} -> {:error, error}
      end
    end,
    defaults: %{}
  )

task =
  Task.new!(
    id: "handoff:phase5",
    goal: "Hand off the next Phase 5 follow-up slice",
    role: handoff_role,
    input: %{focus: "manual verification findings", next_step: "provider-backed examples"}
  )

assignment =
  Assignment.new!(
    task,
    handoff_role,
    inheritance: InheritancePolicy.new!(),
    input: %{input: task.input}
  )

[result] = ExecuteChildAssignments.execute!(TaskPlan.new!([task]), [assignment])

%{
  expectations: %{status: :handoff, handoff_brief_present: true, open_questions_present: true},
  actual: %{
    status: result.status,
    handoff: %{
      brief: truncate.(result.handoff.brief, 260),
      open_questions: result.handoff.open_questions,
      next_actions: result.handoff.next_actions,
      constraints: result.handoff.constraints
    },
    metadata: result.metadata
  }
}
```

Observed output:

```elixir
%{
  actual: %{
    status: :handoff,
    metadata: %{role: "handoff_writer", assignment_id: "assignment:handoff:phase5"},
    handoff: %{
      brief: "**Task Handoff Brief: Phase 5 Follow-up Slice**\n\n**Goal:** ...",
      open_questions: ["What should the receiving thread validate first?"],
      next_actions: ["Continue the delegated investigation"],
      constraints: ["Preserve explicit decomposition contracts"]
    }
  }
}
```

Assessment:

- Matched expectation.
- This gave a live provider-backed check of a non-`:completed` Phase 5 result
  state.

## Findings

### 1. `RunicAI.LLM.generate_object/4` was not honoring its own contract

Severity: high

Observed behavior:

- Real providers returned `%ReqLLM.Response{object: map}`.
- `RunicAI.LLM.generate_object/4` passed that struct through unchanged.
- Phase 5 jury flows then received provider responses where they expected plain
  maps or evaluation-like data.

Root cause:

- ReqLLM 1.10 returns `%ReqLLM.Response{}` for structured generation.
- `RunicAI.LLM` still treated `generate_object` as a passthrough operation.

Fix implemented:

- Unwrap `ReqLLM.Response.object` at both the adapter and public facade layer.

Validation after fix:

- direct structured-output smoke test returned plain maps for OpenAI and
  Anthropic
- jury scenario completed successfully

### 2. Evaluation-like child maps were normalized too early without task defaults

Severity: high

Observed behavior:

- Judge child tasks returned maps with `score`, `verdict`, and `reason`.
- `ExecuteChildAssignments` tried to coerce them into
  `RunicAI.Decomposition.Evaluation` before injecting `subject_id`.
- The live jury lane failed deterministically with
  `"decomposition evaluation subject_id must be a non-empty string"`.

Root cause:

- `normalize_child_result/2` recognized evaluation-shaped maps but did not
  merge `assignment.task.metadata[:subject_id]` and `[:judge]` first.

Fix implemented:

- Fill missing evaluation defaults from task metadata before coercion.
- Preserve task and assignment metadata in the normalized `Decomposition.Result`.

Validation after fix:

- judge results completed
- `JudgeCandidates` produced four stable evaluations
- judge labels came from workflow metadata as intended

### 3. `JoinPolicy` `:merge` is still lossy for overlapping keys

Severity: medium

Observed behavior:

- In the planner/executor run, both child outputs included `:model`.
- The merged output kept only one `:model` value without warning.

Root cause:

- `ReduceChildResults.merge_outputs/1` uses plain `Map.merge/2`.
- Conflict resolution is implicit and order-dependent.

Recommended fix:

1. add an explicit conflict policy to `RunicAI.Decomposition.JoinPolicy`
2. offer at least `:first_wins`, `:last_wins`, `:error`, and `:nest_by_task`
3. make `ParallelResearchSynthesizer` prefer namespaced outputs by task id

This was not fixed during this verification pass.

### 4. `ParallelResearchSynthesizer` is structurally correct but semantically shallow

Severity: low

Observed behavior:

- The recipe returned the right number of findings and mentioned the requested
  topics.
- The default summary is a deterministic concatenation of child outputs rather
  than a true synthesis artifact.

Interpretation:

- This is more of a recipe limitation than a substrate bug.

Recommended fix:

1. allow an optional synthesizer child role that performs a final LLM-backed
   synthesis over completed findings
2. keep the current deterministic join as the default fallback

## Error Log Notes

Tidewave log tail during the session consistently showed repeated:

```text
[error] ** (Plug.Conn.NotSentError) a response was neither set nor sent from the connection
```

Representative timestamps seen during this verification:

- `12:50:02`
- `12:55:15`
- `13:01:47`

Assessment:

- These did not correlate with RunicAI exceptions or Phase 5 result failures.
- They appear to be Tidewave/Bandit endpoint noise rather than RunicAI
  decomposition failures.

## Final Assessment

Phase 5 is now manually verified against real providers with one meaningful
exception still open:

- the decomposition substrate, planner/executor recipe, jury recipe, and live
  handoff path all behaved as intended after two deterministic fixes
- `generate_object` normalization and evaluation metadata propagation needed
  real-provider verification to surface
- `:merge` conflict handling remains an open design issue
- the default research synthesizer remains useful as a structural example but is
  not yet a semantically strong synthesis recipe

## Verification Outcome

- `mix compile` passed
- `mix test` passed
- test count after verification fixes: `138`

