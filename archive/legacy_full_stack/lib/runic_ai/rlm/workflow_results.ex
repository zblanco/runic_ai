defmodule RunicAI.RLM.WorkflowResults do
  @moduledoc """
  Extracts assistant/RLM result data from Runic workflow productions.

  Component outputs are ordinary Runic facts. The compiler supplies the mapping
  from blueprint component ids to Runic component names; this module reads those
  facts through Runic's public result APIs.
  """

  alias Runic.Workflow
  alias RunicAI.RLM.Components.BudgetLedger
  alias RunicAI.RLM.WorkflowMetrics

  @spec extract(Workflow.t(), map(), keyword()) :: map()
  def extract(%Workflow{} = workflow, compiled, opts \\ []) when is_map(compiled) do
    component_results = component_results(workflow, compiled)
    intermediate_outputs = intermediate_outputs(component_results)
    output = latest_output(workflow, compiled.output_name)
    execution = WorkflowMetrics.summarize(workflow, compiled, opts)
    metrics = execution.metrics

    %{
      output: output,
      facts: Workflow.raw_productions(workflow),
      artifacts: artifacts(component_results),
      scorecard: scorecard(component_results),
      budget_summary: budget_summary(component_results, compiled, metrics),
      execution_metrics: metrics,
      native_nodes: execution.native_nodes,
      intermediate_outputs: intermediate_outputs,
      component_results: component_results
    }
  end

  @spec latest_output(Workflow.t(), atom() | String.t() | nil) :: term()
  def latest_output(_workflow, nil), do: nil

  def latest_output(%Workflow{} = workflow, component_name) do
    workflow
    |> productions(component_name)
    |> List.last()
  end

  defp component_results(%Workflow{} = workflow, compiled) do
    specs = Map.get(compiled, :component_specs, [])
    node_names = Map.get(compiled, :node_names, %{})

    Enum.map(specs, fn spec ->
      id = get(spec, :id, nil)
      name = Map.get(node_names, id)
      productions = productions(workflow, name)
      output = List.last(productions)

      %{
        id: id,
        name: name,
        type: get(spec, :type, nil),
        execution_shape: get(spec, :execution_shape, nil),
        production_count: length(productions),
        productions: productions,
        output: output
      }
    end)
  end

  defp productions(_workflow, nil), do: []

  defp productions(workflow, name) do
    case Workflow.get_component(workflow, name) do
      nil -> []
      component -> Workflow.raw_productions(workflow, component)
    end
  end

  defp intermediate_outputs(component_results) do
    component_results
    |> Enum.reject(&is_nil(&1.id))
    |> Map.new(&{&1.id, &1.output})
    |> Enum.reject(fn {_id, output} -> is_nil(output) end)
    |> Map.new()
  end

  defp artifacts(component_results) do
    component_results
    |> Enum.filter(&(&1.type == :artifact_writer))
    |> Enum.flat_map(&List.wrap(&1.output))
    |> Enum.reject(&is_nil/1)
  end

  defp scorecard(component_results) do
    component_results
    |> Enum.filter(&(&1.type in [:objective_scorecard, :verification]))
    |> Enum.map(& &1.output)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp budget_summary(component_results, compiled, metrics) do
    component_results
    |> Enum.filter(&(&1.type == :budget_ledger))
    |> Enum.map(& &1.output)
    |> Enum.reject(&is_nil/1)
    |> List.last()
    |> merge_metrics(compiled, metrics)
  end

  defp merge_metrics(nil, compiled, metrics) do
    %{
      limits: budget_limits(compiled),
      metrics: metrics,
      over_budget?: false,
      violations: []
    }
  end

  defp merge_metrics(summary, _compiled, metrics) when is_map(summary) do
    summary
    |> BudgetLedger.summary()
    |> update_in([:metrics], &Map.merge(&1 || %{}, metrics))
  end

  defp budget_limits(compiled) do
    compiled
    |> Map.get(:blueprint, %{})
    |> get(:policies, %{})
    |> get(:budgets, %{})
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp get(_map, _key, default), do: default
end
