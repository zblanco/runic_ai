defmodule RunicAI.Coding.Session do
  @moduledoc """
  Session helpers for running the standard coding agent through RunicAI runtime.
  """

  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.AgentState
  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Workspace
  alias RunicAI.Harness.Integrated
  alias RunicAI.Harness.Session, as: HarnessSession
  alias RunicAI.Runtime.SessionSpec

  @spec spec(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: SessionSpec.t()
  def spec(workspace_input, opts \\ []) when is_list(opts) do
    workspace = Workspace.from_input!(workspace_input)

    SessionSpec.new!(
      id: Keyword.get(opts, :id, "coding:session:#{System.unique_integer([:positive])}"),
      recipe: Agent,
      kind: :integrated,
      recipe_opts: recipe_opts(workspace, opts),
      backend: Keyword.get(opts, :backend),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      runner_name: Keyword.get(opts, :runner_name),
      runner_opts: Keyword.get(opts, :runner_opts, []),
      runner_workflow_id: Keyword.get(opts, :runner_workflow_id),
      scheduler: Keyword.get(opts, :scheduler),
      scheduler_opts: Keyword.get(opts, :scheduler_opts, []),
      policy: Keyword.get(opts, :policy),
      metadata:
        Map.merge(
          %{coding_agent?: true, workspace_root: workspace.root},
          Keyword.get(opts, :metadata, %{})
        )
    )
  end

  @spec new(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: HarnessSession.t()
  def new(workspace_input, opts \\ []) when is_list(opts) do
    workspace = Workspace.from_input!(workspace_input)

    Integrated.new_session(Agent,
      id: Keyword.get(opts, :id),
      recipe_opts: recipe_opts(workspace, opts),
      policy: Keyword.get(opts, :policy),
      metadata:
        Map.merge(
          %{coding_agent?: true, workspace_root: workspace.root},
          Keyword.get(opts, :metadata, %{})
        )
    )
  end

  @spec submit(HarnessSession.t(), term(), keyword()) :: HarnessSession.t()
  def submit(%HarnessSession{} = session, input, opts \\ []) do
    session
    |> Integrated.submit(input)
    |> Integrated.drain(Keyword.get(opts, :policy))
  end

  @spec resume(HarnessSession.t(), term(), keyword()) :: HarnessSession.t()
  def resume(%HarnessSession{} = session, decision_or_signal, opts \\ []) do
    submit(session, decision_or_signal, opts)
  end

  @spec snapshot(HarnessSession.t(), keyword()) :: map()
  def snapshot(%HarnessSession{} = session, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "coding")
    runtime = session.snapshot

    session_state =
      case runtime do
        %{agents: agents} when is_map(agents) ->
          Map.get(agents, to_string(agent_id))

        %{agents: agents} when is_list(agents) ->
          Enum.find(agents, &(&1.agent.id == to_string(agent_id)))

        _other ->
          nil
      end

    %{
      version: 1,
      session_id: session.id,
      status: session.status,
      agent_id: to_string(agent_id),
      summary: AgentState.summary(session_state, agent_id),
      trace_events: AgentState.trace_events(session_state, agent_id),
      trajectory: session.trajectory,
      runtime_state: runtime,
      outputs: session.outputs,
      recorded_at: DateTime.utc_now()
    }
  end

  @spec persist_snapshot(HarnessSession.t(), term(), keyword()) ::
          {:ok, String.t() | nil} | {:error, RunicAI.Error.t()}
  def persist_snapshot(%HarnessSession{} = session, persistence, opts \\ []) do
    artifact = %{
      kind: :coding_session_snapshot,
      content: snapshot(session, opts),
      metadata: %{session_id: session.id}
    }

    with {:ok, ref} <- Persistence.put_artifact(persistence, artifact) do
      _ =
        Persistence.record_event(persistence, %{
          kind: :coding_session_snapshot,
          status: session.status,
          metadata: %{session_id: session.id, artifact_ref: ref}
        })

      {:ok, ref}
    end
  end

  @spec interruption_summary(HarnessSession.t(), keyword()) :: map()
  def interruption_summary(%HarnessSession{} = session, opts \\ []) do
    snapshot = snapshot(session, opts)

    %{
      status: :interrupted,
      session_id: session.id,
      summary: snapshot.summary,
      pending?: session.status in [:queued, :running, :waiting, :review],
      interrupted_at: DateTime.utc_now()
    }
  end

  defp recipe_opts(%Workspace{} = workspace, opts) do
    opts
    |> Keyword.drop([
      :id,
      :backend,
      :backend_opts,
      :runner_name,
      :runner_opts,
      :runner_workflow_id,
      :scheduler,
      :scheduler_opts,
      :policy,
      :metadata
    ])
    |> Keyword.put(:workspace, workspace)
  end
end
