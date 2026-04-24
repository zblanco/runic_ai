defmodule RunicAI.Harness.TurnProcessorTest do
  use ExUnit.Case, async: true

  alias RunicAI.Control.GuardDecision
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.TurnProcessor
  alias RunicAI.Phase7Fixtures
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.Recipes.GuardedOperatorToolAgent
  alias RunicAI.ResumeSignal
  alias RunicAI.ReviewDecision
  alias RunicAI.Testing.TraceAssertions
  alias RunicAI.Trace.Sinks.InMemory

  test "drives repeated conversational turns while accumulating trajectory and sink state" do
    policy = test_policy()

    session =
      TurnProcessor.new_session(ChatAgentKernel,
        recipe_opts: [
          model: "test:model",
          system: "You are concise",
          client: Phase7Fixtures.color_memory_client()
        ],
        policy: policy
      )
      |> TurnProcessor.submit(%{
        user: "My favorite color is vermilion. Reply only with noted."
      })
      |> TurnProcessor.drain(policy)
      |> TurnProcessor.submit(%{
        user: "What color did I say was my favorite? Reply with one word."
      })
      |> TurnProcessor.drain(policy)

    assert session.status == :idle
    assert session.snapshot.conversation.turns == 2
    assert List.last(session.outputs).reply_text == "vermilion"
    assert session.measurements.runs == 2
    assert session.measurements.llm_calls == 2
    assert session.measurements.turns == 2
    assert TraceAssertions.count(session.trajectory, :turn_completed) == 2
    assert TraceAssertions.reply_contains?(session.trajectory, "vermilion")
    assert length(in_memory_events(session)) == length(session.trajectory.events)
  end

  test "accepts typed review decisions when resuming a paused guarded tool session" do
    policy = test_policy()

    session =
      TurnProcessor.new_session(GuardedOperatorToolAgent,
        recipe_opts: [
          model: "test:model",
          registry: [Phase7Fixtures.weather_tool()],
          client: Phase7Fixtures.weather_client(),
          pre_tool_guard: fn _request -> :review end
        ],
        policy: policy
      )
      |> TurnProcessor.submit(%{user: "What's the weather in Paris?"})
      |> TurnProcessor.drain(policy)

    review_request = List.last(session.outputs).review_request

    assert session.status == :review
    assert review_request.checkpoint == :pre_tool
    assert TraceAssertions.review_requested?(session.trajectory)

    session =
      session
      |> TurnProcessor.submit(ReviewDecision.new!(review_request.resume_key, :approved))
      |> TurnProcessor.drain(policy)

    assert session.status == :idle
    assert List.last(session.outputs).reply_text == "Paris is sunny."
    assert session.measurements.reviews == 1
    assert session.measurements.tool_calls == 1
    assert TraceAssertions.tool_called?(session.trajectory, "get_weather")
  end

  test "accepts typed resume signals when resuming a waited guarded tool session" do
    policy = test_policy()

    session =
      TurnProcessor.new_session(GuardedOperatorToolAgent,
        recipe_opts: [
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
      |> TurnProcessor.submit(%{user: "What's the weather in Paris?"})
      |> TurnProcessor.drain(policy)

    wait = List.last(session.outputs).wait

    assert session.status == :waiting
    assert wait.reason == :hold
    assert TraceAssertions.wait_registered?(session.trajectory)

    session =
      session
      |> TurnProcessor.submit(ResumeSignal.new!(:resume, wait.resume_key))
      |> TurnProcessor.drain(policy)

    assert session.status == :idle
    assert List.last(session.outputs).reply_text == "Paris is sunny."
    assert session.measurements.waits == 1
    assert session.measurements.tool_calls == 1
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
