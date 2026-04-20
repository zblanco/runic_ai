defmodule RunicAI.Retrieval.Document do
  @moduledoc """
  Normalized retrieved document.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :content, :uri, :metadata]
  defstruct [:id, :content, :uri, :score, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          uri: String.t() | nil,
          score: number() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, "doc-#{System.unique_integer([:positive])}")
    content = Keyword.get(opts, :content, "")
    uri = Keyword.get(opts, :uri)
    score = Keyword.get(opts, :score)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_content(content),
         :ok <- validate_optional_string(:uri, uri),
         :ok <- validate_optional_number(:score, score),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{id: id, content: content, uri: uri, score: score, metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, document} -> document
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = document) do
    new(
      id: document.id,
      content: document.content,
      uri: document.uri,
      score: document.score,
      metadata: document.metadata
    )
  end

  @spec normalize_list([t()]) :: {:ok, [t()]} | {:error, Error.t()}
  def normalize_list(documents) when is_list(documents) do
    documents
    |> Enum.reduce_while({:ok, []}, fn document, {:ok, acc} ->
      case validate(document) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  def normalize_list(other) do
    {:error,
     Error.validation("retrieval documents must be a list of Retrieval.Document structs",
       source: __MODULE__,
       details: %{documents: other}
     )}
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("retrieval document id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_content(content) when is_binary(content) and content != "", do: :ok

  defp validate_content(content) do
    {:error,
     Error.validation("retrieval document content must be a non-empty string",
       source: __MODULE__,
       details: %{content: content}
     )}
  end

  defp validate_optional_string(_field, nil), do: :ok
  defp validate_optional_string(_field, value) when is_binary(value), do: :ok

  defp validate_optional_string(field, value) do
    {:error,
     Error.validation("retrieval document #{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_number(_field, nil), do: :ok
  defp validate_optional_number(_field, value) when is_number(value), do: :ok

  defp validate_optional_number(field, value) do
    {:error,
     Error.validation("retrieval document #{field} must be numeric or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("retrieval document metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
