defmodule RunicAI.LLM.StreamingTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
  alias RunicAI.Event
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.Streaming
  alias RunicAI.LLM.TestClient

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
end
