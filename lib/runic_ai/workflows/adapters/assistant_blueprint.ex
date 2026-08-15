defmodule RunicAI.Workflows.Adapters.AssistantBlueprint do
  @moduledoc """
  Adapts the current assistant workflow blueprint into workflow IR V1.

  Catalog contracts, rather than blueprint-declared port arrays, define the
  resulting node boundaries.
  """

  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Error
  alias RunicAI.Workflows.AdapterResult
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  @spec adapt(WorkflowBlueprint.t() | map()) :: {:ok, AdapterResult.t()} | {:error, Error.t()}
  def adapt(input) do
    raw_edges = raw_edges(input)

    with {:ok, blueprint} <- WorkflowBlueprint.from_input(input),
         {:ok, nodes} <- nodes(blueprint),
         {:ok, edges, edge_diagnostics} <- edges(blueprint.edges, raw_edges, nodes),
         {:ok, ir} <-
           IR.new(blueprint.id, blueprint.objective,
             inputs: source_inputs(blueprint.sources),
             nodes: nodes,
             edges: edges,
             acceptance: acceptance(blueprint.stop_conditions),
             policies: blueprint.policies,
             metadata: %{
               source_representation: :assistant_workflow_blueprint,
               source_metadata: blueprint.metadata
             }
           ) do
      diagnostics =
        edge_diagnostics ++
          blueprint_port_diagnostics(blueprint) ++ contract_pin_diagnostics(nodes)

      {:ok,
       %AdapterResult{
         ir: ir,
         diagnostics: diagnostics,
         lossless?: Enum.all?(diagnostics, &(&1.severity != :warning))
       }}
    end
  end

  defp nodes(blueprint) do
    Enum.reduce_while(blueprint.components, {:ok, %{}}, fn component, {:ok, acc} ->
      case Node.new(component.id, Catalog.component_key(component.type),
             arguments: component.params,
             policy: component.policy,
             metadata: %{
               provenance: component.provenance,
               source_metadata: component.metadata,
               source_type: component.type
             }
           ) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, node.id, node)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp edges(edges, raw_edges, nodes) do
    edges
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, []}, fn {edge, index}, {:ok, acc, diagnostics} ->
      raw = Enum.at(raw_edges, index, %{})

      with {:ok, from_port, from_diagnostic} <-
             endpoint_port(
               raw,
               :output,
               Map.fetch!(nodes, edge.from).contract.outputs,
               edge,
               :from
             ),
           {:ok, to_port, to_diagnostic} <-
             endpoint_port(raw, :input, Map.fetch!(nodes, edge.to).contract.inputs, edge, :to),
           {:ok, ir_edge} <-
             Edge.new(
               %{node: edge.from, port: from_port},
               %{node: edge.to, port: to_port},
               metadata: %{source_index: index}
             ) do
        edge_diagnostics = Enum.reject([from_diagnostic, to_diagnostic], &is_nil/1)

        {:cont, {:ok, Map.put(acc, ir_edge.id, ir_edge), diagnostics ++ edge_diagnostics}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp endpoint_port(raw, field, ports, edge, side) do
    explicit =
      get(raw, field) ||
        get(raw, if(field == :output, do: :from_port, else: :to_port)) ||
        nested_port(raw, side)

    cond do
      is_binary(explicit) and Map.has_key?(ports, explicit) ->
        {:ok, explicit, nil}

      is_atom(explicit) and Map.has_key?(ports, Atom.to_string(explicit)) ->
        {:ok, Atom.to_string(explicit), nil}

      not is_nil(explicit) ->
        {:error,
         Error.validation("assistant blueprint edge references an unknown port",
           source: __MODULE__,
           details: %{
             code: :unknown_edge_port,
             edge: edge,
             side: side,
             port: explicit,
             available: Map.keys(ports)
           }
         )}

      map_size(ports) == 1 ->
        [port] = Map.keys(ports)

        {:ok, port,
         diagnostic(
           :warning,
           :inferred_legacy_port,
           "legacy assistant edge omitted an exact port; the only catalog port was inferred",
           %{edge: edge, side: side, port: port}
         )}

      true ->
        {:error,
         Error.validation("assistant blueprint edge port is ambiguous",
           source: __MODULE__,
           details: %{
             code: :ambiguous_edge_port,
             edge: edge,
             side: side,
             available: Map.keys(ports)
           }
         )}
    end
  end

  defp nested_port(raw, side) do
    case get(raw, side) do
      endpoint when is_map(endpoint) -> get(endpoint, :port)
      _other -> nil
    end
  end

  defp blueprint_port_diagnostics(blueprint) do
    Enum.flat_map(blueprint.components, fn component ->
      fields =
        []
        |> maybe_port_field(component.inputs, :inputs)
        |> maybe_port_field(component.outputs, :outputs)

      if fields == [] do
        []
      else
        [
          diagnostic(
            :warning,
            :ignored_blueprint_ports,
            "blueprint-declared ports were ignored in favor of the authoritative catalog contract",
            %{node_id: component.id, fields: fields}
          )
        ]
      end
    end)
  end

  defp maybe_port_field(fields, [], _field), do: fields
  defp maybe_port_field(fields, ["output"], :outputs), do: fields
  defp maybe_port_field(fields, [:output], :outputs), do: fields
  defp maybe_port_field(fields, _ports, field), do: [field | fields]

  defp contract_pin_diagnostics(nodes) do
    [
      diagnostic(
        :info,
        :catalog_contracts_pinned,
        "assistant component contracts were pinned in workflow IR V1",
        %{contracts: Map.new(nodes, fn {id, node} -> {id, node.contract.ref} end)}
      )
    ]
  end

  defp source_inputs(sources) do
    sources
    |> Enum.map(fn source -> {source.id, %{kind: :source, path: source.path}} end)
    |> Map.new()
  end

  defp acceptance(stop_conditions) do
    stop_conditions
    |> Enum.with_index(1)
    |> Enum.map(fn {condition, index} ->
      %{id: "stop_#{index}", kind: :declared_stop_condition, condition: condition, required: true}
    end)
  end

  defp raw_edges(%WorkflowBlueprint{edges: edges}), do: edges
  defp raw_edges(input) when is_map(input), do: get(input, :edges, []) |> List.wrap()
  defp raw_edges(input) when is_list(input), do: input |> Map.new() |> raw_edges()
  defp raw_edges(_input), do: []

  defp diagnostic(severity, code, message, details) do
    %{severity: severity, code: code, message: message, details: details}
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
