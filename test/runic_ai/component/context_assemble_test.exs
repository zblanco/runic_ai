defmodule RunicAI.Component.ContextAssembleTest do
  use ExUnit.Case, async: true

  alias RunicAI.Component.ContextAssemble
  alias RunicAI.Context.Reference
  alias RunicAI.Context.Window
  alias RunicAI.Contract.Component
  alias RunicAI.Message
  alias RunicAI.Prompt

  test "publishes a pure portable contract without host bindings" do
    encoded = ContextAssemble.contract() |> Component.encode()

    assert encoded["key"] == "runic_ai.context.assemble"
    assert encoded["effects"] == []
    assert encoded["replay"] == "pure"
    refute inspect(encoded) =~ "Assembler"
  end

  test "direct execution and the Runic step select the same owned context" do
    prompt = Prompt.new!([Message.user("question")])

    window =
      Window.new!([
        Reference.new!(%{
          "id" => "public",
          "content" => "accepted",
          "source" => %{"kind" => "document"}
        }),
        Reference.new!(%{
          "id" => "secret",
          "content" => "filtered",
          "source" => %{"kind" => "document"},
          "sensitivity" => ["secret"]
        })
      ])

    assert {:ok, %{"prompt" => direct, "window" => selected}} =
             ContextAssemble.run(%{"prompt" => prompt, "window" => window})

    assert Enum.map(selected.references, & &1.id) == ["public"]
    assert direct.messages |> List.last() |> Message.text() =~ "accepted"

    workflow =
      Runic.workflow(name: "context")
      |> Runic.Workflow.add(ContextAssemble.new())
      |> Runic.Workflow.react_until_satisfied(%{"prompt" => prompt, "window" => window})

    assert {:ok, %{"prompt" => direct, "window" => selected}} in Runic.Workflow.raw_productions(
             workflow
           )
  end
end
