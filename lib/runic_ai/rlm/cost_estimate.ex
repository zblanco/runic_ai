defmodule RunicAI.RLM.CostEstimate do
  @moduledoc """
  Visible estimate of the work an RLM plan is expected to perform.
  """

  alias RunicAI.Error

  @enforce_keys [:assumptions, :metadata]
  defstruct leaf_calls: 0,
            reducer_calls: 0,
            filter_calls: 0,
            environment_reads: 0,
            child_workflows: 0,
            plan_patches: 0,
            input_tokens: 0,
            output_tokens: 0,
            latency_class: :unknown,
            monetary_cost: nil,
            confidence: nil,
            assumptions: [],
            metadata: %{}

  @type t :: %__MODULE__{
          leaf_calls: non_neg_integer(),
          reducer_calls: non_neg_integer(),
          filter_calls: non_neg_integer(),
          environment_reads: non_neg_integer(),
          child_workflows: non_neg_integer(),
          plan_patches: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          latency_class: atom(),
          monetary_cost: number() | nil,
          confidence: number() | nil,
          assumptions: [String.t()],
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    estimate = %__MODULE__{
      leaf_calls: Keyword.get(opts, :leaf_calls, 0),
      reducer_calls: Keyword.get(opts, :reducer_calls, 0),
      filter_calls: Keyword.get(opts, :filter_calls, 0),
      environment_reads: Keyword.get(opts, :environment_reads, 0),
      child_workflows: Keyword.get(opts, :child_workflows, 0),
      plan_patches: Keyword.get(opts, :plan_patches, 0),
      input_tokens: Keyword.get(opts, :input_tokens, 0),
      output_tokens: Keyword.get(opts, :output_tokens, 0),
      latency_class: Keyword.get(opts, :latency_class, :unknown),
      monetary_cost: Keyword.get(opts, :monetary_cost),
      confidence: Keyword.get(opts, :confidence),
      assumptions: Keyword.get(opts, :assumptions, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(estimate)
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, estimate} -> estimate
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = estimate), do: validate(estimate)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      leaf_calls: map_get(input, :leaf_calls) || 0,
      reducer_calls: map_get(input, :reducer_calls) || 0,
      filter_calls: map_get(input, :filter_calls) || 0,
      environment_reads: map_get(input, :environment_reads) || 0,
      child_workflows: map_get(input, :child_workflows) || 0,
      plan_patches: map_get(input, :plan_patches) || 0,
      input_tokens: map_get(input, :input_tokens) || 0,
      output_tokens: map_get(input, :output_tokens) || 0,
      latency_class: map_get(input, :latency_class) || :unknown,
      monetary_cost: map_get(input, :monetary_cost),
      confidence: map_get(input, :confidence),
      assumptions: map_get(input, :assumptions) || [],
      metadata: map_get(input, :metadata) || %{}
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected an RLM CostEstimate-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = estimate) do
    with :ok <- validate_count(estimate.leaf_calls, :leaf_calls),
         :ok <- validate_count(estimate.reducer_calls, :reducer_calls),
         :ok <- validate_count(estimate.filter_calls, :filter_calls),
         :ok <- validate_count(estimate.environment_reads, :environment_reads),
         :ok <- validate_count(estimate.child_workflows, :child_workflows),
         :ok <- validate_count(estimate.plan_patches, :plan_patches),
         :ok <- validate_count(estimate.input_tokens, :input_tokens),
         :ok <- validate_count(estimate.output_tokens, :output_tokens),
         :ok <- validate_optional_number(estimate.monetary_cost, :monetary_cost),
         :ok <- validate_optional_number(estimate.confidence, :confidence),
         :ok <- validate_assumptions(estimate.assumptions),
         :ok <- validate_metadata(estimate.metadata) do
      {:ok, estimate}
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

  defp validate_optional_number(nil, _field), do: :ok
  defp validate_optional_number(value, _field) when is_integer(value) or is_float(value), do: :ok

  defp validate_optional_number(value, field) do
    {:error,
     Error.validation("#{field} must be a number or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_assumptions(assumptions) when is_list(assumptions), do: :ok

  defp validate_assumptions(assumptions) do
    {:error,
     Error.validation("cost estimate assumptions must be a list",
       source: __MODULE__,
       details: %{assumptions: assumptions}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("cost estimate metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
