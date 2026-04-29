defmodule RunicAI.Coding.RLM.RepairNeed do
  @moduledoc "Targeted continuation request created from failed verification."

  alias RunicAI.Error

  @enforce_keys [:id, :reason, :target, :evidence, :metadata]
  defstruct [:id, :reason, :target, evidence: [], metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          reason: String.t(),
          target: term(),
          evidence: [term()],
          metadata: map()
        }

  def new(reason, opts \\ []) when is_binary(reason) and is_list(opts) do
    value = %__MODULE__{
      id: Keyword.get(opts, :id) || "repair-need:#{System.unique_integer([:positive])}",
      reason: reason,
      target: Keyword.get(opts, :target),
      evidence: Keyword.get(opts, :evidence, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(value)
  end

  def new!(reason, opts \\ []) do
    case new(reason, opts) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def validate(%__MODULE__{} = value) do
    with :ok <- non_empty(value.id, :id),
         :ok <- non_empty(value.reason, :reason),
         :ok <- list(value.evidence, :evidence),
         :ok <- map(value.metadata, :metadata) do
      {:ok, value}
    end
  end

  defp non_empty(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty(value, field),
    do:
      {:error,
       Error.validation("repair need #{field} must be a non-empty string",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp list(value, _field) when is_list(value), do: :ok

  defp list(value, field),
    do:
      {:error,
       Error.validation("repair need #{field} must be a list",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field),
    do:
      {:error,
       Error.validation("repair need #{field} must be a map",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
end
