defmodule RunicAI.ContextTest do
  use ExUnit.Case, async: true

  alias RunicAI.Context.{Assembler, Reference, Window}
  alias RunicAI.{Message, Prompt}

  test "context values survive the wire form with provenance intact" do
    reference =
      Reference.new!(%{
        "id" => "doc:1",
        "content" => "grounded fact",
        "source" => %{"uri" => "workspace://notes/1"},
        "sensitivity" => ["workspace"]
      })

    window = Window.new!([reference], query: "fact")

    assert {:ok, decoded} = window |> Window.encode() |> Window.decode()
    assert decoded == window
  end

  test "assembler enforces sensitivity and a deterministic character budget" do
    public = Reference.new!(%{"id" => "public", "content" => "kept", "source" => %{}})

    private =
      Reference.new!(%{
        "id" => "private",
        "content" => "not exposed",
        "source" => %{},
        "sensitivity" => ["secret"]
      })

    prompt = Prompt.new!([Message.user("answer")])

    assert {:ok, assembled, selected} = Assembler.assemble(prompt, Window.new!([public, private]))
    assert Enum.map(selected.references, & &1.id) == ["public"]
    assert selected.truncated
    assert assembled.messages |> List.last() |> Message.text() =~ "[public]"
    refute assembled.messages |> List.last() |> Message.text() =~ "not exposed"
  end

  test "assembler marks windows truncated when the next reference exceeds the budget" do
    first = Reference.new!(%{"id" => "one", "content" => "short", "source" => %{}})

    second =
      Reference.new!(%{"id" => "two", "content" => String.duplicate("x", 100), "source" => %{}})

    assert {:ok, _prompt, selected} =
             Assembler.assemble(
               Prompt.new!([Message.user("answer")]),
               Window.new!([first, second]),
               max_characters: 40
             )

    assert Enum.map(selected.references, & &1.id) == ["one"]
    assert selected.truncated
  end
end
