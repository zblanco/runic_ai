defmodule RunicAI.Control.BudgetPolicy do
  @moduledoc """
  Declarative resource limits for one guarded workflow run.
  """

  alias RunicAI.Error

  @valid_on_exhaustion [:halt, :review, :wait]

  @enforce_keys [:on_exhaustion, :metadata]
  defstruct [
    :max_turns,
    :max_model_calls,
    :max_tool_calls,
    :max_elapsed_ms,
    :max_estimated_cost,
    :max_recursion_depth,
    :on_exhaustion,
    :metadata
  ]

  @type t :: %__MODULE__{
          max_turns: non_neg_integer() | nil,
          max_model_calls: non_neg_integer() | nil,
          max_tool_calls: non_neg_integer() | nil,
          max_elapsed_ms: non_neg_integer() | nil,
          max_estimated_cost: number() | nil,
          max_recursion_depth: non_neg_integer() | nil,
          on_exhaustion: :halt | :review | :wait,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    on_exhaustion = Keyword.get(opts, :on_exhaustion, :halt)

    with :ok <- validate_optional_count(Keyword.get(opts, :max_turns), :max_turns),
         :ok <- validate_optional_count(Keyword.get(opts, :max_model_calls), :max_model_calls),
         :ok <- validate_optional_count(Keyword.get(opts, :max_tool_calls), :max_tool_calls),
         :ok <- validate_optional_count(Keyword.get(opts, :max_elapsed_ms), :max_elapsed_ms),
         :ok <-
           validate_optional_number(Keyword.get(opts, :max_estimated_cost), :max_estimated_cost),
         :ok <-
           validate_optional_count(Keyword.get(opts, :max_recursion_depth), :max_recursion_depth),
         :ok <- validate_on_exhaustion(on_exhaustion),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         max_turns: Keyword.get(opts, :max_turns),
         max_model_calls: Keyword.get(opts, :max_model_calls),
         max_tool_calls: Keyword.get(opts, :max_tool_calls),
         max_elapsed_ms: Keyword.get(opts, :max_elapsed_ms),
         max_estimated_cost: Keyword.get(opts, :max_estimated_cost),
         max_recursion_depth: Keyword.get(opts, :max_recursion_depth),
         on_exhaustion: on_exhaustion,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, budget_policy} -> budget_policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t() | nil} | {:error, Error.t()}
  def from_input(nil), do: {:ok, nil}
  def from_input(%__MODULE__{} = budget_policy), do: validate(budget_policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      max_turns: Map.get(input, :max_turns),
      max_model_calls: Map.get(input, :max_model_calls),
      max_tool_calls: Map.get(input, :max_tool_calls),
      max_elapsed_ms: Map.get(input, :max_elapsed_ms),
      max_estimated_cost: Map.get(input, :max_estimated_cost),
      max_recursion_depth: Map.get(input, :max_recursion_depth),
      on_exhaustion: Map.get(input, :on_exhaustion, :halt),
      metadata: Map.get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Control.BudgetPolicy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword() | map() | nil) :: t() | nil
  def from_input!(input) do
    case from_input(input) do
      {:ok, budget_policy} -> budget_policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = budget_policy) do
    new(
      max_turns: budget_policy.max_turns,
      max_model_calls: budget_policy.max_model_calls,
      max_tool_calls: budget_policy.max_tool_calls,
      max_elapsed_ms: budget_policy.max_elapsed_ms,
      max_estimated_cost: budget_policy.max_estimated_cost,
      max_recursion_depth: budget_policy.max_recursion_depth,
      on_exhaustion: budget_policy.on_exhaustion,
      metadata: budget_policy.metadata
    )
  end

  defp validate_optional_count(nil, _field), do: :ok
  defp validate_optional_count(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_optional_count(value, field) do
    {:error,
     Error.validation("#{field} must be a non-negative integer or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_number(nil, _field), do: :ok
  defp validate_optional_number(value, _field) when is_integer(value) or is_float(value), do: :ok

  defp validate_optional_number(value, field) do
    {:error,
     Error.validation("#{field} must be a number or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_on_exhaustion(on_exhaustion) when on_exhaustion in @valid_on_exhaustion, do: :ok

  defp validate_on_exhaustion(on_exhaustion) do
    {:error,
     Error.validation("invalid on_exhaustion action: #{inspect(on_exhaustion)}",
       source: __MODULE__,
       details: %{on_exhaustion: on_exhaustion, valid_actions: @valid_on_exhaustion}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("budget policy metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
