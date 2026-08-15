defmodule RunicAI.Coding.RLM.Risk do
  @moduledoc "Safety or blast-radius risk surfaced by an RLM coding workflow."

  alias RunicAI.Error

  @valid_levels [:low, :medium, :high, :critical]

  @enforce_keys [:id, :summary, :level, :mitigation, :metadata]
  defstruct [:id, :summary, :level, mitigation: nil, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          summary: String.t(),
          level: atom(),
          mitigation: String.t() | nil,
          metadata: map()
        }

  def new(summary, opts \\ []) when is_binary(summary) and is_list(opts) do
    value = %__MODULE__{
      id: Keyword.get(opts, :id) || "risk:#{System.unique_integer([:positive])}",
      summary: summary,
      level: normalize_level(Keyword.get(opts, :level, :medium)),
      mitigation: Keyword.get(opts, :mitigation),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(value)
  end

  def new!(summary, opts \\ []) do
    case new(summary, opts) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def validate(%__MODULE__{} = value) do
    with :ok <- non_empty(value.id, :id),
         :ok <- non_empty(value.summary, :summary),
         :ok <- level(value.level),
         :ok <- optional_string(value.mitigation, :mitigation),
         :ok <- map(value.metadata, :metadata) do
      {:ok, value}
    end
  end

  defp normalize_level(value) when value in @valid_levels, do: value
  defp normalize_level("low"), do: :low
  defp normalize_level("medium"), do: :medium
  defp normalize_level("high"), do: :high
  defp normalize_level("critical"), do: :critical
  defp normalize_level(value), do: value

  defp non_empty(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty(value, field),
    do:
      {:error,
       Error.validation("risk #{field} must be a non-empty string",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp level(value) when value in @valid_levels, do: :ok

  defp level(value),
    do:
      {:error,
       Error.validation("invalid risk level", source: __MODULE__, details: %{level: value})}

  defp optional_string(nil, _field), do: :ok
  defp optional_string(value, _field) when is_binary(value), do: :ok

  defp optional_string(value, field),
    do:
      {:error,
       Error.validation("risk #{field} must be a string or nil",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field),
    do:
      {:error,
       Error.validation("risk #{field} must be a map",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
end
