defmodule RunicAI.Terminal.EventPresenterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.EventPresenter

  test "renders compact event lines" do
    event =
      Event.new!(:tool,
        agent: :standard,
        phase: :call,
        status: :running,
        title: "Tool call: read_file",
        detail: "%{path: \"lib/demo.ex\"}",
        data: %{tool_name: "read_file"}
      )

    rendered = EventPresenter.render_event(event, detail: :collapsed)

    assert rendered =~ "RUNNING tool/call Tool call: read_file"
    assert rendered =~ "lib/demo.ex"
  end

  test "renders expanded RLM proposal graph details" do
    event =
      Event.new!(:rlm_plan,
        agent: :rlm,
        phase: :proposed,
        status: :ok,
        title: "RLM proposal",
        data: %{
          proposal: %{
            objective: "Explain Demo",
            nodes: [
              %{id: "inspect", kind: :tool, dependencies: []},
              %{id: "answer", kind: :reducer, dependencies: ["inspect"]}
            ]
          }
        }
      )

    rendered = EventPresenter.render_event(event, detail: :expanded)

    assert rendered =~ "objective: Explain Demo"
    assert rendered =~ "[inspect] tool <- root"
    assert rendered =~ "[answer] reducer <- inspect"
  end

  test "renders final standard report" do
    rendered =
      EventPresenter.render_final_report(%{
        agent: :standard,
        status: :completed,
        session_id: "session-1",
        summary: %{
          changed_files: ["lib/demo.ex"],
          tools_used: ["read_file"],
          risks: [],
          reply: "Done"
        }
      })

    assert rendered =~ "Final report"
    assert rendered =~ "changed files: lib/demo.ex"
    assert rendered =~ "reply: Done"
  end
end
