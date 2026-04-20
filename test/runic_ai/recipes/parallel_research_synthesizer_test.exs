defmodule RunicAI.Recipes.ParallelResearchSynthesizerTest do
  use ExUnit.Case, async: true

  alias RunicAI.Decomposition.Role
  alias RunicAI.Recipes.ParallelResearchSynthesizer

  test "fans out research tasks and synthesizes the completed findings" do
    researcher_role =
      Role.new!(
        name: "researcher",
        kind: :workflow,
        description: "Gather one topic worth of evidence",
        builder: &__MODULE__.researcher_builder/1,
        defaults: %{}
      )

    workflow =
      ParallelResearchSynthesizer.react_until_resolution(
        [registry: [researcher_role], researcher_role: "researcher"],
        %{topics: ["atoms", "processes"], query: "Elixir runtime primitives"}
      )

    result = ParallelResearchSynthesizer.latest_result(workflow)

    assert result.output.summary =~ "atoms"
    assert result.output.summary =~ "processes"
    assert length(result.output.findings) == 2
    assert Map.has_key?(result.output.findings_by_task, "research:1")
    assert Map.has_key?(result.output.findings_by_task, "research:2")
    assert result.output.findings_by_task["research:1"].topic == "atoms"
    assert result.output.findings_by_topic["atoms"] |> length() == 1
    assert result.output.synthesis_mode == :deterministic
  end

  test "can run an optional synthesizer role over the completed findings" do
    researcher_role =
      Role.new!(
        name: "researcher",
        kind: :workflow,
        description: "Gather one topic worth of evidence",
        builder: &__MODULE__.researcher_builder/1,
        defaults: %{}
      )

    synthesizer_role =
      Role.new!(
        name: "synthesizer",
        kind: :workflow,
        description: "Synthesize research findings into one summary",
        builder: &__MODULE__.synthesizer_builder/1,
        defaults: %{}
      )

    workflow =
      ParallelResearchSynthesizer.react_until_resolution(
        [
          registry: [researcher_role, synthesizer_role],
          researcher_role: "researcher",
          synthesizer_role: "synthesizer"
        ],
        %{topics: ["atoms", "processes"], query: "Elixir runtime primitives"}
      )

    result = ParallelResearchSynthesizer.latest_result(workflow)

    assert result.output.summary == "Synthesized: atoms, processes"
    assert result.output.synthesized_summary == "Synthesized: atoms, processes"
    assert result.output.synthesis_mode == :child_role
    assert result.output.synthesizer_role == "synthesizer"
    assert result.output.deterministic_summary =~ "atoms"
  end

  test "falls back to deterministic synthesis when the synthesizer child fails" do
    researcher_role =
      Role.new!(
        name: "researcher",
        kind: :workflow,
        description: "Gather one topic worth of evidence",
        builder: &__MODULE__.researcher_builder/1,
        defaults: %{}
      )

    failing_synthesizer_role =
      Role.new!(
        name: "failing_synthesizer",
        kind: :workflow,
        description: "Fails while synthesizing",
        builder: fn _assignment -> {:error, :synthesis_failed} end,
        defaults: %{}
      )

    workflow =
      ParallelResearchSynthesizer.react_until_resolution(
        [
          registry: [researcher_role, failing_synthesizer_role],
          researcher_role: "researcher",
          synthesizer_role: "failing_synthesizer"
        ],
        %{topics: ["atoms", "processes"], query: "Elixir runtime primitives"}
      )

    result = ParallelResearchSynthesizer.latest_result(workflow)

    assert result.output.synthesis_mode == :fallback
    assert result.output.synthesizer_role == "failing_synthesizer"
    assert result.output.summary == result.output.deterministic_summary
    assert result.output.synthesizer_failure != nil
  end

  def researcher_builder(assignment) do
    topic = assignment.input.input[:topic]
    %{topic: topic, notes: "Notes about #{topic}"}
  end

  def synthesizer_builder(assignment) do
    topics =
      assignment.input.input[:topics]
      |> Enum.join(", ")

    %{summary: "Synthesized: #{topics}"}
  end
end
