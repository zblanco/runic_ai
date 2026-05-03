defmodule RunicAI.Terminal.ReviewPromptTest do
  use ExUnit.Case, async: true

  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.ReviewPrompt

  test "maps plain terminal input to review decisions without stdin" do
    request = ReviewRequest.new!(:tool_review, resume_key: "review-1")

    assert {:ok, decision} = ReviewPrompt.decide_with_input(request, "a")
    assert decision.status == :approved
    assert decision.resume_key == "review-1"

    assert {:ok, decision} = ReviewPrompt.decide_with_input(request, "deny")
    assert decision.status == :rejected

    assert {:ok, decision} = ReviewPrompt.decide_with_input(request, "stop")
    assert decision.status == :cancelled
  end

  test "hands rewrite text through the review boundary" do
    request =
      ReviewRequest.new!(:tool_review,
        resume_key: "review-2",
        subject: "old command",
        options: [:approve, :reject, :edit, :cancel]
      )

    assert {:ok, decision} =
             ReviewPrompt.decide_with_input(request, "rewrite",
               editor_fun: fn "old command" -> "new command" end
             )

    assert decision.status == :edited
    assert decision.edited_value == "new command"
  end

  test "builds a blocked event for non-interactive review denial" do
    request = ReviewRequest.new!(:destructive_patch, resume_key: "review-3")

    event = ReviewPrompt.blocked_event(request, %{session_id: "session-1"}, "denied")

    assert event.kind == :hitl
    assert event.status == :blocked
    assert event.session_id == "session-1"
    assert event.detail == "denied"
  end
end
