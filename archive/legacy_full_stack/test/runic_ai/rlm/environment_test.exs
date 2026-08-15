defmodule RunicAI.RLM.EnvironmentTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM
  alias RunicAI.RLM.Environments.InMemory
  alias RunicAI.RLM.MaterializedArtifact
  alias RunicAI.RLM.SliceSet

  test "initializes the default environment from opts" do
    assert {:ok, environment} = RLM.init_environment(metadata: %{purpose: :manual_smoke})
    assert environment.metadata == %{purpose: :manual_smoke}
  end

  test "stores sources outside the prompt and materializes bounded slices" do
    {:ok, environment} = InMemory.init()

    {:ok, source_ref, environment} =
      InMemory.put_source(environment, "alpha beta gamma delta", id: "doc")

    assert source_ref.source_id == "doc"

    {:ok, slice_set} = InMemory.split(environment, source_ref, chunk_size: 10)
    assert %SliceSet{} = slice_set
    assert SliceSet.count(slice_set) == 3

    [first | _] = slice_set.slices
    assert first.offset == 0
    assert first.length == 10

    {:ok, artifact} = InMemory.materialize(environment, first, [])
    assert %MaterializedArtifact{} = artifact
    assert artifact.content == "alpha beta"
    assert [^first | _] = artifact.refs

    {:ok, artifacts} = RLM.materialize(environment, slice_set)
    assert Enum.map(artifacts, & &1.content) == ["alpha beta", " gamma del", "ta"]
  end

  test "search returns provenance-preserving slices" do
    {:ok, environment} = RLM.init_environment()
    {:ok, source_ref, environment} = RLM.put_source(environment, "one fish two fish", id: "poem")

    {:ok, matches} = RLM.search(environment, source_ref, "fish", context: 4)

    assert SliceSet.count(matches) == 2
    assert Enum.map(matches.slices, & &1.metadata.match_offset) == [4, 13]

    {:ok, first_match} = RLM.materialize(environment, hd(matches.slices))
    assert first_match.content == "one fish two"
  end
end
