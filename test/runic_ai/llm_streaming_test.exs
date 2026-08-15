defmodule RunicAI.LLM.StreamingTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
  alias RunicAI.Event
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.Streaming
  alias RunicAI.LLM.TestClient
  alias RunicAI.Steps.InterpretTurn

  defmodule UnsupportedStreamClient do
    @behaviour RunicAI.LLM

    @impl true
    def stream_text(_model, _prompt, _opts) do
      {:error, Error.new(:unsupported, "streaming is not supported")}
    end

    @impl true
    def generate_text(_model, _prompt, _opts) do
      {:ok, TestClient.result("fallback response")}
    end

    @impl true
    def generate_object(_model, _prompt, _schema, _opts), do: {:ok, %{}}
  end

  defmodule ToolStreamClient do
    @behaviour RunicAI.LLM

    @impl true
    def stream_text(_model, _prompt, _opts) do
      {:ok, metadata_handle} =
        ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
          %{
            usage: %{input_tokens: 20, output_tokens: 10, total_tokens: 30},
            finish_reason: :tool_calls
          }
        end)

      stream =
        [
          ReqLLM.StreamChunk.tool_call(
            "apply_patch",
            %{operations: [%{op: "create", path: "lib/demo.ex", content: "demo"}]},
            %{id: "call_stream_patch"}
          )
        ]

      {:ok,
       %ReqLLM.StreamResponse{
         stream: stream,
         metadata_handle: metadata_handle,
         cancel: fn -> :ok end,
         model: ReqLLM.model!("openai:gpt-4o-mini"),
         context: ReqLLM.Context.new()
       }}
    end

    @impl true
    def generate_text(_model, _prompt, _opts), do: raise("eager fallback must not run")

    @impl true
    def generate_object(_model, _prompt, _schema, _opts), do: {:ok, %{}}
  end

  test "emits normalized stream stages and returns the complete result" do
    parent = self()
    sink = fn stage -> send(parent, {:stream_stage, stage}) end

    assert {:ok, %Result{} = result} =
             Streaming.generate_text("test:model", "Hello",
               client: TestClient,
               stream_sink: sink,
               run_id: "run:stream",
               session_id: "session:stream",
               agent: :assistant,
               stream_id: "assistant:run:stream:final",
               message_id: "stream:assistant:run:stream:final",
               stream_chunk_size: 99
             )

    assert Result.text(result) == "I received: Hello"

    assert_receive {:stream_stage,
                    %Event{
                      kind: :chunk,
                      phase: :assistant_chunk,
                      status: :running,
                      data: %{
                        "stream_id" => "assistant:run:stream:final",
                        "message_id" => "stream:assistant:run:stream:final",
                        "content" => "I received: Hello",
                        "sequence" => 1,
                        "stream_complete" => false
                      }
                    }}

    assert_receive {:stream_stage,
                    %Event{
                      kind: :message,
                      phase: :assistant,
                      status: :ok,
                      data: %{
                        "content" => "I received: Hello",
                        "stream_complete" => true,
                        "sequence" => 2
                      }
                    }}
  end

  test "falls back to eager generation when the client does not support streaming" do
    parent = self()
    sink = fn stage -> send(parent, {:stream_stage, stage}) end

    assert {:ok, %Result{} = result} =
             Streaming.generate_text("test:model", "Hello",
               client: UnsupportedStreamClient,
               stream_sink: sink
             )

    assert Result.text(result) == "fallback response"
    refute_receive {:stream_stage, _stage}
  end

  test "materializes streamed tool calls and persists generation evidence" do
    parent = self()
    sink = fn stage -> send(parent, {:stream_stage, stage}) end

    assert {:ok, %Result{} = result} =
             Streaming.generate_text("test:model", "Create a module",
               client: ToolStreamClient,
               tools: [],
               tool_choice: :required,
               stream_sink: sink,
               stream_chunk_size: 99
             )

    assert result.finish_reason == :tool_calls

    assert [%ReqLLM.ToolCall{function: %{name: "apply_patch"}}] =
             ReqLLM.Response.tool_calls(result.raw)

    assert {:ok, %{kind: :tool_requests, details: %{tool_calls: [tool_call]}}} =
             InterpretTurn.interpret(result, [])

    assert tool_call.name == "apply_patch"

    assert_receive {:stream_stage,
                    %Event{
                      phase: :assistant,
                      data: %{
                        "generation_evidence" => %{
                          "finish_reason" => "tool_calls",
                          "tool_call_count" => 1,
                          "tool_choice" => "required",
                          "usage" => %{"total_tokens" => 30}
                        }
                      }
                    }}
  end

  test "falls back when a function client returns an eager result for stream_text" do
    parent = self()
    sink = fn stage -> send(parent, {:stream_stage, stage}) end

    client = fn _model, _prompt, _opts ->
      send(parent, :client_called)
      {:ok, TestClient.result("eager function response")}
    end

    assert {:ok, %Result{} = result} =
             Streaming.generate_text("test:model", "Hello",
               client: client,
               stream_sink: sink
             )

    assert Result.text(result) == "eager function response"
    assert_receive :client_called
    refute_receive :client_called
    refute_receive {:stream_stage, _stage}
  end

  test "removes component tracing metadata before eager provider generation" do
    parent = self()

    client = fn _model, _prompt, opts ->
      send(parent, {:provider_opts, opts})
      {:ok, TestClient.result("filtered")}
    end

    assert {:ok, %Result{} = result} =
             Streaming.generate_text("test:model", "Hello",
               client: client,
               component_id: "extract",
               component_type: :llm_map,
               workflow_node: "extract",
               source_step: :llm_map,
               temperature: 0.1
             )

    assert Result.text(result) == "filtered"
    assert_receive {:provider_opts, provider_opts}
    assert provider_opts[:temperature] == 0.1
    refute Keyword.has_key?(provider_opts, :component_id)
    refute Keyword.has_key?(provider_opts, :component_type)
    refute Keyword.has_key?(provider_opts, :workflow_node)
    refute Keyword.has_key?(provider_opts, :source_step)
  end
end
