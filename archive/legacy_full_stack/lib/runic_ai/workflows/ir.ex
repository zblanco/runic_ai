defmodule RunicAI.Workflows.IR do
  @moduledoc """
  Canonical, JSON-safe semantic workflow representation.

  IR V1 is intentionally independent from authoring syntax, persistence rows,
  compiled Runic graphs, and execution state.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.JSONValue
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node

  @format "runic_ai/workflow_ir"
  @version 1

  @enforce_keys [:id, :objective]
  @derive Jason.Encoder
  defstruct [
    :id,
    :objective,
    format: @format,
    format_version: @version,
    revision: 1,
    inputs: %{},
    nodes: %{},
    edges: %{},
    acceptance: [],
    policies: %{},
    holes: [],
    presentation: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          format: String.t(),
          format_version: pos_integer(),
          revision: pos_integer(),
          inputs: map(),
          nodes: %{String.t() => Node.t()},
          edges: %{String.t() => Edge.t()},
          acceptance: [map()],
          policies: map(),
          holes: [map()],
          presentation: map(),
          metadata: map()
        }

  @spec format() :: String.t()
  def format, do: @format

  @spec format_version() :: pos_integer()
  def format_version, do: @version

  @spec new(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, objective, opts \\ []) when is_list(opts) do
    with :ok <- validate_non_empty(id, :id),
         :ok <- validate_non_empty(objective, :objective),
         :ok <- validate_revision(Keyword.get(opts, :revision, 1)),
         {:ok, nodes} <- normalize_nodes(Keyword.get(opts, :nodes, %{})),
         {:ok, edges} <- normalize_edges(Keyword.get(opts, :edges, %{})),
         :ok <- validate_map(Keyword.get(opts, :inputs, %{}), :inputs),
         :ok <- validate_list(Keyword.get(opts, :acceptance, []), :acceptance),
         :ok <- validate_map(Keyword.get(opts, :policies, %{}), :policies),
         :ok <- validate_list(Keyword.get(opts, :holes, []), :holes),
         :ok <- validate_map(Keyword.get(opts, :presentation, %{}), :presentation),
         :ok <- validate_map(Keyword.get(opts, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         objective: objective,
         revision: Keyword.get(opts, :revision, 1),
         inputs: Keyword.get(opts, :inputs, %{}),
         nodes: nodes,
         edges: edges,
         acceptance: Keyword.get(opts, :acceptance, []),
         policies: Keyword.get(opts, :policies, %{}),
         holes: Keyword.get(opts, :holes, []),
         presentation: Keyword.get(opts, :presentation, %{}),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec from_input(t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = ir), do: validate(ir)

  def from_input(input) when is_map(input) do
    with :ok <- validate_format(get(input, :format, @format)),
         :ok <- validate_format_version(get(input, :format_version, @version)) do
      new(get(input, :id), get(input, :objective),
        revision: get(input, :revision, 1),
        inputs: get(input, :inputs, %{}),
        nodes: get(input, :nodes, %{}),
        edges: get(input, :edges, %{}),
        acceptance: get(input, :acceptance, []),
        policies: get(input, :policies, %{}),
        holes: get(input, :holes, []),
        presentation: get(input, :presentation, %{}),
        metadata: get(input, :metadata, %{})
      )
    end
  end

  def from_input(input) do
    {:error,
     Error.validation("workflow IR must be a map",
       source: __MODULE__,
       details: %{code: :invalid_workflow_ir, input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = ir) do
    new(ir.id, ir.objective,
      revision: ir.revision,
      inputs: ir.inputs,
      nodes: ir.nodes,
      edges: ir.edges,
      acceptance: ir.acceptance,
      policies: ir.policies,
      holes: ir.holes,
      presentation: ir.presentation,
      metadata: ir.metadata
    )
  end

  @spec semantic_hash(t()) :: String.t()
  def semantic_hash(%__MODULE__{} = ir) do
    ir
    |> Map.from_struct()
    |> Map.drop([:presentation])
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_nodes(nodes) when is_list(nodes) do
    normalize_nodes(Map.new(nodes, fn node -> {get(node, :id), node} end))
  end

  defp normalize_nodes(nodes) when is_map(nodes) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn {key, input}, {:ok, acc} ->
      case Node.from_input(input) do
        {:ok, %Node{id: id} = node} ->
          if key_matches_id?(key, id) do
            {:cont, {:ok, Map.put(acc, id, node)}}
          else
            {:halt,
             {:error,
              Error.validation("workflow IR node map key must equal node id",
                source: __MODULE__,
                details: %{code: :node_key_mismatch, key: key, id: id}
              )}}
          end

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_nodes(nodes) do
    {:error,
     Error.validation("workflow IR nodes must be an id-keyed map",
       source: __MODULE__,
       details: %{code: :invalid_nodes, nodes: nodes}
     )}
  end

  defp normalize_edges(edges) when is_list(edges) do
    normalize_edges(Map.new(edges, fn edge -> {get(edge, :id), edge} end))
  end

  defp normalize_edges(edges) when is_map(edges) do
    Enum.reduce_while(edges, {:ok, %{}}, fn {key, input}, {:ok, acc} ->
      case Edge.from_input(input) do
        {:ok, %Edge{id: id} = edge} ->
          if key_matches_id?(key, id) do
            {:cont, {:ok, Map.put(acc, id, edge)}}
          else
            {:halt,
             {:error,
              Error.validation("workflow IR edge map key must equal edge id",
                source: __MODULE__,
                details: %{code: :edge_key_mismatch, key: key, id: id}
              )}}
          end

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_edges(edges) do
    {:error,
     Error.validation("workflow IR edges must be an id-keyed map",
       source: __MODULE__,
       details: %{code: :invalid_edges, edges: edges}
     )}
  end

  defp validate_format(@format), do: :ok

  defp validate_format(format) do
    {:error,
     Error.validation("unsupported workflow IR format",
       source: __MODULE__,
       details: %{code: :unsupported_ir_format, format: format}
     )}
  end

  defp validate_format_version(@version), do: :ok

  defp validate_format_version(version) do
    {:error,
     Error.validation("unsupported workflow IR format version",
       source: __MODULE__,
       details: %{code: :unsupported_ir_version, version: version}
     )}
  end

  defp validate_revision(revision) when is_integer(revision) and revision > 0, do: :ok

  defp validate_revision(revision) do
    {:error,
     Error.validation("workflow IR revision must be a positive integer",
       source: __MODULE__,
       details: %{code: :invalid_revision, revision: revision}
     )}
  end

  defp validate_non_empty(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_non_empty(value, field) do
    {:error,
     Error.validation("workflow IR #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{code: :invalid_ir_field, field: field, value: value}
     )}
  end

  defp validate_map(value, field) when is_map(value),
    do: JSONValue.validate_unambiguous(value, __MODULE__, field)

  defp validate_map(value, field) do
    {:error,
     Error.validation("workflow IR #{field} must be a map",
       source: __MODULE__,
       details: %{code: :invalid_ir_field, field: field, value: value}
     )}
  end

  defp validate_list(value, field) when is_list(value),
    do: JSONValue.validate_unambiguous(value, __MODULE__, field)

  defp validate_list(value, field) do
    {:error,
     Error.validation("workflow IR #{field} must be a list",
       source: __MODULE__,
       details: %{code: :invalid_ir_field, field: field, value: value}
     )}
  end

  defp key_matches_id?(key, id) when is_binary(key), do: key == id
  defp key_matches_id?(key, id) when is_atom(key), do: Atom.to_string(key) == id
  defp key_matches_id?(_key, _id), do: false

  defp canonical_term(%_{} = struct), do: struct |> Map.from_struct() |> canonical_term()

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)

  defp canonical_term(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp canonical_term(value), do: value

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
