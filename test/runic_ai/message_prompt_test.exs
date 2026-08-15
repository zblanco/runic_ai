defmodule RunicAI.MessagePromptTest do
  use ExUnit.Case, async: true

  alias RunicAI.Message
  alias RunicAI.MessageContent
  alias RunicAI.Prompt

  test "multimodal owned messages and prompts round trip without provider types" do
    message =
      Message.new!(
        :user,
        [
          MessageContent.text("Review this: "),
          MessageContent.reference(:document_ref, "artifact:document/42", "application/pdf")
        ],
        metadata: %{workspace: "alpha"}
      )

    prompt = Prompt.new!([Message.system("Be concise"), message])
    encoded = Prompt.encode(prompt)

    assert {:ok, ^prompt} = encoded |> Jason.encode!() |> Jason.decode!() |> Prompt.decode()
    assert Message.text(message) == "Review this: "
    refute encoded |> inspect() =~ "ReqLLM"
  end

  test "unsafe media references and external roles are rejected without atom creation" do
    assert_raise ArgumentError, fn ->
      MessageContent.reference(:image_ref, "file:///etc/passwd")
    end

    unknown = "external_role_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, [%{path: ["role"]}]} =
             Message.decode(%{
               "role" => unknown,
               "content" => [%{"type" => "text", "text" => "x"}]
             })

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "tool content retains only JSON-safe owned values" do
    call = MessageContent.tool_call("call-1", "search", %{query: "runic"})
    result = MessageContent.tool_result("call-1", "search", %{hits: 2})

    assert MessageContent.encode(call)["value"] == %{"query" => "runic"}
    assert MessageContent.encode(result)["value"] == %{"hits" => 2}
  end
end
