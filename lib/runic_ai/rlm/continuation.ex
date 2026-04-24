defmodule RunicAI.RLM.Continuation do
  @moduledoc """
  Typed description of further RLM work justified by an episode or result.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :next, :metadata]
  defstruct [:id, :next, :episode_id, budget_delta: %{}, routing: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          next: term(),
          episode_id: String.t() | nil,
          budget_delta: map(),
          routing: map(),
          metadata: map()
        }

  @spec new(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(next, opts \\ []) when is_list(opts) do
    continuation = %__MODULE__{
      id: Keyword.get(opts, :id) || "continuation:#{System.unique_integer([:positive])}",
      next: next,
      episode_id: Keyword.get(opts, :episode_id),
      budget_delta: Keyword.get(opts, :budget_delta, %{}),
      routing: Keyword.get(opts, :routing, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(continuation)
  end

  @spec new!(term(), keyword()) :: t()
  def new!(next, opts \\ []) do
    case new(next, opts) do
      {:ok, continuation} -> continuation
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = continuation) do
    with :ok <- validate_id(continuation.id),
         :ok <- validate_optional_id(continuation.episode_id, :episode_id),
         :ok <- validate_map(continuation.budget_delta, :budget_delta),
         :ok <- validate_map(continuation.routing, :routing),
         :ok <- validate_map(continuation.metadata, :metadata) do
      {:ok, continuation}
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("continuation id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_optional_id(nil, _field), do: :ok
  defp validate_optional_id(id, _field) when is_binary(id) and id != "", do: :ok

  defp validate_optional_id(id, field) do
    {:error,
     Error.validation("continuation #{field} must be a non-empty string or nil",
       source: __MODULE__,
       details: %{field: field, value: id}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("continuation #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
