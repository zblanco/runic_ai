defmodule RunicAI.Steps.RLMMapLeavesTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM.LeafResult
  alias RunicAI.RLM.MaterializedArtifact
  alias RunicAI.Steps.RLMMapLeaves

  test "preserves mapper-provided leaf results" do
    artifact = MaterializedArtifact.new!("bounded text", id: "artifact:one")

    mapper = fn artifact ->
      LeafResult.new!("summary",
        id: "leaf:custom",
        artifact: artifact,
        usage: %{input_tokens: 12, output_tokens: 3},
        metadata: %{phase: :extract}
      )
    end

    assert {:ok, [%LeafResult{} = result]} = RLMMapLeaves.map_artifacts([artifact], mapper)
    assert result.id == "leaf:custom"
    assert result.artifact == artifact
    assert result.usage == %{input_tokens: 12, output_tokens: 3}
    assert result.metadata == %{phase: :extract}
  end
end
