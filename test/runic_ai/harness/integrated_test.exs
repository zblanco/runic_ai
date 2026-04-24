defmodule RunicAI.Harness.IntegratedTest do
  use ExUnit.Case, async: true

  alias RunicAI.Control.GuardDecision
  alias RunicAI.Harness.Integrated
  alias RunicAI.Harness.Policy
  alias RunicAI.Phase7Fixtures
  alias RunicAI.Recipes.IntegratedChatAgent
  alias RunicAI.Recipes.IntegratedToolAgent
  alias RunicAI.ReviewDecision
  alias RunicAI.Testing.TraceAssertions
  alias RunicAI.Trace.Sinks.InMemory

  test "drives multi-turn integrated chat sessions while preserving workflow-owned runtime" do
    policy = test_policy()

    session =
      Integrated.new_session(IntegratedChatAgent,
        recipe_opts: [
          default_agent_id: "chat",
          model: "test:model",
          system: "You are concise",
          client: Phase7Fixtures.color_memory_client()
        ],
        policy: policy
      )
      |> Integrated.submit(%{
        user: "My favorite color is vermilion. Reply only with noted."
      })
      |> Integrated.drain(policy)
      |> Integrated.submit(%{
        user: "What color did I say was my favorite? Reply with one word."
      })
      |> Integrated.drain(policy)

    lane = session.snapshot.agents["chat"]

    assert session.status == :idle
    assert lane.agent_state.conversation.turns == 2
    assert List.last(session.outputs).latest_reply_text == "vermilion"
    assert session.measurements.runs == 2
    assert session.measurements.turns == 2
    assert session.measurements.emissions == 2
    assert TraceAssertions.count(session.trajectory, :emission) == 2
    assert length(in_memory_events(session)) == length(session.trajectory.events)
  end

  test "accepts typed review decisions when resuming an integrated tool lane" do
    policy = test_policy()

    session =
      Integrated.new_session(IntegratedToolAgent,
        recipe_opts: [
          default_agent_id: "agent",
          model: "test:model",
          registry: [Phase7Fixtures.weather_tool()],
          client: Phase7Fixtures.weather_client(),
          pre_tool_guard: fn _request -> :review end
        ],
        policy: policy
      )
      |> Integrated.submit(%{user: "What's the weather in Paris?"})
      |> Integrated.drain(policy)

    review_request = List.last(session.outputs).latest_review_request

    assert session.status == :review
    assert review_request.checkpoint == :pre_tool
    assert TraceAssertions.review_requested?(session.trajectory)

    session =
      session
      |> Integrated.submit(ReviewDecision.new!(review_request.resume_key, :approved))
      |> Integrated.drain(policy)

    assert session.status == :idle
    assert List.last(session.outputs).latest_reply_text == "Paris is sunny."
    assert session.snapshot.agents["agent"].pending_work == nil
    assert TraceAssertions.tool_called?(session.trajectory, "get_weather")
  end

  test "routes wake signals through the integrated driver and resumes the correct lane" do
    policy = test_policy()

    session =
      Integrated.new_session(IntegratedToolAgent,
        recipe_opts: [
          default_agent_id: "agent",
          model: "test:model",
          registry: [Phase7Fixtures.weather_tool()],
          client: Phase7Fixtures.weather_client(),
          pre_tool_guard: fn _request ->
            GuardDecision.wait!(:hold,
              metadata: %{until: DateTime.add(DateTime.utc_now(), 60, :second)}
            )
          end
        ],
        policy: policy
      )
      |> Integrated.submit(%{user: "What's the weather in Paris?"})
      |> Integrated.drain(policy)

    wait = List.last(session.outputs).latest_wait

    assert session.status == :waiting
    assert wait.reason == :hold
    assert TraceAssertions.wait_registered?(session.trajectory)

    session =
      session
      |> Integrated.submit(%{wake: %{resume_key: wait.resume_key}})
      |> Integrated.drain(policy)

    assert session.status == :idle
    assert List.last(session.outputs).latest_reply_text == "Paris is sunny."
    assert session.measurements.waits == 1
  end

  defp test_policy do
    Policy.new!(
      capture_policy: [mode: :summary],
      sinks: [InMemory]
    )
  end

  defp in_memory_events(session) do
    session.trace_sinks
    |> Enum.find_value(fn
      %{module: InMemory, state: state} -> InMemory.events(state)
      _other -> nil
    end)
    |> Kernel.||([])
  end
end
