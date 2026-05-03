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

  test "renders expanded RLM proposal as Mermaid when graph mode requests it" do
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

    rendered = EventPresenter.render_event(event, detail: :expanded, graph: :mermaid)

    assert rendered =~ "flowchart TD"
    assert rendered =~ "n1[\"inspect\\n(tool)\"]"
    assert rendered =~ "n1 --> n2"
  end

  test "renders compiled Runic graph summary from native nodes and serializers" do
    event =
      Event.new!(:rlm_plan,
        agent: :assistant,
        phase: :compiled,
        status: :ok,
        title: "Assistant workflow compiled",
        data: %{
          compiled: %{
            graph_summary: %{
              runic: %{
                native_nodes: [
                  %{id: "input", name: "assistant_input", kind: :input},
                  %{id: "map", name: "assistant_node_3_map", kind: :map}
                ],
                edgelist: [%{from: "assistant_input", to: "assistant_node_3_map"}],
                serializers: %{mermaid: "flowchart TD\n  A --> B"}
              }
            }
          }
        }
      )

    text = EventPresenter.render_event(event, detail: :expanded)
    assert text =~ "[assistant_input] input <- root"
    assert text =~ "[assistant_node_3_map] map <- assistant_input"

    mermaid = EventPresenter.render_event(event, detail: :expanded, graph: :mermaid)
    assert mermaid =~ "flowchart TD"
    assert mermaid =~ "A --> B"
  end

  test "renders representative event kinds without dropping titles" do
    events =
      [
        {:status, :session, :running, "Status"},
        {:message, :assistant, :ok, "Message"},
        {:tool, :call, :ok, "Tool"},
        {:hitl, :review, :review, "HITL"},
        {:rlm_plan, :proposed, :ok, "RLM plan"},
        {:rlm_node, :episode, :ok, "RLM node"},
        {:verification, :observation, :ok, "Verification"},
        {:repair, :attempt, :ok, "Repair"},
        {:error, :run, :error, "Error"},
        {:summary, :output, :ok, "Summary"}
      ]

    for {kind, phase, status, title} <- events do
      rendered =
        kind
        |> Event.new!(phase: phase, status: status, title: title, detail: "detail", data: %{})
        |> EventPresenter.render_event(detail: :collapsed)

      assert rendered =~ title
      assert rendered =~ String.upcase(to_string(status))
    end
  end

  test "renders mmdflux tool output as terminal content in collapsed mode" do
    event =
      Event.new!(:status,
        agent: :standard,
        phase: :tool_result,
        status: :ok,
        title: "Tool result",
        detail: "%{output: %{rendered: \"hidden\"}}",
        data: %{
          output: %{
            output: %{
              command: "mmdflux --format text --color off",
              status: :pass,
              path: "livebooks/rlm-coding-agent.livemd",
              heading: "Architecture",
              diagram_index: 1,
              line_start: 70,
              rendered: "flowchart TD\n  A --> B"
            }
          }
        }
      )

    rendered = EventPresenter.render_event(event, detail: :collapsed)

    assert rendered =~ "mmdflux: pass"
    assert rendered =~ "source: livebooks/rlm-coding-agent.livemd, heading Architecture"
    assert rendered =~ "rendered:"
    assert rendered =~ "    flowchart TD"
    assert rendered =~ "      A --> B"
  end

  test "renders final standard report" do
    rendered =
      EventPresenter.render_final_report(%{
        agent: :standard,
        status: :completed,
        session_id: "session-1",
        summary: %{
          status: :completed,
          changed_files: ["lib/demo.ex"],
          tools_used: ["read_file"],
          risks: [],
          reply: "Done"
        }
      })

    assert rendered =~ "Final report"
    assert rendered =~ "agent status: completed"
    assert rendered =~ "changed files: lib/demo.ex"
    assert rendered =~ "reply: Done"
  end

  test "renders Mermaid diagrams in final standard report" do
    rendered =
      EventPresenter.render_final_report(%{
        agent: :standard,
        status: :completed,
        session_id: "session-1",
        summary: %{
          status: :idle,
          tools_used: ["extract_diagrams", "render_mermaid"],
          rendered_diagrams: [
            %{
              status: :pass,
              path: "guides/stateless-vs-stateful-agents.md",
              heading: "Integrated stateful agents",
              diagram_index: 2,
              line_start: 78,
              rendered: "flowchart LR\n  RuntimeState --> SessionState"
            }
          ],
          reply: "Rendered."
        }
      })

    assert rendered =~ "rendered diagrams:"
    assert rendered =~ "guides/stateless-vs-stateful-agents.md"
    assert rendered =~ "heading Integrated stateful agents"
    assert rendered =~ "flowchart LR"
    assert rendered =~ "RuntimeState --> SessionState"
    assert rendered =~ "reply: Rendered."
  end

  test "renders standard report agent errors as first-class final context" do
    rendered =
      EventPresenter.render_final_report(%{
        agent: :standard,
        status: :error,
        session_id: "session-1",
        summary: %{
          status: :halted,
          last_error: "validation: tool arguments failed validation",
          risks: ["turn ended with error: validation: tool arguments failed validation"]
        }
      })

    assert rendered =~ "status: error"
    assert rendered =~ "agent status: halted"
    assert rendered =~ "error: validation: tool arguments failed validation"
    assert rendered =~ "turn ended with error"
  end
end
