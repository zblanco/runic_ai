defmodule RunicAI.RLM.Components.BudgetLedger do
  @moduledoc """
  Runtime budget accounting for generated RLM workflows.

  The ledger is intentionally component-neutral. It records common quantities
  emitted by source, materialization, LLM map/reduce, and artifact components
  and turns budget overruns into structured validation errors.
  """

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Error

  @enforce_keys [:started_at_ms, :limits]
  @derive Jason.Encoder
  defstruct started_at_ms: nil,
            limits: %{},
            metrics: %{
              nodes_executed: 0,
              component_counts: %{},
              source_count: 0,
              slice_count: 0,
              materialized_count: 0,
              materialized_bytes: 0,
              llm_map_calls: 0,
              reduce_calls: 0,
              artifact_writes: 0,
              elapsed_ms: 0
            },
            over_budget?: false,
            violations: []

  @type t :: %__MODULE__{}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(budgets \\ %{}) do
    budgets = opts_map(budgets)

    {:ok,
     %__MODULE__{
       started_at_ms: System.monotonic_time(:millisecond),
       limits: normalize_limits(budgets)
     }}
  end

  @spec new!(map() | keyword()) :: t()
  def new!(budgets \\ %{}) do
    {:ok, ledger} = new(budgets)
    ledger
  end

  @spec run(map() | keyword(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, params \\ %{}) do
    ledger =
      input
      |> ledger_from_input(params)
      |> summary()

    {:ok, ledger}
  end

  @spec record(t() | map() | nil, ComponentBlueprint.t() | map(), term()) ::
          {:ok, t()} | {:error, Error.t()}
  def record(ledger, component, output) do
    ledger = normalize_ledger(ledger)
    type = component_type(component)
    metrics = ledger.metrics

    metrics =
      metrics
      |> update_in([:nodes_executed], &((&1 || 0) + 1))
      |> update_in([:component_counts], &increment_count(&1 || %{}, type))
      |> merge_component_metrics(type, output)
      |> Map.put(:elapsed_ms, System.monotonic_time(:millisecond) - ledger.started_at_ms)

    ledger = %{ledger | metrics: metrics}
    violations = violations(ledger)

    if violations == [] do
      {:ok, ledger}
    else
      {:error,
       Error.validation("assistant RLM workflow budget exceeded",
         source: __MODULE__,
         details: %{violations: violations, metrics: metrics, limits: ledger.limits}
       )}
    end
  end

  @spec summary(t() | map() | nil) :: map()
  def summary(ledger) do
    ledger = normalize_ledger(ledger)
    violations = violations(ledger)

    %{
      limits: ledger.limits,
      metrics: ledger.metrics,
      over_budget?: violations != [],
      violations: violations
    }
  end

  defp ledger_from_input(%__MODULE__{} = ledger, _params), do: ledger
  defp ledger_from_input(%{budget_ledger: ledger}, _params), do: normalize_ledger(ledger)
  defp ledger_from_input(%{"budget_ledger" => ledger}, _params), do: normalize_ledger(ledger)

  defp ledger_from_input(%{limits: _limits, metrics: _metrics} = ledger, _params),
    do: normalize_ledger(ledger)

  defp ledger_from_input(_input, params), do: new!(params)

  defp normalize_ledger(%__MODULE__{} = ledger), do: ledger

  defp normalize_ledger(%{limits: limits, metrics: metrics} = ledger) do
    %__MODULE__{
      started_at_ms:
        get(ledger, :started_at_ms, nil) || get(ledger, :started_at, nil) ||
          System.monotonic_time(:millisecond),
      limits: normalize_limits(limits || %{}),
      metrics: normalize_metrics(metrics || %{}),
      over_budget?: get(ledger, :over_budget?, false),
      violations: List.wrap(get(ledger, :violations, []))
    }
  end

  defp normalize_ledger(nil), do: new!(%{})

  defp normalize_ledger(other) when is_map(other) do
    normalize_ledger(%{
      limits: get(other, :limits, %{}),
      metrics: get(other, :metrics, other),
      started_at_ms: get(other, :started_at_ms, nil),
      over_budget?: get(other, :over_budget?, false),
      violations: get(other, :violations, [])
    })
  end

  defp normalize_ledger(_other), do: new!(%{})

  defp normalize_limits(limits) do
    limits
    |> opts_map()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case positive_integer(value) do
        nil -> acc
        integer -> Map.put(acc, normalize_key(key), integer)
      end
    end)
  end

  defp normalize_metrics(metrics) do
    default = new!().metrics

    metrics
    |> opts_map()
    |> Enum.reduce(default, fn {key, value}, acc ->
      key = normalize_key(key)

      cond do
        key == :component_counts and is_map(value) ->
          Map.put(acc, key, value)

        is_integer(value) ->
          Map.put(acc, key, value)

        true ->
          acc
      end
    end)
  end

  defp merge_component_metrics(metrics, :source_discovery, output) do
    Map.put(metrics, :source_count, max(metrics.source_count || 0, count(output)))
  end

  defp merge_component_metrics(metrics, :source_splitter, output) do
    metrics
    |> Map.put(:source_count, max(metrics.source_count || 0, source_count(output)))
    |> Map.put(:slice_count, max(metrics.slice_count || 0, count(output)))
  end

  defp merge_component_metrics(metrics, :source_materializer, output) do
    metrics
    |> Map.update!(:materialized_count, &(&1 + count(output)))
    |> Map.update!(:materialized_bytes, &(&1 + integer_field(output, :total_bytes)))
  end

  defp merge_component_metrics(metrics, :llm_map, output) do
    Map.update!(metrics, :llm_map_calls, &(&1 + count(output)))
  end

  defp merge_component_metrics(metrics, type, output)
       when type in [:llm_leaf, :blueprint_reduce] do
    calls = max(integer_field(output, :groups), 0) + if type == :llm_leaf, do: 1, else: 0
    Map.update!(metrics, :reduce_calls, &(&1 + max(calls, 1)))
  end

  defp merge_component_metrics(metrics, :artifact_writer, _output) do
    Map.update!(metrics, :artifact_writes, &(&1 + 1))
  end

  defp merge_component_metrics(metrics, _type, _output), do: metrics

  defp violations(%__MODULE__{} = ledger) do
    [
      limit_violation(ledger, :max_nodes, :nodes_executed),
      limit_violation(ledger, :max_source_count, :source_count),
      limit_violation(ledger, :max_sources, :source_count),
      limit_violation(ledger, :max_slice_count, :slice_count),
      limit_violation(ledger, :max_slices, :slice_count),
      limit_violation(ledger, :max_materialized_bytes, :materialized_bytes),
      limit_violation(ledger, :max_total_materialized_bytes, :materialized_bytes),
      limit_violation(ledger, :max_llm_map_calls, :llm_map_calls),
      limit_violation(ledger, :max_reduce_calls, :reduce_calls),
      total_llm_violation(ledger),
      limit_violation(ledger, :max_runtime_ms, :elapsed_ms)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp limit_violation(%__MODULE__{} = ledger, limit_key, metric_key) do
    limit = Map.get(ledger.limits, limit_key)
    actual = Map.get(ledger.metrics, metric_key, 0)

    if is_integer(limit) and actual > limit do
      %{limit: limit_key, metric: metric_key, actual: actual, allowed: limit}
    end
  end

  defp total_llm_violation(%__MODULE__{} = ledger) do
    limit = Map.get(ledger.limits, :max_llm_calls)
    actual = ledger.metrics.llm_map_calls + ledger.metrics.reduce_calls

    if is_integer(limit) and actual > limit do
      %{limit: :max_llm_calls, metric: :llm_calls, actual: actual, allowed: limit}
    end
  end

  defp increment_count(counts, type) do
    key = Atom.to_string(type)
    Map.update(counts, key, 1, &(&1 + 1))
  end

  defp component_type(%ComponentBlueprint{type: type}), do: type
  defp component_type(%{type: type}) when is_atom(type), do: type
  defp component_type(%{"type" => type}) when is_binary(type), do: normalize_key(type)
  defp component_type(_component), do: :unknown

  defp source_count(%{sources: sources}) when is_list(sources), do: length(sources)
  defp source_count(%{"sources" => sources}) when is_list(sources), do: length(sources)
  defp source_count(_output), do: 0

  defp count(output), do: integer_field(output, :count)

  defp integer_field(map, key) when is_map(map) do
    value = Map.get(map, key, Map.get(map, Atom.to_string(key), 0))
    if is_integer(value), do: value, else: 0
  end

  defp integer_field(_map, _key), do: 0

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case String.replace(key, "-", "_") do
      "artifact_writes" -> :artifact_writes
      "component_counts" -> :component_counts
      "elapsed_ms" -> :elapsed_ms
      "llm_map_calls" -> :llm_map_calls
      "materialized_bytes" -> :materialized_bytes
      "materialized_count" -> :materialized_count
      "max_llm_calls" -> :max_llm_calls
      "max_llm_map_calls" -> :max_llm_map_calls
      "max_materialized_bytes" -> :max_materialized_bytes
      "max_nodes" -> :max_nodes
      "max_reduce_calls" -> :max_reduce_calls
      "max_runtime_ms" -> :max_runtime_ms
      "max_slice_count" -> :max_slice_count
      "max_slices" -> :max_slices
      "max_source_count" -> :max_source_count
      "max_sources" -> :max_sources
      "max_total_materialized_bytes" -> :max_total_materialized_bytes
      "nodes_executed" -> :nodes_executed
      "reduce_calls" -> :reduce_calls
      "slice_count" -> :slice_count
      "source_count" -> :source_count
      other -> other
    end
  end

  defp normalize_key(key), do: key

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
