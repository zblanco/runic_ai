defmodule RunicAI.Evaluation.Metric do
  @moduledoc """
  Running evaluation metric definition with an accumulator-oriented update path.
  """

  alias RunicAI.Error
  alias RunicAI.Evaluation.Result

  @valid_kinds [:quality, :latency, :cost, :safety, :custom]

  @enforce_keys [:name, :kind, :initial, :extractor, :accumulator, :finalizer, :metadata]
  defstruct [:name, :kind, :initial, :extractor, :accumulator, :finalizer, :metadata]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          kind: atom(),
          initial: term(),
          extractor: (Result.t() -> term()),
          accumulator: (term(), term() -> term()),
          finalizer: (term() -> term()),
          metadata: map()
        }

  @spec new(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(name, opts) when is_list(opts) do
    kind = Keyword.get(opts, :kind, :custom)
    metadata = Keyword.get(opts, :metadata, %{})
    extractor = Keyword.get(opts, :extractor)
    accumulator = Keyword.get(opts, :accumulator)
    finalizer = Keyword.get(opts, :finalizer, & &1)

    with :ok <- validate_name(name),
         :ok <- validate_kind(kind),
         :ok <- validate_extractor(extractor),
         :ok <- validate_accumulator(accumulator),
         :ok <- validate_finalizer(finalizer),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         name: name,
         kind: kind,
         initial: Keyword.get(opts, :initial),
         extractor: extractor,
         accumulator: accumulator,
         finalizer: finalizer,
         metadata: metadata
       }}
    end
  end

  @spec new!(atom() | String.t(), keyword()) :: t()
  def new!(name, opts) do
    case new(name, opts) do
      {:ok, metric} -> metric
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec count(atom() | String.t(), (Result.t() -> term()), keyword()) :: t()
  def count(name, extractor, opts \\ []) when is_function(extractor, 1) do
    new!(
      name,
      Keyword.merge(
        [
          kind: Keyword.get(opts, :kind, :custom),
          initial: 0,
          extractor: extractor,
          accumulator: fn value, state -> state + if(value, do: 1, else: 0) end,
          finalizer: & &1,
          metadata: Keyword.get(opts, :metadata, %{})
        ],
        []
      )
    )
  end

  @spec sum(atom() | String.t(), (Result.t() -> number()), keyword()) :: t()
  def sum(name, extractor, opts \\ []) when is_function(extractor, 1) do
    new!(
      name,
      kind: Keyword.get(opts, :kind, :custom),
      initial: 0,
      extractor: extractor,
      accumulator: fn value, state -> state + normalize_number(value) end,
      finalizer: & &1,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec average(atom() | String.t(), (Result.t() -> number() | nil), keyword()) :: t()
  def average(name, extractor, opts \\ []) when is_function(extractor, 1) do
    new!(
      name,
      kind: Keyword.get(opts, :kind, :custom),
      initial: %{sum: 0.0, count: 0, average: nil},
      extractor: extractor,
      accumulator: fn value, state ->
        number = normalize_number(value)
        count = state.count + if(is_number(value), do: 1, else: 0)
        sum = state.sum + number

        %{sum: sum, count: count, average: if(count > 0, do: sum / count, else: nil)}
      end,
      finalizer: fn state -> state.average end,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec defaults() :: [t()]
  def defaults do
    [
      count(:cases_passed, &(&1.status == :passed), kind: :quality),
      count(:cases_failed, &(&1.status in [:failed, :error]), kind: :quality),
      average(:overall_score, &Map.get(&1.scores, :overall), kind: :quality),
      average(:latency_ms, &Map.get(&1.metrics, :elapsed_ms), kind: :latency),
      sum(:llm_calls, &Map.get(&1.metrics, :llm_calls, 0), kind: :cost),
      sum(:tool_calls, &Map.get(&1.metrics, :tool_calls, 0), kind: :cost),
      sum(:total_tokens, &Map.get(&1.metrics, :total_tokens, 0), kind: :cost)
    ]
  end

  @spec init_all([t()]) :: map()
  def init_all(metrics) when is_list(metrics) do
    Map.new(metrics, fn metric -> {metric.name, metric.initial} end)
  end

  @spec accumulate(t(), map(), Result.t()) :: map()
  def accumulate(%__MODULE__{} = metric, aggregate, %Result{} = result) when is_map(aggregate) do
    current_state = Map.get(aggregate, metric.name, metric.initial)
    next_state = metric.accumulator.(metric.extractor.(result), current_state)
    Map.put(aggregate, metric.name, next_state)
  end

  @spec accumulate_all([t()], map(), Result.t()) :: map()
  def accumulate_all(metrics, aggregate, %Result{} = result)
      when is_list(metrics) and is_map(aggregate) do
    Enum.reduce(metrics, aggregate, fn metric, acc -> accumulate(metric, acc, result) end)
  end

  @spec finalize_all([t()], map()) :: map()
  def finalize_all(metrics, aggregate) when is_list(metrics) and is_map(aggregate) do
    Map.new(metrics, fn metric ->
      {metric.name, metric.finalizer.(Map.get(aggregate, metric.name, metric.initial))}
    end)
  end

  defp validate_name(name) when is_atom(name) or (is_binary(name) and name != ""), do: :ok

  defp validate_name(name) do
    {:error,
     Error.validation("evaluation metric name must be an atom or non-empty string",
       source: __MODULE__,
       details: %{name: name}
     )}
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid evaluation metric kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_extractor(extractor) when is_function(extractor, 1), do: :ok

  defp validate_extractor(extractor) do
    {:error,
     Error.validation("evaluation metric extractor must be a 1-arity function",
       source: __MODULE__,
       details: %{extractor: extractor}
     )}
  end

  defp validate_accumulator(accumulator) when is_function(accumulator, 2), do: :ok

  defp validate_accumulator(accumulator) do
    {:error,
     Error.validation("evaluation metric accumulator must be a 2-arity function",
       source: __MODULE__,
       details: %{accumulator: accumulator}
     )}
  end

  defp validate_finalizer(finalizer) when is_function(finalizer, 1), do: :ok

  defp validate_finalizer(finalizer) do
    {:error,
     Error.validation("evaluation metric finalizer must be a 1-arity function",
       source: __MODULE__,
       details: %{finalizer: finalizer}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("evaluation metric metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp normalize_number(value) when is_number(value), do: value * 1.0
  defp normalize_number(_value), do: 0.0
end
