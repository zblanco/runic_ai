defmodule RunicAI.Terminal.OwlPresenterTest do
  use ExUnit.Case, async: true

  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.OwlPresenter

  test "renders an ASCII-safe header when unicode is disabled" do
    rendered =
      OwlPresenter.render_header(
        %{
          session_id: "session-1",
          cwd: "/tmp/demo",
          agent: :standard,
          renderer: :owl,
          theme: :runic
        },
        color: :never,
        unicode: :never,
        theme: :runic
      )

    assert rendered =~ "+-"
    assert rendered =~ "RunicAI agent"
    assert rendered =~ "renderer:  owl"
  end

  test "renders styled event output without losing detail" do
    event =
      Event.new!(:tool,
        agent: :standard,
        phase: :call,
        status: :running,
        title: "Tool call: read_file",
        detail: "%{path: \"lib/demo.ex\"}",
        data: %{tool_name: "read_file"}
      )

    rendered =
      OwlPresenter.render_event(event,
        detail: :collapsed,
        color: :always,
        theme: :runic,
        width: 120
      )

    assert rendered =~ "\e["
    assert rendered =~ "Tool call: read_file"
    assert rendered =~ "lib/demo.ex"
  end

  test "renders review prompts through the Owl presenter" do
    request =
      ReviewRequest.new!(:destructive_patch,
        resume_key: "review-1",
        details: %{reason: "delete file", path: "lib/old.ex"}
      )

    rendered =
      OwlPresenter.render_review_prompt(request,
        color: :never,
        unicode: :never,
        theme: :runic
      )

    assert rendered =~ "Review required"
    assert rendered =~ "delete file"
    assert rendered =~ "lib/old.ex"
  end

  test "renders multiline final reports without table drift" do
    rendered =
      OwlPresenter.render_final_report(
        %{
          agent: :standard,
          status: :idle,
          session_id: "session-1",
          summary: %{
            reply: """
            **RunicAI** is a workflow-native framework.

            ## What it provides

            - Chat agents
            - Tool-using agents
            """
          }
        },
        color: :never,
        unicode: :always,
        theme: :runic,
        width: 80
      )

    refute rendered =~ "field"
    refute rendered =~ "value"
    assert rendered =~ "reply:"
    assert rendered =~ "**RunicAI** is a workflow-native framework."
    assert rendered =~ "## What it provides"
    assert rendered =~ "- Tool-using agents"
  end
end
