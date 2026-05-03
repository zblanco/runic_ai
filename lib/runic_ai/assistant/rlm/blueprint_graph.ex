defmodule RunicAI.Assistant.RLM.BlueprintGraph do
  @moduledoc """
  Multigraph-backed normalized graph view of an assistant workflow blueprint.
  """

  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentCatalog
  alias RunicAI.RLM.ComponentSpec

  @enforce_keys [:blueprint, :graph, :specs, :by_id, :ordered_specs, :batches, :roots, :leaves]
  defstruct [
    :blueprint,
    :graph,
    specs: [],
    by_id: %{},
    ordered_specs: [],
    batches: [],
    roots: [],
    leaves: []
  ]

  @type t :: %__MODULE__{
          blueprint: WorkflowBlueprint.t(),
          graph: Multigraph.t(),
          specs: [ComponentSpec.t()],
          by_id: %{String.t() => ComponentSpec.t()},
          ordered_specs: [ComponentSpec.t()],
          batches: [[ComponentSpec.t()]],
          roots: [ComponentSpec.t()],
          leaves: [ComponentSpec.t()]
        }

  @spec build(WorkflowBlueprint.t() | map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(blueprint_input, opts \\ []) when is_list(opts) do
    case analyze(blueprint_input, opts) do
      {:ok, graph, diagnostics} ->
        if Enum.any?(diagnostics, &(&1.severity == :error)) do
          {:error, validation_error(diagnostics)}
        else
          {:ok, graph}
        end

      {:error, diagnostics} ->
        {:error, validation_error(diagnostics)}
    end
  end

  @spec diagnostics(WorkflowBlueprint.t() | map(), keyword()) :: [map()]
  def diagnostics(blueprint_input, opts \\ []) when is_list(opts) do
    case analyze(blueprint_input, opts) do
      {:ok, _graph, diagnostics} -> diagnostics
      {:error, diagnostics} -> diagnostics
    end
  end

  @spec parent_ids(t(), String.t()) :: [String.t()]
  def parent_ids(%__MODULE__{} = graph, id) do
    graph
    |> spec!(id)
    |> then(&Multigraph.in_edges(graph.graph, &1, by: :flow))
    |> Enum.map(& &1.v1.id)
  end

  @spec child_ids(t(), String.t()) :: [String.t()]
  def child_ids(%__MODULE__{} = graph, id) do
    graph
    |> spec!(id)
    |> then(&Multigraph.out_edges(graph.graph, &1, by: :flow))
    |> Enum.map(& &1.v2.id)
  end

  @spec output_component_id(t()) :: String.t() | nil
  def output_component_id(%__MODULE__{leaves: []}), do: nil
  def output_component_id(%__MODULE__{leaves: leaves}), do: List.last(leaves).id

  @spec summary(t(), keyword()) :: map()
  def summary(%__MODULE__{} = graph, opts \\ []) do
    node_names = Keyword.get(opts, :node_names, %{})

    %{
      id: graph.blueprint.id,
      objective: graph.blueprint.objective,
      nodes:
        Enum.map(graph.ordered_specs, fn spec ->
          spec
          |> ComponentSpec.summary()
          |> Map.merge(%{
            name: Map.get(node_names, spec.id),
            parents: parent_ids(graph, spec.id),
            children: child_ids(graph, spec.id)
          })
        end),
      edges: graph.blueprint.edges,
      roots: Enum.map(graph.roots, & &1.id),
      leaves: Enum.map(graph.leaves, & &1.id),
      batches: Enum.map(graph.batches, fn batch -> Enum.map(batch, & &1.id) end),
      stop_conditions: graph.blueprint.stop_conditions
    }
  end

  defp analyze(blueprint_input, opts) do
    case WorkflowBlueprint.from_input(blueprint_input) do
      {:ok, blueprint} ->
        {specs, spec_diagnostics} = specs(blueprint, opts)
        graph_diagnostics = structural_diagnostics(blueprint, specs, opts)
        diagnostics = spec_diagnostics ++ graph_diagnostics

        if Enum.any?(diagnostics, &(&1.severity == :error)) do
          {:error, diagnostics}
        else
          graph = build_graph(blueprint, specs)
          {:ok, graph_view(blueprint, specs, graph), diagnostics}
        end

      {:error, %Error{} = error} ->
        {:error, [diagnostic(:error, :invalid_contract, error.message, %{error: error})]}
    end
  end

  defp specs(%WorkflowBlueprint{} = blueprint, opts) do
    Enum.reduce(blueprint.components, {[], []}, fn component, {specs, diagnostics} ->
      case ComponentCatalog.spec_from_blueprint(
             component,
             Keyword.merge(opts, blueprint_id: blueprint.id)
           ) do
        {:ok, spec} ->
          {[spec | specs], diagnostics}

        {:error, %Error{} = error} ->
          {specs,
           [
             diagnostic(
               :error,
               error_code(error, :invalid_component_params),
               error.message,
               %{component_id: Map.get(component, :id), error: error}
             )
             | diagnostics
           ]}
      end
    end)
    |> then(fn {specs, diagnostics} -> {Enum.reverse(specs), Enum.reverse(diagnostics)} end)
  end

  defp structural_diagnostics(%WorkflowBlueprint{} = blueprint, specs, opts) do
    duplicate_diagnostics(blueprint) ++
      endpoint_diagnostics(blueprint) ++
      cycle_diagnostics(blueprint, specs) ++
      shape_diagnostics(blueprint, specs, opts)
  end

  defp duplicate_diagnostics(%WorkflowBlueprint{} = blueprint) do
    ids = WorkflowBlueprint.component_ids(blueprint)
    duplicates = ids -- Enum.uniq(ids)

    if duplicates == [] do
      []
    else
      [
        diagnostic(:error, :duplicate_component_ids, "component ids must be unique", %{
          duplicates: Enum.uniq(duplicates)
        })
      ]
    end
  end

  defp endpoint_diagnostics(%WorkflowBlueprint{} = blueprint) do
    ids = MapSet.new(WorkflowBlueprint.component_ids(blueprint))

    Enum.flat_map(blueprint.edges, fn edge ->
      cond do
        not MapSet.member?(ids, edge.from) ->
          [
            diagnostic(:error, :unknown_edge_source, "edge references an unknown source node", %{
              edge: edge
            })
          ]

        not MapSet.member?(ids, edge.to) ->
          [
            diagnostic(:error, :unknown_edge_target, "edge references an unknown target node", %{
              edge: edge
            })
          ]

        edge.from == edge.to ->
          [diagnostic(:error, :self_edge, "edge cannot point to the same node", %{edge: edge})]

        true ->
          []
      end
    end)
  end

  defp cycle_diagnostics(%WorkflowBlueprint{} = blueprint, specs) do
    ids = WorkflowBlueprint.component_ids(blueprint)

    if length(specs) == length(blueprint.components) and length(ids) == length(Enum.uniq(ids)) and
         endpoint_diagnostics(blueprint) == [] do
      graph = build_graph(blueprint, specs)

      if Multigraph.is_acyclic?(graph) do
        []
      else
        [diagnostic(:error, :cycle, "workflow blueprint graph must be acyclic")]
      end
    else
      []
    end
  end

  defp shape_diagnostics(%WorkflowBlueprint{} = blueprint, specs, opts) do
    ids = WorkflowBlueprint.component_ids(blueprint)

    if length(specs) == length(blueprint.components) and length(ids) == length(Enum.uniq(ids)) and
         endpoint_diagnostics(blueprint) == [] do
      graph = build_graph(blueprint, specs)

      if Multigraph.is_acyclic?(graph) do
        view = graph_view(blueprint, specs, graph)
        root_leaf_diagnostics(view, opts) ++ isolated_component_diagnostics(view)
      else
        []
      end
    else
      []
    end
  end

  defp root_leaf_diagnostics(%__MODULE__{} = graph, opts) do
    if Keyword.get(opts, :include_root_leaf_diagnostics?, false) do
      [
        diagnostic(:warning, :root_components, "workflow blueprint root components detected", %{
          roots: Enum.map(graph.roots, & &1.id)
        }),
        diagnostic(:warning, :leaf_components, "workflow blueprint leaf components detected", %{
          leaves: Enum.map(graph.leaves, & &1.id)
        })
      ]
    else
      []
    end
  end

  defp isolated_component_diagnostics(%__MODULE__{specs: [_single]}), do: []

  defp isolated_component_diagnostics(%__MODULE__{} = graph) do
    isolated =
      Enum.filter(graph.specs, fn spec ->
        Multigraph.in_edges(graph.graph, spec, by: :flow) == [] and
          Multigraph.out_edges(graph.graph, spec, by: :flow) == []
      end)

    if isolated == [] do
      []
    else
      [
        diagnostic(
          :warning,
          :unreachable_component,
          "component is isolated from blueprint flow and will not affect terminal outputs",
          %{component_ids: Enum.map(isolated, & &1.id)}
        )
      ]
    end
  end

  defp build_graph(%WorkflowBlueprint{} = blueprint, specs) do
    by_id = Map.new(specs, &{&1.id, &1})

    graph =
      Multigraph.new(
        type: :directed,
        multigraph: true,
        vertex_identifier: &vertex_id/1
      )

    graph = Enum.reduce(specs, graph, &Multigraph.add_vertex(&2, &1))

    Enum.reduce(blueprint.edges, graph, fn edge, graph ->
      Multigraph.add_edge(
        graph,
        Map.fetch!(by_id, edge.from),
        Map.fetch!(by_id, edge.to),
        label: :flow,
        properties: Map.take(edge, [:from, :to, :input, :output, "input", "output"])
      )
    end)
  end

  defp graph_view(%WorkflowBlueprint{} = blueprint, specs, graph) do
    ordered = Multigraph.topsort(graph) || []
    batches = Multigraph.batch_topsort(graph) || []

    %__MODULE__{
      blueprint: blueprint,
      graph: graph,
      specs: specs,
      by_id: Map.new(specs, &{&1.id, &1}),
      ordered_specs: ordered,
      batches: batches,
      roots: Enum.filter(ordered, &(Multigraph.in_edges(graph, &1, by: :flow) == [])),
      leaves: Enum.filter(ordered, &(Multigraph.out_edges(graph, &1, by: :flow) == []))
    }
  end

  defp spec!(%__MODULE__{by_id: by_id}, id), do: Map.fetch!(by_id, id)

  defp vertex_id(%{id: id}), do: id
  defp vertex_id(id), do: id

  defp validation_error(diagnostics) do
    Error.validation("assistant workflow blueprint graph rejected",
      source: __MODULE__,
      details: %{diagnostics: diagnostics}
    )
  end

  defp error_code(%Error{details: details}, default) when is_map(details),
    do: Map.get(details, :code, default)

  defp error_code(_error, default), do: default

  defp diagnostic(severity, code, message, details \\ %{}) do
    %{severity: severity, code: code, message: message, details: details}
  end
end
