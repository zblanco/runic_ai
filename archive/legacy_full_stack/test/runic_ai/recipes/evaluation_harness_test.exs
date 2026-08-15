defmodule RunicAI.Recipes.EvaluationHarnessTest do
  use ExUnit.Case, async: true

  alias RunicAI.Evaluation.Case
  alias RunicAI.Harness.Policy
  alias RunicAI.Phase7Fixtures
  alias RunicAI.Recipes.ChatAgentKernel
  alias RunicAI.Recipes.EvaluationHarness
  alias RunicAI.Recipes.IntegratedToolAgent

  test "evaluates turn-processor recipes and returns aggregate regression metrics" do
    run =
      EvaluationHarness.run(
        [
          Case.new!(
            id: "hello-case",
            input: %{user: "say hello"},
            expected: [{:contains_text, "hello"}]
          ),
          Case.new!(
            id: "goodbye-case",
            input: %{user: "say goodbye"},
            expected: [{:contains_text, "goodbye"}]
          )
        ],
        recipe: ChatAgentKernel,
        recipe_opts: [
          model: "test:model",
          client:
            Phase7Fixtures.keyword_reply_client([
              {"hello", "hello there"},
              {"goodbye", "goodbye now"}
            ])
        ],
        policy: Policy.new!(capture_policy: [mode: :summary])
      )

    assert length(run.results) == 2
    assert Enum.all?(run.results, &(&1.status == :passed))
    assert run.aggregate.cases_passed == 2
    assert run.aggregate.cases_failed == 0
    assert run.aggregate.llm_calls == 2.0
    assert run.aggregate.tool_calls == 0.0
    assert run.aggregate.overall_score == 1.0
    assert match?(%DateTime{}, run.started_at)
    assert match?(%DateTime{}, run.completed_at)
  end

  test "selects the most advanced run snapshot and aggregate state for integrated recipes" do
    workflow =
      EvaluationHarness.run_workflow(
        [
          Case.new!(
            id: "paris-case",
            input: %{user: "What's the weather in Paris?"},
            expected: [
              {:contains_text, "Paris is sunny."},
              {:tool_called, "get_weather"}
            ]
          ),
          Case.new!(
            id: "berlin-case",
            input: %{user: "What's the weather in Berlin?"},
            expected: [
              {:contains_text, "Berlin is sunny."},
              {:tool_called, "get_weather"}
            ]
          )
        ],
        recipe: IntegratedToolAgent,
        recipe_opts: [
          default_agent_id: "agent",
          model: "test:model",
          registry: [Phase7Fixtures.weather_tool()],
          client: Phase7Fixtures.weather_client()
        ],
        policy: Policy.new!(capture_policy: [mode: :summary])
      )

    run = EvaluationHarness.latest_run(workflow)
    aggregate_state = EvaluationHarness.latest_aggregate_state(workflow)
    aggregate = EvaluationHarness.latest_aggregate(workflow)

    assert length(EvaluationHarness.latest_cases(workflow)) == 2
    assert length(EvaluationHarness.latest_results(workflow)) == 2
    assert length(run.results) == 2
    assert Enum.all?(run.results, &(&1.status == :passed))
    assert aggregate_state.cases_passed == 2
    assert aggregate.cases_passed == 2
    assert aggregate.tool_calls == 2.0
    assert aggregate.llm_calls == 4.0
    assert aggregate.overall_score == 1.0
  end
end
