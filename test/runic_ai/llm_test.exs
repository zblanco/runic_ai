defmodule RunicAI.LLMTest do
  use ExUnit.Case, async: true

  alias RunicAI.LLM
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.TestClient
  alias RunicAI.Message
  alias RunicAI.Prompt

  describe "generate_text/3" do
    test "dispatches to a module client" do
      assert {:ok, result} =
               LLM.generate_text("test:model", "Hello", client: TestClient)

      assert %Result{} = result
      assert Result.text(result) =~ "I received: Hello"
    end

    test "normalizes raw provider responses from function clients" do
      client = fn _model, prompt, _opts ->
        {:ok, TestClient.response("echo: #{prompt}")}
      end

      assert {:ok, result} =
               LLM.generate_text("test:model", "Hi", client: client)

      assert %Result{} = result
      assert Result.text(result) == "echo: Hi"
    end

    test "passes extra opts through to the client" do
      client = fn _model, _prompt, opts ->
        {:ok, TestClient.result("temp=#{opts[:temperature]}")}
      end

      assert {:ok, result} =
               LLM.generate_text("m", "p", client: client, temperature: 0.5)

      assert Result.text(result) == "temp=0.5"
    end

    test "accepts a normalized request struct" do
      prompt =
        Prompt.new!([
          Message.new!(:system, "You are helpful"),
          Message.new!(:user, "Hello")
        ])

      request = Request.new!("test:model", prompt, client: TestClient)

      assert {:ok, result} = LLM.generate_text(request)
      assert Result.text(result) =~ "I received: Hello"
    end
  end

  describe "stream_text/3" do
    test "dispatches to a module client" do
      prompt = Prompt.new!([Message.new!(:user, "Hello")])

      assert {:ok, stream_response} =
               LLM.stream_text("test:model", prompt, client: TestClient)

      text = Enum.map_join(stream_response.stream, fn chunk -> chunk.text end)
      assert text =~ "I received: Hello"
    end

    test "dispatches to a function client" do
      client = fn _model, _prompt, _opts ->
        {:ok, TestClient.stream_response("streamed")}
      end

      assert {:ok, sr} = LLM.stream_text("m", "p", client: client)
      text = Enum.map_join(sr.stream, fn chunk -> chunk.text end)
      assert text == "streamed"
    end
  end

  describe "generate_object/4" do
    test "dispatches to a module client" do
      schema = [name: [type: :string]]

      assert {:ok, %{name: "Test", value: 42}} =
               LLM.generate_object("m", "p", schema, client: TestClient)
    end

    test "dispatches to a function client" do
      client = fn _model, _prompt, _schema, _opts ->
        {:ok, %{answer: 99}}
      end

      assert {:ok, %{answer: 99}} =
               LLM.generate_object("m", "p", [], client: client)
    end

    test "normalizes raw provider responses from function clients" do
      client = fn _model, _prompt, _schema, _opts ->
        response = RunicAI.LLM.TestClient.response("structured")
        {:ok, %ReqLLM.Response{response | object: %{"answer" => 99}}}
      end

      assert {:ok, %{"answer" => 99}} =
               LLM.generate_object("m", "p", [], client: client)
    end
  end
end
