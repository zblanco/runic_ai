defmodule RunicSandbox.Checkpoint do
  @moduledoc """
  Provider-neutral checkpoint identity for a sandbox session.
  """

  alias RunicSandbox.Error

  @enforce_keys [:id, :session_id, :backend, :ref, :created_at, :metadata]
  defstruct id: nil, session_id: nil, backend: nil, ref: nil, created_at: nil, metadata: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          backend: atom(),
          ref: String.t(),
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = checkpoint), do: validate(checkpoint)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    %__MODULE__{
      id: get(input, :id, nil),
      session_id: get(input, :session_id, nil),
      backend: get(input, :backend, nil),
      ref: get(input, :ref, nil),
      created_at: get(input, :created_at, nil),
      metadata: get(input, :metadata, %{})
    }
    |> validate()
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, checkpoint} -> checkpoint
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = checkpoint) do
    with :ok <- validate_string(checkpoint.id, :id),
         :ok <- validate_string(checkpoint.session_id, :session_id),
         :ok <- validate_atom(checkpoint.backend, :backend),
         :ok <- validate_string(checkpoint.ref, :ref),
         :ok <- validate_optional_datetime(checkpoint.created_at, :created_at),
         :ok <- validate_map(checkpoint.metadata, :metadata) do
      {:ok, checkpoint}
    end
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value) and not is_nil(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_datetime(nil, _field), do: :ok
  defp validate_optional_datetime(%DateTime{}, _field), do: :ok

  defp validate_optional_datetime(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be a DateTime",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox checkpoint #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
