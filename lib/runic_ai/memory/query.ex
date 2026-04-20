defmodule RunicAI.Memory.Query do
  @moduledoc """
  Query contract for memory recall.
  """

  alias RunicAI.Context.Focus
  alias RunicAI.Error

  @enforce_keys [:focus, :kinds, :limit, :metadata]
  defstruct [:focus, :predicate, :kinds, :limit, :metadata]

  @type t :: %__MODULE__{
          focus: Focus.t(),
          kinds: [RunicAI.Memory.Entry.kind()],
          limit: pos_integer(),
          predicate: (RunicAI.Memory.Entry.t() -> boolean()) | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    focus = Keyword.fetch!(opts, :focus)
    kinds = Keyword.get(opts, :kinds, [:episodic, :semantic, :temporal])
    limit = Keyword.get(opts, :limit, 6)
    predicate = Keyword.get(opts, :predicate)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, focus} <- normalize_focus(focus),
         :ok <- validate_kinds(kinds),
         :ok <- validate_limit(limit),
         :ok <- validate_predicate(predicate),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         focus: focus,
         kinds: kinds,
         limit: limit,
         predicate: predicate,
         metadata: metadata
       }}
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
      focus: query.focus,
      kinds: query.kinds,
      limit: query.limit,
      predicate: query.predicate,
      metadata: query.metadata
    )
  end

  defp normalize_focus(%Focus{} = focus), do: Focus.validate(focus)

  defp normalize_focus(focus) do
    {:error,
     Error.validation("memory query focus must be a Context.Focus",
       source: __MODULE__,
       details: %{focus: focus}
     )}
  end

  defp validate_kinds(kinds) when is_list(kinds) do
    if Enum.all?(kinds, &(&1 in [:episodic, :semantic, :temporal])) do
      :ok
    else
      {:error, Error.validation("memory query kinds contain invalid values", source: __MODULE__)}
    end
  end

  defp validate_kinds(kinds) do
    {:error,
     Error.validation("memory query kinds must be a list",
       source: __MODULE__,
       details: %{kinds: kinds}
     )}
  end

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit(limit) do
    {:error,
     Error.validation("memory query limit must be a positive integer",
       source: __MODULE__,
       details: %{limit: limit}
     )}
  end

  defp validate_predicate(nil), do: :ok
  defp validate_predicate(predicate) when is_function(predicate, 1), do: :ok

  defp validate_predicate(predicate) do
    {:error,
     Error.validation("memory query predicate must be a 1-arity function or nil",
       source: __MODULE__,
       details: %{predicate: predicate}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("memory query metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
