defmodule RunicAIWeb.GraphLiveTest do
  use RunicAIWeb.ConnCase, async: false

  alias RunicAI.Persistence.SQLite
  alias RunicAI.Workbench

  test "agent index lists built-in agent graph pages", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/agents")

    assert html =~ "Agent Graphs"
    assert html =~ "Assistant"
    assert html =~ "Standard/ReAct"
    assert html =~ "RLM"
  end

  test "built-in agent page renders Mermaid source and node inspector", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/agents/assistant")

    assert html =~ "Built-in Assistant graph"
    assert html =~ "flowchart TD"
    assert html =~ "Node inspector"
    assert html =~ "Generate workflow blueprint"
  end

  test "run graph page exposes proposal materialized and execution graph sources", %{conn: conn} do
    run_id = seed_graph_run()

    {:ok, view, html} = live(conn, ~p"/runs/#{run_id}/graph?graph=materialized")

    assert html =~ "Workflow Graph"
    assert html =~ "Materialized Runic workflow graph"
    assert html =~ "assistant_input"
    assert html =~ "Proposal"
    assert html =~ "Execution"

    view
    |> element("button", "Execution")
    |> render_click()

    assert_patch(view, ~p"/runs/#{run_id}/graph?graph=execution")
  end

  test "invalid Mermaid graph keeps source fallback renderable", %{conn: conn} do
    run_id = seed_graph_run(mermaid: "flowchart TD\n  bad(")

    {:ok, _view, html} = live(conn, ~p"/runs/#{run_id}/graph?graph=materialized")

    assert html =~ "Source fallback"
    assert html =~ "flowchart TD"
    assert html =~ "bad("
  end

  defp seed_graph_run(opts \\ []) do
    SQLite.migrate!(Workbench.store!())

    run_id = "test:graph:#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()
    mermaid = Keyword.get(opts, :mermaid, "flowchart TD\n  assistant_input --> assistant_map")

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: "test:graph:event:proposal:#{System.unique_integer([:positive])}",
        session_id: run_id,
        run_id: run_id,
        agent: :rlm,
        kind: :rlm_plan,
        phase: :proposed,
        status: :ok,
        title: "RLM proposal",
        detail: "proposal ready",
        data_json: %{
          proposal: %{
            objective: "Render known generated RLM graph",
            nodes: [
              %{id: "inspect", kind: :tool},
              %{id: "answer", kind: :reducer, dependencies: ["inspect"]}
            ],
            edges: [%{from: "inspect", to: "answer"}]
          }
        },
        at: now
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: "test:graph:event:compiled:#{System.unique_integer([:positive])}",
        session_id: run_id,
        run_id: run_id,
        agent: :rlm,
        kind: :rlm_plan,
        phase: :compiled,
        status: :ok,
        title: "RLM compiled",
        detail: "compiled ready",
        data_json: %{
          compiled: %{
            graph_summary: %{
              runic: %{
                native_nodes: [
                  %{id: "input", name: "assistant_input", kind: :input},
                  %{id: "map", name: "assistant_map", kind: :map}
                ],
                edgelist: [%{from: "assistant_input", to: "assistant_map"}],
                serializers: %{mermaid: mermaid}
              }
            }
          }
        },
        at: DateTime.add(now, 1)
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: "test:graph:event:runnable:#{System.unique_integer([:positive])}",
        session_id: run_id,
        run_id: run_id,
        agent: :rlm,
        kind: :rlm_node,
        phase: :node_completed,
        status: :ok,
        title: "Node completed",
        detail: "assistant_map completed",
        data_json: %{
          stage: :node_completed,
          status: :ok,
          data: %{node_id: "assistant_map", type: :map, output: %{text: "done"}}
        },
        at: DateTime.add(now, 2)
      })

    run_id
  end
end
