defmodule RunicAI.Runtime.Backends.RunnerIntegrated do
  @moduledoc """
  Runner-backed backend for integrated, workflow-owned recipe sessions.

  The public state remains a `RunicAI.Harness.Session`, while the backend keeps
  one long-lived `Runic.Runner` workflow id for managed execution.
  """

  @behaviour RunicAI.Runtime.Backend

  alias RunicAI.Error
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.Runtime.Backends.RunnerSupport
  alias RunicAI.Runtime.SessionSpec

  defstruct [:spec, :session, :runner, :workflow_id, run_count: 0, metadata: %{}]

  @type t :: %__MODULE__{
          spec: SessionSpec.t(),
          session: Session.t(),
          runner: atom(),
          workflow_id: term(),
          run_count: non_neg_integer(),
          metadata: map()
        }

  @impl true
  def init(%SessionSpec{kind: :integrated} = spec) do
    runner = RunnerSupport.runner_name(spec)
    workflow_id = RunnerSupport.workflow_id(spec, :integrated)
    workflow = RunnerSupport.session_operation_workflow(:runic_ai_runner_integrated_session)

    with :ok <- RunnerSupport.start_workflow(runner, workflow_id, workflow, spec.runner_opts) do
      session =
        case RunnerSupport.latest_session(runner, workflow_id) do
          {:ok, %Session{} = session} ->
            session

          {:error, _error} ->
            spec.driver.new_session(spec.recipe,
              id: spec.id,
              recipe_opts: spec.recipe_opts,
              policy: spec.policy,
              metadata: spec.metadata
            )
        end

      {:ok,
       %__MODULE__{
         spec: spec,
         session: session,
         runner: runner,
         workflow_id: workflow_id,
         metadata: %{backend: :runner_integrated, runner: runner, workflow_id: workflow_id}
       }}
    end
  end

  def init(%SessionSpec{} = spec) do
    {:error,
     Error.validation("RunnerIntegrated requires an integrated session spec",
       source: __MODULE__,
       details: %{kind: spec.kind}
     )}
  end

  @impl true
  def submit(%__MODULE__{session: session, spec: spec} = state, input) do
    {:ok, %{state | session: spec.driver.submit(session, input)}}
  end

  @impl true
  def advance(%__MODULE__{} = state, %Policy{} = policy),
    do: run_operation(state, :advance, policy)

  @impl true
  def drain(%__MODULE__{} = state, %Policy{} = policy), do: run_operation(state, :drain, policy)

  @impl true
  def session(%__MODULE__{session: session}), do: session

  @impl true
  def snapshot(%__MODULE__{session: session}), do: session.snapshot

  @impl true
  def outputs(%__MODULE__{session: session}), do: session.outputs

  @impl true
  def trajectory(%__MODULE__{session: session}), do: session.trajectory

  @impl true
  def shutdown(%__MODULE__{}), do: :ok

  defp run_operation(%__MODULE__{} = state, operation, %Policy{} = policy) do
    with {:ok, session} <-
           RunnerSupport.run_session_operation(
             state.runner,
             state.workflow_id,
             operation,
             state.session,
             policy,
             state.spec.runner_opts
           ) do
      {:ok, %{state | session: session, run_count: state.run_count + 1}}
    end
  end
end
