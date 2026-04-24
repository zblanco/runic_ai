defmodule RunicAI.RLM.PlanPatch do
  @moduledoc """
  Validated proposal for runtime growth of an RLM plan.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.PlanNode

  @enforce_keys [:nodes, :metadata]
  defstruct nodes: [], connect_to: [], metadata: %{}

  @type t :: %__MODULE__{
          nodes: [PlanNode.t()],
          connect_to: [String.t()],
          metadata: map()
        }

  @spec new([PlanNode.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(nodes, opts \\ []) when is_list(nodes) and is_list(opts) do
    connect_to = Keyword.get(opts, :connect_to, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, nodes} <- normalize_nodes(nodes),
         :ok <- validate_ids(connect_to, :connect_to),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{nodes: nodes, connect_to: connect_to, metadata: metadata}}
    end
  end

  @spec new!([PlanNode.t()], keyword()) :: t()
  def new!(nodes, opts \\ []) do
    case new(nodes, opts) do
      {:ok, patch} -> patch
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = patch) do
    new(patch.nodes, connect_to: patch.connect_to, metadata: patch.metadata)
  end

  defp normalize_nodes(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn
      %PlanNode{} = node, {:ok, acc} ->
        case PlanNode.validate(node) do
          {:ok, node} -> {:cont, {:ok, [node | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.validation("plan patch nodes must be PlanNode structs",
            source: __MODULE__,
            details: %{node: other}
          )}}
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp validate_ids(ids, _field) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")), do: :ok, else: invalid_ids(ids)
  end

  defp validate_ids(ids, _field), do: invalid_ids(ids)

  defp invalid_ids(ids) do
    {:error,
     Error.validation("plan patch connect_to must be a list of non-empty node ids",
       source: __MODULE__,
       details: %{connect_to: ids}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("plan patch metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
