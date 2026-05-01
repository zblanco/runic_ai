defmodule RunicAI.RLM.TraceSummary do
  @moduledoc """
  Compact summaries for assistant and coding RLM traces.
  """

  @spec summarize(map() | [map()], keyword()) :: map()
  def summarize(result_or_events, opts \\ [])

  def summarize(events, opts) when is_list(events) do
    result = Keyword.get(opts, :result, %{})
    summarize_result(result, events)
  end

  def summarize(result, opts) when is_map(result) do
    summarize_result(result, Keyword.get(opts, :events, []))
  end

  @spec markdown(map(), keyword()) :: String.t()
  def markdown(summary, opts \\ []) do
    title = Keyword.get(opts, :title, "Assistant RLM Trace Summary")

    [
      "# #{title}",
      "",
      "- Status: #{field(summary, :scorecard_status) || "unknown"}",
      "- Nodes generated: #{field(summary, :nodes_generated) || 0}",
      "- Component types: #{inline_list(field(summary, :component_types) || [])}",
      "- Source count: #{field(summary, :source_count) || 0}",
      "- Slice count: #{field(summary, :slice_count) || 0}",
      "- Materialized count: #{field(summary, :materialized_count) || 0}",
      "- LLM map calls: #{field(summary, :llm_map_count) || 0}",
      "- Reduce groups: #{field(summary, :reduce_group_count) || 0}",
      "- Artifact: #{artifact_line(field(summary, :write_result))}",
      "- Repairs: #{length(field(summary, :repair_history) || [])}",
      "",
      "## Budget",
      "",
      "```elixir",
      inspect(field(summary, :budget_summary) || %{}, pretty: true, limit: 50),
      "```",
      "",
      "## Scorecard",
      "",
      "```elixir",
      inspect(field(summary, :scorecard) || %{}, pretty: true, limit: 50),
      "```"
    ]
    |> Enum.join("\n")
  end

  defp summarize_result(result, events) do
    blueprint = field(result, :blueprint) || field(result, :proposal) || %{}
    context = field(result, :context) || %{}
    outputs = field(context, :outputs) || %{}
    scorecard = field(result, :scorecard) || field(result, :objective_scorecard)
    artifacts = field(result, :artifacts) || field(context, :artifacts) || []
    budget = field(context, :budget_ledger) || get_in_map(scorecard, [:budget_summary])
    component_types_by_id = component_types_by_id(blueprint)

    %{
      nodes_generated: length(field(blueprint, :components) || field(blueprint, :nodes) || []),
      component_types: component_types(blueprint),
      source_count:
        max_value(outputs, component_types_by_id, [:source_count, :count], [
          :source_discovery,
          :source_splitter
        ]),
      slice_count:
        max_value(outputs, component_types_by_id, [:slice_count, :count], [:source_splitter]),
      materialized_count:
        max_value(outputs, component_types_by_id, [:materialized_count, :count], [
          :source_materializer
        ]),
      llm_map_count:
        max_value(outputs, component_types_by_id, [:llm_map_count, :count], [:llm_map]),
      reduce_group_count:
        max_value(outputs, component_types_by_id, [:reduce_group_count, :groups], [
          :llm_leaf,
          :blueprint_reduce
        ]),
      write_result: List.last(List.wrap(artifacts)),
      scorecard_status: field(scorecard || %{}, :objective_status),
      scorecard: scorecard,
      repair_history: field(result, :repair_history) || [],
      event_count: length(events),
      budget_summary: budget_summary(budget)
    }
  end

  defp component_types(blueprint) do
    blueprint
    |> field(:components)
    |> case do
      nil -> field(blueprint, :nodes) || []
      components -> components
    end
    |> Enum.map(&(field(&1, :type) || field(&1, :kind)))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp component_types_by_id(blueprint) do
    blueprint
    |> field(:components)
    |> case do
      nil -> field(blueprint, :nodes) || []
      components -> components
    end
    |> Map.new(fn component ->
      {to_string(field(component, :id)),
       normalize_type(field(component, :type) || field(component, :kind))}
    end)
  end

  defp max_value(outputs, component_types_by_id, field_keys, type_filters) do
    outputs
    |> Enum.filter(fn {component_id, _output} ->
      Map.get(component_types_by_id, to_string(component_id)) in type_filters
    end)
    |> Enum.map(fn {_component_id, output} ->
      Enum.find_value(field_keys, 0, &integer_field(output, &1))
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    case String.replace(type, "-", "_") do
      "blueprint_reduce" -> :blueprint_reduce
      "blueprint_transform" -> :blueprint_transform
      "document_compare" -> :document_compare
      "llm_leaf" -> :llm_leaf
      "llm_map" -> :llm_map
      "record_group" -> :record_group
      "record_map" -> :record_map
      "report_composer" -> :report_composer
      "source_discovery" -> :source_discovery
      "source_materializer" -> :source_materializer
      "source_splitter" -> :source_splitter
      "tabular_parser" -> :tabular_parser
      other -> other
    end
  end

  defp normalize_type(type), do: type

  defp budget_summary(nil), do: %{}

  defp budget_summary(%RunicAI.RLM.Components.BudgetLedger{} = ledger),
    do: RunicAI.RLM.Components.BudgetLedger.summary(ledger)

  defp budget_summary(%{limits: _limits, metrics: _metrics} = summary), do: summary
  defp budget_summary(other), do: other

  defp artifact_line(nil), do: "none"
  defp artifact_line(artifact), do: field(artifact, :path) || inspect(artifact, limit: 10)

  defp integer_field(map, key) when is_map(map) do
    value = field(map, key)
    if is_integer(value), do: value, else: nil
  end

  defp integer_field(_map, _key), do: nil

  defp inline_list([]), do: "none"
  defp inline_list(values), do: values |> Enum.map(&"`#{&1}`") |> Enum.join(", ")

  defp get_in_map(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
