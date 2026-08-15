defmodule RunicAI.LLM.ClientTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
  alias RunicAI.LLM.ReqLLMClient
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result
  alias RunicAI.Message
  alias RunicAI.Testing.ScriptedClient

  test "scripted client returns only normalized outcomes" do
    request = Request.new!("test:model", "hello")
    result = Result.new!(Message.assistant("world"))

    assert {:ok, ^result} = ScriptedClient.generate(request, script: result)

    assert {:error, %Error{code: "invalid_client_result"}} =
             ScriptedClient.generate(request, script: {:ok, %{provider: "leak"}})
  end

  test "ReqLLM responses are projected into owned results" do
    request = Request.new!("openai:gpt-test", "hello", parameters: %{temperature: 0.1})

    dispatch = fn received_request, %ReqLLM.Context{} = context, opts ->
      assert received_request == request
      assert Keyword.fetch!(opts, :temperature) == 0.1
      assert [%ReqLLM.Message{role: :user}] = ReqLLM.Context.to_list(context)
      {:ok, response("hello back")}
    end

    assert {:ok, %Result{} = result} = ReqLLMClient.generate(request, dispatch: dispatch)
    assert Result.text(result) == "hello back"
    assert result.usage.total_tokens == 5
    assert result.evidence.provider == "openai"
    refute Map.has_key?(Result.encode(result), "raw")
  end

  test "retryable provider failures become retry outcomes with safe details" do
    request = Request.new!("openai:gpt-test", "hello")
    dispatch = fn _request, _context, _opts -> {:error, %{status: 429, body: "secret"}} end

    assert {:retry, %Error{retryable: true} = error} =
             ReqLLMClient.generate(request, dispatch: dispatch)

    refute Error.encode(error) |> Jason.encode!() =~ "secret"
  end

  test "reasoning stays separate from final answer text" do
    request = Request.new!("openai:gpt-test", "think")

    dispatch = fn _request, _context, _opts ->
      {:ok, response("", thinking: "private channel")}
    end

    assert {:ok, %Result{reasoning: "private channel"} = result} =
             ReqLLMClient.generate(request, dispatch: dispatch)

    assert Result.text(result) == ""
    assert Result.encode(result)["reasoning"] == "private channel"
  end

  test "structured provider output is validated against the owned contract" do
    request =
      Request.new!("openai:gpt-test", "score",
        output: %{
          type: "object",
          properties: %{score: %{type: "integer"}},
          required: ["score"]
        }
      )

    invalid = fn _request, _context, _opts ->
      {:ok, response("", object: %{"score" => "bad"})}
    end

    assert {:error, %Error{code: "invalid_structured_output"}} =
             ReqLLMClient.generate(request, dispatch: invalid)
  end

  test "portable tools and tool-result messages reach ReqLLM without executable bindings" do
    tool = %{
      "name" => "workspace_describe",
      "description" => "Describe the workspace",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    prompt =
      RunicAI.Prompt.new!([
        Message.user("inspect"),
        Message.new!(:tool, "done",
          name: "workspace_describe",
          metadata: %{"tool_call_id" => "call-1"}
        )
      ])

    request =
      Request.new!("openai:gpt-test", prompt,
        tools: [tool],
        extensions: %{"tool_choice" => "auto"}
      )

    dispatch = fn _request, %ReqLLM.Context{} = context, opts ->
      assert [%ReqLLM.Message{role: :user}, %ReqLLM.Message{role: :tool, tool_call_id: "call-1"}] =
               ReqLLM.Context.to_list(context)

      assert [%ReqLLM.Tool{name: "workspace_describe"}] = Keyword.fetch!(opts, :tools)
      assert Keyword.fetch!(opts, :tool_choice) == "auto"
      {:ok, response("complete")}
    end

    assert {:ok, %Result{}} = ReqLLMClient.generate(request, dispatch: dispatch)
  end

  defp response(text, opts \\ []) do
    message =
      ReqLLM.Context.assistant(text)
      |> then(fn message ->
        case Keyword.get(opts, :thinking) do
          nil ->
            message

          thinking ->
            %{
              message
              | content: message.content ++ [ReqLLM.Message.ContentPart.thinking(thinking)]
            }
        end
      end)

    %ReqLLM.Response{
      id: "response-1",
      model: "gpt-test",
      context: ReqLLM.Context.new([message]),
      message: message,
      object: Keyword.get(opts, :object),
      stream?: false,
      stream: nil,
      usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
      finish_reason: :stop,
      provider_meta: %{warnings: ["fixture"]},
      error: nil
    }
  end
end
