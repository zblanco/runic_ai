defmodule RunicAI.RLM.MaterializedArtifact do
  @moduledoc """
  Bounded source material brought into a workflow step.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :content, :refs, :metadata]
  defstruct [:id, :content, refs: [], metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          refs: [term()],
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(content, opts \\ []) when is_binary(content) and is_list(opts) do
    id = Keyword.get(opts, :id) || "artifact:#{System.unique_integer([:positive])}"
    refs = Keyword.get(opts, :refs, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_refs(refs),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{id: id, content: content, refs: refs, metadata: metadata}}
    end
  end

  @spec new!(String.t(), keyword()) :: t()
  def new!(content, opts \\ []) do
    case new(content, opts) do
      {:ok, artifact} -> artifact
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = artifact) do
    new(artifact.content, id: artifact.id, refs: artifact.refs, metadata: artifact.metadata)
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = artifact), do: artifact.content

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("materialized artifact id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_refs(refs) when is_list(refs), do: :ok

  defp validate_refs(refs) do
    {:error,
     Error.validation("materialized artifact refs must be a list",
       source: __MODULE__,
       details: %{refs: refs}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("materialized artifact metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
