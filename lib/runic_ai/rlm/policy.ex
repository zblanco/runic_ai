defmodule RunicAI.RLM.Policy do
  @moduledoc """
  Bounds and execution preferences for an RLM run.
  """

  alias RunicAI.Error

  @enforce_keys [:metadata]
  defstruct leaf_window: 4_000,
            max_depth: 1,
            max_branching_factor: nil,
            max_leaf_calls: nil,
            max_reduce_calls: nil,
            max_environment_reads: nil,
            max_child_workflows: nil,
            max_plan_patches: nil,
            max_estimated_tokens: nil,
            max_estimated_cost: nil,
            accuracy_target: nil,
            allowed_combinators: nil,
            concurrency: nil,
            review_policy: nil,
            cache_policy: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          leaf_window: pos_integer(),
          max_depth: non_neg_integer(),
          max_branching_factor: non_neg_integer() | nil,
          max_leaf_calls: non_neg_integer() | nil,
          max_reduce_calls: non_neg_integer() | nil,
          max_environment_reads: non_neg_integer() | nil,
          max_child_workflows: non_neg_integer() | nil,
          max_plan_patches: non_neg_integer() | nil,
          max_estimated_tokens: non_neg_integer() | nil,
          max_estimated_cost: number() | nil,
          accuracy_target: number() | nil,
          allowed_combinators: [atom()] | nil,
          concurrency: pos_integer() | nil,
          review_policy: term(),
          cache_policy: term(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    policy = %__MODULE__{
      leaf_window: Keyword.get(opts, :leaf_window, 4_000),
      max_depth: Keyword.get(opts, :max_depth, 1),
      max_branching_factor: Keyword.get(opts, :max_branching_factor),
      max_leaf_calls: Keyword.get(opts, :max_leaf_calls),
      max_reduce_calls: Keyword.get(opts, :max_reduce_calls),
      max_environment_reads: Keyword.get(opts, :max_environment_reads),
      max_child_workflows: Keyword.get(opts, :max_child_workflows),
      max_plan_patches: Keyword.get(opts, :max_plan_patches),
      max_estimated_tokens: Keyword.get(opts, :max_estimated_tokens),
      max_estimated_cost: Keyword.get(opts, :max_estimated_cost),
      accuracy_target: Keyword.get(opts, :accuracy_target),
      allowed_combinators: Keyword.get(opts, :allowed_combinators),
      concurrency: Keyword.get(opts, :concurrency),
      review_policy: Keyword.get(opts, :review_policy),
      cache_policy: Keyword.get(opts, :cache_policy),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(policy)
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      leaf_window: map_get(input, :leaf_window) || 4_000,
      max_depth: map_get(input, :max_depth) || 1,
      max_branching_factor: map_get(input, :max_branching_factor),
      max_leaf_calls: map_get(input, :max_leaf_calls),
      max_reduce_calls: map_get(input, :max_reduce_calls),
      max_environment_reads: map_get(input, :max_environment_reads),
      max_child_workflows: map_get(input, :max_child_workflows),
      max_plan_patches: map_get(input, :max_plan_patches),
      max_estimated_tokens: map_get(input, :max_estimated_tokens),
      max_estimated_cost: map_get(input, :max_estimated_cost),
      accuracy_target: map_get(input, :accuracy_target),
      allowed_combinators: map_get(input, :allowed_combinators),
      concurrency: map_get(input, :concurrency),
      review_policy: map_get(input, :review_policy),
      cache_policy: map_get(input, :cache_policy),
      metadata: map_get(input, :metadata) || %{}
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected an RLM Policy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    with :ok <- validate_positive_count(policy.leaf_window, :leaf_window),
         :ok <- validate_count(policy.max_depth, :max_depth),
         :ok <- validate_optional_count(policy.max_branching_factor, :max_branching_factor),
         :ok <- validate_optional_count(policy.max_leaf_calls, :max_leaf_calls),
         :ok <- validate_optional_count(policy.max_reduce_calls, :max_reduce_calls),
         :ok <- validate_optional_count(policy.max_environment_reads, :max_environment_reads),
         :ok <- validate_optional_count(policy.max_child_workflows, :max_child_workflows),
         :ok <- validate_optional_count(policy.max_plan_patches, :max_plan_patches),
         :ok <- validate_optional_count(policy.max_estimated_tokens, :max_estimated_tokens),
         :ok <- validate_optional_number(policy.max_estimated_cost, :max_estimated_cost),
         :ok <- validate_optional_number(policy.accuracy_target, :accuracy_target),
         :ok <- validate_allowed_combinators(policy.allowed_combinators),
         :ok <- validate_optional_positive_count(policy.concurrency, :concurrency),
         :ok <- validate_metadata(policy.metadata) do
      {:ok, policy}
    end
  end

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp validate_count(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_count(value, field) do
    {:error,
     Error.validation("#{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_positive_count(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_count(value, field) do
    {:error,
     Error.validation("#{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_count(nil, _field), do: :ok
  defp validate_optional_count(value, field), do: validate_count(value, field)

  defp validate_optional_positive_count(nil, _field), do: :ok
  defp validate_optional_positive_count(value, field), do: validate_positive_count(value, field)

  defp validate_optional_number(nil, _field), do: :ok
  defp validate_optional_number(value, _field) when is_integer(value) or is_float(value), do: :ok

  defp validate_optional_number(value, field) do
    {:error,
     Error.validation("#{field} must be a number or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_allowed_combinators(nil), do: :ok
  defp validate_allowed_combinators(combinators) when is_list(combinators), do: :ok

  defp validate_allowed_combinators(combinators) do
    {:error,
     Error.validation("allowed_combinators must be a list or nil",
       source: __MODULE__,
       details: %{allowed_combinators: combinators}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("RLM policy metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
