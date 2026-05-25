defmodule RunicAI.Control.ControlContractsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Control.BudgetDecision
  alias RunicAI.Control.BudgetPolicy
  alias RunicAI.Control.BudgetSnapshot
  alias RunicAI.Control.FallbackPolicy
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardPoint
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Control.RetryPolicy
  alias RunicAI.ResumeSignal
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  test "wait, review request, review decision, and resume signal validate" do
    assert {:ok, %Wait{resume_key: resume_key}} =
             Wait.new(:user_input, reason: :need_user, until: DateTime.utc_now())

    assert is_binary(resume_key)

    assert {:ok, %ReviewRequest{checkpoint: :pre_answer}} =
             ReviewRequest.new(:guard_review,
               checkpoint: :pre_answer,
               subject: %{draft: "answer"}
             )

    assert {:ok, %ReviewDecision{status: :edited}} =
             ReviewDecision.new("resume-1", :edited, edited_value: %{approved: true})

    assert {:ok, %ResumeSignal{kind: :review}} =
             ResumeSignal.new(:review, "resume-1", payload: %{approved: true})

    assert %ReviewDecision{status: :approved} =
             ReviewDecision.from_input!(%{resume_key: "resume-2", status: :approved})

    assert %ReviewDecision{
             resume_key: "resume-3",
             status: :edited,
             edited_value: "continue with narrower scope",
             actor: "web",
             metadata: %{"source" => "browser"}
           } =
             ReviewDecision.from_input!(%{
               "resume_key" => "resume-3",
               "status" => "edited",
               "edited_value" => "continue with narrower scope",
               "actor" => "web",
               "metadata" => %{"source" => "browser"}
             })

    assert %ResumeSignal{kind: :external_signal} =
             ResumeSignal.from_input!(%{
               kind: :external_signal,
               resume_key: "resume-2",
               payload: %{released: true}
             })

    assert %ResumeSignal{
             kind: :review,
             resume_key: "resume-3",
             payload: %{"released" => true},
             metadata: %{"source" => "browser"}
           } =
             ResumeSignal.from_input!(%{
               "kind" => "review",
               "resume_key" => "resume-3",
               "payload" => %{"released" => true},
               "metadata" => %{"source" => "browser"}
             })
  end

  test "review decisions and resume signals return validation errors for malformed maps" do
    assert {:error, review_error} = ReviewDecision.from_input(%{"status" => "approved"})
    assert review_error.message == "review decision resume_key must be a non-empty string"
    assert review_error.details.resume_key == nil

    assert {:error, status_error} =
             ReviewDecision.from_input(%{"resume_key" => "resume-4", "status" => "unknown"})

    assert status_error.message =~ "invalid review decision status"
    assert status_error.details.status == "unknown"

    assert {:error, signal_error} =
             ResumeSignal.from_input(%{"kind" => "unregistered", "resume_key" => "resume-5"})

    assert signal_error.message =~ "unsupported resume signal kind"
    assert signal_error.details.kind == "unregistered"

    assert {:error, resume_key_error} = ResumeSignal.from_input(%{"kind" => "review"})
    assert resume_key_error.message == "resume signal resume_key must be a non-empty string"
    assert resume_key_error.details.resume_key == nil
  end

  test "budget policy, snapshot, and decision validate" do
    assert {:ok, %BudgetPolicy{on_exhaustion: :review}} =
             BudgetPolicy.new(max_turns: 3, max_tool_calls: 2, on_exhaustion: :review)

    snapshot =
      BudgetSnapshot.new!(
        turns: 3,
        model_calls: 3,
        tool_calls: 1,
        elapsed_ms: 200,
        estimated_cost: 0.03,
        recursion_depth: 1
      )

    assert {:ok, %BudgetDecision{status: :soft_limit, action: :continue}} =
             BudgetDecision.new(:soft_limit, :continue, snapshot,
               reasons: [%{metric: :turns, actual: 3, limit: 3, status: :soft_limit}]
             )
  end

  test "guard request and guard decision validate" do
    state = State.new!(system: "You are helpful")

    assert GuardPoint.standard?(:pre_answer)
    refute GuardPoint.standard?(:custom_guard)
    assert :ok = GuardPoint.validate(:custom_guard)

    guard_request =
      GuardRequest.new!(
        :pre_answer,
        state,
        subject: %{draft: "answer"},
        metadata: %{source: :test}
      )

    assert guard_request.point == :pre_answer

    assert {:ok, %GuardDecision{action: :rewrite}} =
             GuardDecision.rewrite(:edited, %{draft: "approved"})
  end

  test "retry and fallback policies accept functional hooks" do
    assert {:ok, %RetryPolicy{max_attempts: 3}} =
             RetryPolicy.new(
               max_attempts: 3,
               backoff: fn attempt -> attempt end,
               retry_if: &match?({:error, _}, &1)
             )

    assert {:ok, %FallbackPolicy{alternates: [alt]}} =
             FallbackPolicy.new(
               alternates: [fn -> {:ok, :alt} end],
               fallback_if: &match?({:error, _}, &1),
               degrade_to: fn _ -> {:ok, :degraded} end
             )

    assert is_function(alt)
  end

  test "turn request reserves phase 3 control inputs from llm opts" do
    turn_request =
      TurnRequest.from_input!(
        %{
          user: "hello",
          runtime: %{elapsed_ms: 1000},
          review_decision: %{status: :approved},
          resume_signal: %{resume_key: "resume-1"},
          control: %{mode: :review}
        },
        system: "You are helpful",
        model: "test:model",
        temperature: 0.2
      )

    assert turn_request.llm_opts[:temperature] == 0.2
    refute Keyword.has_key?(turn_request.llm_opts, :runtime)
    refute Keyword.has_key?(turn_request.llm_opts, :review_decision)
    refute Keyword.has_key?(turn_request.llm_opts, :resume_signal)
    refute Keyword.has_key?(turn_request.llm_opts, :control)
  end
end
