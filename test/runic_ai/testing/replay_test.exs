defmodule RunicAI.Testing.ReplayTest do
  use ExUnit.Case, async: true

  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.TurnProcessor
  alias RunicAI.Phase7Fixtures
  alias RunicAI.Recipes.ConversationalToolAgent
  alias RunicAI.Retrieval.Result, as: RetrievalResult
  alias RunicAI.Testing.Replay
  alias RunicAI.Testing.TraceAssertions
  alias RunicAI.Trace.Event
  alias RunicAI.Trace.Trajectory

  test "reconstructs llm and tool doubles from a captured tool trajectory" do
    policy = Policy.new!(capture_policy: [mode: :replay])

    source_session =
      TurnProcessor.run(
        ConversationalToolAgent,
        %{user: "What's the weather in Paris?"},
        recipe_opts: [
          model: "test:model",
          registry: [Phase7Fixtures.weather_tool()],
          client: Phase7Fixtures.weather_client()
        ],
        policy: policy
      )

    trajectory = source_session.trajectory

    replay_session =
      TurnProcessor.run(
        ConversationalToolAgent,
        %{user: "What's the weather in Paris?"},
        recipe_opts: [
          model: "test:model",
          registry: Replay.tool_registry(trajectory, [Phase7Fixtures.weather_tool()]),
          client: Replay.llm_client(trajectory)
        ],
        policy: policy
      )

    assert List.last(replay_session.outputs).reply_text == "Paris is sunny."
    assert TraceAssertions.tool_called?(replay_session.trajectory, "get_weather")
  end

  test "builds retrieval providers from retrieval result events" do
    retrieval_result = RetrievalResult.empty(text: "weather question")

    trajectory =
      Trajectory.new!(
        id: "trace:retrieval",
        session_kind: :turn_processor,
        recipe: :retrieval_demo,
        metadata: %{}
      )
      |> Trajectory.append_event!(
        Event.new!(:retrieval_result, metadata: %{}, output: retrieval_result)
      )

    provider = Replay.retrieval_provider(trajectory)

    assert {:ok, ^retrieval_result} = provider.("weather question", [])
  end
end
