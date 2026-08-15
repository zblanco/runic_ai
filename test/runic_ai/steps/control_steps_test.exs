defmodule RunicAI.Steps.ControlStepsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Conversation.State, as: ConversationState
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Error
  alias RunicAI.LLM.TestClient
  alias RunicAI.ResumeSignal
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Steps.ApplyReviewDecision
  alias RunicAI.Steps.AssembleTurnPrompt
  alias RunicAI.Steps.EvaluateBudget
  alias RunicAI.Steps.EvaluateGuard
  alias RunicAI.Steps.ExecuteToolCallsControlled
  alias RunicAI.Steps.GenerateTurnControlled
  alias RunicAI.Steps.NormalizeResumeSignal
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection
  alias RunicAI.Wait

  test "evaluate budget accounts for projected tool calls" do
    state =
      State.new!(
        system: "You are helpful",
        metadata: %{usage: %{model_calls: 1, tool_calls: 1}}
      )

    turn_result = TurnResult.tool_requests!()

    execution_plan =
      ExecutionPlan.new!([
        CallRequest.new!("call_1", "tool_a", %{}, request_index: 0),
        CallRequest.new!("call_2", "tool_b", %{}, request_index: 1)
      ])

    assert {:ok, decision} =
             EvaluateBudget.evaluate(
               %{
                 state: state,
                 turn_result: turn_result,
                 execution_plan: execution_plan,
                 runtime: %{elapsed_ms: 200, recursion_depth: 1}
               },
               budget_policy: [max_tool_calls: 2, on_exhaustion: :review]
             )

    assert decision.status == :exhausted
    assert decision.action == :review
    assert Enum.any?(decision.reasons, &(&1.metric == :tool_calls and &1.actual == 3))
  end

  test "evaluate budget supports turn, model, elapsed, cost, and recursion limits" do
    state =
      State.new!(
        conversation: ConversationState.new!([], turns: 2),
        metadata: %{usage: %{model_calls: 2, estimated_cost: 0.25}}
      )

    cases = [
      {[max_turns: 1], %{state: state}, :turns, 2},
      {[max_model_calls: 1], %{state: state}, :model_calls, 2},
      {[max_elapsed_ms: 100], %{state: state, runtime: %{elapsed_ms: 250}}, :elapsed_ms, 250},
      {[max_estimated_cost: 0.10], %{state: state, runtime: %{estimated_cost: 0.25}},
       :estimated_cost, 0.25},
      {[max_recursion_depth: 1], %{state: state, runtime: %{recursion_depth: 3}},
       :recursion_depth, 3}
    ]

    Enum.each(cases, fn {budget_policy, input, metric, actual} ->
      assert {:ok, decision} =
               EvaluateBudget.evaluate(input,
                 budget_policy: Keyword.put(budget_policy, :on_exhaustion, :halt)
               )

      assert decision.status == :exhausted
      assert decision.action == :halt
      assert Enum.any?(decision.reasons, &(&1.metric == metric and &1.actual == actual))
    end)
  end

  test "evaluate guard normalizes rewrite decisions" do
    state = State.new!(system: "You are helpful")

    guard_request =
      GuardRequest.new!(
        :pre_answer,
        state,
        subject: TurnResult.reply!("draft answer")
      )

    assert {:ok, %GuardDecision{action: :rewrite, replacement: %TurnResult{} = replacement}} =
             EvaluateGuard.evaluate(guard_request,
               evaluator: fn _request -> {:rewrite, TurnResult.reply!("approved answer")} end
             )

    assert replacement.message.content == "approved answer"
  end

  test "apply review decision supports edited approvals" do
    review_request =
      ReviewRequest.new!(
        :guard_review,
        checkpoint: :pre_answer,
        resume_key: "resume-1",
        subject: %{draft: "answer"}
      )

    review_decision =
      ReviewDecision.new!("resume-1", :edited, edited_value: %{approved: "final answer"})

    assert {:ok, %{approved: "final answer"}} =
             ApplyReviewDecision.apply_decision(review_request, review_decision)
  end

  test "apply review decision returns terminal decisions for reject and cancel" do
    review_request =
      ReviewRequest.new!(
        :guard_review,
        checkpoint: :pre_answer,
        resume_key: "resume-2",
        subject: %{draft: "answer"}
      )

    assert {:ok, reject_decision} =
             ApplyReviewDecision.apply_decision(
               review_request,
               ReviewDecision.new!("resume-2", :rejected)
             )

    assert reject_decision.action == :halt
    assert reject_decision.reason == :review_rejected

    assert {:ok, cancel_decision} =
             ApplyReviewDecision.apply_decision(
               review_request,
               ReviewDecision.new!("resume-2", :cancelled)
             )

    assert cancel_decision.action == :stop
    assert cancel_decision.reason == :review_cancelled
  end

  test "normalize resume signal validates resume keys" do
    wait = Wait.new!(:external_signal, resume_key: "resume-1", payload: %{kind: :signal})
    resume_signal = ResumeSignal.new!(:external_signal, "resume-1", payload: %{approved: true})

    assert {:ok, %{approved: true}} = NormalizeResumeSignal.normalize(wait, resume_signal)
  end

  test "controlled generate retries retryable failures" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      case Agent.get_and_update(counter, fn value -> {value, value + 1} end) do
        0 ->
          {:error, Error.provider("temporary failure", retryable?: true)}

        _ ->
          {:ok, TestClient.result("eventual success")}
      end
    end

    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state,
        input_message: "Hello",
        model: "test:model",
        client: client
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, result} =
             GenerateTurnControlled.generate(turn_request, prompt,
               retry_policy: [max_attempts: 2]
             )

    assert result.message.content == "eventual success"
  end

  test "controlled generate surfaces retry exhaustion" do
    client = fn _model, _prompt, _opts ->
      {:error, Error.provider("still failing", retryable?: true)}
    end

    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state,
        input_message: "Hello",
        model: "test:model",
        client: client
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:retry, %Error{message: "still failing"}} =
             GenerateTurnControlled.generate(turn_request, prompt,
               retry_policy: [max_attempts: 2]
             )
  end

  test "controlled generate annotates terminal fallback errors with their route" do
    client = fn model, _prompt, _opts ->
      {:error, Error.provider("#{model} failed", details: %{requested_model: model})}
    end

    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state,
        input_message: "Hello",
        model: "test:primary",
        client: client
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:error, %Error{} = error} =
             GenerateTurnControlled.generate(turn_request, prompt,
               fallback_policy: [alternates: [%{model: "test:fallback"}]]
             )

    assert error.details.requested_model == "test:fallback"
    assert error.details.fallback?
    assert error.details.primary_model == "test:primary"
    assert error.details.fallback_model == "test:fallback"
  end

  test "controlled generate does not change models for permanent account failures" do
    {:ok, models} = Agent.start_link(fn -> [] end)

    client = fn model, _prompt, _opts ->
      Agent.update(models, &(&1 ++ [model]))

      {:error,
       Error.provider("generation failed",
         details: %{
           requested_model: model,
           status: 429,
           reason_message: "insufficient_quota: credit balance exhausted"
         }
       )}
    end

    turn_request =
      State.new!(system: "You are helpful")
      |> TurnRequest.new!(
        input_message: "Hello",
        model: "test:primary",
        client: client
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:error, %Error{}} =
             GenerateTurnControlled.generate(turn_request, prompt,
               fallback_policy: [alternates: [%{model: "test:fallback"}]]
             )

    assert Agent.get(models, & &1) == ["test:primary"]
  end

  test "controlled tool execution falls back when batch results contain errors" do
    failing_tool =
      Definition.new!(
        name: "failing_tool",
        description: "Always fails",
        parameter_schema: [],
        executor: fn _args ->
          {:error, Error.unexpected("boom")}
        end
      )

    selection = Selection.new!(Registry.new!([failing_tool]), [failing_tool])
    request = CallRequest.new!("call_1", "failing_tool", %{}, request_index: 0)
    execution_plan = ExecutionPlan.new!([request])

    alternate_batch =
      BatchResult.new!([
        CallResult.ok!(request, %{result: "fallback ok"})
      ])

    assert {:ok,
            %BatchResult{results: [%CallResult{status: :ok, output: %{result: "fallback ok"}}]}} =
             ExecuteToolCallsControlled.execute(
               execution_plan,
               selection,
               fallback_policy: [
                 alternates: [
                   fn _plan, _selection -> {:ok, alternate_batch} end
                 ]
               ]
             )
  end

  test "controlled generate honors ordered fallback routes" do
    client = fn _model, _prompt, _opts ->
      {:error, Error.provider("primary failure")}
    end

    state = State.new!(system: "You are helpful")

    turn_request =
      TurnRequest.new!(state,
        input_message: "Hello",
        model: "test:model",
        client: client
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, result} =
             GenerateTurnControlled.generate(
               turn_request,
               prompt,
               fallback_policy: [
                 alternates: [
                   fn _request, _prompt ->
                     {:error, Error.provider("first alternate failed")}
                   end,
                   fn _request, _prompt -> {:ok, TestClient.result("fallback success")} end
                 ]
               ]
             )

    assert result.message.content == "fallback success"
  end

  test "controlled generate retries tool-free required turns then falls back to another model" do
    {:ok, calls} = Agent.start_link(fn -> %{} end)

    fallback_response =
      TestClient.tool_response([
        TestClient.tool_call("apply_patch", %{
          operations: [%{op: "create", path: "lib/demo.ex", content: "demo"}]
        })
      ])

    client = fn model, _prompt, _opts ->
      Agent.update(calls, fn state ->
        Map.update(state, model, 1, fn count -> count + 1 end)
      end)

      case model do
        "test:primary" -> {:ok, TestClient.result("I cannot make the requested change.")}
        "test:fallback" -> {:ok, fallback_response}
      end
    end

    turn_request =
      State.new!(system: "You are a coding agent")
      |> TurnRequest.new!(
        input_message: "Create the module",
        model: "test:primary",
        client: client,
        tool_choice: :required
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, result} =
             GenerateTurnControlled.generate(turn_request, prompt,
               retry_policy: [max_attempts: 2, backoff: 0],
               fallback_policy: [alternates: [%{model: "test:fallback"}]]
             )

    assert Agent.get(calls, & &1) == %{"test:fallback" => 1, "test:primary" => 2}
    assert result.finish_reason == :tool_calls
    assert result.metadata.generation_evidence.fallback?
    assert result.metadata.generation_evidence.primary_model == "test:primary"
    assert result.metadata.generation_evidence.fallback_model == "test:fallback"
    assert result.metadata.generation_evidence.tool_call_count == 1
  end

  test "controlled generate accepts a normal tool-free answer when tools are optional" do
    client = fn _model, _prompt, _opts -> {:ok, TestClient.result("Done")} end

    turn_request =
      State.new!(system: "You are helpful")
      |> TurnRequest.new!(
        input_message: "Answer normally",
        model: "test:primary",
        client: client
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, result} =
             GenerateTurnControlled.generate(turn_request, prompt,
               fallback_policy: [alternates: ["test:fallback"]]
             )

    assert result.message.content == "Done"
    refute Map.get(result.metadata, :generation_evidence, %{})[:fallback?]
  end

  test "controlled generate accepts a final answer after a required tool was already observed" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      Agent.update(calls, &(&1 + 1))
      {:ok, TestClient.result("Verification passed")}
    end

    state =
      State.new!(
        system: "You are a coding agent",
        messages: [RunicAI.Message.new!(:tool, "command passed", name: "run_tests")]
      )

    turn_request =
      TurnRequest.new!(state,
        model: "test:primary",
        client: client,
        tool_choice: :required
      )

    prompt = AssembleTurnPrompt.build_prompt(turn_request)

    assert {:ok, result} =
             GenerateTurnControlled.generate(turn_request, prompt,
               retry_policy: [max_attempts: 3, backoff: 0],
               fallback_policy: [alternates: ["test:fallback"]]
             )

    assert result.message.content == "Verification passed"
    assert Agent.get(calls, & &1) == 1
  end
end
