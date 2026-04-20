defmodule RunicAI.Retrieval.Query do
  @moduledoc """
  Backend-neutral retrieval query contract.
  """

  alias RunicAI.Error

  @enforce_keys [:text, :filters, :scope, :top_k, :metadata]
  defstruct [:text, :filters, :scope, :top_k, :metadata]

  @type t :: %__MODULE__{
          text: String.t(),
          filters: map(),
          scope: term(),
          top_k: pos_integer(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    text = Keyword.get(opts, :text, "")
    filters = Keyword.get(opts, :filters, %{})
    scope = Keyword.get(opts, :scope, :default)
    top_k = Keyword.get(opts, :top_k, 5)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_text(text),
         :ok <- validate_filters(filters),
         :ok <- validate_top_k(top_k),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{text: text, filters: filters, scope: scope, top_k: top_k, metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, query} -> query
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = query) do
    new(
      text: query.text,
      filters: query.filters,
      scope: query.scope,
      top_k: query.top_k,
      metadata: query.metadata
    )
  end

  defp validate_text(text) when is_binary(text) and text != "", do: :ok

  defp validate_text(text) do
    {:error,
     Error.validation("retrieval query text must be a non-empty string",
       source: __MODULE__,
       details: %{text: text}
     )}
  end

  defp validate_filters(filters) when is_map(filters), do: :ok

  defp validate_filters(filters) do
    {:error,
     Error.validation("retrieval query filters must be a map",
       source: __MODULE__,
       details: %{filters: filters}
     )}
  end

  defp validate_top_k(top_k) when is_integer(top_k) and top_k > 0, do: :ok

  defp validate_top_k(top_k) do
    {:error,
     Error.validation("retrieval query top_k must be a positive integer",
       source: __MODULE__,
       details: %{top_k: top_k}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("retrieval query metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
