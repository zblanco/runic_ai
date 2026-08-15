defmodule RunicAI.PromptTest do
  use ExUnit.Case, async: true

  alias RunicAI.Message
  alias RunicAI.Prompt

  test "builds a prompt from normalized messages" do
    messages = [
      Message.new!(:system, "You are helpful"),
      Message.new!(:user, "Hello")
    ]

    assert {:ok, prompt} = Prompt.new(messages, metadata: %{origin: :test})
    assert length(prompt.messages) == 2
    assert prompt.metadata == %{origin: :test}
  end

  test "converts to and from ReqLLM context" do
    prompt =
      Prompt.new!([
        Message.new!(:system, "You are helpful"),
        Message.new!(:user, "Hello")
      ])

    context = Prompt.to_req_llm(prompt)
    assert %ReqLLM.Context{} = context

    assert {:ok, round_tripped} = Prompt.from_req_llm(context)
    assert Enum.map(round_tripped.messages, & &1.role) == [:system, :user]
  end
end
