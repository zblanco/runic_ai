defmodule RunicAI.Integrated.Emission do
  @moduledoc """
  Identity-carrying envelope for externally visible integrated runtime outputs.
  """

  alias RunicAI.Error

  @valid_kinds [:reply, :final, :review, :wait, :handoff, :status]

  @enforce_keys [:agent_id, :kind, :metadata]
  defstruct [:agent_id, :kind, :value, metadata: %{}]

  @type kind :: :reply | :final | :review | :wait | :handoff | :status

  @type t :: %__MODULE__{
          agent_id: String.t(),
          kind: kind(),
          value: term(),
          metadata: map()
        }

  @spec new(String.t() | atom(), kind() | String.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(agent_id, kind, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_agent_id} <- normalize_agent_id(agent_id),
         {:ok, normalized_kind} <- normalize_kind(kind),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         agent_id: normalized_agent_id,
         kind: normalized_kind,
         value: Keyword.get(opts, :value),
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t() | atom(), kind() | String.t(), keyword()) :: t()
  def new!(agent_id, kind, opts \\ []) do
    case new(agent_id, kind, opts) do
      {:ok, emission} -> emission
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = emission) do
    new(emission.agent_id, emission.kind, value: emission.value, metadata: emission.metadata)
  end

  defp normalize_agent_id(agent_id) when is_binary(agent_id) and agent_id != "",
    do: {:ok, agent_id}

  defp normalize_agent_id(agent_id) when is_atom(agent_id), do: {:ok, Atom.to_string(agent_id)}

  defp normalize_agent_id(agent_id) do
    {:error,
     Error.validation("integrated emission agent_id must be a non-empty string or atom",
       source: __MODULE__,
       details: %{agent_id: agent_id}
     )}
  end

  defp normalize_kind(kind) when kind in @valid_kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    case Enum.find(@valid_kinds, &(Atom.to_string(&1) == kind)) do
      nil ->
        {:error,
         Error.validation("invalid integrated emission kind: #{inspect(kind)}",
           source: __MODULE__,
           details: %{kind: kind, valid_kinds: @valid_kinds}
         )}

      normalized_kind ->
        {:ok, normalized_kind}
    end
  end

  defp normalize_kind(kind) do
    {:error,
     Error.validation("invalid integrated emission kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("integrated emission metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
