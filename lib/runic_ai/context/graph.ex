defmodule RunicAI.Context.Graph do
  @moduledoc """
  Thin wrapper around `Multigraph` that keeps a stable node index.
  """

  alias RunicAI.Context.Node
  alias RunicAI.Context.Ref
  alias RunicAI.Error

  @enforce_keys [:multigraph, :node_index, :metadata]
  defstruct [:multigraph, :node_index, :metadata]

  @type t :: %__MODULE__{
          multigraph: Multigraph.t(),
          node_index: %{optional(String.t()) => Node.t()},
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    partition_by = Keyword.get(opts, :partition_by, &default_partition_by/1)

    %__MODULE__{
      multigraph:
        Multigraph.new(
          type: :directed,
          multigraph: true,
          partition_by: partition_by,
          vertex_identifier: fn %Node{id: id} -> id end
        ),
      node_index: %{},
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = graph) do
    with :ok <- validate_node_index(graph.node_index),
         :ok <- validate_metadata(graph.metadata) do
      {:ok, graph}
    end
  end

  @spec put_node(t(), Node.t()) :: {:ok, t()} | {:error, Error.t()}
  def put_node(%__MODULE__{} = graph, %Node{} = node) do
    with {:ok, _graph} <- validate(graph),
         {:ok, node} <- Node.validate(node) do
      multigraph = Multigraph.add_vertex(graph.multigraph, node, [node.kind])

      {:ok,
       %__MODULE__{
         graph
         | multigraph: multigraph,
           node_index: Map.put(graph.node_index, node.id, node)
       }}
    end
  end

  @spec put_node!(t(), Node.t()) :: t()
  def put_node!(%__MODULE__{} = graph, %Node{} = node) do
    case put_node(graph, node) do
      {:ok, updated_graph} -> updated_graph
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec get_node(t(), Ref.t() | String.t()) :: Node.t() | nil
  def get_node(%__MODULE__{} = graph, %Ref{} = ref), do: Map.get(graph.node_index, Ref.key(ref))
  def get_node(%__MODULE__{} = graph, id) when is_binary(id), do: Map.get(graph.node_index, id)

  @spec has_ref?(t(), Ref.t()) :: boolean()
  def has_ref?(%__MODULE__{} = graph, %Ref{} = ref),
    do: Map.has_key?(graph.node_index, Ref.key(ref))

  @spec list_nodes(t()) :: [Node.t()]
  def list_nodes(%__MODULE__{} = graph) do
    graph.node_index
    |> Map.values()
    |> Enum.sort_by(&{DateTime.to_unix(&1.created_at, :microsecond), &1.id})
  end

  @spec list_nodes_by_kind(t(), Node.kind()) :: [Node.t()]
  def list_nodes_by_kind(%__MODULE__{} = graph, kind) do
    graph
    |> list_nodes()
    |> Enum.filter(&(&1.kind == kind))
  end

  @spec add_relation(t(), Ref.t() | String.t(), Ref.t() | String.t(), atom(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def add_relation(%__MODULE__{} = graph, source, target, label, opts \\ [])
      when is_atom(label) do
    properties = Keyword.get(opts, :properties, %{})
    weight = Keyword.get(opts, :weight, 1)

    with {:ok, _graph} <- validate(graph),
         {:ok, source_node} <- fetch_existing_node(graph, source, :source),
         {:ok, target_node} <- fetch_existing_node(graph, target, :target),
         :ok <- validate_properties(properties),
         :ok <- validate_weight(weight) do
      multigraph =
        Multigraph.add_edge(graph.multigraph, source_node, target_node,
          label: label,
          properties: properties,
          weight: weight
        )

      {:ok, %__MODULE__{graph | multigraph: multigraph}}
    end
  end

  @spec add_relation!(t(), Ref.t() | String.t(), Ref.t() | String.t(), atom(), keyword()) :: t()
  def add_relation!(%__MODULE__{} = graph, source, target, label, opts \\ []) do
    case add_relation(graph, source, target, label, opts) do
      {:ok, updated_graph} -> updated_graph
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec out_nodes(t(), Ref.t() | String.t(), atom() | nil) :: [Node.t()]
  def out_nodes(%__MODULE__{} = graph, source, label \\ nil) do
    with {:ok, source_node} <- fetch_existing_node(graph, source, :source) do
      opts = if label, do: [by: label], else: []

      graph.multigraph
      |> Multigraph.out_edges(source_node, opts)
      |> Enum.map(& &1.v2)
    else
      _ -> []
    end
  end

  @spec in_nodes(t(), Ref.t() | String.t(), atom() | nil) :: [Node.t()]
  def in_nodes(%__MODULE__{} = graph, target, label \\ nil) do
    with {:ok, target_node} <- fetch_existing_node(graph, target, :target) do
      opts = if label, do: [by: label], else: []

      graph.multigraph
      |> Multigraph.in_edges(target_node, opts)
      |> Enum.map(& &1.v1)
    else
      _ -> []
    end
  end

  @spec summarized?(t(), Ref.t() | String.t()) :: boolean()
  def summarized?(%__MODULE__{} = graph, ref_or_id) do
    graph
    |> in_nodes(ref_or_id, :summarizes)
    |> Enum.any?()
  end

  @spec top_level_nodes(t(), Node.kind()) :: [Node.t()]
  def top_level_nodes(%__MODULE__{} = graph, kind) do
    graph
    |> list_nodes_by_kind(kind)
    |> Enum.filter(fn node ->
      graph
      |> in_nodes(node.id, :summarizes)
      |> Enum.filter(&(&1.kind == kind))
      |> Enum.empty?()
    end)
  end

  defp fetch_existing_node(%__MODULE__{} = graph, %Ref{} = ref, _role) do
    case get_node(graph, ref) do
      %Node{} = node ->
        {:ok, node}

      nil ->
        {:error, Error.validation("missing context node for #{Ref.key(ref)}", source: __MODULE__)}
    end
  end

  defp fetch_existing_node(%__MODULE__{} = graph, id, role) when is_binary(id) do
    case get_node(graph, id) do
      %Node{} = node ->
        {:ok, node}

      nil ->
        {:error,
         Error.validation("missing #{role} context node for #{inspect(id)}", source: __MODULE__)}
    end
  end

  defp validate_node_index(node_index) when is_map(node_index) do
    node_index
    |> Map.values()
    |> Enum.reduce_while(:ok, fn node, _acc ->
      case Node.validate(node) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_node_index(node_index) do
    {:error,
     Error.validation("context graph node_index must be a map",
       source: __MODULE__,
       details: %{node_index: node_index}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context graph metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp validate_properties(properties) when is_map(properties), do: :ok

  defp validate_properties(properties) do
    {:error,
     Error.validation("context graph edge properties must be a map",
       source: __MODULE__,
       details: %{properties: properties}
     )}
  end

  defp validate_weight(weight) when is_number(weight), do: :ok

  defp validate_weight(weight) do
    {:error,
     Error.validation("context graph edge weight must be numeric",
       source: __MODULE__,
       details: %{weight: weight}
     )}
  end

  defp default_partition_by(%Multigraph.Edge{label: label}), do: [label]
end
