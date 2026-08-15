defmodule RunicAI.Context.LineageSnapshot do
  @moduledoc """
  Checkpoint of context lineage tied to a runtime session lifecycle.
  """

  alias RunicAI.Context.Graph
  alias RunicAI.Error

  @enforce_keys [:id, :session_id, :created_at, :metadata]
  defstruct [:id, :session_id, :graph, :snapshot, :created_at, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          graph: Graph.t() | nil,
          snapshot: term(),
          created_at: DateTime.t(),
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    id = Keyword.get(opts, :id, "lineage:#{session_id}:#{System.unique_integer([:positive])}")
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_id(session_id),
         :ok <- validate_created_at(created_at),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         graph: Keyword.get(opts, :graph),
         snapshot: Keyword.get(opts, :snapshot),
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), keyword()) :: t()
  def new!(session_id, opts \\ []) do
    case new(session_id, opts) do
      {:ok, snapshot} -> snapshot
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("lineage snapshot id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_created_at(%DateTime{}), do: :ok

  defp validate_created_at(created_at) do
    {:error,
     Error.validation("lineage snapshot created_at must be a DateTime",
       source: __MODULE__,
       details: %{created_at: created_at}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("lineage snapshot #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
