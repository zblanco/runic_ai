defmodule RunicAI.Evaluation.Run do
  @moduledoc """
  Aggregate evaluation run artifact.
  """

  alias RunicAI.Error
  alias RunicAI.Evaluation.Case
  alias RunicAI.Evaluation.Result

  @enforce_keys [:id, :cases, :results, :aggregate, :metadata]
  defstruct [
    :id,
    :recipe,
    :policy,
    cases: [],
    results: [],
    aggregate: %{},
    started_at: nil,
    completed_at: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          recipe: module() | atom() | String.t() | nil,
          policy: term(),
          cases: [Case.t()],
          results: [Result.t()],
          aggregate: map(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id, default_id())
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         {:ok, cases} <- normalize_cases(Keyword.get(opts, :cases, [])),
         {:ok, results} <- normalize_results(Keyword.get(opts, :results, [])),
         :ok <- validate_aggregate(Keyword.get(opts, :aggregate, %{})),
         :ok <- validate_metadata(metadata),
         :ok <- validate_timestamp(Keyword.get(opts, :started_at), :started_at),
         :ok <- validate_timestamp(Keyword.get(opts, :completed_at), :completed_at) do
      {:ok,
       %__MODULE__{
         id: id,
         recipe: Keyword.get(opts, :recipe),
         policy: Keyword.get(opts, :policy),
         cases: cases,
         results: results,
         aggregate: Keyword.get(opts, :aggregate, %{}),
         started_at: Keyword.get(opts, :started_at),
         completed_at: Keyword.get(opts, :completed_at),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, evaluation_run} -> evaluation_run
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = evaluation_run) do
    new(
      id: evaluation_run.id,
      recipe: evaluation_run.recipe,
      policy: evaluation_run.policy,
      cases: evaluation_run.cases,
      results: evaluation_run.results,
      aggregate: evaluation_run.aggregate,
      started_at: evaluation_run.started_at,
      completed_at: evaluation_run.completed_at,
      metadata: evaluation_run.metadata
    )
  end

  defp normalize_cases(cases) when is_list(cases) do
    cases
    |> Enum.reduce_while({:ok, []}, fn
      %Case{} = evaluation_case, {:ok, acc} ->
        case Case.validate(evaluation_case) do
          {:ok, normalized_case} -> {:cont, {:ok, [normalized_case | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.validation("evaluation run cases must be Evaluation.Case values",
            source: __MODULE__,
            details: %{case: other}
          )}}
    end)
    |> case do
      {:ok, normalized_cases} -> {:ok, Enum.reverse(normalized_cases)}
      error -> error
    end
  end

  defp normalize_cases(other) do
    {:error,
     Error.validation("evaluation run cases must be a list",
       source: __MODULE__,
       details: %{cases: other}
     )}
  end

  defp normalize_results(results) when is_list(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      %Result{} = result, {:ok, acc} ->
        case Result.new(result.case_id,
               status: result.status,
               session: result.session,
               outputs: result.outputs,
               trajectory: result.trajectory,
               scores: result.scores,
               metrics: result.metrics,
               failures: result.failures,
               metadata: result.metadata
             ) do
          {:ok, normalized_result} -> {:cont, {:ok, [normalized_result | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end

      other, _acc ->
        {:halt,
         {:error,
          Error.validation("evaluation run results must be Evaluation.Result values",
            source: __MODULE__,
            details: %{result: other}
          )}}
    end)
    |> case do
      {:ok, normalized_results} -> {:ok, Enum.reverse(normalized_results)}
      error -> error
    end
  end

  defp normalize_results(other) do
    {:error,
     Error.validation("evaluation run results must be a list",
       source: __MODULE__,
       details: %{results: other}
     )}
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("evaluation run id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_aggregate(aggregate) when is_map(aggregate), do: :ok

  defp validate_aggregate(aggregate) do
    {:error,
     Error.validation("evaluation run aggregate must be a map",
       source: __MODULE__,
       details: %{aggregate: aggregate}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("evaluation run metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp validate_timestamp(nil, _field), do: :ok
  defp validate_timestamp(%DateTime{}, _field), do: :ok

  defp validate_timestamp(value, field) do
    {:error,
     Error.validation("evaluation run #{field} must be a DateTime or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp default_id, do: "eval:#{System.unique_integer([:positive])}"
end
