defmodule RunicAI.Memory.Entry do
  @moduledoc """
  Provenance-bearing memory item for episodic, semantic, or temporal recall.
  """

  alias RunicAI.Context.Ref
  alias RunicAI.Error

  @valid_kinds [:episodic, :semantic, :temporal]

  @enforce_keys [:id, :kind, :content, :refs, :salience, :metadata]
  defstruct [
    :id,
    :kind,
    :content,
    :summary,
    :valid_from,
    :valid_until,
    :salience,
    :refs,
    :metadata
  ]

  @type kind :: :episodic | :semantic | :temporal

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          content: String.t(),
          summary: String.t() | nil,
          refs: [Ref.t()],
          valid_from: DateTime.t() | nil,
          valid_until: DateTime.t() | nil,
          salience: number(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, "memory-#{System.unique_integer([:positive])}")
    kind = Keyword.get(opts, :kind, :episodic)
    content = Keyword.get(opts, :content, "")
    summary = Keyword.get(opts, :summary)
    refs = Keyword.get(opts, :refs, [])
    valid_from = Keyword.get(opts, :valid_from)
    valid_until = Keyword.get(opts, :valid_until)
    salience = Keyword.get(opts, :salience, 0.5)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_kind(kind),
         :ok <- validate_content(content),
         :ok <- validate_optional_string(:summary, summary),
         {:ok, refs} <- normalize_refs(refs),
         :ok <- validate_optional_datetime(:valid_from, valid_from),
         :ok <- validate_optional_datetime(:valid_until, valid_until),
         :ok <- validate_salience(salience),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         content: content,
         summary: summary,
         refs: refs,
         valid_from: valid_from,
         valid_until: valid_until,
         salience: salience,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, entry} -> entry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = entry) do
    new(
      id: entry.id,
      kind: entry.kind,
      content: entry.content,
      summary: entry.summary,
      refs: entry.refs,
      valid_from: entry.valid_from,
      valid_until: entry.valid_until,
      salience: entry.salience,
      metadata: entry.metadata
    )
  end

  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{} = entry, now \\ DateTime.utc_now()) do
    starts_ok? = is_nil(entry.valid_from) or DateTime.compare(entry.valid_from, now) in [:lt, :eq]
    ends_ok? = is_nil(entry.valid_until) or DateTime.compare(entry.valid_until, now) in [:gt, :eq]
    starts_ok? and ends_ok?
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("memory entry id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid memory entry kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_content(content) when is_binary(content) and content != "", do: :ok

  defp validate_content(content) do
    {:error,
     Error.validation("memory entry content must be a non-empty string",
       source: __MODULE__,
       details: %{content: content}
     )}
  end

  defp validate_optional_string(_field, nil), do: :ok
  defp validate_optional_string(_field, value) when is_binary(value), do: :ok

  defp validate_optional_string(field, value) do
    {:error,
     Error.validation("memory entry #{field} must be a string or nil",
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
     Error.validation("memory entry refs must be a list of Context.Ref structs",
       source: __MODULE__,
       details: %{refs: refs}
     )}
  end

  defp validate_optional_datetime(_field, nil), do: :ok
  defp validate_optional_datetime(_field, %DateTime{}), do: :ok

  defp validate_optional_datetime(field, value) do
    {:error,
     Error.validation("memory entry #{field} must be a DateTime or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_salience(salience) when is_number(salience), do: :ok

  defp validate_salience(salience) do
    {:error,
     Error.validation("memory entry salience must be numeric",
       source: __MODULE__,
       details: %{salience: salience}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("memory entry metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
