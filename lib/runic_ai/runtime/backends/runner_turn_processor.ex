defmodule RunicAI.Runtime.Backends.RunnerTurnProcessor do
  @moduledoc """
  Runner-backed backend for external-state turn-processor recipe sessions.

  Each advancement is executed by a short-lived `Runic.Runner` workflow, then
  projected back into the canonical harness session snapshot.
  """

  @behaviour RunicAI.Runtime.Backend

  alias RunicAI.Error
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.Runtime.Backends.RunnerSupport
  alias RunicAI.Runtime.SessionSpec

  defstruct [:spec, :session, :runner, run_count: 0, metadata: %{}]

  @type t :: %__MODULE__{
          spec: SessionSpec.t(),
          session: Session.t(),
          runner: atom(),
          run_count: non_neg_integer(),
          metadata: map()
        }

  @impl true
  def init(%SessionSpec{kind: :turn_processor} = spec) do
    runner = RunnerSupport.runner_name(spec)

    session =
      spec.driver.new_session(spec.recipe,
        id: spec.id,
        recipe_opts: spec.recipe_opts,
        policy: spec.policy,
        metadata: spec.metadata
      )

    {:ok,
     %__MODULE__{
       spec: spec,
       session: session,
       runner: runner,
       metadata: %{backend: :runner_turn_processor, runner: runner}
     }}
  end

  def init(%SessionSpec{} = spec) do
    {:error,
     Error.validation("RunnerTurnProcessor requires a turn-processor session spec",
       source: __MODULE__,
       details: %{kind: spec.kind}
     )}
  end

  @impl true
  def submit(%__MODULE__{session: session, spec: spec} = state, input) do
    {:ok, %{state | session: spec.driver.submit(session, input)}}
  end

  @impl true
  def advance(%__MODULE__{} = state, %Policy{} = policy), do: run_once(state, :advance, policy)

  @impl true
  def drain(%__MODULE__{} = state, %Policy{} = policy), do: run_once(state, :drain, policy)

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

  defp run_once(%__MODULE__{} = state, operation, %Policy{} = policy) do
    workflow_id = {RunicAI.Runtime, state.spec.id, operation, state.run_count + 1}
    workflow = RunnerSupport.session_operation_workflow(:runic_ai_runner_turn_processor_session)

    with :ok <-
           RunnerSupport.start_workflow(
             state.runner,
             workflow_id,
             workflow,
             state.spec.runner_opts
           ),
         {:ok, session} <-
           RunnerSupport.run_session_operation(
             state.runner,
             workflow_id,
             operation,
             state.session,
             policy,
             state.spec.runner_opts
           ) do
      _ = Runic.Runner.stop(state.runner, workflow_id, persist: true)
      {:ok, %{state | session: session, run_count: state.run_count + 1}}
    end
  end
end
