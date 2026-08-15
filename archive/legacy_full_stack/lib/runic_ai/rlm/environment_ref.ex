defmodule RunicAI.RLM.EnvironmentRef do
  @moduledoc """
  Stable reference to a source stored in an RLM environment.
  """

  alias RunicAI.Error

  @enforce_keys [:environment, :source_id]
  defstruct [:environment, :source_id, :label, metadata: %{}]

  @type t :: %__MODULE__{
          environment: module(),
          source_id: String.t(),
          label: String.t() | nil,
          metadata: map()
        }

  @spec new(module(), String.t() | integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(environment, source_id, opts \\ []) when is_atom(environment) and is_list(opts) do
    source_id = normalize_source_id(source_id)
    label = Keyword.get(opts, :label)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_source_id(source_id),
         :ok <- validate_label(label),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         environment: environment,
         source_id: source_id,
         label: label,
         metadata: metadata
       }}
    end
  end

  @spec new!(module(), String.t() | integer(), keyword()) :: t()
  def new!(environment, source_id, opts \\ []) do
    case new(environment, source_id, opts) do
      {:ok, ref} -> ref
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = ref) do
    new(ref.environment, ref.source_id, label: ref.label, metadata: ref.metadata)
  end

  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = ref), do: "#{inspect(ref.environment)}:#{ref.source_id}"

  defp normalize_source_id(source_id) when is_integer(source_id), do: Integer.to_string(source_id)
  defp normalize_source_id(source_id) when is_binary(source_id), do: source_id
  defp normalize_source_id(source_id), do: to_string(source_id)

  defp validate_source_id(source_id) when is_binary(source_id) and source_id != "", do: :ok

  defp validate_source_id(source_id) do
    {:error,
     Error.validation("environment source_id must be a non-empty string",
       source: __MODULE__,
       details: %{source_id: source_id}
     )}
  end

  defp validate_label(nil), do: :ok
  defp validate_label(label) when is_binary(label), do: :ok

  defp validate_label(label) do
    {:error,
     Error.validation("environment ref label must be a string or nil",
       source: __MODULE__,
       details: %{label: label}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("environment ref metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
