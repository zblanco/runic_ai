defmodule RunicAI.Terminal.InteractiveContextTest do
  use ExUnit.Case, async: true

  alias RunicAI.Terminal.InteractiveContext

  test "adds bounded rendered diagram targets to follow-up prompts" do
    objective =
      InteractiveContext.add_carryover("Now render the same diagrams", %{
        summary: %{
          rendered_diagrams: [
            %{
              path: "guides/stateless-vs-stateful-agents.md",
              diagram_index: 2,
              heading: "Integrated stateful agents",
              line_start: 78
            }
          ]
        }
      })

    assert objective =~ "Now render the same diagrams"
    assert objective =~ "Previous terminal diagram context"
    assert objective =~ "guides/stateless-vs-stateful-agents.md"
    assert objective =~ "diagram_index: 2"
  end

  test "leaves prompts unchanged without diagram context" do
    assert InteractiveContext.add_carryover("Explain this repo", %{summary: %{}}) ==
             "Explain this repo"
  end
end
