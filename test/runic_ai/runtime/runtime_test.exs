defmodule RunicAI.RuntimeTest do
  use ExUnit.Case, async: false

  alias RunicAI.Control.GuardDecision
  alias RunicAI.Harness.Policy
  alias RunicAI.Phase7Fixtures
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.Recipes.GuardedOperatorToolAgent
  alias RunicAI.Recipes.IntegratedChatAgent
  alias RunicAI.Runtime
  alias RunicAI.Testing.TraceAssertions

  test "runs an in-memory supervised turn-processor session" do
    id = unique_id("runtime-chat")
    {:ok, handle} = start_chat_session(id, backend: :in_memory)
    on_exit(fn -> Runtime.stop(handle) end)

    assert :ok = Runtime.subscribe(handle)
    assert {:ok, queued} = Runtime.submit(handle, %{user: "My favorite color is vermilion."})
    assert queued.status == :queued

    assert {:ok, session} = Runtime.drain(handle)

    assert session.id == id
    assert session.status == :idle
    assert List.last(session.outputs).reply_text == "noted"
    assert TraceAssertions.count(Runtime.trajectory(handle), :turn_completed) == 1
    assert_receive {:runic_ai_runtime, ^id, :output, %{reply_text: "noted"}}, 500
  end

  test "runs an external-state recipe through the Runner turn-processor backend" do
    id = unique_id("runtime-runner-turn")
    {:ok, handle} = start_chat_session(id, backend: :runner_turn_processor)
    on_exit(fn -> Runtime.stop(handle) end)

    {:ok, session} =
      handle
      |> Runtime.submit(%{user: "My favorite color is vermilion."})
      |> then(fn {:ok, _session} -> Runtime.drain(handle) end)

    assert session.status == :idle
    assert List.last(session.outputs).reply_text == "noted"
    assert session.snapshot.conversation.turns == 1
  end

  test "runs an integrated recipe through one long-lived Runner backend workflow" do
    id = unique_id("runtime-runner-integrated")

    {:ok, handle} =
      Runtime.start_session(
        id: id,
        kind: :integrated,
        recipe: IntegratedChatAgent,
        backend: :runner_integrated,
        recipe_opts: [
          default_agent_id: "chat",
          model: "test:model",
          system: "You are concise",
          client: Phase7Fixtures.color_memory_client()
        ],
        policy: test_policy()
      )

    on_exit(fn -> Runtime.stop(handle) end)

    {:ok, _queued} = Runtime.submit(handle, %{user: "My favorite color is vermilion."})
    {:ok, session} = Runtime.drain(handle)

    assert session.status == :idle
    assert List.last(session.outputs).latest_reply_text == "noted"
    assert session.snapshot.agents["chat"].agent_state.conversation.turns == 1
    assert match?({RunicAI.Runtime, ^id, :integrated}, handle.runner_workflow_id)
  end

  test "local timer scheduler wakes a waited session" do
    id = unique_id("runtime-wake")
    until = DateTime.add(DateTime.utc_now(), 30, :millisecond)

    {:ok, handle} =
      Runtime.start_session(
        id: id,
        recipe: GuardedOperatorToolAgent,
        scheduler: :local_timer,
        recipe_opts: [
          model: "test:model",
          registry: [Phase7Fixtures.weather_tool()],
          client: Phase7Fixtures.weather_client(),
          pre_tool_guard: fn _request -> GuardDecision.wait!(:hold, metadata: %{until: until}) end
        ],
        policy: test_policy()
      )

    on_exit(fn -> Runtime.stop(handle) end)
    :ok = Runtime.subscribe(handle)

    {:ok, _queued} = Runtime.submit(handle, %{user: "What's the weather in Paris?"})
    {:ok, waiting_session} = Runtime.drain(handle)

    assert waiting_session.status == :waiting
    assert wait_for_status(id, :idle, 1_000).status == :idle
    assert List.last(Runtime.outputs(handle)).reply_text == "Paris is sunny."
  end

  defp start_chat_session(id, opts) do
    Runtime.start_session(
      [
        id: id,
        recipe: ChatAgentKernel,
        recipe_opts: [
          model: "test:model",
          system: "You are concise",
          client: Phase7Fixtures.color_memory_client()
        ],
        policy: test_policy()
      ] ++ opts
    )
  end

  defp test_policy do
    Policy.new!(capture_policy: [mode: :summary])
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp wait_for_status(id, status, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_status(id, status, started_at, timeout_ms)
  end

  defp do_wait_for_status(id, status, started_at, timeout_ms) do
    remaining = timeout_ms - (System.monotonic_time(:millisecond) - started_at)

    assert remaining > 0

    receive do
      {:runic_ai_runtime, ^id, :snapshot, %{status: ^status} = session} ->
        session

      {:runic_ai_runtime, ^id, :snapshot, _session} ->
        do_wait_for_status(id, status, started_at, timeout_ms)

      _other ->
        do_wait_for_status(id, status, started_at, timeout_ms)
    after
      min(remaining, 50) ->
        do_wait_for_status(id, status, started_at, timeout_ms)
    end
  end
end
