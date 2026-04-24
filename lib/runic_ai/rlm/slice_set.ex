defmodule RunicAI.RLM.SliceSet do
  @moduledoc """
  Ordered collection of slices produced by one split operation.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.Slice

  @enforce_keys [:slices, :metadata]
  defstruct [:source_ref, slices: [], metadata: %{}]

  @type t :: %__MODULE__{
          source_ref: EnvironmentRef.t() | nil,
          slices: [Slice.t()],
          metadata: map()
        }

  @spec new([Slice.t()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(slices, opts \\ []) when is_list(slices) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, slices} <- normalize_slices(slices),
         {:ok, source_ref} <- infer_source_ref(slices, Keyword.get(opts, :source_ref)),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{source_ref: source_ref, slices: slices, metadata: metadata}}
    end
  end

  @spec new!([Slice.t()], keyword()) :: t()
  def new!(slices, opts \\ []) do
    case new(slices, opts) do
      {:ok, slice_set} -> slice_set
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = slice_set) do
    new(slice_set.slices, source_ref: slice_set.source_ref, metadata: slice_set.metadata)
  end

  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{slices: slices}), do: length(slices)

  @spec total_length(t()) :: non_neg_integer()
  def total_length(%__MODULE__{slices: slices}), do: Enum.reduce(slices, 0, &(&1.length + &2))

  defp normalize_slices(slices) do
    Enum.reduce_while(slices, {:ok, []}, fn
      %Slice{} = slice, {:ok, acc} ->
        case Slice.validate(slice) do
          {:ok, slice} -> {:cont, {:ok, [slice | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.validation("slice set entries must be Slice structs",
            source: __MODULE__,
            details: %{slice: other}
          )}}
    end)
    |> case do
      {:ok, slices} -> {:ok, Enum.reverse(slices)}
      error -> error
    end
  end

  defp infer_source_ref([], nil), do: {:ok, nil}

  defp infer_source_ref(_slices, %EnvironmentRef{} = source_ref),
    do: EnvironmentRef.validate(source_ref)

  defp infer_source_ref([first | rest], nil) do
    if Enum.all?(rest, &same_source?(&1.source_ref, first.source_ref)) do
      {:ok, first.source_ref}
    else
      {:ok, nil}
    end
  end

  defp same_source?(%EnvironmentRef{} = left, %EnvironmentRef{} = right) do
    left.environment == right.environment and left.source_id == right.source_id
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("slice set metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
