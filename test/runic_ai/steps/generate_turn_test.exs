defmodule RunicAI.Steps.GenerateTurnTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Event
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.TestClient
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.GenerateTurn

  test "generates a turn from a turn request and prompt" do
    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state, input_message: "Hello", model: "test:model", client: TestClient)

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, %Result{} = result} = GenerateTurn.generate(turn_request, prompt)
    assert Result.text(result) =~ "I received: Hello"
  end

  test "generates while emitting stream events when stream opts are supplied" do
    parent = self()
    sink = fn stage -> send(parent, {:stream_stage, stage}) end
    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state, input_message: "Hello", model: "test:model", client: TestClient)

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, %Result{} = result} =
             GenerateTurn.generate(turn_request, prompt,
               stream_sink: sink,
               run_id: "run:turn",
               session_id: "session:turn",
               agent: :standard,
               stream_id: "assistant:run:turn:generate_turn",
               message_id: "stream:assistant:run:turn:generate_turn",
               stream_chunk_size: 99
             )

    assert Result.text(result) =~ "I received: Hello"

    assert_receive {:stream_stage,
                    %Event{
                      kind: :chunk,
                      run_id: "run:turn",
                      session_id: "session:turn",
                      agent: :standard,
                      data: %{"message_id" => "stream:assistant:run:turn:generate_turn"}
                    }}

    assert_receive {:stream_stage,
                    %Event{
                      kind: :message,
                      data: %{"content" => content, "stream_complete" => true}
                    }}

    assert content =~ "I received: Hello"
  end
end
