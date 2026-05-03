defmodule RunicAI.RLM.WorkflowMetrics do
  @moduledoc """
  Computes execution metrics from Runic workflow productions.

  The dynamic assistant compiler no longer owns an execution context that can
  mutate counters as nodes run. Metrics therefore come from the workflow facts
  and the compiler's component-id to Runic-node-name mapping.
  """

  alias Runic.Workflow

  @empty_metrics %{
    nodes_executed: 0,
    component_counts: %{},
    source_count: 0,
    slice_count: 0,
    materialized_count: 0,
    materialized_bytes: 0,
    llm_map_calls: 0,
    record_map_calls: 0,
    reduce_calls: 0,
    artifact_writes: 0,
    elapsed_ms: 0
  }

  @spec empty_metrics() :: map()
  def empty_metrics, do: @empty_metrics

  @spec summarize(Workflow.t(), map(), keyword()) :: map()
  def summarize(%Workflow{} = workflow, compiled, opts \\ []) when is_map(compiled) do
    component_metrics = component_metrics(workflow, compiled)
    native_nodes = runtime_nodes(workflow, compiled)

    metrics =
      component_metrics
      |> Enum.reduce(@empty_metrics, &merge_component_metrics/2)
      |> Map.put(:nodes_executed, Enum.count(native_nodes, &(&1.production_count > 0)))
      |> Map.put(:component_counts, component_counts(component_metrics))
      |> Map.put(:elapsed_ms, non_negative_integer(Keyword.get(opts, :elapsed_ms), 0))

    %{
      metrics: metrics,
      native_nodes: native_nodes,
      component_metrics: component_metrics
    }
  end

  @spec runtime_nodes(Workflow.t(), map()) :: [map()]
  def runtime_nodes(%Workflow{} = workflow, compiled) when is_map(compiled) do
    runtime_nodes(compiled)
    |> Enum.map(fn node ->
      productions = productions(workflow, node.name)

      node
      |> Map.put(:production_count, length(productions))
      |> Map.put(:last_output, List.last(productions))
    end)
  end

  @spec runtime_nodes(map()) :: [map()]
  def runtime_nodes(compiled) when is_map(compiled) do
    graph_summary = get(compiled, :graph_summary, %{})
    runic = get(graph_summary, :runic, %{})

    case get(runic, :native_nodes, []) do
      nodes when is_list(nodes) and nodes != [] ->
        Enum.map(nodes, &normalize_runtime_node/1)

      _other ->
        derived_runtime_nodes(compiled)
    end
  end

  defp component_metrics(%Workflow{} = workflow, compiled) do
    specs = get(compiled, :component_specs, [])
    node_names = get(compiled, :node_names, %{})

    Enum.map(specs, fn spec ->
      id = get(spec, :id, nil)
      type = normalize_type(get(spec, :type, nil))
      shape = normalize_type(get(spec, :execution_shape, nil))
      name = Map.get(node_names, id) || Map.get(node_names, to_string(id))

      productions = productions(workflow, name)
      output = List.last(productions)

      native_counts =
        case shape do
          :map ->
            %{
              item_selection_count: production_count(workflow, "#{name}_items"),
              item_count: production_count(workflow, name)
            }

          :reduce ->
            %{
              fan_in_count: production_count(workflow, "#{name}_fan_in"),
              reduce_count: production_count(workflow, name)
            }

          _other ->
            %{}
        end

      %{
        id: id,
        name: name,
        type: type,
        execution_shape: shape,
        production_count: length(productions),
        output: output,
        native_counts: native_counts
      }
    end)
  end

  defp merge_component_metrics(component, metrics) do
    metrics
    |> merge_source_metrics(component)
    |> merge_slice_metrics(component)
    |> merge_materialized_metrics(component)
    |> merge_map_metrics(component)
    |> merge_reduce_metrics(component)
    |> merge_artifact_metrics(component)
  end

  defp merge_source_metrics(metrics, %{type: :source_discovery, output: output}) do
    Map.put(metrics, :source_count, max(metrics.source_count, count(output)))
  end

  defp merge_source_metrics(metrics, _component), do: metrics

  defp merge_slice_metrics(metrics, %{type: :source_splitter, output: output}) do
    metrics
    |> Map.put(:source_count, max(metrics.source_count, source_count(output)))
    |> Map.put(:slice_count, max(metrics.slice_count, count(output)))
  end

  defp merge_slice_metrics(metrics, _component), do: metrics

  defp merge_materialized_metrics(metrics, %{type: :source_materializer, output: output}) do
    metrics
    |> Map.put(:materialized_count, max(metrics.materialized_count, count(output)))
    |> Map.put(
      :materialized_bytes,
      max(metrics.materialized_bytes, integer_field(output, :total_bytes))
    )
  end

  defp merge_materialized_metrics(metrics, _component), do: metrics

  defp merge_map_metrics(metrics, %{type: :llm_map} = component) do
    Map.update!(metrics, :llm_map_calls, &(&1 + map_item_count(component)))
  end

  defp merge_map_metrics(metrics, %{type: :record_map} = component) do
    Map.update!(metrics, :record_map_calls, &(&1 + map_item_count(component)))
  end

  defp merge_map_metrics(metrics, _component), do: metrics

  defp merge_reduce_metrics(metrics, %{type: type} = component)
       when type in [:llm_leaf, :blueprint_reduce] do
    calls =
      case component.execution_shape do
        :reduce -> max(get_in(component.native_counts, [:fan_in_count]) || 0, 1)
        _other -> max(integer_field(component.output, :groups), 1)
      end

    Map.update!(metrics, :reduce_calls, &(&1 + calls))
  end

  defp merge_reduce_metrics(metrics, _component), do: metrics

  defp merge_artifact_metrics(metrics, %{type: :artifact_writer, output: output}) do
    writes =
      output
      |> List.wrap()
      |> Enum.count(fn
        %{status: status} -> status in [:written, "written"]
        %{"status" => status} -> status in [:written, "written"]
        _other -> false
      end)

    Map.update!(metrics, :artifact_writes, &(&1 + writes))
  end

  defp merge_artifact_metrics(metrics, _component), do: metrics

  defp component_counts(component_metrics) do
    component_metrics
    |> Enum.filter(&executed_component?/1)
    |> Enum.reduce(%{}, fn component, counts ->
      Map.update(counts, Atom.to_string(component.type), 1, &(&1 + 1))
    end)
  end

  defp executed_component?(%{production_count: count}) when count > 0, do: true

  defp executed_component?(%{native_counts: native_counts}) when is_map(native_counts) do
    Enum.any?(native_counts, fn {_key, count} -> is_integer(count) and count > 0 end)
  end

  defp executed_component?(_component), do: false

  defp map_item_count(%{execution_shape: :map, native_counts: native_counts}) do
    Map.get(native_counts, :item_count, 0)
  end

  defp map_item_count(%{output: output}), do: count(output)

  defp production_count(%Workflow{} = workflow, name) when is_binary(name) do
    workflow
    |> productions(name)
    |> length()
  end

  defp production_count(_workflow, _name), do: 0

  defp productions(_workflow, nil), do: []

  defp productions(workflow, name) do
    case Workflow.get_component(workflow, name) do
      nil -> []
      component -> Workflow.raw_productions(workflow, component)
    end
  end

  defp derived_runtime_nodes(compiled) do
    specs = get(compiled, :component_specs, [])
    node_names = get(compiled, :node_names, %{})

    [%{id: "assistant_input", name: "assistant_input", type: :assistant_input, kind: :input}]
    |> Kernel.++(
      Enum.flat_map(specs, fn spec ->
        id = get(spec, :id, nil)
        type = normalize_type(get(spec, :type, nil))
        shape = normalize_type(get(spec, :execution_shape, nil))
        name = Map.get(node_names, id) || Map.get(node_names, to_string(id))

        runtime_nodes_for(id, type, shape, name)
      end)
    )
  end

  defp runtime_nodes_for(_id, _type, _shape, nil), do: []

  defp runtime_nodes_for(id, type, :map, name) do
    [
      %{id: id, name: "#{name}_items", type: type, kind: :map_items},
      %{id: id, name: name, type: type, kind: :map}
    ]
  end

  defp runtime_nodes_for(id, type, :reduce, name) do
    [
      %{id: id, name: "#{name}_fan_in", type: type, kind: :reduce_fan_in},
      %{id: id, name: name, type: type, kind: :reduce_finalize}
    ]
  end

  defp runtime_nodes_for(id, type, _shape, name) do
    [%{id: id, name: name, type: type, kind: :component}]
  end

  defp normalize_runtime_node(node) when is_map(node) do
    %{
      id: stringify(get(node, :id, nil)),
      name: stringify(get(node, :name, nil)),
      type: normalize_type(get(node, :type, nil)),
      kind: normalize_type(get(node, :kind, nil))
    }
  end

  defp count(output), do: integer_field(output, :count)

  defp source_count(%{sources: sources}) when is_list(sources), do: length(sources)
  defp source_count(%{"sources" => sources}) when is_list(sources), do: length(sources)
  defp source_count(_output), do: 0

  defp integer_field(map, key) when is_map(map) do
    value = get(map, key, 0)
    if is_integer(value), do: value, else: 0
  end

  defp integer_field(_map, _key), do: 0

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp normalize_type(value) when is_atom(value), do: value

  defp normalize_type(value) when is_binary(value) do
    case String.replace(value, "-", "_") do
      "assistant_input" -> :assistant_input
      "source_discovery" -> :source_discovery
      "source_splitter" -> :source_splitter
      "source_materializer" -> :source_materializer
      "tabular_parser" -> :tabular_parser
      "llm_map" -> :llm_map
      "record_map" -> :record_map
      "record_group" -> :record_group
      "document_compare" -> :document_compare
      "llm_leaf" -> :llm_leaf
      "report_composer" -> :report_composer
      "blueprint_transform" -> :blueprint_transform
      "blueprint_reduce" -> :blueprint_reduce
      "artifact_writer" -> :artifact_writer
      "objective_scorecard" -> :objective_scorecard
      "verification" -> :verification
      "budget_ledger" -> :budget_ledger
      "step" -> :step
      "map" -> :map
      "reduce" -> :reduce
      "side_effect_step" -> :side_effect_step
      "map_items" -> :map_items
      "reduce_fan_in" -> :reduce_fan_in
      "reduce_finalize" -> :reduce_finalize
      "component" -> :component
      "input" -> :input
      other -> other
    end
  end

  defp normalize_type(value), do: value

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp get(_map, _key, default), do: default
end
