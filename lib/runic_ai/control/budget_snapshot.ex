defmodule RunicAI.Control.BudgetSnapshot do
  @moduledoc """
  Observed usage values evaluated against a budget policy.
  """

  alias RunicAI.Error

  @enforce_keys [
    :turns,
    :model_calls,
    :tool_calls,
    :elapsed_ms,
    :estimated_cost,
    :recursion_depth,
    :metadata
  ]
  defstruct [
    :turns,
    :model_calls,
    :tool_calls,
    :elapsed_ms,
    :estimated_cost,
    :recursion_depth,
    :metadata
  ]

  @type t :: %__MODULE__{
          turns: non_neg_integer(),
          model_calls: non_neg_integer(),
          tool_calls: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          estimated_cost: number(),
          recursion_depth: non_neg_integer(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_count(Keyword.get(opts, :turns, 0), :turns),
         :ok <- validate_count(Keyword.get(opts, :model_calls, 0), :model_calls),
         :ok <- validate_count(Keyword.get(opts, :tool_calls, 0), :tool_calls),
         :ok <- validate_count(Keyword.get(opts, :elapsed_ms, 0), :elapsed_ms),
         :ok <- validate_number(Keyword.get(opts, :estimated_cost, 0.0), :estimated_cost),
         :ok <- validate_count(Keyword.get(opts, :recursion_depth, 0), :recursion_depth),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         turns: Keyword.get(opts, :turns, 0),
         model_calls: Keyword.get(opts, :model_calls, 0),
         tool_calls: Keyword.get(opts, :tool_calls, 0),
         elapsed_ms: Keyword.get(opts, :elapsed_ms, 0),
         estimated_cost: Keyword.get(opts, :estimated_cost, 0.0),
         recursion_depth: Keyword.get(opts, :recursion_depth, 0),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, budget_snapshot} -> budget_snapshot
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = budget_snapshot) do
    new(
      turns: budget_snapshot.turns,
      model_calls: budget_snapshot.model_calls,
      tool_calls: budget_snapshot.tool_calls,
      elapsed_ms: budget_snapshot.elapsed_ms,
      estimated_cost: budget_snapshot.estimated_cost,
      recursion_depth: budget_snapshot.recursion_depth,
      metadata: budget_snapshot.metadata
    )
  end

  defp validate_count(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_count(value, field) do
    {:error,
     Error.validation("#{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_number(value, _field) when is_integer(value) or is_float(value), do: :ok

  defp validate_number(value, field) do
    {:error,
     Error.validation("#{field} must be a number",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("budget snapshot metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
