defmodule RunicAI.Coding.RLM.ObjectiveSession do
  @moduledoc """
  Durable objective state for multi-iteration RLM coding runs.

  A single RLM workflow run can propose, execute, verify, and repair one
  workflow. Long-running coding objectives need a layer above that run: it
  records each workflow attempt, checks whether the objective is actually
  satisfied, derives the next repair-oriented objective when useful, and turns
  budget exhaustion into an explicit operator decision instead of a silent
  failure.
  """

  alias RunicAI.Error
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest

  @terminal_statuses [
    :objective_satisfied,
    :needs_review_approval,
    :needs_budget_approval,
    :blocked,
    :failed
  ]

  @enforce_keys [:id, :objective, :status, :created_at, :updated_at]
  defstruct [
    :id,
    :objective,
    :status,
    :latest_result,
    :latest_error,
    :next_objective,
    created_at: nil,
    updated_at: nil,
    max_iterations: 3,
    iterations: [],
    progress_log: [],
    completed_tasks: [],
    open_tasks: [],
    review_requests: [],
    budget_requests: [],
    metadata: %{}
  ]

  @type status ::
          :planning
          | :running
          | :objective_satisfied
          | :needs_review_approval
          | :needs_budget_approval
          | :blocked
          | :failed

  @type decision :: %{
          required(:action) =>
            :continue
            | :complete
            | :request_review_approval
            | :request_budget_approval
            | :stop_blocked
            | :stop_failed,
          required(:status) => status(),
          optional(:next_objective) => String.t(),
          optional(:reason) => String.t(),
          optional(:request) => map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          status: status(),
          latest_result: map() | nil,
          latest_error: Error.t() | nil,
          next_objective: String.t() | nil,
          max_iterations: pos_integer(),
          iterations: [map()],
          progress_log: [map()],
          completed_tasks: [map()],
          open_tasks: [map()],
          review_requests: [map()],
          budget_requests: [map()],
          metadata: map(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    objective = String.trim(objective)

    cond do
      objective == "" ->
        {:error,
         Error.validation("objective session objective must be a non-empty string",
           source: __MODULE__
         )}

      not valid_max_iterations?(Keyword.get(opts, :max_iterations, 3)) ->
        {:error,
         Error.validation("objective session max_iterations must be a positive integer",
           source: __MODULE__,
           details: %{max_iterations: Keyword.get(opts, :max_iterations)}
         )}

      true ->
        now = Keyword.get(opts, :now, DateTime.utc_now())

        {:ok,
         %__MODULE__{
           id: Keyword.get(opts, :id) || "rlm-objective:#{System.unique_integer([:positive])}",
           objective: objective,
           status: Keyword.get(opts, :status, :planning),
           max_iterations: Keyword.get(opts, :max_iterations, 3),
           metadata: normalize_map(Keyword.get(opts, :metadata, %{})),
           created_at: now,
           updated_at: now
         }}
    end
  end

  @spec new!(String.t(), keyword()) :: t()
  def new!(objective, opts \\ []) do
    case new(objective, opts) do
      {:ok, session} -> session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    %{
      id: session.id,
      objective: session.objective,
      status: session.status,
      latest_result: session.latest_result,
      latest_error: error_to_map(session.latest_error),
      next_objective: session.next_objective,
      created_at: session.created_at,
      updated_at: session.updated_at,
      max_iterations: session.max_iterations,
      iterations: session.iterations,
      progress_log: session.progress_log,
      completed_tasks: session.completed_tasks,
      open_tasks: session.open_tasks,
      review_requests: session.review_requests,
      budget_requests: session.budget_requests,
      metadata: session.metadata
    }
    |> reject_nil_values()
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(input) when is_map(input) do
    objective = field(input, :objective)
    max_iterations = field(input, :max_iterations) || 3

    with {:ok, status} <- normalize_status(field(input, :status)),
         {:ok, created_at} <- normalize_datetime(field(input, :created_at), DateTime.utc_now()),
         {:ok, updated_at} <- normalize_datetime(field(input, :updated_at), created_at),
         {:ok, session} <-
           new(objective || "",
             id: field(input, :id),
             status: status,
             max_iterations: max_iterations,
             metadata: field(input, :metadata) || %{},
             now: created_at
           ) do
      {:ok,
       %{
         session
         | latest_result: field(input, :latest_result),
           latest_error: error_from_map(field(input, :latest_error)),
           next_objective: non_blank_string(field(input, :next_objective)),
           updated_at: updated_at,
           iterations: field(input, :iterations) || [],
           progress_log: field(input, :progress_log) || [],
           completed_tasks: field(input, :completed_tasks) || [],
           open_tasks: field(input, :open_tasks) || [],
           review_requests: field(input, :review_requests) || [],
           budget_requests: field(input, :budget_requests) || []
       }}
    end
  end

  def from_map(input) do
    {:error,
     Error.validation("objective session state must be a map",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec from_map!(map()) :: t()
  def from_map!(input) do
    case from_map(input) do
      {:ok, session} -> session
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec next_workflow_objective(t()) :: String.t()
  def next_workflow_objective(%__MODULE__{next_objective: objective, objective: fallback})
      when is_binary(objective),
      do: non_blank_string(objective) || fallback

  def next_workflow_objective(%__MODULE__{objective: objective}), do: objective

  @spec iteration_started(t(), keyword()) :: t()
  def iteration_started(%__MODULE__{} = session, opts \\ []) do
    iteration = iteration_number(session)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    session
    |> Map.put(:status, :running)
    |> Map.put(:updated_at, now)
    |> append_progress(:iteration_started, %{
      iteration: iteration,
      objective: Keyword.get(opts, :objective, next_workflow_objective(session))
    })
  end

  @spec record_result(t(), map(), keyword()) :: t()
  def record_result(%__MODULE__{} = session, result, opts \\ []) when is_map(result) do
    iteration = iteration_number(session)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    status = result_status(result, session, opts)
    repair_needs = repair_needs(result)
    review_request = review_request(result)
    task_updates = task_updates(result)
    next_objective = next_objective(status, session.objective, repair_needs, result)
    budget_request = budget_request(status, session, result, opts)

    entry = %{
      iteration: iteration,
      status: status,
      scorecard_status: scorecard_status(result),
      repair_status: repair_status(result),
      repair_needs: repair_needs,
      review_request: review_request,
      task_updates: task_updates,
      changed_files: changed_files(result),
      output_preview: output_preview(result),
      recorded_at: now
    }

    session
    |> Map.put(:status, status)
    |> Map.put(:latest_result, result)
    |> Map.put(:latest_error, nil)
    |> Map.put(:next_objective, next_objective)
    |> Map.put(:updated_at, now)
    |> update_in([Access.key(:iterations)], &(&1 ++ [entry]))
    |> update_tasks(status, result, repair_needs, review_request)
    |> maybe_append_review_request(review_request)
    |> maybe_append_budget_request(budget_request)
    |> append_progress(:iteration_completed, entry)
  end

  @spec record_error(t(), Error.t() | term(), keyword()) :: t()
  def record_error(%__MODULE__{} = session, error, opts \\ []) do
    error = normalize_error(error)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    status =
      if budget_error?(error) or iteration_number(session) > session.max_iterations do
        :needs_budget_approval
      else
        :failed
      end

    request =
      if status == :needs_budget_approval do
        current_iteration = iteration_number(session)

        %{
          id: budget_resume_key(session, current_iteration),
          resume_key: budget_resume_key(session, current_iteration),
          reason: error.message,
          requested_at: now,
          current_iteration: current_iteration,
          max_iterations: session.max_iterations,
          status: :pending,
          suggested_next_action:
            "Approve more runtime or repair budget, then resume the objective."
        }
      end

    session
    |> Map.put(:status, status)
    |> Map.put(:latest_result, nil)
    |> Map.put(:latest_error, error)
    |> Map.put(:next_objective, nil)
    |> Map.put(:updated_at, now)
    |> maybe_append_budget_request(request)
    |> append_progress(:iteration_error, %{
      iteration: iteration_number(session),
      status: status,
      error: error_summary(error)
    })
  end

  @spec record_review_decision(t(), ReviewDecision.t() | map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def record_review_decision(%__MODULE__{} = session, decision_input, opts \\ []) do
    with {:ok, %ReviewDecision{} = decision} <- ReviewDecision.from_input(decision_input),
         {:ok, review_request} <- latest_pending_review_request(session),
         :ok <- validate_review_resume_key(review_request, decision) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      status =
        case decision.status do
          status when status in [:approved, :edited] -> :planning
          _status -> :blocked
        end

      next_objective =
        if status == :planning do
          review_next_objective(session, review_request, decision, opts)
        end

      session =
        session
        |> Map.put(:status, status)
        |> Map.put(:latest_error, resumed_latest_error(session, status))
        |> Map.put(:next_objective, next_objective)
        |> Map.put(:updated_at, now)
        |> close_review_task(review_request)
        |> record_review_request_decision(review_request, decision, now)
        |> append_progress(:review_completed, %{
          status: status,
          review_request: review_request,
          review_decision: review_decision_summary(decision),
          next_objective: next_objective
        })

      {:ok, session}
    end
  end

  @spec record_budget_decision(t(), ReviewDecision.t() | map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def record_budget_decision(%__MODULE__{} = session, decision_input, opts \\ []) do
    with {:ok, %ReviewDecision{} = decision} <- ReviewDecision.from_input(decision_input),
         {:ok, budget_request} <- latest_pending_budget_request(session),
         :ok <- validate_budget_resume_key(budget_request, decision) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      status =
        case decision.status do
          status when status in [:approved, :edited] -> :planning
          _status -> :blocked
        end

      next_objective =
        if status == :planning do
          budget_next_objective(session, budget_request, decision, opts)
        end

      max_iterations =
        if status == :planning do
          approved_max_iterations(session, budget_request, decision, opts)
        else
          session.max_iterations
        end

      metadata =
        if status == :planning do
          approved_runtime_metadata(session, budget_request, decision, opts)
        else
          session.metadata
        end

      session =
        session
        |> Map.put(:status, status)
        |> Map.put(:latest_error, resumed_latest_error(session, status))
        |> Map.put(:next_objective, next_objective)
        |> Map.put(:max_iterations, max_iterations)
        |> Map.put(:metadata, metadata)
        |> Map.put(:updated_at, now)
        |> record_budget_request_decision(budget_request, decision, now)
        |> append_progress(:budget_completed, %{
          status: status,
          budget_request: budget_request,
          budget_decision: review_decision_summary(decision),
          next_objective: next_objective,
          max_iterations: max_iterations,
          run_deadline_ms: field(metadata, :run_deadline_ms),
          max_runtime_ms: field(metadata, :max_runtime_ms)
        })

      {:ok, session}
    end
  end

  @spec decision(t()) :: decision()
  def decision(%__MODULE__{} = session) do
    case session.status do
      :objective_satisfied ->
        %{action: :complete, status: session.status, reason: "objective scorecard satisfied"}

      :needs_review_approval ->
        %{
          action: :request_review_approval,
          status: session.status,
          reason: "objective is waiting for operator review approval",
          request: List.last(session.review_requests) || %{}
        }

      :needs_budget_approval ->
        %{
          action: :request_budget_approval,
          status: session.status,
          reason: "objective needs more runtime or repair budget",
          request: List.last(session.budget_requests) || %{}
        }

      :failed ->
        %{action: :stop_failed, status: session.status, reason: latest_error_message(session)}

      :blocked ->
        %{action: :stop_blocked, status: session.status, reason: "objective blocked"}

      _status ->
        %{
          action: :continue,
          status: session.status,
          next_objective: next_workflow_objective(session),
          reason: "objective remains incomplete and budget remains available"
        }
    end
  end

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = session) do
    %{
      id: session.id,
      objective: session.objective,
      status: session.status,
      iteration_count: length(session.iterations),
      max_iterations: session.max_iterations,
      completed_task_count: length(session.completed_tasks),
      open_task_count: length(session.open_tasks),
      review_request_count: length(session.review_requests),
      pending_review_request_count: length(pending_review_requests(session)),
      budget_request_count: length(session.budget_requests),
      pending_budget_request_count: length(pending_budget_requests(session)),
      latest_error: error_to_map(session.latest_error),
      latest_error_kind: latest_error_field(session.latest_error, :kind),
      latest_error_message: latest_error_field(session.latest_error, :message),
      latest_review_request: List.last(session.review_requests),
      latest_budget_request: List.last(session.budget_requests),
      decision: decision(session),
      updated_at: session.updated_at
    }
  end

  defp valid_max_iterations?(value), do: is_integer(value) and value > 0

  defp result_status(result, session, _opts) do
    cond do
      review_request(result) ->
        :needs_review_approval

      objective_satisfied?(result) ->
        :objective_satisfied

      budget_limited_result?(result) ->
        :needs_budget_approval

      iteration_number(session) >= session.max_iterations ->
        :needs_budget_approval

      failed_result?(result) ->
        :failed

      blocking_result?(result) ->
        :running

      true ->
        :running
    end
  end

  defp latest_pending_review_request(%__MODULE__{status: :needs_review_approval} = session) do
    case session |> pending_review_requests() |> List.last() do
      request when is_map(request) ->
        {:ok, request}

      _other ->
        {:error,
         Error.validation("objective session has no pending review request",
           source: __MODULE__,
           details: %{session_id: session.id}
         )}
    end
  end

  defp latest_pending_review_request(%__MODULE__{} = session) do
    {:error,
     Error.validation("objective session is not waiting for review approval",
       source: __MODULE__,
       details: %{session_id: session.id, status: session.status}
     )}
  end

  defp pending_review_requests(%__MODULE__{} = session) do
    Enum.filter(session.review_requests, &pending_review_request?/1)
  end

  defp pending_review_request?(request) when is_map(request) do
    field(request, :status) in [nil, :pending, "pending", :waiting, "waiting"]
  end

  defp pending_review_request?(_request), do: false

  defp latest_pending_budget_request(%__MODULE__{status: :needs_budget_approval} = session) do
    case session |> pending_budget_requests() |> List.last() do
      request when is_map(request) ->
        {:ok, request}

      _other ->
        {:error,
         Error.validation("objective session has no pending budget request",
           source: __MODULE__,
           details: %{session_id: session.id}
         )}
    end
  end

  defp latest_pending_budget_request(%__MODULE__{} = session) do
    {:error,
     Error.validation("objective session is not waiting for budget approval",
       source: __MODULE__,
       details: %{session_id: session.id, status: session.status}
     )}
  end

  defp pending_budget_requests(%__MODULE__{} = session) do
    Enum.filter(session.budget_requests, &pending_budget_request?/1)
  end

  defp pending_budget_request?(request) when is_map(request) do
    field(request, :status) in [nil, :pending, "pending", :waiting, "waiting"]
  end

  defp pending_budget_request?(_request), do: false

  defp validate_review_resume_key(review_request, %ReviewDecision{} = decision) do
    if field(review_request, :resume_key) == decision.resume_key do
      :ok
    else
      {:error,
       Error.validation("review decision resume_key did not match the objective review request",
         source: __MODULE__,
         details: %{
           request: field(review_request, :resume_key),
           decision: decision.resume_key
         }
       )}
    end
  end

  defp validate_budget_resume_key(budget_request, %ReviewDecision{} = decision) do
    if field(budget_request, :resume_key) == decision.resume_key or
         field(budget_request, :id) == decision.resume_key do
      :ok
    else
      {:error,
       Error.validation("budget decision resume_key did not match the objective budget request",
         source: __MODULE__,
         details: %{
           request: field(budget_request, :resume_key) || field(budget_request, :id),
           decision: decision.resume_key
         }
       )}
    end
  end

  defp review_next_objective(session, review_request, %ReviewDecision{} = decision, opts) do
    non_blank_string(Keyword.get(opts, :next_objective)) ||
      edited_review_objective(decision) ||
      """
      Continue the objective after operator approval.

      Original objective:
      #{session.objective}

      Approved review checkpoint:
      #{field(review_request, :checkpoint) || field(review_request, :kind)}

      Stop only when the objective scorecard reports objective_satisfied.
      """
      |> String.trim()
  end

  defp edited_review_objective(%ReviewDecision{status: :edited, edited_value: value})
       when is_binary(value) do
    non_blank_string(value)
  end

  defp edited_review_objective(_decision), do: nil

  defp resumed_latest_error(_session, :planning), do: nil
  defp resumed_latest_error(session, _status), do: session.latest_error

  defp budget_next_objective(session, budget_request, %ReviewDecision{} = decision, opts) do
    non_blank_string(Keyword.get(opts, :next_objective)) ||
      edited_review_objective(decision) ||
      """
      Continue the objective after operator budget approval.

      Original objective:
      #{session.objective}

      Budget approval reason:
      #{field(budget_request, :reason) || "additional objective-loop budget approved"}

      Stop only when the objective scorecard reports objective_satisfied.
      """
      |> String.trim()
  end

  defp approved_max_iterations(session, budget_request, %ReviewDecision{} = decision, opts) do
    requested_max =
      Keyword.get(opts, :max_iterations) ||
        metadata_integer(decision.metadata, :max_iterations) ||
        field(budget_request, :max_iterations)

    additional =
      Keyword.get(opts, :additional_iterations) ||
        metadata_integer(decision.metadata, :additional_iterations) ||
        metadata_integer(decision.metadata, :approved_iterations) ||
        field(budget_request, :additional_iterations) ||
        1

    [
      session.max_iterations + additional,
      length(session.iterations) + 1,
      requested_max
    ]
    |> Enum.filter(&is_integer/1)
    |> Enum.max()
  end

  defp approved_runtime_metadata(session, budget_request, %ReviewDecision{} = decision, opts) do
    metadata = normalize_map(session.metadata)
    now_ms = Keyword.get(opts, :monotonic_now_ms, System.monotonic_time(:millisecond))
    existing_deadline = metadata_integer(metadata, :run_deadline_ms)

    max_runtime_ms =
      metadata_integer(decision.metadata, :max_runtime_ms) ||
        metadata_integer(budget_request, :max_runtime_ms) ||
        positive_integer(Keyword.get(opts, :max_runtime_ms)) ||
        metadata_integer(metadata, :max_runtime_ms)

    additional_runtime_ms =
      metadata_integer(decision.metadata, :additional_runtime_ms) ||
        metadata_integer(decision.metadata, :approved_runtime_ms) ||
        metadata_integer(budget_request, :additional_runtime_ms) ||
        positive_integer(Keyword.get(opts, :additional_runtime_ms))

    new_deadline =
      cond do
        is_integer(additional_runtime_ms) ->
          max(existing_deadline || now_ms, now_ms) + additional_runtime_ms

        is_integer(existing_deadline) and existing_deadline <= now_ms and
            is_integer(max_runtime_ms) ->
          now_ms + max_runtime_ms

        true ->
          existing_deadline
      end

    metadata
    |> maybe_put_metadata(:max_runtime_ms, max_runtime_ms)
    |> maybe_put_metadata(:run_deadline_ms, new_deadline)
  end

  defp objective_satisfied?(result) do
    scorecard_status(result) in [:objective_satisfied, "objective_satisfied"]
  end

  defp budget_limited_result?(result) do
    repair_status(result) in [:exhausted, "exhausted"] or
      not is_nil(runtime_timeout(result)) or
      repair_needs(result)
      |> Enum.any?(fn need ->
        text = "#{field(need, :reason)} #{field(need, :id)}"

        String.contains?(String.downcase(text), "budget") or
          String.contains?(String.downcase(text), "timeout")
      end)
  end

  defp failed_result?(result) do
    field(result, :status) in [:failed, "failed", :error, "error"] or
      scorecard_status(result) in [:failed, "failed"]
  end

  defp blocking_result?(result) do
    field(result, :status) in [:blocked, "blocked"] or repair_needs(result) != []
  end

  defp next_objective(:objective_satisfied, _objective, _repair_needs, _result), do: nil
  defp next_objective(:needs_review_approval, _objective, _repair_needs, _result), do: nil
  defp next_objective(:needs_budget_approval, _objective, _repair_needs, _result), do: nil
  defp next_objective(:failed, _objective, _repair_needs, _result), do: nil

  defp next_objective(_status, objective, [], _result) do
    """
    Continue the objective and produce stronger verification evidence.

    Original objective:
    #{objective}
    """
    |> String.trim()
  end

  defp next_objective(_status, objective, repair_needs, _result) do
    """
    Continue the objective by repairing the remaining blocking evidence.

    Original objective:
    #{objective}

    Blocking repair needs:
    #{inspect(Enum.map(repair_needs, &repair_need_summary/1), pretty: true, limit: 20)}

    Stop only when the objective scorecard reports objective_satisfied.
    """
    |> String.trim()
  end

  defp budget_request(:needs_budget_approval, session, result, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    current_iteration = length(session.iterations) + 1
    resume_key = budget_resume_key(session, current_iteration)

    %{
      id: resume_key,
      resume_key: resume_key,
      kind: :objective_budget_approval,
      checkpoint: :budget_approval,
      reason: budget_reason(result),
      requested_at: now,
      current_iteration: current_iteration,
      max_iterations: session.max_iterations,
      scorecard_status: scorecard_status(result),
      repair_status: repair_status(result),
      status: :pending,
      options: [:approve, :reject, :cancel],
      suggested_next_action: "Approve more runtime or repair budget, then resume the objective."
    }
  end

  defp budget_request(_status, _session, _result, _opts), do: nil

  defp budget_reason(result) do
    cond do
      repair_status(result) in [:exhausted, "exhausted"] ->
        "repair budget exhausted before objective satisfaction"

      not is_nil(runtime_timeout(result)) ->
        "runtime budget exhausted during active workflow execution"

      true ->
        "objective iteration budget exhausted before objective satisfaction"
    end
  end

  defp budget_resume_key(%__MODULE__{} = session, iteration) do
    "budget:#{session.id}:#{iteration || length(session.iterations) + 1}"
  end

  defp update_tasks(session, :objective_satisfied, result, _repair_needs, _review_request) do
    task = %{
      id: "objective",
      title: session.objective,
      status: :completed,
      scorecard_status: scorecard_status(result)
    }

    session
    |> merge_task_updates(task_updates(result), [])
    |> Map.update!(:completed_tasks, fn tasks -> Enum.uniq_by(tasks ++ [task], &task_id/1) end)
    |> Map.put(:open_tasks, [])
  end

  defp update_tasks(session, :needs_review_approval, result, _repair_needs, review_request) do
    open_tasks =
      review_request
      |> List.wrap()
      |> Enum.map(fn request ->
        %{
          id: field(request, :resume_key) || "review-approval",
          title: review_task_title(request),
          status: :review,
          target: field(request, :checkpoint),
          metadata: field(request, :metadata) || %{}
        }
      end)

    merge_task_updates(session, task_updates(result), open_tasks)
  end

  defp update_tasks(session, _status, result, repair_needs, _review_request) do
    open_tasks =
      repair_needs
      |> Enum.with_index(1)
      |> Enum.map(fn {need, index} ->
        %{
          id: field(need, :id) || "repair-need-#{index}",
          title: field(need, :reason) || "Repair blocking objective evidence",
          status: :open,
          target: field(need, :target),
          metadata: field(need, :metadata) || %{}
        }
      end)

    merge_task_updates(session, task_updates(result), open_tasks)
  end

  defp merge_task_updates(session, explicit_updates, inferred_open_tasks) do
    inferred_open =
      inferred_open_tasks
      |> Enum.with_index(1)
      |> Enum.map(fn {task, index} -> normalize_task_update(task, index, :open) end)
      |> Enum.reject(&is_nil/1)

    explicit_updates =
      explicit_updates
      |> Enum.with_index(1)
      |> Enum.map(fn {task, index} -> normalize_task_update(task, index, :open) end)
      |> Enum.reject(&is_nil/1)

    completed_updates = Enum.filter(explicit_updates, &(field(&1, :status) == :completed))
    open_updates = Enum.reject(explicit_updates, &(field(&1, :status) == :completed))

    completed_tasks =
      session.completed_tasks
      |> Kernel.++(completed_updates)
      |> uniq_tasks_by_latest_id()

    completed_ids = MapSet.new(Enum.map(completed_tasks, &task_id/1))

    open_tasks =
      session.open_tasks
      |> Kernel.++(inferred_open)
      |> Kernel.++(open_updates)
      |> Enum.reject(&(task_id(&1) in completed_ids))
      |> uniq_tasks_by_latest_id()

    %{session | completed_tasks: completed_tasks, open_tasks: open_tasks}
  end

  defp uniq_tasks_by_latest_id(tasks) do
    tasks
    |> Enum.reverse()
    |> Enum.uniq_by(&task_id/1)
    |> Enum.reverse()
  end

  defp task_updates(result) do
    context = field(result, :context) || %{}

    [
      field(result, :task_updates),
      field(result, :objective_tasks),
      field(result, :tasks),
      field(context, :task_updates),
      field(context, :objective_tasks),
      field(context, :tasks)
    ]
    |> Enum.flat_map(&task_updates_from_source/1)
  end

  defp task_updates_from_source(nil), do: []
  defp task_updates_from_source(source) when is_list(source), do: source

  defp task_updates_from_source(source) when is_map(source) do
    cond do
      task_like?(source) ->
        [source]

      field(source, :task_updates) || field(source, :tasks) ->
        [field(source, :task_updates), field(source, :tasks)]
        |> Enum.flat_map(&task_updates_from_source/1)

      true ->
        open_tasks =
          source
          |> field(:open_tasks)
          |> List.wrap()
          |> Enum.map(&put_default_task_status(&1, :open))

        completed_tasks =
          source
          |> field(:completed_tasks)
          |> List.wrap()
          |> Enum.map(&put_default_task_status(&1, :completed))

        open_tasks ++ completed_tasks
    end
  end

  defp task_updates_from_source(_source), do: []

  defp normalize_task_update(task, index, default_status) when is_map(task) do
    id = field(task, :id) || field(task, :task_id) || "task-#{index}"
    status = normalize_task_status(field(task, :status) || field(task, :state) || default_status)

    %{
      id: id,
      title: field(task, :title) || field(task, :reason) || field(task, :description) || id,
      status: status,
      target: field(task, :target),
      metadata: field(task, :metadata) || %{}
    }
    |> reject_nil_values()
  end

  defp normalize_task_update(task, _index, default_status) when is_binary(task) do
    %{id: task, title: task, status: default_status, metadata: %{}}
  end

  defp normalize_task_update(_task, _index, _default_status), do: nil

  defp normalize_task_status(status) when status in [:completed, :done, :objective_satisfied],
    do: :completed

  defp normalize_task_status(status)
       when status in [:running, :in_progress, :planned, :pending, :open, :review, :blocked],
       do: status

  defp normalize_task_status("completed"), do: :completed
  defp normalize_task_status("done"), do: :completed
  defp normalize_task_status("objective_satisfied"), do: :completed
  defp normalize_task_status("running"), do: :running
  defp normalize_task_status("in_progress"), do: :in_progress
  defp normalize_task_status("planned"), do: :planned
  defp normalize_task_status("pending"), do: :pending
  defp normalize_task_status("review"), do: :review
  defp normalize_task_status("blocked"), do: :blocked
  defp normalize_task_status(_status), do: :open

  defp put_default_task_status(task, status) when is_map(task) do
    if field(task, :status) || field(task, :state) do
      task
    else
      Map.put(task, :status, status)
    end
  end

  defp put_default_task_status(task, status) when is_binary(task) do
    %{id: task, title: task, status: status}
  end

  defp put_default_task_status(task, _status), do: task

  defp task_like?(task) when is_map(task) do
    not is_nil(field(task, :id)) or not is_nil(field(task, :task_id)) or
      not is_nil(field(task, :title))
  end

  defp task_like?(_task), do: false

  defp task_id(task), do: field(task, :id) || field(task, :task_id)

  defp close_review_task(%__MODULE__{} = session, review_request) do
    review_ids =
      [
        field(review_request, :resume_key),
        field(review_request, :id),
        "review-approval"
      ]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Map.update!(session, :open_tasks, fn tasks ->
      Enum.reject(tasks, &(task_id(&1) in review_ids))
    end)
  end

  defp maybe_append_review_request(session, nil), do: session

  defp maybe_append_review_request(session, request) do
    update_in(session.review_requests, fn requests ->
      Enum.uniq_by(requests ++ [request], fn request -> field(request, :resume_key) end)
    end)
  end

  defp record_review_request_decision(
         %__MODULE__{} = session,
         review_request,
         %ReviewDecision{} = decision,
         resolved_at
       ) do
    update_in(session.review_requests, fn requests ->
      Enum.map(requests, fn request ->
        if same_review_request?(request, review_request) do
          put_request_decision(request, decision.status, decision, resolved_at)
        else
          request
        end
      end)
    end)
  end

  defp same_review_request?(request, review_request) do
    Enum.any?([:resume_key, :id], fn key ->
      not is_nil(field(request, key)) and field(request, key) == field(review_request, key)
    end)
  end

  defp maybe_append_budget_request(session, nil), do: session

  defp maybe_append_budget_request(session, request) do
    update_in(session.budget_requests, &(&1 ++ [request]))
  end

  defp record_budget_request_decision(
         %__MODULE__{} = session,
         budget_request,
         %ReviewDecision{} = decision,
         resolved_at
       ) do
    update_in(session.budget_requests, fn requests ->
      Enum.map(requests, fn request ->
        if same_budget_request?(request, budget_request) do
          put_request_decision(request, budget_request_status(decision), decision, resolved_at)
        else
          request
        end
      end)
    end)
  end

  defp put_request_decision(request, status, %ReviewDecision{} = decision, resolved_at) do
    request
    |> Map.drop([:status, "status", :resolved_at, "resolved_at", :decision, "decision"])
    |> Map.put(:status, status)
    |> Map.put(:resolved_at, resolved_at)
    |> Map.put(:decision, review_decision_summary(decision))
  end

  defp same_budget_request?(request, budget_request) do
    Enum.any?([:resume_key, :id], fn key ->
      not is_nil(field(request, key)) and field(request, key) == field(budget_request, key)
    end)
  end

  defp budget_request_status(%ReviewDecision{status: status}) when status in [:approved, :edited],
    do: :approved

  defp budget_request_status(%ReviewDecision{status: status}), do: status

  defp append_progress(session, event, data) do
    update_in(session.progress_log, fn log ->
      log ++
        [
          %{
            event: event,
            data: data,
            at: session.updated_at
          }
        ]
    end)
  end

  defp iteration_number(%__MODULE__{} = session), do: length(session.iterations) + 1

  defp scorecard_status(result) do
    result
    |> latest_scorecard()
    |> case do
      nil -> nil
      scorecard -> field(scorecard, :objective_status)
    end
  end

  defp latest_scorecard(result) do
    cond do
      not is_nil(field(result, :objective_scorecard)) ->
        field(result, :objective_scorecard)

      not is_nil(field(result, :scorecard)) ->
        field(result, :scorecard)

      is_map(field(result, :context)) ->
        result
        |> field(:context)
        |> field(:scorecards)
        |> case do
          scorecards when is_list(scorecards) -> List.last(scorecards)
          _other -> nil
        end

      true ->
        nil
    end
  end

  defp repair_needs(result) do
    result
    |> field(:context)
    |> case do
      context when is_map(context) -> field(context, :repair_needs)
      _other -> []
    end
    |> List.wrap()
  end

  defp repair_status(result) do
    field(result, :repair_status) || result |> field(:context) |> field(:repair_status)
  end

  defp runtime_timeout(result) do
    result
    |> field(:context)
    |> field(:runtime_timeout)
  end

  defp review_request(result) do
    [
      field(result, :latest_review_request),
      field(result, :review_request),
      field(field(result, :context), :latest_review_request),
      field(field(result, :context), :review_request),
      field(field(result, :context), :review_requests) |> List.wrap() |> List.last()
    ]
    |> Enum.find(&review_request?/1)
    |> normalize_review_request()
  end

  defp review_request?(%ReviewRequest{}), do: true

  defp review_request?(request) when is_map(request) do
    not is_nil(field(request, :resume_key)) and not is_nil(field(request, :kind))
  end

  defp review_request?(_request), do: false

  defp normalize_review_request(nil), do: nil

  defp normalize_review_request(%ReviewRequest{} = request) do
    %{
      kind: request.kind,
      subject: request.subject,
      checkpoint: request.checkpoint,
      resume_key: request.resume_key,
      status: :pending,
      options: request.options,
      details: request.details,
      metadata: request.metadata
    }
  end

  defp normalize_review_request(request) when is_map(request) do
    %{
      kind: field(request, :kind),
      subject: field(request, :subject),
      checkpoint: field(request, :checkpoint),
      resume_key: field(request, :resume_key),
      status: field(request, :status) || :pending,
      options: field(request, :options) || [],
      details: field(request, :details) || %{},
      metadata: field(request, :metadata) || %{}
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp changed_files(result) do
    context = field(result, :context) || %{}

    [
      field(result, :changed_files),
      field(context, :changed_files),
      latest_scorecard(result) && field(latest_scorecard(result), :changed_files)
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp output_preview(result) do
    result
    |> field(:output)
    |> inspect(limit: 20, printable_limit: 500)
    |> String.slice(0, 500)
  end

  defp repair_need_summary(need) do
    %{
      id: field(need, :id),
      reason: field(need, :reason),
      target: field(need, :target),
      metadata: field(need, :metadata) || %{}
    }
  end

  defp review_task_title(request) do
    kind = field(request, :kind) || "review"
    checkpoint = field(request, :checkpoint)

    if checkpoint do
      "#{kind} approval required at #{checkpoint}"
    else
      "#{kind} approval required"
    end
  end

  defp review_decision_summary(%ReviewDecision{} = decision) do
    %{
      resume_key: decision.resume_key,
      status: decision.status,
      edited_value: decision.edited_value,
      actor: decision.actor,
      metadata: decision.metadata
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp metadata_integer(metadata, key) when is_map(metadata) do
    case field(metadata, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_positive_integer(value)
      _other -> nil
    end
  end

  defp metadata_integer(_metadata, _key), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(value) when is_binary(value), do: parse_positive_integer(value)
  defp positive_integer(_value), do: nil

  defp maybe_put_metadata(metadata, _key, nil), do: metadata

  defp maybe_put_metadata(metadata, key, value) when is_atom(key) do
    metadata
    |> Map.drop([Atom.to_string(key)])
    |> Map.put(key, value)
  end

  defp maybe_put_metadata(metadata, key, value) when is_binary(key) do
    metadata
    |> maybe_drop_metadata_key(safe_existing_atom(key))
    |> Map.put(key, value)
  end

  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_drop_metadata_key(metadata, nil), do: metadata
  defp maybe_drop_metadata_key(metadata, key), do: Map.drop(metadata, [key])

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp normalize_status(status)
       when status in [
              :planning,
              :running,
              :objective_satisfied,
              :needs_review_approval,
              :needs_budget_approval,
              :blocked,
              :failed
            ],
       do: {:ok, status}

  defp normalize_status("planning"), do: {:ok, :planning}
  defp normalize_status("running"), do: {:ok, :running}
  defp normalize_status("objective_satisfied"), do: {:ok, :objective_satisfied}
  defp normalize_status("needs_review_approval"), do: {:ok, :needs_review_approval}
  defp normalize_status("needs_budget_approval"), do: {:ok, :needs_budget_approval}
  defp normalize_status("blocked"), do: {:ok, :blocked}
  defp normalize_status("failed"), do: {:ok, :failed}
  defp normalize_status(nil), do: {:ok, :planning}

  defp normalize_status(status) do
    {:error,
     Error.validation("invalid objective session status",
       source: __MODULE__,
       details: %{status: status}
     )}
  end

  defp normalize_datetime(nil, default), do: {:ok, default}
  defp normalize_datetime(%DateTime{} = value, _default), do: {:ok, value}

  defp normalize_datetime(value, _default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, reason} ->
        {:error,
         Error.validation("invalid objective session timestamp",
           source: __MODULE__,
           details: %{timestamp: value, reason: reason}
         )}
    end
  end

  defp normalize_datetime(value, _default) do
    {:error,
     Error.validation("invalid objective session timestamp",
       source: __MODULE__,
       details: %{timestamp: value}
     )}
  end

  defp error_to_map(nil), do: nil

  defp error_to_map(%Error{} = error) do
    %{
      kind: error.kind,
      message: error.message,
      details: error.details,
      source: error.source,
      retryable?: error.retryable?,
      metadata: error.metadata
    }
    |> reject_nil_values()
  end

  defp error_to_map(error), do: %{message: inspect(error), kind: :unexpected}

  defp error_from_map(nil), do: nil

  defp error_from_map(error) when is_map(error) do
    Error.new(
      error_kind(field(error, :kind)),
      to_string(field(error, :message) || "objective error"),
      details: field(error, :details) || %{},
      source: field(error, :source),
      retryable?: field(error, :retryable?) in [true, "true"],
      metadata: field(error, :metadata) || %{}
    )
  end

  defp error_from_map(error), do: Error.from_reason(error, source: __MODULE__)

  defp error_kind(kind) when kind in [:validation, :provider, :timeout, :unexpected], do: kind
  defp error_kind("validation"), do: :validation
  defp error_kind("provider"), do: :provider
  defp error_kind("timeout"), do: :timeout
  defp error_kind("unexpected"), do: :unexpected
  defp error_kind(_kind), do: :unexpected

  defp budget_error?(%Error{} = error) do
    error.kind == :timeout or String.contains?(String.downcase(error.message), "budget")
  end

  defp latest_error_message(%__MODULE__{latest_error: %Error{} = error}), do: error.message
  defp latest_error_message(_session), do: "objective failed"

  defp latest_error_field(%Error{} = error, key), do: Map.get(error, key)
  defp latest_error_field(_error, _key), do: nil

  defp normalize_error(%Error{} = error), do: error

  defp normalize_error(error) do
    Error.from_reason(error, source: __MODULE__, message: inspect(error))
  end

  defp error_summary(%Error{} = error) do
    %{kind: error.kind, message: error.message, details: error.details}
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(_other), do: %{}

  defp non_blank_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_blank_string(_value), do: nil

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
