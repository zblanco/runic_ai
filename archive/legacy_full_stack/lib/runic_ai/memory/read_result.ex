defmodule RunicAI.Memory.ReadResult do
  @moduledoc """
  Normalized output of a memory recall operation.
  """

  alias RunicAI.Context.Ref
  alias RunicAI.Error
  alias RunicAI.Memory.Entry

  @enforce_keys [:entries, :refs, :metadata]
  defstruct [:entries, :refs, :metadata]

  @type t :: %__MODULE__{
          entries: [Entry.t()],
          refs: [Ref.t()],
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    entries = Keyword.get(opts, :entries, [])
    refs = Keyword.get(opts, :refs, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, entries} <- normalize_entries(entries),
         {:ok, refs} <- normalize_refs(refs),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{entries: entries, refs: refs, metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    new(entries: result.entries, refs: result.refs, metadata: result.metadata)
  end

  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Entry.validate(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_entries(entries) do
    {:error,
     Error.validation("memory read entries must be a list of Memory.Entry structs",
       source: __MODULE__,
       details: %{entries: entries}
     )}
  end

  defp normalize_refs(refs) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case Ref.validate(ref) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_refs(refs) do
    {:error,
     Error.validation("memory read refs must be a list of Context.Ref structs",
       source: __MODULE__,
       details: %{refs: refs}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("memory read metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
