defmodule RunicAI.RLM.LeafResult do
  @moduledoc """
  Result produced by one bounded leaf operation over a slice or artifact.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :output, :metadata]
  defstruct [:id, :slice, :artifact, :output, usage: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          slice: term(),
          artifact: term(),
          output: term(),
          usage: map(),
          metadata: map()
        }

  @spec new(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(output, opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id) || "leaf:#{System.unique_integer([:positive])}"
    usage = Keyword.get(opts, :usage, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_map(usage, :usage),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         slice: Keyword.get(opts, :slice),
         artifact: Keyword.get(opts, :artifact),
         output: output,
         usage: usage,
         metadata: metadata
       }}
    end
  end

  @spec new!(term(), keyword()) :: t()
  def new!(output, opts \\ []) do
    case new(output, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    new(result.output,
      id: result.id,
      slice: result.slice,
      artifact: result.artifact,
      usage: result.usage,
      metadata: result.metadata
    )
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("leaf result id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("leaf result #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
