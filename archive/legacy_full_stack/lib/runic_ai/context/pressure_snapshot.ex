defmodule RunicAI.Context.PressureSnapshot do
  @moduledoc """
  Measured context pressure before relief decisions are applied.
  """

  alias RunicAI.Context.Ref
  alias RunicAI.Error

  @enforce_keys [
    :current_tokens,
    :tail_tokens,
    :summary_tokens,
    :memory_tokens,
    :retrieval_tokens,
    :compactable_refs,
    :metadata
  ]
  defstruct [
    :current_tokens,
    :tail_tokens,
    :summary_tokens,
    :memory_tokens,
    :retrieval_tokens,
    :compactable_refs,
    :metadata
  ]

  @type t :: %__MODULE__{
          current_tokens: non_neg_integer(),
          tail_tokens: non_neg_integer(),
          summary_tokens: non_neg_integer(),
          memory_tokens: non_neg_integer(),
          retrieval_tokens: non_neg_integer(),
          compactable_refs: [Ref.t()],
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    current_tokens = Keyword.get(opts, :current_tokens, 0)
    tail_tokens = Keyword.get(opts, :tail_tokens, 0)
    summary_tokens = Keyword.get(opts, :summary_tokens, 0)
    memory_tokens = Keyword.get(opts, :memory_tokens, 0)
    retrieval_tokens = Keyword.get(opts, :retrieval_tokens, 0)
    compactable_refs = Keyword.get(opts, :compactable_refs, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_non_negative(:current_tokens, current_tokens),
         :ok <- validate_non_negative(:tail_tokens, tail_tokens),
         :ok <- validate_non_negative(:summary_tokens, summary_tokens),
         :ok <- validate_non_negative(:memory_tokens, memory_tokens),
         :ok <- validate_non_negative(:retrieval_tokens, retrieval_tokens),
         {:ok, compactable_refs} <- normalize_refs(compactable_refs),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         current_tokens: current_tokens,
         tail_tokens: tail_tokens,
         summary_tokens: summary_tokens,
         memory_tokens: memory_tokens,
         retrieval_tokens: retrieval_tokens,
         compactable_refs: compactable_refs,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, snapshot} -> snapshot
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = snapshot) do
    new(
      current_tokens: snapshot.current_tokens,
      tail_tokens: snapshot.tail_tokens,
      summary_tokens: snapshot.summary_tokens,
      memory_tokens: snapshot.memory_tokens,
      retrieval_tokens: snapshot.retrieval_tokens,
      compactable_refs: snapshot.compactable_refs,
      metadata: snapshot.metadata
    )
  end

  defp validate_non_negative(_field, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative(field, value) do
    {:error,
     Error.validation("context pressure #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
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
     Error.validation("context pressure compactable_refs must be a list of Context.Ref structs",
       source: __MODULE__,
       details: %{compactable_refs: refs}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context pressure metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
