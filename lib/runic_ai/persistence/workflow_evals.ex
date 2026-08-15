defmodule RunicAI.Persistence.WorkflowEvals do
  @moduledoc """
  Durable eval rows and GEPA-style textual-module candidates with Pareto selection.
  """

  import Ecto.Query

  alias RunicAI.Persistence.JSON
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.Schemas.WorkflowEvalRecord
  alias RunicAI.Persistence.Schemas.WorkflowOptimizationCandidate

  @default_dimensions [
    {:verified_success_rate, :max},
    {:human_comprehension, :max},
    {:output_tokens, :min},
    {:latency_ms, :min},
    {:cost_usd, :min},
    {:unsafe_effect_rate, :min}
  ]

  @spec record_case(Store.t(), map(), keyword()) ::
          {:ok, [WorkflowEvalRecord.t()]} | {:error, term()}
  def record_case(%Store{} = store, %{case_id: case_id, rows: rows}, opts \\ []) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          Enum.map(rows, fn row ->
            %WorkflowEvalRecord{}
            |> WorkflowEvalRecord.changeset(%{
              suite: Keyword.get(opts, :suite, "workflow_substrate_v1"),
              case_id: case_id,
              task_family: Keyword.get(opts, :task_family),
              arm: row.arm,
              model: Keyword.get(opts, :model),
              status: row.status,
              candidate_id: Keyword.get(opts, :candidate_id),
              metrics_json: JSON.safe(row.metrics),
              diagnostics_json: JSON.safe(row.diagnostics),
              artifacts_json: JSON.safe(row.artifacts),
              inserted_at: DateTime.utc_now()
            })
            |> store.repo.insert!()
          end)
        end)
      end)
    end)
    |> transaction_result()
  end

  @spec rows(Store.t(), String.t(), keyword()) :: [WorkflowEvalRecord.t()]
  def rows(%Store{} = store, suite, opts \\ []) do
    query =
      from(record in WorkflowEvalRecord,
        where: record.suite == ^suite,
        order_by: [asc: record.case_id, asc: record.arm, asc: record.inserted_at]
      )

    query =
      case Keyword.get(opts, :case_id) do
        nil -> query
        case_id -> from(record in query, where: record.case_id == ^case_id)
      end

    SQLite.with_repo(store, fn -> store.repo.all(query) end)
  end

  @spec create_candidate(Store.t(), map() | keyword()) ::
          {:ok, WorkflowOptimizationCandidate.t()} | {:error, term()}
  def create_candidate(%Store{} = store, attrs) when is_list(attrs),
    do: create_candidate(store, Map.new(attrs))

  def create_candidate(%Store{} = store, attrs) when is_map(attrs) do
    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          name = value(attrs, :name)
          task_family = value(attrs, :task_family)

          version =
            store.repo.one(
              from(candidate in WorkflowOptimizationCandidate,
                where:
                  candidate.name == ^name and
                    candidate.task_family == ^task_family,
                select: max(candidate.version)
              )
            ) || 0

          %WorkflowOptimizationCandidate{}
          |> WorkflowOptimizationCandidate.changeset(%{
            name: name,
            version: version + 1,
            task_family: task_family,
            status: value(attrs, :status, :active),
            pareto: value(attrs, :pareto, false),
            parent_ids_json: %{ids: List.wrap(value(attrs, :parent_ids, []))},
            modules_json: JSON.safe(value(attrs, :modules, %{})),
            metrics_json: JSON.safe(value(attrs, :metrics, %{})),
            feedback_json: JSON.safe(value(attrs, :feedback, %{}))
          })
          |> store.repo.insert!()
        end)
      end)
    end)
    |> transaction_result()
  end

  @spec refresh_pareto(Store.t(), String.t() | nil, keyword()) ::
          {:ok, [WorkflowOptimizationCandidate.t()]} | {:error, term()}
  def refresh_pareto(%Store{} = store, task_family, opts \\ []) do
    dimensions = Keyword.get(opts, :dimensions, @default_dimensions)

    SQLite.with_repo(store, fn ->
      SQLite.retry_busy_write(fn ->
        store.repo.transaction(fn ->
          query =
            from(candidate in WorkflowOptimizationCandidate,
              where: candidate.task_family == ^task_family and candidate.status != "rejected"
            )

          candidates = store.repo.all(query)
          frontier_ids = candidates |> pareto_frontier(dimensions) |> MapSet.new(& &1.id)

          Enum.map(candidates, fn candidate ->
            candidate
            |> WorkflowOptimizationCandidate.changeset(%{
              pareto: MapSet.member?(frontier_ids, candidate.id),
              status: if(MapSet.member?(frontier_ids, candidate.id), do: :retained, else: :active)
            })
            |> store.repo.update!()
          end)
        end)
      end)
    end)
    |> transaction_result()
  end

  @spec pareto_frontier([map()], keyword()) :: [map()]
  def pareto_frontier(candidates, dimensions \\ @default_dimensions) when is_list(candidates) do
    Enum.reject(candidates, fn candidate ->
      Enum.any?(candidates, fn other ->
        candidate != other and dominates?(other, candidate, dimensions)
      end)
    end)
  end

  defp dominates?(left, right, dimensions) do
    comparisons =
      Enum.flat_map(dimensions, fn {metric, direction} ->
        case {metric_value(left, metric), metric_value(right, metric)} do
          {l, r} when is_number(l) and is_number(r) -> [{compare(l, r, direction), metric}]
          _missing -> []
        end
      end)

    comparisons != [] and
      Enum.all?(comparisons, fn {comparison, _metric} -> comparison in [:equal, :better] end) and
      Enum.any?(comparisons, fn {comparison, _metric} -> comparison == :better end)
  end

  defp compare(left, right, :max) when left > right, do: :better
  defp compare(left, right, :min) when left < right, do: :better
  defp compare(left, right, _direction) when left == right, do: :equal
  defp compare(_left, _right, _direction), do: :worse

  defp metric_value(candidate, key) do
    metrics = Map.get(candidate, :metrics_json, Map.get(candidate, :metrics, %{})) || %{}
    Map.get(metrics, key, Map.get(metrics, Atom.to_string(key)))
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp value(input, key, default \\ nil) do
    Map.get(input, key, Map.get(input, Atom.to_string(key), default))
  end
end
