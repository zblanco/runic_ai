defmodule RunicAI.Retrieval.Result do
  @moduledoc """
  Normalized retrieval result for context assembly.
  """

  alias RunicAI.Error
  alias RunicAI.Retrieval.Document
  alias RunicAI.Retrieval.Query

  @enforce_keys [:documents, :query, :provider, :metadata]
  defstruct [:documents, :query, :provider, :metadata]

  @type t :: %__MODULE__{
          documents: [Document.t()],
          query: Query.t(),
          provider: term(),
          metadata: map()
        }

  @spec new(Query.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Query{} = query, opts \\ []) when is_list(opts) do
    documents = Keyword.get(opts, :documents, [])
    provider = Keyword.get(opts, :provider, :none)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, query} <- Query.validate(query),
         {:ok, documents} <- Document.normalize_list(documents),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{documents: documents, query: query, provider: provider, metadata: metadata}}
    end
  end

  @spec new!(Query.t(), keyword()) :: t()
  def new!(%Query{} = query, opts \\ []) do
    case new(query, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec empty(keyword()) :: t()
  def empty(opts \\ []) do
    query = Query.new!(text: Keyword.get(opts, :text, "context"), top_k: 1)

    new!(query,
      documents: [],
      provider: Keyword.get(opts, :provider, :none),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    new(result.query,
      documents: result.documents,
      provider: result.provider,
      metadata: result.metadata
    )
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("retrieval result metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
