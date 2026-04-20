defmodule RunicAI.Recipes.ParallelResearchSynthesizer do
  @moduledoc """
  Reference fan-out workflow for parallel evidence gathering followed by a
  deterministic synthesis join.

  The default reducer returns a deterministic, namespaced synthesis artifact
  keyed by task and topic. Callers may also provide `:synthesizer_role` to run
  a final child delegate over the completed findings, with deterministic
  synthesis kept as the fallback path.
  """

  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.InheritancePolicy
  alias RunicAI.Decomposition.JoinPolicy
  alias RunicAI.Decomposition.Registry
  alias RunicAI.Decomposition.Result
  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.Task
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.Recipes.PlannerExecutorWorkflow
  alias RunicAI.Steps.ExecuteChildAssignments

  @spec new(keyword()) :: Runic.Workflow.t()
  def new(opts \\ []) do
    PlannerExecutorWorkflow.new(
      Keyword.merge(
        [
          name: Keyword.get(opts, :name, :parallel_research_synthesizer),
          planner: fn input -> default_planner(input, opts) end,
          join_policy: Keyword.get(opts, :join_policy, default_join_policy(opts))
        ],
        opts
      )
    )
  end

  @spec react_until_resolution(keyword(), map(), keyword()) :: Runic.Workflow.t()
  def react_until_resolution(opts, input, react_opts \\ [])
      when is_list(opts) and is_map(input) do
    new(opts)
    |> Runic.Workflow.react_until_satisfied(input, react_opts)
  end

  defdelegate latest_task_plan(workflow), to: PlannerExecutorWorkflow
  defdelegate latest_assignments(workflow), to: PlannerExecutorWorkflow
  defdelegate latest_child_results(workflow), to: PlannerExecutorWorkflow
  defdelegate latest_result(workflow), to: PlannerExecutorWorkflow
  defdelegate latest_output(workflow), to: PlannerExecutorWorkflow

  @spec default_join_policy(keyword()) :: JoinPolicy.t()
  def default_join_policy(opts \\ []) do
    JoinPolicy.new!(
      mode: :custom,
      on_partial_failure: :ignore,
      synthesizer: fn payload -> synthesize_results(payload, opts) end
    )
  end

  @spec synthesize_results(map(), keyword()) :: map() | Result.t()
  def synthesize_results(%{completed: completed}, opts \\ []) do
    deterministic_output = deterministic_synthesis(completed)

    case resolve_synthesizer_role(opts) do
      nil ->
        deterministic_output

      {:ok, %Role{} = role} ->
        run_optional_synthesizer(role, deterministic_output, completed, opts)

      {:error, reason} ->
        Result.failed!("research:synthesis", reason, metadata: %{synthesis_mode: :child_role})
    end
  end

  defp default_planner(input, opts) when is_map(input) do
    cond do
      Map.has_key?(input, :task_plan) or Map.has_key?(input, "task_plan") ->
        input

      Map.has_key?(input, :tasks) or Map.has_key?(input, "tasks") ->
        input

      topics = Map.get(input, :topics) || Map.get(input, "topics") ->
        role =
          Map.get(input, :researcher_role) || Map.get(input, "researcher_role") ||
            Keyword.get(opts, :researcher_role, "researcher")

        query = Map.get(input, :query) || Map.get(input, "query")

        tasks =
          topics
          |> Enum.with_index(1)
          |> Enum.map(fn {topic, index} ->
            Task.new!(
              id: "research:#{index}",
              goal: "Research #{topic}",
              role: role,
              input: %{topic: topic, query: query},
              metadata: %{topic: topic, query: query}
            )
          end)

        %{tasks: tasks, join_policy: Keyword.get(opts, :join_policy, default_join_policy(opts))}

      true ->
        input
    end
  end

  defp deterministic_synthesis(completed) do
    findings =
      Enum.map(completed, fn %Result{} = result ->
        %{
          task_id: result.task_id,
          topic: result.metadata[:topic],
          query: result.metadata[:query],
          summary: summarize_output(result.output),
          output: result.output,
          artifacts: result.artifacts,
          metadata: result.metadata
        }
      end)

    deterministic_summary =
      findings
      |> Enum.map_join("\n\n", fn finding ->
        label = finding.topic || finding.task_id
        "- #{label}: #{finding.summary}"
      end)

    %{
      query: findings |> Enum.find_value(& &1.query),
      topics: findings |> Enum.map(&(&1.topic || &1.task_id)),
      findings: findings,
      findings_by_task: Map.new(findings, &{&1.task_id, &1}),
      findings_by_topic: Enum.group_by(findings, &(&1.topic || &1.task_id)),
      summary: deterministic_summary,
      deterministic_summary: deterministic_summary,
      sources: Enum.flat_map(completed, & &1.artifacts),
      synthesis_mode: :deterministic
    }
  end

  defp run_optional_synthesizer(%Role{} = role, deterministic_output, _completed, opts) do
    synthesis_input = %{
      query: deterministic_output.query,
      topics: deterministic_output.topics,
      findings: deterministic_output.findings,
      findings_by_task: deterministic_output.findings_by_task,
      findings_by_topic: deterministic_output.findings_by_topic,
      deterministic_summary: deterministic_output.deterministic_summary,
      sources: deterministic_output.sources
    }

    task =
      Task.new!(
        id: "research:synthesis",
        goal:
          Keyword.get(
            opts,
            :synthesizer_goal,
            "Synthesize the research findings into one final summary"
          ),
        role: role,
        instructions: Keyword.get(opts, :synthesizer_instructions),
        input: synthesis_input,
        metadata: %{
          query: deterministic_output.query,
          topics: deterministic_output.topics,
          phase: :synthesis
        }
      )

    assignment =
      Assignment.new!(
        task,
        role,
        inheritance: synthesizer_inheritance(role, opts),
        input: %{
          task_id: task.id,
          assignment_id: "assignment:#{task.id}",
          role: role.name,
          role_kind: role.kind,
          goal: task.goal,
          instructions: task.instructions,
          input: synthesis_input,
          metadata: task.metadata
        },
        metadata: %{phase: :synthesis}
      )

    [result] = ExecuteChildAssignments.execute!(TaskPlan.new!([task]), [assignment])

    case result do
      %Result{status: :completed, output: synthesized_output} ->
        merge_synthesized_output(deterministic_output, synthesized_output, role)

      %Result{status: status} = control_result when status in [:review, :wait, :handoff] ->
        control_result

      %Result{} = failed_result ->
        deterministic_output
        |> Map.put(:synthesis_mode, :fallback)
        |> Map.put(:synthesizer_role, role.name)
        |> Map.put(:synthesizer_failure, failed_result.error || failed_result.output)
    end
  end

  defp merge_synthesized_output(deterministic_output, synthesized_output, %Role{} = role)
       when is_binary(synthesized_output) do
    deterministic_output
    |> Map.put(:summary, synthesized_output)
    |> Map.put(:synthesized_summary, synthesized_output)
    |> Map.put(:synthesizer_role, role.name)
    |> Map.put(:synthesis_mode, :child_role)
  end

  defp merge_synthesized_output(deterministic_output, synthesized_output, %Role{} = role)
       when is_map(synthesized_output) do
    summary =
      map_value(synthesized_output, :summary) ||
        map_value(synthesized_output, :synthesized_summary) ||
        deterministic_output.summary

    deterministic_output
    |> Map.put(:summary, summary)
    |> Map.put(:synthesized_summary, summary)
    |> Map.put(:synthesized_output, synthesized_output)
    |> Map.put(:synthesizer_role, role.name)
    |> Map.put(:synthesis_mode, :child_role)
  end

  defp merge_synthesized_output(deterministic_output, synthesized_output, %Role{} = role) do
    deterministic_output
    |> Map.put(:synthesized_output, synthesized_output)
    |> Map.put(:synthesizer_role, role.name)
    |> Map.put(:synthesis_mode, :child_role)
  end

  defp resolve_synthesizer_role(opts) do
    case Keyword.get(opts, :synthesizer_role) do
      nil ->
        nil

      %Role{} = role ->
        {:ok, role}

      role_name when is_binary(role_name) ->
        with {:ok, registry} <- Registry.from_input(Keyword.get(opts, :registry)),
             {:ok, role} <- Registry.fetch(registry, role_name) do
          {:ok, role}
        end
    end
  end

  defp synthesizer_inheritance(%Role{} = role, opts) do
    Keyword.get(opts, :synthesizer_inheritance_policy) ||
      Map.get(role.defaults, :inheritance_policy) ||
      Map.get(role.defaults, "inheritance_policy") ||
      InheritancePolicy.new!()
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp summarize_output(output) when is_binary(output), do: output
  defp summarize_output(%{notes: notes}) when is_binary(notes), do: notes
  defp summarize_output(%{"notes" => notes}) when is_binary(notes), do: notes
  defp summarize_output(%{summary: summary}) when is_binary(summary), do: summary
  defp summarize_output(%{"summary" => summary}) when is_binary(summary), do: summary
  defp summarize_output(%{content: content}) when is_binary(content), do: content
  defp summarize_output(%{"content" => content}) when is_binary(content), do: content
  defp summarize_output(output) when is_map(output), do: inspect(output)
  defp summarize_output(output), do: inspect(output)
end
