defmodule RunicAI.Coding.AgentStateTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.State
  alias RunicAI.Coding.AgentState
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Message

  test "summarizes rendered Mermaid diagrams from render_mermaid tool observations" do
    tool_message =
      Message.new!(
        :tool,
        Jason.encode!(%{
          result: %{
            status: "pass",
            command: "mmdflux --format text --color auto",
            path: "guides/stateless-vs-stateful-agents.md",
            heading: "Stateful Agents",
            diagram_index: 2,
            line_start: 42,
            rendered: "flowchart LR\n  App --> RuntimeState"
          }
        }),
        name: "render_mermaid"
      )

    agent_state =
      State.new!(
        messages: [
          tool_message,
          Message.new!(:assistant, "Rendered the diagram.")
        ]
      )

    session = SessionState.new!("coding", agent_state: agent_state)
    summary = AgentState.summary(session)

    assert [
             %{
               status: "pass",
               path: "guides/stateless-vs-stateful-agents.md",
               heading: "Stateful Agents",
               diagram_index: 2,
               line_start: 42,
               rendered: "flowchart LR\n  App --> RuntimeState"
             }
           ] = summary.rendered_diagrams
  end
end
