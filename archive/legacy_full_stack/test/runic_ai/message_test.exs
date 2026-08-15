defmodule RunicAI.MessageTest do
  use ExUnit.Case, async: true

  alias RunicAI.Message

  describe "new/3" do
    test "builds a normalized message" do
      assert {:ok, message} = Message.new(:user, "Hello", metadata: %{source: :test})

      assert message.role == :user
      assert message.content == "Hello"
      assert message.metadata == %{source: :test}
    end

    test "rejects invalid roles" do
      assert {:error, error} = Message.new(:moderator, "Hello")
      assert error.kind == :validation
      assert error.message =~ "invalid message role"
    end
  end

  test "round-trips through ReqLLM messages" do
    req_message = ReqLLM.Context.assistant("Hello", metadata: %{source: :provider})

    assert {:ok, message} = Message.from_req_llm(req_message)
    assert message.role == :assistant
    assert message.content == "Hello"
    assert message.metadata[:source] == :provider

    assert %ReqLLM.Message{} = Message.to_req_llm(message)
  end
end
