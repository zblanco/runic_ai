defmodule RunicAI.Integrated.RuntimeStateTest do
  use ExUnit.Case, async: true

  alias RunicAI.Integrated.PendingWork
  alias RunicAI.Integrated.RuntimeState
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Integrated.Signal
  alias RunicAI.Wait

  test "queues signals for only the targeted agent lane" do
    runtime =
      RuntimeState.new!(
        agents: [
          session("alpha"),
          session("beta")
        ],
        metadata: %{default_agent_id: "alpha"}
      )

    updated_runtime =
      RuntimeState.reduce!(
        runtime,
        Signal.new!(:receive_turn, agent_id: "alpha", payload: "hello")
      )

    assert {:ok, ready_bundle} = RuntimeState.next_ready(updated_runtime)
    assert ready_bundle.agent_id == "alpha"
    assert ready_bundle.signal.payload == "hello"
    assert updated_runtime.agents["alpha"].status == :queued
    assert updated_runtime.agents["beta"].status == :idle
    assert updated_runtime.agents["beta"].inbox == []
  end

  test "registers resume and scheduled wake indexes from paused session updates" do
    wait =
      Wait.new!(
        :guard,
        resume_key: "wait:alpha",
        until: DateTime.add(DateTime.utc_now(), 300, :second)
      )

    paused_session =
      session("alpha")
      |> SessionState.with_pending_work!(
        PendingWork.new!(:wait, request: wait, checkpoint: :pre_tool),
        status: :waiting
      )

    runtime = RuntimeState.new!(agents: [paused_session])

    assert runtime.resume_index["wait:alpha"] == "alpha"
    assert runtime.scheduled["wait:alpha"].agent_id == "alpha"

    resumed_runtime =
      RuntimeState.reduce!(
        runtime,
        Signal.new!(:wake, metadata: %{resume_key: "wait:alpha"})
      )

    assert resumed_runtime.agents["alpha"].status == :queued
    assert [%Signal{kind: :wake}] = resumed_runtime.agents["alpha"].inbox
  end

  defp session(agent_id) do
    SessionState.new!(
      agent_id,
      agent_state: RunicAI.Agent.State.new!(),
      metadata: %{turn_defaults: %{model: "test:model", llm_opts: []}}
    )
  end
end
