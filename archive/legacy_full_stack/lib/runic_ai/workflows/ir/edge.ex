defmodule RunicAI.Workflows.IR.Edge do
  @moduledoc """
  Exact output-to-input binding in workflow IR V1.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.JSONValue

  @enforce_keys [:id, :from, :to]
  @derive Jason.Encoder
  defstruct [:id, :from, :to, mode: :data, metadata: %{}]

  @type endpoint :: %{required(:node) => String.t(), required(:port) => String.t()}
  @type t :: %__MODULE__{
          id: String.t(),
          from: endpoint(),
          to: endpoint(),
          mode: atom(),
          metadata: map()
        }

  @spec new(endpoint() | map(), endpoint() | map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(from, to, opts \\ []) when is_list(opts) do
    with {:ok, from} <- normalize_endpoint(from, :from),
         {:ok, to} <- normalize_endpoint(to, :to),
         :ok <- validate_map(Keyword.get(opts, :metadata, %{}), :metadata) do
      id = Keyword.get(opts, :id) || id(from, to)

      {:ok,
       %__MODULE__{
         id: id,
         from: from,
         to: to,
         mode: Keyword.get(opts, :mode, :data),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec from_input(t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = edge), do: new(edge.from, edge.to, edge_to_opts(edge))

  def from_input(input) when is_map(input) do
    new(get(input, :from), get(input, :to),
      id: get(input, :id),
      mode: normalize_mode(get(input, :mode, :data)),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("workflow IR edge must be a map",
       source: __MODULE__,
       details: %{code: :invalid_ir_edge, input: input}
     )}
  end

  @spec id(endpoint(), endpoint()) :: String.t()
  def id(from, to), do: "#{from.node}.#{from.port}->#{to.node}.#{to.port}"

  defp normalize_endpoint(endpoint, side) when is_map(endpoint) do
    node = get(endpoint, :node)
    port = get(endpoint, :port)

    if non_empty?(node) and non_empty?(port) do
      {:ok, %{node: node, port: port}}
    else
      {:error,
       Error.validation("workflow IR edge #{side} endpoint requires node and port",
         source: __MODULE__,
         details: %{code: :invalid_edge_endpoint, side: side, endpoint: endpoint}
       )}
    end
  end

  defp normalize_endpoint(endpoint, side) do
    {:error,
     Error.validation("workflow IR edge #{side} endpoint must be a map",
       source: __MODULE__,
       details: %{code: :invalid_edge_endpoint, side: side, endpoint: endpoint}
     )}
  end

  defp edge_to_opts(edge) do
    [id: edge.id, mode: edge.mode, metadata: edge.metadata]
  end

  defp validate_map(value, field) when is_map(value),
    do: JSONValue.validate_unambiguous(value, __MODULE__, field)

  defp validate_map(value, field) do
    {:error,
     Error.validation("workflow IR edge #{field} must be a map",
       source: __MODULE__,
       details: %{code: :invalid_edge_field, field: field, value: value}
     )}
  end

  defp non_empty?(value), do: is_binary(value) and value != ""
  defp normalize_mode("data"), do: :data
  defp normalize_mode("control"), do: :control
  defp normalize_mode(mode), do: mode

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
