defmodule RunicAI.RLM.WorkflowExecutor do
  @moduledoc """
  Minimal Runic executor for RLM workflows.

  This keeps execution on Runic's prepare/execute/apply path while preserving
  `RunicAI.Error` values for repair loops.
  """

  alias Runic.Workflow
  alias Runic.Workflow.PolicyDriver
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.SchedulerPolicy
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentError

  @spec run(Workflow.t(), term(), keyword()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def run(%Workflow{} = workflow, input, opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :execution_mode, :three_phase) do
      mode when mode in [:runner, :runic_runner] ->
        run_with_runner(workflow, input, opts)

      _mode ->
        workflow
        |> Workflow.plan_eagerly(input)
        |> run_until_satisfied(opts)
    end
  end

  @spec run_with_runner(Workflow.t(), term(), keyword()) ::
          {:ok, Workflow.t()} | {:error, Error.t()}
  def run_with_runner(%Workflow{} = workflow, input, opts \\ []) when is_list(opts) do
    runner = Keyword.get(opts, :runner_name, RunicAI.RLM.WorkflowExecutor.Runner)
    workflow_id = Keyword.get(opts, :workflow_id, {:rlm, System.unique_integer([:positive])})

    with :ok <- ensure_runner(runner),
         {:ok, _pid} <- Runic.Runner.start_workflow(runner, workflow_id, workflow),
         :ok <- Runic.Runner.run(runner, workflow_id, input, runner_opts(opts)),
         {:ok, workflow} <- wait_for_runner_workflow(runner, workflow_id, opts) do
      _ =
        Runic.Runner.stop(runner, workflow_id,
          persist: Keyword.get(opts, :persist_runner?, false)
        )

      {:ok, workflow}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, {:already_started, _pid}} ->
        {:error,
         Error.validation("Runic runner workflow id is already active",
           source: __MODULE__,
           details: %{workflow_id: workflow_id}
         )}

      {:error, reason} ->
        {:error,
         Error.from_reason(reason, source: __MODULE__, details: %{workflow_id: workflow_id})}
    end
  end

  defp run_until_satisfied(%Workflow{} = workflow, opts) do
    if Workflow.is_runnable?(workflow) do
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      runnables
      |> execute_runnables(workflow, opts)
      |> apply_or_error(workflow, opts)
    else
      {:ok, workflow}
    end
  end

  defp execute_runnables(runnables, workflow, opts) do
    policies = effective_policies(workflow, opts)
    driver_opts = driver_opts(opts)
    sink = event_sink(workflow)

    if Keyword.get(opts, :async, false) do
      execute_runnables_async(runnables, policies, driver_opts, sink, opts)
    else
      Enum.map(runnables, &execute_runnable(&1, policies, driver_opts, sink))
    end
  end

  defp execute_runnables_async(runnables, policies, driver_opts, sink, opts) do
    global_max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, :infinity)

    runnables
    |> Enum.group_by(&node_name(&1.node))
    |> Enum.flat_map(fn {_node, group} ->
      max_concurrency =
        group
        |> Enum.map(&policy_max_concurrency(&1, policies))
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> global_max_concurrency end)
        |> min(global_max_concurrency)

      group
      |> Task.async_stream(&execute_runnable(&1, policies, driver_opts, sink),
        max_concurrency: max_concurrency,
        timeout: timeout
      )
      |> Enum.map(fn
        {:ok, runnable} -> runnable
        {:exit, reason} -> Runnable.fail(%Runnable{}, {:exit, reason})
      end)
    end)
  end

  defp execute_runnable(%Runnable{} = runnable, policies, driver_opts, sink) do
    policy = resolved_policy(runnable, policies)
    started_at = System.monotonic_time(:millisecond)
    emit_runnable_stage(sink, :node_started, :running, runnable, policy, started_at)

    {executed, policy_events} =
      runnable
      |> PolicyDriver.execute(policy, Keyword.put(driver_opts, :emit_events, true))
      |> normalize_policy_result()

    completed_at = System.monotonic_time(:millisecond)

    emit_runnable_stage(
      sink,
      if(executed.status == :failed, do: :node_failed, else: :node_completed),
      if(executed.status == :failed, do: :error, else: :ok),
      executed,
      policy,
      completed_at,
      duration_ms: completed_at - started_at,
      output: preview(output_value(executed)),
      policy_events: policy_events
    )

    executed
  end

  defp normalize_policy_result({%Runnable{} = runnable, events}) when is_list(events),
    do: {runnable, events}

  defp normalize_policy_result(%Runnable{} = runnable), do: {runnable, []}

  defp apply_or_error(executed, workflow, opts) do
    case Enum.find(executed, &(&1.status == :failed)) do
      nil ->
        executed
        |> Enum.reduce(workflow, fn runnable, workflow ->
          Workflow.apply_runnable(workflow, runnable)
        end)
        |> run_until_satisfied(opts)

      %Runnable{} = runnable ->
        {:error, error_from_runnable(runnable)}
    end
  end

  defp error_from_runnable(%Runnable{error: %ComponentError{} = component_error} = runnable) do
    %Error{} = error = component_error.error

    %Error{
      error
      | details:
          error.details
          |> Map.merge(%{
            component_id: component_error.component_id,
            component_type: component_error.component_type,
            runnable_id: runnable.id,
            node: node_name(runnable.node)
          })
    }
  end

  defp error_from_runnable(%Runnable{} = runnable) do
    Error.from_reason(runnable.error,
      source: __MODULE__,
      details: %{
        runnable_id: runnable.id,
        node: node_name(runnable.node)
      }
    )
  end

  defp node_name(%{name: name}) when not is_nil(name), do: name
  defp node_name(%{hash: hash}) when not is_nil(hash), do: hash
  defp node_name(node), do: inspect(node)

  defp effective_policies(%Workflow{scheduler_policies: base}, opts) do
    runtime = Keyword.get(opts, :scheduler_policies)
    mode = Keyword.get(opts, :scheduler_policies_mode, :merge)

    case {runtime, mode} do
      {nil, _mode} -> base
      {policies, :replace} when is_list(policies) -> policies
      {policies, :merge} when is_list(policies) -> SchedulerPolicy.merge_policies(policies, base)
      _other -> base
    end
  end

  defp driver_opts(opts) do
    opts
    |> Keyword.take([:deadline_at])
  end

  defp policy_max_concurrency(%Runnable{} = runnable, policies) do
    runnable
    |> resolved_policy(policies)
    |> Map.get(:executor_opts, [])
    |> Keyword.get(:max_concurrency)
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> nil
    end
  end

  defp resolved_policy(%Runnable{} = runnable, policies) do
    base = SchedulerPolicy.resolve(runnable, policies)

    case component_policy_map(runnable) do
      policy when is_map(policy) ->
        SchedulerPolicy.new(Map.merge(Map.from_struct(base), policy))

      _other ->
        base
    end
  end

  defp component_policy_map(%Runnable{} = runnable) do
    context = get_in(runnable, [Access.key(:context), Access.key(:run_context)]) || %{}
    global = get(context, :_global, %{})

    policies =
      get(global, :component_policies_by_id, get(context, :component_policies_by_id, %{}))

    component = component_context(runnable)
    id = get(component, :id, get(component, :component_id, nil))

    get(policies, id, get(policies, to_string(id), nil))
  end

  defp event_sink(%Workflow{} = workflow) do
    workflow
    |> Workflow.get_run_context()
    |> case do
      %{_global: %{event_sink: sink}} when is_function(sink, 1) -> sink
      %{"_global" => %{"event_sink" => sink}} when is_function(sink, 1) -> sink
      _other -> nil
    end
  rescue
    _exception -> nil
  end

  defp emit_runnable_stage(sink, stage, status, runnable, policy, at, extra \\ [])

  defp emit_runnable_stage(nil, _stage, _status, _runnable, _policy, _at, _extra), do: :ok

  defp emit_runnable_stage(sink, stage, status, %Runnable{} = runnable, policy, at, extra)
       when is_function(sink, 1) do
    sink.(%{
      run_id: runnable_run_id(runnable),
      stage: stage,
      status: status,
      data:
        %{
          runnable: runnable_summary(runnable, policy),
          node: node_name(runnable.node),
          input: preview(input_value(runnable)),
          monotonic_ms: at
        }
        |> Map.merge(Map.new(extra))
        |> maybe_put_error(runnable)
    })

    :ok
  rescue
    _exception -> :ok
  end

  defp runnable_summary(%Runnable{} = runnable, %SchedulerPolicy{} = policy) do
    component = component_context(runnable)

    %{
      id: runnable.id,
      node: node_name(runnable.node),
      node_hash: Map.get(runnable.node, :hash),
      component_id: get(component, :id, get(component, :component_id, nil)),
      component_type: get(component, :type, get(component, :component_type, nil)),
      status: runnable.status,
      policy: %{
        max_retries: policy.max_retries,
        timeout_ms: policy.timeout_ms,
        execution_mode: policy.execution_mode,
        on_failure: policy.on_failure,
        executor_opts: Map.new(policy.executor_opts || [])
      }
    }
  end

  defp component_context(%Runnable{} = runnable) do
    meta = get_in(runnable, [Access.key(:context), Access.key(:meta_context)]) || %{}

    cond do
      is_map(get(meta, :component, nil)) ->
        get(meta, :component, nil)

      is_map(input_value(runnable)) ->
        %{
          id: get(input_value(runnable), :component_id, nil),
          type: get(input_value(runnable), :component_type, nil)
        }

      true ->
        %{}
    end
  end

  defp runnable_run_id(%Runnable{} = runnable) do
    meta = get_in(runnable, [Access.key(:context), Access.key(:meta_context)]) || %{}
    run_context = get_in(runnable, [Access.key(:context), Access.key(:run_context)]) || %{}
    global_context = get(run_context, :_global, %{})

    base_context =
      get(
        global_context,
        :base_context,
        get(run_context, :base_context, get(meta, :base_context, %{}))
      )

    base_context
    |> get(:metadata, %{})
    |> get(:run_id, nil)
  end

  defp input_value(%Runnable{input_fact: %{value: value}}), do: value
  defp input_value(_runnable), do: nil

  defp output_value(%Runnable{result: %{value: value}}), do: value
  defp output_value(_runnable), do: nil

  defp maybe_put_error(data, %Runnable{status: :failed} = runnable) do
    Map.put(data, :error, preview(runnable.error))
  end

  defp maybe_put_error(data, _runnable), do: data

  defp preview(value) when is_binary(value) do
    if String.length(value) > 500, do: String.slice(value, 0, 500) <> "...", else: value
  end

  defp preview(value), do: inspect(value, limit: 12, printable_limit: 500)

  defp ensure_runner(runner) do
    case Runic.Runner.start_link(name: runner) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp runner_opts(opts) do
    opts
    |> Keyword.take([:run_context, :scheduler_policies, :scheduler_policies_mode])
  end

  defp wait_for_runner_workflow(runner, workflow_id, opts) do
    deadline =
      System.monotonic_time(:millisecond) +
        case Keyword.get(opts, :timeout, :infinity) do
          :infinity -> 30_000
          timeout when is_integer(timeout) and timeout > 0 -> timeout
          _other -> 30_000
        end

    do_wait_for_runner_workflow(runner, workflow_id, deadline)
  end

  defp do_wait_for_runner_workflow(runner, workflow_id, deadline) do
    with {:ok, workflow} <- Runic.Runner.get_workflow(runner, workflow_id) do
      cond do
        not Workflow.is_runnable?(workflow) and Workflow.raw_productions(workflow) != [] ->
          {:ok, workflow}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, :timeout}

        true ->
          Process.sleep(10)
          do_wait_for_runner_workflow(runner, workflow_id, deadline)
      end
    end
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp get(_map, _key, default), do: default
end
