defmodule RunicAI.Coding.RLM.WorkflowScorecard do
  @moduledoc """
  Objective-level scorecard for RLM coding runs.

  The scorecard separates graph execution from objective satisfaction. A
  workflow can finish orchestration while still failing required acceptance or
  child-result checks.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Error

  @statuses [
    :orchestration_complete,
    :objective_satisfied,
    :objective_incomplete,
    :blocked,
    :failed
  ]

  @enforce_keys [
    :id,
    :objective_status,
    :acceptance_results,
    :command_statuses,
    :child_results,
    :changed_files,
    :repair_count,
    :residual_risks,
    :metadata
  ]
  defstruct [
    :id,
    :objective_status,
    acceptance_results: [],
    command_statuses: [],
    child_results: [],
    changed_files: [],
    repair_count: 0,
    residual_risks: [],
    metadata: %{}
  ]

  @type objective_status ::
          :orchestration_complete
          | :objective_satisfied
          | :objective_incomplete
          | :blocked
          | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          objective_status: objective_status(),
          acceptance_results: [AcceptanceCheck.result()],
          command_statuses: [term()],
          child_results: [ChildResult.t()],
          changed_files: [Path.t()],
          repair_count: non_neg_integer(),
          residual_risks: [String.t()],
          metadata: map()
        }

  @spec statuses() :: [objective_status()]
  def statuses, do: @statuses

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    scorecard = %__MODULE__{
      id: Keyword.get(opts, :id) || "workflow-scorecard:#{System.unique_integer([:positive])}",
      objective_status:
        Keyword.get_lazy(opts, :objective_status, fn ->
          derive_status(
            Keyword.get(opts, :acceptance_results, []),
            Keyword.get(opts, :child_results, []),
            Keyword.get(opts, :command_statuses, [])
          )
        end),
      acceptance_results: Keyword.get(opts, :acceptance_results, []),
      command_statuses: Keyword.get(opts, :command_statuses, []),
      child_results: Keyword.get(opts, :child_results, []),
      changed_files: Keyword.get(opts, :changed_files, []),
      repair_count: Keyword.get(opts, :repair_count, 0),
      residual_risks: Keyword.get(opts, :residual_risks, []),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{}))
    }

    validate(scorecard)
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, scorecard} -> scorecard
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_inputs(keyword()) :: t()
  def from_inputs(opts) when is_list(opts) do
    new!(opts)
  end

  @spec objective_satisfied?(t() | map()) :: boolean()
  def objective_satisfied?(%__MODULE__{objective_status: :objective_satisfied}), do: true

  def objective_satisfied?(input) when is_map(input),
    do: get(input, :objective_status) in [:objective_satisfied, "objective_satisfied"]

  @spec derive_status([term()], [term()], [term()]) :: objective_status()
  def derive_status(acceptance_results, child_results, command_statuses) do
    current_acceptance_results = current_acceptance_results(acceptance_results)
    blocking_acceptance_results = blocking_acceptance_results(current_acceptance_results)

    cond do
      any_child_status?(child_results, [:failed]) ->
        :failed

      any_command_status?(command_statuses, [:blocked, :timeout, :killed]) ->
        :blocked

      any_child_status?(child_results, [:blocked, :needs_review]) ->
        :blocked

      current_acceptance_results != [] and
          blocking_acceptance_results == [] ->
        :objective_satisfied

      any_child_status?(child_results, [:partial]) ->
        :objective_incomplete

      blocking_acceptance_results != [] ->
        :objective_incomplete

      true ->
        :orchestration_complete
    end
  end

  @spec current_acceptance_results([term()]) :: [term()]
  def current_acceptance_results(acceptance_results) when is_list(acceptance_results) do
    acceptance_results
    |> Enum.reverse()
    |> Enum.uniq_by(&acceptance_identity/1)
    |> Enum.reverse()
  end

  @spec blocking_acceptance_results([term()]) :: [term()]
  def blocking_acceptance_results(acceptance_results) when is_list(acceptance_results) do
    current_results = current_acceptance_results(acceptance_results)
    blocking_results = Enum.filter(current_results, &AcceptanceCheck.blocking_failure?/1)

    if semantic_objective_verified?(current_results) do
      Enum.reject(blocking_results, &heuristic_source_failure?/1)
    else
      blocking_results
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = scorecard) do
    with :ok <- non_empty_string(scorecard.id, :id),
         :ok <- valid_status(scorecard.objective_status),
         :ok <- list(scorecard.acceptance_results, :acceptance_results),
         :ok <- list(scorecard.command_statuses, :command_statuses),
         {:ok, child_results} <- normalize_child_results(scorecard.child_results),
         :ok <- string_list(scorecard.changed_files, :changed_files),
         :ok <- non_neg_integer(scorecard.repair_count, :repair_count),
         :ok <- string_list(scorecard.residual_risks, :residual_risks),
         :ok <- map(scorecard.metadata, :metadata) do
      {:ok, %{scorecard | child_results: child_results}}
    end
  end

  defp any_child_status?(child_results, statuses) do
    child_results
    |> Enum.flat_map(fn child ->
      case ChildResult.from_input(child) do
        {:ok, child} -> [child.status]
        {:error, _error} -> []
      end
    end)
    |> Enum.any?(&(&1 in statuses))
  end

  defp acceptance_identity(result) when is_map(result) do
    get(result, :id) || {get(result, :type), inspect(get(result, :metadata))}
  end

  defp acceptance_identity(result), do: inspect(result)

  defp semantic_objective_verified?(results) do
    semantic_results = Enum.filter(results, &(result_type(&1) == :semantic_requirement))

    semantic_results != [] and required_results_passed?(semantic_results) and
      required_results_passed?(durable_results(results))
  end

  defp durable_results(results) do
    Enum.filter(
      results,
      &(result_type(&1) in [
          :artifact_present,
          :command_passes,
          :command_fails_with,
          :file_exists,
          :runtime_smoke
        ])
    )
  end

  defp required_results_passed?(results) do
    Enum.all?(results, fn result ->
      not required?(result) or passed?(result)
    end)
  end

  defp heuristic_source_failure?(result) do
    result_type(result) in [
      :source_contains,
      :source_not_contains,
      :module_exists,
      :function_exists,
      :test_count_min,
      :warning_count_zero
    ]
  end

  defp result_type(result) do
    result
    |> get(:type)
    |> normalize_type()
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.replace("-", "_")
    |> case do
      "semantic_requirement" -> :semantic_requirement
      "artifact_present" -> :artifact_present
      "command_passes" -> :command_passes
      "command_fails_with" -> :command_fails_with
      "file_exists" -> :file_exists
      "runtime_smoke" -> :runtime_smoke
      "source_contains" -> :source_contains
      "source_not_contains" -> :source_not_contains
      "module_exists" -> :module_exists
      "function_exists" -> :function_exists
      "test_count_min" -> :test_count_min
      "warning_count_zero" -> :warning_count_zero
      _other -> type
    end
  end

  defp normalize_type(type), do: type

  defp required?(result), do: get(result, :required?, true) in [true, "true", nil]

  defp passed?(result), do: get(result, :status) in [:pass, "pass"]

  defp any_command_status?(command_statuses, statuses) do
    command_statuses
    |> List.wrap()
    |> Enum.any?(fn command ->
      status = get(command, :status)
      status in statuses or status in Enum.map(statuses, &Atom.to_string/1)
    end)
  end

  defp normalize_child_results(child_results) when is_list(child_results) do
    child_results
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case ChildResult.from_input(child) do
        {:ok, child} -> {:cont, {:ok, [child | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, children} -> {:ok, Enum.reverse(children)}
      error -> error
    end
  end

  defp normalize_child_results(child_results) do
    {:error,
     Error.validation("workflow scorecard child_results must be a list",
       source: __MODULE__,
       details: %{child_results: child_results}
     )}
  end

  defp valid_status(status) when status in @statuses, do: :ok

  defp valid_status(status) do
    {:error,
     Error.validation("invalid workflow scorecard status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @statuses}
     )}
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("workflow scorecard #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp non_neg_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_neg_integer(value, field) do
    {:error,
     Error.validation("workflow scorecard #{field} must be a non-negative integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp list(value, _field) when is_list(value), do: :ok

  defp list(value, field) do
    {:error,
     Error.validation("workflow scorecard #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string_list(value, field) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: :ok, else: list(value, field)
  end

  defp string_list(value, field), do: list(value, field)

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("workflow scorecard #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_value, _key, default), do: default
end
