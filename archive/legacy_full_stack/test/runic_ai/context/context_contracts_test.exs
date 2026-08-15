defmodule RunicAI.Context.ContextContractsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Context.Focus
  alias RunicAI.Context.Graph
  alias RunicAI.Context.Node
  alias RunicAI.Context.Ref
  alias RunicAI.Context.State
  alias RunicAI.Message

  test "stores nodes and labeled relations in the wrapped graph" do
    message_ref = Ref.new!(:message, 1, label: "user:1")
    summary_ref = Ref.new!(:summary, 1, label: "summary:1")

    message_node =
      Node.new_from_ref!(message_ref, Message.new!(:user, "The build is failing in CI."))

    summary_node =
      Node.new_from_ref!(summary_ref, "The recent discussion focused on CI failures.",
        metadata: %{depth: 0}
      )

    graph =
      Graph.new()
      |> Graph.put_node!(message_node)
      |> Graph.put_node!(summary_node)
      |> Graph.add_relation!(summary_ref, message_ref, :summarizes)

    assert Graph.get_node(graph, message_ref).content.content == "The build is failing in CI."
    assert Graph.summarized?(graph, message_ref)
    assert [top_summary] = Graph.top_level_nodes(graph, :summary)
    assert Node.ref(top_summary).target_id == "1"
  end

  test "context state keeps focus and ref sets together" do
    focus =
      Focus.new!(
        goal: "Finish the auth debugging thread",
        questions: ["Which callback is failing?"]
      )

    ref = Ref.new!(:message, 4, label: "assistant:4")

    state =
      State.new!(
        root_refs: [ref],
        active_refs: [ref],
        tail_refs: [ref],
        last_focus: focus
      )

    assert state.last_focus.goal == "Finish the auth debugging thread"
    assert [stored_ref] = state.active_refs
    assert stored_ref.label == "assistant:4"
  end
end
