defmodule RunicAI.Integrated.AgentRef do
  @moduledoc """
  Durable identity and profile reference for one workflow-owned agent lane.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :metadata]
  defstruct [:id, :role, :parent_id, :conversation_id, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          role: term(),
          parent_id: String.t() | nil,
          conversation_id: String.t() | nil,
          metadata: map()
        }

  @spec new(String.t() | atom(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, opts \\ []) when is_list(opts) do
    conversation_id = Keyword.get(opts, :conversation_id)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_id} <- normalize_id(id, :id),
         {:ok, parent_id} <- normalize_optional_id(Keyword.get(opts, :parent_id), :parent_id),
         :ok <- validate_conversation_id(conversation_id),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: normalized_id,
         role: Keyword.get(opts, :role),
         parent_id: parent_id,
         conversation_id: conversation_id,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t() | atom(), keyword()) :: t()
  def new!(id, opts \\ []) do
    case new(id, opts) do
      {:ok, agent_ref} -> agent_ref
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = agent_ref) do
    new(agent_ref.id,
      role: agent_ref.role,
      parent_id: agent_ref.parent_id,
      conversation_id: agent_ref.conversation_id,
      metadata: agent_ref.metadata
    )
  end

  @spec id(t()) :: String.t()
  def id(%__MODULE__{id: id}), do: id

  defp normalize_optional_id(nil, _field), do: {:ok, nil}
  defp normalize_optional_id(value, field), do: normalize_id(value, field)

  defp normalize_id(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_id(value, _field) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_id(value, field) do
    {:error,
     Error.validation("integrated agent #{field} must be a non-empty string or atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_conversation_id(nil), do: :ok
  defp validate_conversation_id(conversation_id) when is_binary(conversation_id), do: :ok

  defp validate_conversation_id(conversation_id) do
    {:error,
     Error.validation("integrated conversation_id must be a string or nil",
       source: __MODULE__,
       details: %{conversation_id: conversation_id}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("integrated agent metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
