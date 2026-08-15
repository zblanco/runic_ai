defmodule RunicAI.Optimization.Suggestion do
  @moduledoc """
  Observational optimization output.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :kind, :summary, :details, :metadata]
  defstruct [:id, :kind, :summary, confidence: nil, details: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          summary: String.t(),
          confidence: float() | nil,
          details: map(),
          metadata: map()
        }

  @spec new(atom(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, summary, opts \\ [])
      when is_atom(kind) and is_binary(summary) and is_list(opts) do
    id = Keyword.get(opts, :id, "suggestion:#{System.unique_integer([:positive])}")
    details = Keyword.get(opts, :details, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_confidence(Keyword.get(opts, :confidence)),
         :ok <- validate_map(details, :details),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         summary: summary,
         confidence: Keyword.get(opts, :confidence),
         details: details,
         metadata: metadata
       }}
    end
  end

  @spec new!(atom(), String.t(), keyword()) :: t()
  def new!(kind, summary, opts \\ []) do
    case new(kind, summary, opts) do
      {:ok, suggestion} -> suggestion
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("optimization suggestion id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_confidence(nil), do: :ok
  defp validate_confidence(value) when is_float(value) and value >= 0.0 and value <= 1.0, do: :ok

  defp validate_confidence(value) do
    {:error,
     Error.validation("optimization suggestion confidence must be a float from 0.0 to 1.0",
       source: __MODULE__,
       details: %{confidence: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("optimization suggestion #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
