defmodule RunicAI.Coding.RLM.RepairController do
  @moduledoc """
  Classifies failed verification evidence into bounded repair needs.
  """

  alias RunicAI.Coding.RLM.RepairNeed
  alias RunicAI.Coding.RLM.WorkflowScorecard

  @spec from_scorecard(WorkflowScorecard.t(), [map()]) :: [RepairNeed.t()]
  def from_scorecard(%WorkflowScorecard{} = scorecard, acceptance_results \\ []) do
    if WorkflowScorecard.objective_satisfied?(scorecard) do
      []
    else
      acceptance_results = WorkflowScorecard.blocking_acceptance_results(acceptance_results)

      []
      |> Kernel.++(acceptance_repairs(acceptance_results))
      |> Kernel.++(child_repairs(scorecard.child_results))
      |> Kernel.++(command_repairs(scorecard.command_statuses))
      |> Enum.uniq_by(&{&1.reason, inspect(&1.target)})
      |> Enum.sort_by(&repair_priority/1)
    end
  end

  @spec classify(map() | struct()) :: atom()
  def classify(evidence) do
    text =
      evidence
      |> inspect(limit: 50, printable_limit: 2_000)
      |> String.downcase()

    cond do
      field(evidence, :type) in [:runtime_smoke, "runtime_smoke"] ->
        :runtime_smoke_failure

      field(evidence, :type) in [:semantic_requirement, "semantic_requirement"] ->
        :semantic_requirement_incomplete

      String.contains?(text, "runtime_smoke") or String.contains?(text, "runtime smoke") ->
        :runtime_smoke_failure

      String.contains?(text, "warning") ->
        :compiler_warning

      String.contains?(text, "compile") ->
        :compile_error

      String.contains?(text, "test") or String.contains?(text, "failure") ->
        :test_failure

      String.contains?(text, "supervisor") or String.contains?(text, "registry") ->
        :missing_runtime_wiring

      String.contains?(text, "child") ->
        :incomplete_child_result

      String.contains?(text, "scaffold") ->
        :weak_test_coverage

      true ->
        :missing_deliverable
    end
  end

  defp acceptance_repairs(results) do
    results
    |> Enum.filter(fn result -> result.required? and result.status in [:fail, :skipped] end)
    |> Enum.map(fn result ->
      RepairNeed.new!(
        "acceptance #{result.status}: #{result.type}",
        target: result.id,
        evidence: [result],
        metadata:
          %{
            category: classify(result),
            check_type: result.type,
            status: result.status,
            message: result.message
          }
          |> maybe_put(:repair_instruction, repair_instruction(result))
          |> maybe_put(:output_preview, output_preview(result))
          |> maybe_put(:requirement, requirement(result))
          |> maybe_put(:evidence_refs, evidence_refs(result))
          |> maybe_put(:judge, judge(result))
          |> maybe_put(:smoke_id, smoke_id(result))
      )
    end)
  end

  defp child_repairs(child_results) do
    child_results
    |> Enum.reject(&(&1.status == :completed))
    |> Enum.map(fn child ->
      RepairNeed.new!(
        "child #{child.status}: #{child.role || child.id}",
        target: child.id,
        evidence: [child],
        metadata: %{category: :incomplete_child_result, status: child.status, role: child.role}
      )
    end)
  end

  defp command_repairs(command_statuses) do
    command_statuses
    |> Enum.filter(&command_result?/1)
    |> latest_by_command()
    |> Enum.reject(&(status(&1) in [:pass, "pass", nil]))
    |> Enum.map(fn command ->
      RepairNeed.new!(
        "command #{status(command)}: #{format_command(command)}",
        target: field(command, :command) || field(command, :argv),
        evidence: [command],
        metadata:
          %{
            category: classify(command),
            status: status(command),
            cwd: field(command, :cwd),
            argv: field(command, :argv)
          }
          |> maybe_put(:output_preview, output_preview(command))
      )
    end)
  end

  defp command_result?(%RunicAI.Coding.CommandResult{}), do: true

  defp command_result?(command) when is_map(command) do
    is_list(field(command, :argv)) or is_binary(field(command, :command))
  end

  defp command_result?(_command), do: false

  defp latest_by_command(command_statuses) do
    command_statuses
    |> Enum.reverse()
    |> Enum.uniq_by(&command_signature/1)
    |> Enum.reverse()
  end

  defp command_signature(command) do
    case field(command, :argv) do
      argv when is_list(argv) -> {:argv, argv}
      _other -> {:command, field(command, :command)}
    end
  end

  defp status(value), do: field(value, :status)

  defp repair_instruction(result) do
    field(result, :metadata)
    |> case do
      metadata when is_map(metadata) ->
        field(metadata, :repair_instruction)

      _metadata ->
        nil
    end
  end

  defp output_preview(result) do
    result
    |> field(:metadata)
    |> then(fn metadata ->
      field(result, :output_preview) || field(result, :output) || observed_output(metadata)
    end)
    |> preview()
  end

  defp requirement(result) do
    result
    |> field(:metadata)
    |> case do
      metadata when is_map(metadata) -> field(metadata, :requirement)
      _metadata -> nil
    end
  end

  defp evidence_refs(result) do
    result
    |> field(:metadata)
    |> case do
      metadata when is_map(metadata) -> field(metadata, :evidence_refs)
      _metadata -> nil
    end
  end

  defp judge(result) do
    result
    |> field(:metadata)
    |> case do
      metadata when is_map(metadata) -> field(metadata, :judge)
      _metadata -> nil
    end
  end

  defp smoke_id(result) do
    result
    |> field(:metadata)
    |> case do
      metadata when is_map(metadata) ->
        field(metadata, :id) || metadata |> field(:smoke) |> field(:id)

      _metadata ->
        nil
    end
  end

  defp observed_output(metadata) when is_map(metadata) do
    case field(metadata, :observed) || field(metadata, :smoke) do
      observed when is_map(observed) ->
        field(observed, :output_preview) || field(observed, :output)

      _observed ->
        nil
    end
  end

  defp observed_output(_metadata), do: nil

  defp preview(nil), do: nil
  defp preview(value) when is_binary(value), do: String.slice(value, 0, 2_000)
  defp preview(value), do: value |> inspect(limit: 40) |> String.slice(0, 2_000)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil

  defp format_command(command) do
    command
    |> field(:command)
    |> case do
      nil -> field(command, :argv)
      value -> value
    end
    |> case do
      value when is_list(value) -> Enum.join(value, " ")
      value when is_binary(value) -> value
      nil -> "unknown command"
      value -> inspect(value)
    end
  end

  defp repair_priority(%RepairNeed{} = need) do
    case field(need.metadata, :category) do
      :compile_error -> 0
      :test_failure -> 1
      :runtime_smoke_failure -> 2
      :semantic_requirement_incomplete -> 3
      :missing_runtime_wiring -> 4
      :compiler_warning -> 4
      :weak_test_coverage -> 5
      :incomplete_child_result -> 6
      _other -> 10
    end
  end
end
