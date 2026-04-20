defmodule RunicAI.Context.Ref do
  @moduledoc """
  Stable pointer to a context node or source artifact.
  """

  alias RunicAI.Error

  @valid_kinds [:message, :summary, :memory, :retrieval, :observation, :handoff, :artifact]

  @enforce_keys [:kind, :target_id]
  defstruct [:kind, :target_id, :label, provenance: [], metadata: %{}]

  @type kind :: :message | :summary | :memory | :retrieval | :observation | :handoff | :artifact

  @type t :: %__MODULE__{
          kind: kind(),
          target_id: String.t(),
          label: String.t() | nil,
          provenance: [t() | String.t()],
          metadata: map()
        }

  @spec new(kind(), String.t() | integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, target_id, opts \\ []) when is_list(opts) do
    label = Keyword.get(opts, :label)
    provenance = Keyword.get(opts, :provenance, [])
    metadata = Keyword.get(opts, :metadata, %{})
    target_id = normalize_target_id(target_id)

    with :ok <- validate_kind(kind),
         :ok <- validate_target_id(target_id),
         :ok <- validate_label(label),
         :ok <- validate_provenance(provenance),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: kind,
         target_id: target_id,
         label: label,
         provenance: provenance,
         metadata: metadata
       }}
    end
  end

  @spec new!(kind(), String.t() | integer(), keyword()) :: t()
  def new!(kind, target_id, opts \\ []) do
    case new(kind, target_id, opts) do
      {:ok, ref} -> ref
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = ref) do
    new(ref.kind, ref.target_id,
      label: ref.label,
      provenance: ref.provenance,
      metadata: ref.metadata
    )
  end

  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = ref), do: "#{ref.kind}:#{ref.target_id}"

  @spec same_target?(t(), t()) :: boolean()
  def same_target?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left.kind == right.kind and left.target_id == right.target_id
  end

  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @valid_kinds

  defp normalize_target_id(target_id) when is_integer(target_id), do: Integer.to_string(target_id)
  defp normalize_target_id(target_id) when is_binary(target_id), do: target_id
  defp normalize_target_id(target_id), do: to_string(target_id)

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid context ref kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_target_id(target_id) when is_binary(target_id) and target_id != "", do: :ok

  defp validate_target_id(target_id) do
    {:error,
     Error.validation("context ref target_id must be a non-empty string",
       source: __MODULE__,
       details: %{target_id: target_id}
     )}
  end

  defp validate_label(nil), do: :ok
  defp validate_label(label) when is_binary(label), do: :ok

  defp validate_label(label) do
    {:error,
     Error.validation("context ref label must be a string or nil",
       source: __MODULE__,
       details: %{label: label}
     )}
  end

  defp validate_provenance(provenance) when is_list(provenance), do: :ok

  defp validate_provenance(provenance) do
    {:error,
     Error.validation("context ref provenance must be a list",
       source: __MODULE__,
       details: %{provenance: provenance}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context ref metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
