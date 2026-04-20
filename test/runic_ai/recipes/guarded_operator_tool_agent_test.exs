defmodule RunicAI.Recipes.GuardedOperatorToolAgentTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Prompt
  alias RunicAI.Recipes.GuardedOperatorToolAgent
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Tool.Definition
  alias RunicAI.Wait

  test "pauses with a review request before executing a guarded tool batch" do
    client = fn _model, %Prompt{} = _prompt, _opts ->
      {:ok,
       RunicAI.LLM.TestClient.tool_response([
         RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
       ])}
    end

    workflow =
      GuardedOperatorToolAgent.new(
        model: "test:model",
        registry: [weather_tool()],
        client: client,
        pre_tool_guard: fn _request -> :review end
      )
      |> Workflow.react_until_satisfied(%{user: "What's the weather in Paris?"})

    state = GuardedOperatorToolAgent.latest_state(workflow)

    assert %ReviewRequest{} = GuardedOperatorToolAgent.latest_review_request(workflow)

    assert %TurnResult{kind: :tool_requests} =
             GuardedOperatorToolAgent.latest_turn_result(workflow)

    assert %ReviewRequest{} = state.pending_action
    assert Enum.map(state.conversation.messages, & &1.role) == [:user, :assistant]
    assert GuardedOperatorToolAgent.latest_tool_results(workflow) == nil
  end

  test "rewrites an answer before it is committed to state" do
    workflow =
      GuardedOperatorToolAgent.new(
        model: "test:model",
        client: RunicAI.LLM.TestClient.client("draft answer"),
        pre_answer_guard: fn _request ->
          {:rewrite, TurnResult.reply!("approved answer")}
        end
      )
      |> Workflow.react_until_satisfied(%{user: "Answer the question."})

    state = GuardedOperatorToolAgent.latest_state(workflow)

    assert GuardedOperatorToolAgent.latest_reply_text(workflow) == "approved answer"
    assert List.last(state.conversation.messages).content == "approved answer"
    assert state.pending_action == nil
  end

  test "resumes a pre-tool review approval and completes the tool loop" do
    client = fn _model, %Prompt{messages: messages}, _opts ->
      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          {:ok,
           RunicAI.LLM.TestClient.tool_response(
             [
               RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
             ],
             "Let me check."
           )}

        tool_message ->
          assert tool_message.content =~ "\"sunny\""
          {:ok, RunicAI.LLM.TestClient.result("Paris is sunny.")}
      end
    end

    initial_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          registry: [weather_tool()],
          client: client,
          pre_tool_guard: fn _request -> :review end
        ],
        %{user: "What's the weather in Paris?"}
      )

    review_request = GuardedOperatorToolAgent.latest_review_request(initial_workflow)
    paused_state = GuardedOperatorToolAgent.latest_state(initial_workflow)

    resumed_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          registry: [weather_tool()],
          client: client,
          pre_tool_guard: fn _request -> :review end
        ],
        %{
          state: paused_state,
          review_decision: %{resume_key: review_request.resume_key, status: :approved}
        }
      )

    resumed_state = GuardedOperatorToolAgent.latest_state(resumed_workflow)

    assert GuardedOperatorToolAgent.latest_reply_text(resumed_workflow) == "Paris is sunny."
    assert resumed_state.pending_action == nil
    assert resumed_state.conversation.turns == 2
  end

  test "resumes a pre-answer review approval and commits the original answer" do
    initial_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :review end
        ],
        %{user: "Answer carefully."}
      )

    review_request = GuardedOperatorToolAgent.latest_review_request(initial_workflow)
    paused_state = GuardedOperatorToolAgent.latest_state(initial_workflow)

    resumed_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :review end
        ],
        %{
          state: paused_state,
          review_decision: %{resume_key: review_request.resume_key, status: :approved}
        }
      )

    resumed_state = GuardedOperatorToolAgent.latest_state(resumed_workflow)

    assert GuardedOperatorToolAgent.latest_reply_text(resumed_workflow) == "draft answer"
    assert List.last(resumed_state.conversation.messages).content == "draft answer"
    assert resumed_state.pending_action == nil
  end

  test "resumes a pre-answer review edit and commits the edited answer" do
    initial_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :review end
        ],
        %{user: "Answer carefully."}
      )

    review_request = GuardedOperatorToolAgent.latest_review_request(initial_workflow)
    paused_state = GuardedOperatorToolAgent.latest_state(initial_workflow)

    resumed_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :review end
        ],
        %{
          state: paused_state,
          review_decision: %{
            resume_key: review_request.resume_key,
            status: :edited,
            edited_value: "approved answer"
          }
        }
      )

    resumed_state = GuardedOperatorToolAgent.latest_state(resumed_workflow)

    assert GuardedOperatorToolAgent.latest_reply_text(resumed_workflow) == "approved answer"
    assert List.last(resumed_state.conversation.messages).content == "approved answer"
    assert resumed_state.pending_action == nil
  end

  test "resumes a pre-answer review rejection as a halt without committing the answer" do
    initial_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :review end
        ],
        %{user: "Answer carefully."}
      )

    review_request = GuardedOperatorToolAgent.latest_review_request(initial_workflow)
    paused_state = GuardedOperatorToolAgent.latest_state(initial_workflow)

    resumed_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :review end
        ],
        %{
          state: paused_state,
          review_decision: ReviewDecision.new!(review_request.resume_key, :rejected)
        }
      )

    resumed_state = GuardedOperatorToolAgent.latest_state(resumed_workflow)

    assert GuardedOperatorToolAgent.latest_continue_decision(resumed_workflow).action == :halt
    assert resumed_state.status == :halted
    assert Enum.map(resumed_state.conversation.messages, & &1.role) == [:user]
  end

  test "pauses with a review request before committing an answer" do
    workflow =
      GuardedOperatorToolAgent.new(
        model: "test:model",
        client: RunicAI.LLM.TestClient.client("draft answer"),
        pre_answer_guard: fn _request -> :review end
      )
      |> Workflow.react_until_satisfied(%{user: "Answer carefully."})

    state = GuardedOperatorToolAgent.latest_state(workflow)

    assert %ReviewRequest{checkpoint: :pre_answer} =
             GuardedOperatorToolAgent.latest_review_request(workflow)

    assert GuardedOperatorToolAgent.latest_reply_text(workflow) == "draft answer"
    assert %ReviewRequest{} = state.pending_action
    assert Enum.map(state.conversation.messages, & &1.role) == [:user]
  end

  test "halts on budget exhaustion before committing an answer while preserving the user message" do
    workflow =
      GuardedOperatorToolAgent.new(
        model: "test:model",
        client: RunicAI.LLM.TestClient.client("draft answer"),
        budget_policy: [max_turns: 0, on_exhaustion: :halt]
      )
      |> Workflow.react_until_satisfied(%{user: "This should halt."})

    state = GuardedOperatorToolAgent.latest_state(workflow)

    assert GuardedOperatorToolAgent.latest_continue_decision(workflow).action == :halt
    assert state.status == :halted
    assert Enum.map(state.conversation.messages, & &1.role) == [:user]
    assert state.conversation.last_assistant_message == nil
  end

  test "reacts until resolution across guarded tool-use turns when controls allow progress" do
    client = fn _model, %Prompt{messages: messages}, _opts ->
      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          {:ok,
           RunicAI.LLM.TestClient.tool_response(
             [
               RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
             ],
             "Let me check."
           )}

        tool_message ->
          assert tool_message.content =~ "\"sunny\""
          {:ok, RunicAI.LLM.TestClient.result("Paris is sunny.")}
      end
    end

    workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          registry: [weather_tool()],
          client: client
        ],
        %{user: "What's the weather in Paris?"}
      )

    state = GuardedOperatorToolAgent.latest_state(workflow)

    assert GuardedOperatorToolAgent.latest_turn_result(workflow).kind == :reply
    assert GuardedOperatorToolAgent.latest_reply_text(workflow) == "Paris is sunny."
    assert state.conversation.turns == 2
    assert GuardedOperatorToolAgent.latest_review_request(workflow) == nil
    assert GuardedOperatorToolAgent.latest_wait(workflow) == nil
  end

  test "can pause with a wait before answering" do
    workflow =
      GuardedOperatorToolAgent.new(
        model: "test:model",
        client: RunicAI.LLM.TestClient.client("draft answer"),
        pre_answer_guard: fn _request -> :wait end
      )
      |> Workflow.react_until_satisfied(%{user: "Need operator input."})

    state = GuardedOperatorToolAgent.latest_state(workflow)

    assert %Wait{} = GuardedOperatorToolAgent.latest_wait(workflow)
    assert %Wait{} = state.pending_action
    assert Enum.map(state.conversation.messages, & &1.role) == [:user]
  end

  test "resumes a pre-answer wait and commits the pending answer" do
    initial_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :wait end
        ],
        %{user: "Need operator input."}
      )

    wait = GuardedOperatorToolAgent.latest_wait(initial_workflow)
    paused_state = GuardedOperatorToolAgent.latest_state(initial_workflow)

    resumed_workflow =
      GuardedOperatorToolAgent.react_until_resolution(
        [
          model: "test:model",
          client: RunicAI.LLM.TestClient.client("draft answer"),
          pre_answer_guard: fn _request -> :wait end
        ],
        %{
          state: paused_state,
          resume_signal: %{
            kind: wait.kind,
            resume_key: wait.resume_key,
            payload: %{released: true}
          }
        }
      )

    resumed_state = GuardedOperatorToolAgent.latest_state(resumed_workflow)

    assert GuardedOperatorToolAgent.latest_reply_text(resumed_workflow) == "draft answer"
    assert resumed_state.pending_action == nil
    assert Enum.map(resumed_state.conversation.messages, & &1.role) == [:user, :assistant]
  end

  test "retries generation inside the guarded recipe before answering" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      case Agent.get_and_update(counter, fn value -> {value, value + 1} end) do
        0 ->
          {:error, RunicAI.Error.provider("temporary failure", retryable?: true)}

        _ ->
          {:ok, RunicAI.LLM.TestClient.result("eventual success")}
      end
    end

    workflow =
      GuardedOperatorToolAgent.new(
        model: "test:model",
        client: client,
        generation_retry_policy: [max_attempts: 2]
      )
      |> Workflow.react_until_satisfied(%{user: "Hello"})

    assert GuardedOperatorToolAgent.latest_reply_text(workflow) == "eventual success"
  end

  defp weather_tool do
    Definition.new!(
      name: "get_weather",
      description: "Get the weather for a city",
      parameter_schema: [location: [type: :string, required: true]],
      executor: fn %{location: location} ->
        {:ok, %{location: location, forecast: "sunny"}}
      end
    )
  end
end
