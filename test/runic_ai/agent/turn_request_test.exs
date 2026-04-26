defmodule RunicAI.Agent.TurnRequestTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Message
  alias RunicAI.Prompt

  test "builds a turn request from defaults and map input" do
    turn_request =
      TurnRequest.from_input!(
        %{user: "Hello"},
        system: "You are helpful",
        model: "test:model",
        temperature: 0.2
      )

    assert turn_request.input_message.content == "Hello"
    assert turn_request.model == "test:model"
    assert turn_request.llm_opts[:temperature] == 0.2
    refute Keyword.has_key?(turn_request.llm_opts, :system)
    refute Keyword.has_key?(turn_request.llm_opts, :messages)
    refute Keyword.has_key?(turn_request.llm_opts, :assigns)
    refute Keyword.has_key?(turn_request.llm_opts, :state_metadata)
  end

  test "reserves context inputs from llm opts" do
    turn_request =
      TurnRequest.from_input!(
        %{user: "Hello", focus: "deployment status", goal: "answer from context"},
        model: "test:model",
        temperature: 0.2
      )

    assert turn_request.llm_opts[:temperature] == 0.2
    refute Keyword.has_key?(turn_request.llm_opts, :focus)
    refute Keyword.has_key?(turn_request.llm_opts, :goal)
  end

  test "preserves leading system messages while windowing history" do
    state =
      State.new!(
        messages: [
          Message.new!(:system, "system"),
          Message.new!(:user, "one"),
          Message.new!(:assistant, "two"),
          Message.new!(:user, "three"),
          Message.new!(:assistant, "four")
        ]
      )

    turn_request =
      TurnRequest.new!(state, input_message: "five", model: "test:model", history_window: 2)

    assert Enum.map(TurnRequest.history_messages(turn_request), & &1.content) == [
             "system",
             "three",
             "four"
           ]
  end

  test "assembles prompt messages from pinned, history, input, and observations" do
    state = State.new!(messages: [Message.new!(:assistant, "Earlier answer")])

    turn_request =
      TurnRequest.new!(state,
        input_message: "Current question",
        model: "test:model",
        pinned_messages: [Message.new!(:system, "Pinned instruction")],
        observations: [Message.new!(:assistant, "Observation")]
      )

    assert Enum.map(TurnRequest.prompt_messages(turn_request), & &1.content) == [
             "Pinned instruction",
             "Earlier answer",
             "Current question",
             "Observation"
           ]

    assert {:ok, %Prompt{}} = TurnRequest.to_prompt(turn_request)
  end
end
