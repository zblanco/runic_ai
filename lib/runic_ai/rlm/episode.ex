defmodule RunicAI.RLM.Episode do
  @moduledoc """
  Synchronization artifact returned by scoped child or worker execution.
  """

  alias RunicAI.Error

  @valid_statuses [:satisfied, :partial, :blocked, :extended, :failed]

  @enforce_keys [:id, :status, :outcome, :artifacts, :provenance, :usage, :metadata]
  defstruct [
    :id,
    :status,
    :parent_node_id,
    :worker_id,
    :outcome,
    :continuation,
    artifacts: [],
    provenance: [],
    usage: %{},
    metadata: %{}
  ]

  @type status :: :satisfied | :partial | :blocked | :extended | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          parent_node_id: String.t() | nil,
          worker_id: String.t() | nil,
          outcome: term(),
          continuation: term(),
          artifacts: [term()],
          provenance: [term()],
          usage: map(),
          metadata: map()
        }

  @spec new(status(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(status, outcome, opts \\ []) when is_list(opts) do
    episode = %__MODULE__{
      id: Keyword.get(opts, :id) || "episode:#{System.unique_integer([:positive])}",
      status: status,
      parent_node_id: Keyword.get(opts, :parent_node_id),
      worker_id: Keyword.get(opts, :worker_id),
      outcome: outcome,
      continuation: Keyword.get(opts, :continuation),
      artifacts: Keyword.get(opts, :artifacts, []),
      provenance: Keyword.get(opts, :provenance, []),
      usage: Keyword.get(opts, :usage, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(episode)
  end

  @spec new!(status(), term(), keyword()) :: t()
  def new!(status, outcome, opts \\ []) do
    case new(status, outcome, opts) do
      {:ok, episode} -> episode
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = episode) do
    with :ok <- validate_id(episode.id),
         :ok <- validate_status(episode.status),
         :ok <- validate_optional_id(episode.parent_node_id, :parent_node_id),
         :ok <- validate_optional_id(episode.worker_id, :worker_id),
         :ok <- validate_list(episode.artifacts, :artifacts),
         :ok <- validate_list(episode.provenance, :provenance),
         :ok <- validate_map(episode.usage, :usage),
         :ok <- validate_map(episode.metadata, :metadata) do
      {:ok, episode}
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("episode id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_optional_id(nil, _field), do: :ok
  defp validate_optional_id(id, _field) when is_binary(id) and id != "", do: :ok

  defp validate_optional_id(id, field) do
    {:error,
     Error.validation("episode #{field} must be a non-empty string or nil",
       source: __MODULE__,
       details: %{field: field, value: id}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid episode status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("episode #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("episode #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
