defmodule RunicAI.LLM.TestClient do
  @moduledoc """
  A fake LLM client for tests that returns deterministic responses.

  Can be used as a `:client` module or via helper functions that build
  normalized `RunicAI.LLM.Result` values or raw `ReqLLM.Response` structs.

  ## As a module client

      RunicAI.LLM.generate_text("model", "prompt", client: RunicAI.LLM.TestClient)

  ## Building responses for inline function clients

      client = fn _model, _prompt, _opts ->
        {:ok, RunicAI.LLM.TestClient.response("custom answer")}
      end

  ## Echoing input

      client = &RunicAI.LLM.TestClient.echo/3
      # Returns the prompt text back as the assistant response

  """

  @behaviour RunicAI.LLM

  alias RunicAI.LLM.Result
  alias RunicAI.Prompt

  @impl true
  def generate_text(_model, prompt, _opts \\ []) do
    text = extract_text(prompt)
    {:ok, result("I received: #{text}")}
  end

  @impl true
  def stream_text(_model, prompt, _opts \\ []) do
    text = extract_text(prompt)
    {:ok, stream_response("I received: #{text}")}
  end

  @impl true
  def generate_object(_model, _prompt, _schema, _opts \\ []) do
    {:ok, %{name: "Test", value: 42}}
  end

  @doc "Echoes the prompt text back as an assistant response."
  def echo(_model, prompt, _opts \\ []) do
    {:ok, result(extract_text(prompt))}
  end

  @doc "Builds a normalized `RunicAI.LLM.Result` with the given text."
  def result(text) when is_binary(text) do
    Result.new!(RunicAI.Message.new!(:assistant, text),
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    )
  end

  @doc "Builds a well-formed `ReqLLM.Response` with the given text."
  def response(text) when is_binary(text) do
    context =
      ReqLLM.Context.new([
        ReqLLM.Context.assistant(text)
      ])

    %ReqLLM.Response{
      id: "test-#{System.unique_integer([:positive])}",
      model: "test:fake-model",
      context: context,
      message: ReqLLM.Context.assistant(text),
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
      finish_reason: :stop
    }
  end

  @doc "Builds a normalized ReqLLM tool call."
  def tool_call(name, arguments, opts \\ []) when is_binary(name) and is_map(arguments) do
    ReqLLM.ToolCall.new(Keyword.get(opts, :id), name, Jason.encode!(arguments))
  end

  @doc "Builds a well-formed `ReqLLM.Response` that asks for tools."
  def tool_response(tool_calls, text \\ "") when is_list(tool_calls) and is_binary(text) do
    message = ReqLLM.Context.assistant(text, tool_calls: tool_calls)

    %ReqLLM.Response{
      id: "test-#{System.unique_integer([:positive])}",
      model: "test:fake-model",
      context: ReqLLM.Context.new([message]),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
      finish_reason: :tool_calls
    }
  end

  @doc "Builds a fake stream response that yields tokens from the given text."
  def stream_response(text) when is_binary(text) do
    tokens = String.graphemes(text)

    {:ok, metadata_handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{
          usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
          finish_reason: :stop
        }
      end)

    stream =
      Stream.map(tokens, fn token ->
        ReqLLM.StreamChunk.text(token)
      end)

    %ReqLLM.StreamResponse{
      stream: stream,
      metadata_handle: metadata_handle,
      cancel: fn -> :ok end,
      model: ReqLLM.model!("openai:gpt-4o-mini"),
      context: ReqLLM.Context.new()
    }
  end

  @doc "Returns a function client that always responds with the given text."
  def client(text) do
    fn _model, _prompt, _opts -> {:ok, result(text)} end
  end

  @doc "Returns a function client that responds with a raw ReqLLM response."
  def raw_client(text) do
    fn _model, _prompt, _opts -> {:ok, response(text)} end
  end

  defp extract_text(prompt) when is_binary(prompt), do: prompt
  defp extract_text(%Prompt{messages: messages}), do: extract_text_from_messages(messages)

  defp extract_text(%ReqLLM.Context{} = ctx) do
    ctx
    |> ReqLLM.Context.to_list()
    |> Enum.map(&RunicAI.Message.from_req_llm!/1)
    |> extract_text_from_messages()
  end

  defp extract_text(_), do: ""

  defp extract_text_from_messages(messages) do
    messages
    |> Enum.filter(fn msg -> msg.role == :user end)
    |> List.last()
    |> case do
      nil -> ""
      msg -> msg.content
    end
  end
end
