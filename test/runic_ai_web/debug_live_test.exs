defmodule RunicAIWeb.DebugLiveTest do
  use RunicAIWeb.ConnCase, async: false

  alias RunicAI.Persistence.ManagedWorkflows
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Workbench

  test "logs page filters by query params and exports persisted JSONL", %{conn: conn} do
    run_id = seed_debug_run()

    {:ok, _view, html} = live(conn, ~p"/debug/logs?run_id=#{run_id}&kind=status&limit=2")

    assert html =~ "Debug Logs"
    assert html =~ "Phase 5 debug run started"
    assert html =~ "showing 1 of 1 rows"
    assert html =~ "JSONL"

    conn = get(conn, ~p"/debug/export/#{run_id}")
    assert response(conn, 200) =~ "Phase 5 debug run started"
    assert get_resp_header(conn, "content-type") == ["application/x-ndjson; charset=utf-8"]
  end

  test "traces page keeps event sets bounded by limit", %{conn: conn} do
    run_id = seed_debug_run()

    {:ok, _view, html} = live(conn, ~p"/debug/traces?run_id=#{run_id}&limit=2")

    assert html =~ "Traces And Events"
    assert html =~ "Terminal Events"
    assert html =~ "Runnable Lifecycle"
    assert html =~ "Workflow Events"
    assert html =~ "limit 2"
  end

  test "managed workflows page is reloadable from status query param", %{conn: conn} do
    run_id = seed_debug_run()

    {:ok, _view, html} = live(conn, ~p"/debug/managed?status=paused&q=phase-five-debug")

    assert html =~ "Managed Workflows"
    assert html =~ "phase-five-debug"
    assert html =~ run_id
  end

  test "scorecards page exposes objective status filters", %{conn: conn} do
    run_id = seed_debug_run()

    {:ok, _view, html} =
      live(conn, ~p"/debug/scorecards?run_id=#{run_id}&status=objective_satisfied")

    assert html =~ "Scorecards And Evals"
    assert html =~ "objective_satisfied"
    assert html =~ run_id
  end

  test "context inspector shows source cues messages artifacts and facts", %{conn: conn} do
    run_id = seed_debug_run()

    {:ok, _view, html} = live(conn, ~p"/debug/context?run_id=#{run_id}&limit=10")

    assert html =~ "Context Inspector"
    assert html =~ "Source Cues"
    assert html =~ "source-cue-phase-five"
    assert html =~ ".docs/phase-five-debug.md"
    assert html =~ "Final Phase 5 answer"
  end

  test "health page shows system and persistence counts", %{conn: conn} do
    seed_debug_run()

    {:ok, _view, html} = live(conn, ~p"/debug/health")

    assert html =~ "System Health"
    assert html =~ "terminal_events"
    assert html =~ "managed_workflows"
    assert html =~ "127.0.0.1"
  end

  test "diagnostics export redacts token material and includes packaging health", %{conn: conn} do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.merge(previous, auth_token: "secret-token", auth_required?: true)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    conn = get(conn, ~p"/debug/diagnostics?token=secret-token")
    body = json_response(conn, 200)

    assert body["app"]["name"] == "runic_ai"
    assert body["workbench"]["auth_required?"] == true
    refute inspect(body) =~ "secret-token"
  end

  defp seed_debug_run do
    SQLite.migrate!(Workbench.store!())

    unique = System.unique_integer([:positive])
    run_id = "test:debug:#{unique}"
    workflow_key = "phase-five-debug-#{unique}"
    now = DateTime.utc_now()

    {:ok, _workflow} =
      ManagedWorkflows.create(Workbench.store!(), %{
        workflow_key: workflow_key,
        workflow_name: "Phase Five Debug",
        status: :paused,
        definition_kind: :term,
        definition: %{steps: [:collect, :verify]},
        checkpoint_strategy: :manual,
        restart_policy: :manual,
        last_run_id: run_id,
        metadata_json: %{trigger: "browser-validation"}
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: "test:debug:event:start:#{System.unique_integer([:positive])}",
        session_id: run_id,
        run_id: run_id,
        agent: :assistant,
        kind: :status,
        phase: :session,
        status: :running,
        title: "Phase 5 debug run started",
        detail: "source-cue-phase-five from .docs/phase-five-debug.md",
        data_json: %{objective: "Validate Phase 5 debug workbench"},
        at: now
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: "test:debug:event:node:#{System.unique_integer([:positive])}",
        session_id: run_id,
        run_id: run_id,
        agent: :assistant,
        kind: :rlm_node,
        phase: :node_completed,
        status: :ok,
        title: "Context inspector node completed",
        detail: "source-cue-phase-five",
        data_json: %{
          stage: :node_completed,
          data: %{
            runnable: %{
              id: "debug-node",
              node: "inspect_sources",
              component_id: "context_inspector",
              component_type: "tool_leaf"
            },
            output: %{text: "source-cue-phase-five"}
          }
        },
        at: DateTime.add(now, 1, :second)
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: "test:debug:event:summary:#{System.unique_integer([:positive])}",
        session_id: run_id,
        run_id: run_id,
        agent: :assistant,
        kind: :summary,
        phase: :completed,
        status: :ok,
        title: "Phase 5 debug run completed",
        detail: "Final Phase 5 answer with source-cue-phase-five",
        data_json: %{
          output_text: "Final Phase 5 answer",
          scorecard: %{
            component_id: "phase_5_validation",
            objective_status: :objective_satisfied,
            source_cues: ["source-cue-phase-five"]
          },
          artifacts: [
            %{
              path: ".docs/phase-five-debug.md",
              kind: "report",
              action: "verified",
              payload: %{source_cue: "source-cue-phase-five"}
            }
          ]
        },
        at: DateTime.add(now, 2, :second)
      })

    run_id
  end
end
