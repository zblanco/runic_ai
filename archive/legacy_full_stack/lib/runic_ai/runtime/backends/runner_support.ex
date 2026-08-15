defmodule RunicAI.Runtime.Backends.RunnerSupport do
  @moduledoc false

  require Runic

  alias Runic.Workflow
  alias RunicAI.Error
  alias RunicAI.Harness.Session
  alias RunicAI.Runtime.SessionSpec

  @default_runner RunicAI.Runtime.Runner

  @spec runner_name(SessionSpec.t()) :: atom()
  def runner_name(%SessionSpec{runner_name: nil}), do: @default_runner
  def runner_name(%SessionSpec{runner_name: runner_name}), do: runner_name

  @spec workflow_id(SessionSpec.t(), term()) :: term()
  def workflow_id(%SessionSpec{runner_workflow_id: nil, id: id}, suffix),
    do: {RunicAI.Runtime, id, suffix}

  def workflow_id(%SessionSpec{runner_workflow_id: workflow_id}, _suffix), do: workflow_id

  @spec session_operation_workflow(atom()) :: Workflow.t()
  def session_operation_workflow(name) do
    operation_step =
      Runic.step(
        fn
          {:advance, %Session{} = session, policy} ->
            session.driver.advance(session, policy)

          {:drain, %Session{} = session, policy} ->
            session.driver.drain(session, policy)
        end,
        name: :runtime_session_operation
      )

    Workflow.new(name: name)
    |> Workflow.add(operation_step)
  end

  @spec run_session_operation(atom(), term(), atom(), Session.t(), term(), keyword()) ::
          {:ok, Session.t()} | {:error, Error.t()}
  def run_session_operation(runner, workflow_id, operation, %Session{} = session, policy, opts) do
    case Runic.Runner.run(
           runner,
           workflow_id,
           {operation, session, policy},
           run_opts(policy, opts)
         ) do
      :ok ->
        await_latest_session(runner, workflow_id, session, opts)

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "runner session operation failed"
         )}
    end
  end

  @spec latest_session(atom(), term()) :: {:ok, Session.t()} | {:error, Error.t()}
  def latest_session(runner, workflow_id) do
    with {:ok, results} <- Runic.Runner.get_results(runner, workflow_id) do
      case results |> Enum.filter(&match?(%Session{}, &1)) |> List.last() do
        %Session{} = session ->
          {:ok, session}

        nil ->
          {:error,
           Error.unexpected("runner workflow did not produce a harness session",
             source: __MODULE__,
             details: %{runner: runner, workflow_id: workflow_id}
           )}
      end
    else
      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "could not fetch runner workflow results"
         )}
    end
  end

  defp await_latest_session(runner, workflow_id, %Session{} = submitted_session, opts) do
    timeout_ms = Keyword.get(opts, :operation_timeout_ms, 120_000)
    started_at = System.monotonic_time(:millisecond)
    do_await_latest_session(runner, workflow_id, submitted_session, started_at, timeout_ms)
  end

  defp do_await_latest_session(runner, workflow_id, submitted_session, started_at, timeout_ms) do
    case latest_session(runner, workflow_id) do
      {:ok, %Session{} = candidate} ->
        if projected?(submitted_session, candidate) do
          {:ok, candidate}
        else
          maybe_wait_for_projection(
            runner,
            workflow_id,
            submitted_session,
            started_at,
            timeout_ms
          )
        end

      {:error, _error} ->
        maybe_wait_for_projection(runner, workflow_id, submitted_session, started_at, timeout_ms)
    end
  end

  defp maybe_wait_for_projection(runner, workflow_id, submitted_session, started_at, timeout_ms) do
    if System.monotonic_time(:millisecond) - started_at >= timeout_ms do
      {:error,
       Error.timeout("runner session operation timed out before projection was available",
         source: __MODULE__,
         details: %{runner: runner, workflow_id: workflow_id, session_id: submitted_session.id}
       )}
    else
      Process.sleep(10)
      do_await_latest_session(runner, workflow_id, submitted_session, started_at, timeout_ms)
    end
  end

  defp projected?(%Session{queue: []} = submitted_session, %Session{} = candidate) do
    length(candidate.trajectory.events) >= length(submitted_session.trajectory.events)
  end

  defp projected?(%Session{} = submitted_session, %Session{} = candidate) do
    length(candidate.outputs) > length(submitted_session.outputs) or
      length(candidate.trajectory.events) > length(submitted_session.trajectory.events) or
      candidate.status == :error
  end

  @spec start_workflow(atom(), term(), Workflow.t(), keyword()) :: :ok | {:error, Error.t()}
  def start_workflow(runner, workflow_id, %Workflow{} = workflow, opts) do
    runner_opts =
      opts
      |> Keyword.put_new(:executor, :inline)
      |> Keyword.put_new(:checkpoint_strategy, :every_cycle)

    case Runic.Runner.start_workflow(runner, workflow_id, workflow, runner_opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        {:error,
         Error.from_reason(reason,
           source: __MODULE__,
           message: "could not start runner workflow"
         )}
    end
  rescue
    exception ->
      {:error,
       Error.from_exception(exception,
         source: __MODULE__,
         message: "could not start runner workflow"
       )}
  catch
    kind, reason ->
      {:error,
       Error.from_reason({kind, reason},
         source: __MODULE__,
         message: "could not start runner workflow"
       )}
  end

  defp run_opts(policy, _opts) do
    case Map.get(policy, :run_context, %{}) do
      run_context when map_size(run_context) == 0 -> []
      run_context -> [run_context: run_context]
    end
  end
end
