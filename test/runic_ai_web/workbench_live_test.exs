defmodule RunicAIWeb.WorkbenchLiveTest do
  use RunicAIWeb.ConnCase, async: false

  alias RunicAI.Workbench
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite

  test "renders the durable workbench shell and selected session", %{conn: conn} do
    session_id = unique_session_id()

    seed_session(session_id, "Render the LiveView workbench")

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ "Agent workbench"
    assert html =~ "Render the LiveView workbench"
    assert html =~ "Durable browser message"
    assert html =~ "Debug records"
    assert html =~ "Events"
    assert html =~ ~s(href="/")
    assert html =~ "RunicAI home"
  end

  test "renders immediate user conversation context when run metadata is sparse", %{conn: conn} do
    session_id = unique_session_id()

    seed_sparse_user_session(session_id, "Sparse metadata session", "Visible follow-up user turn")

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ "Sparse metadata session"
    assert html =~ "Visible follow-up user turn"
    assert html =~ "doops"
  end

  test "root route renders the chat input landing page", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Show recent session")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(src="/images/runic-tome-logo.png")
    assert html =~ "Ask RunicAI to research, explain, inspect, plan, or make a local change"
    refute html =~ "Show recent session"
    refute html =~ "Recent sessions"
    refute html =~ "Agent workbench"
  end

  test "root composer starts a run and navigates to the workbench session", %{conn: conn} do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_landing_run/3)
      |> Keyword.put(:max_runtime_ms, 2_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("landing")
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#landing-run-form")
    |> render_submit(%{
      run: %{
        "session_id" => session_id,
        "objective" => "Explain the local workbench"
      }
    })

    assert_redirect(view, ~p"/sessions/#{session_id}")
  end

  test "new session route starts with an empty objective state and sidebar launch affordance", %{
    conn: conn
  } do
    session_id = unique_session_id()
    seed_session(session_id, "Existing session remains in history")

    {:ok, _view, html} = live(conn, ~p"/sessions/new")

    assert html =~ "New session"
    assert html =~ "Local agent workbench"
    assert html =~ "Start a local assistant run from the composer below."
    assert html =~ "Run setup"
    assert html =~ "structured/source-grounded workflows"
    assert html =~ "pause in browser"
    assert html =~ "Existing session remains in history"
  end

  test "review controls persist a durable decision before reloading the session", %{conn: conn} do
    session_id = unique_session_id()
    review_id = "review:web:#{System.unique_integer([:positive])}"
    seed_session(session_id, "Approve the pending browser review")
    seed_review(session_id, review_id)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    view
    |> element("button", "Reviews")
    |> render_click()

    assert render(view) =~ "Approve once"

    view
    |> element("#review-form-#{dom_id(review_id)}")
    |> render_submit(%{review: %{"id" => review_id, "action" => "approve", "rewrite" => ""}})

    store = Workbench.store!()

    assert [%{status: "approved"}] =
             store
             |> Queries.review_requests(session_id)
             |> Enum.map(&%{status: &1.status})
  end

  test "blocked non-review events do not render disabled HITL controls in chat", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Summarize review-oriented architecture")
    seed_blocked_scorecard(session_id)

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    refute html =~ "Review required"
    refute html =~ "Approve once"
    assert html =~ "Objective scorecard blocked"
  end

  test "phase 7 controls expose command palette filters pins and display modes", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Polish the browser controls")

    {:ok, view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ "Command palette"

    view
    |> element("#command-palette-button")
    |> render_click()

    assert render(view) =~ "Commands"
    assert render(view) =~ "New session"

    view
    |> element("button[phx-click='toggle_session_pin']")
    |> render_click()

    assert render(view) =~ "Pinned"

    view
    |> element("button[phx-value-filter='pinned']")
    |> render_click()

    assert_patch(view, ~p"/sessions/#{session_id}?filter=pinned")
    assert render(view) =~ "Polish the browser controls"

    view
    |> element("button[phx-click='toggle_contrast']")
    |> render_click()

    assert render(view) =~ ~s(data-contrast="high")

    view
    |> element("button[phx-click='toggle_motion']")
    |> render_click()

    assert render(view) =~ ~s(data-motion="reduced")
  end

  test "artifact inspector supports diff focus bookmarks and comparison slots", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Inspect a browser artifact diff")
    seed_artifact(session_id)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    view
    |> element("button[phx-value-tab='artifacts']")
    |> render_click()

    assert render(view) =~ "Diff artifact"
    assert render(view) =~ "+new browser line"

    view
    |> element("button[phx-click='toggle_artifact_bookmark']")
    |> render_click()

    assert render(view) =~ "Bookmarked"

    view
    |> element("button[phx-click='toggle_compare_session']")
    |> render_click()

    view
    |> element("button[phx-value-tab='details']")
    |> render_click()

    assert render(view) =~ "Prompt/model comparison"
    assert render(view) =~ "Inspect a browser artifact diff"
  end

  test "encoded session ids are routed through LiveView instead of static assets", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Load an encoded session route")

    conn = get(conn, "/sessions/#{URI.encode(session_id)}")

    assert html_response(conn, 200) =~ "Load an encoded session route"
  end

  defp seed_session(session_id, objective) do
    SQLite.migrate!(Workbench.store!())

    now = DateTime.utc_now()

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("start"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :status,
        phase: :session,
        status: :running,
        title: "Workbench run queued",
        detail: objective,
        data_json: %{
          run_id: session_id,
          cwd: File.cwd!(),
          objective: objective,
          model: "test:model"
        },
        at: now
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("message"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :message,
        phase: :assistant,
        status: :ok,
        title: "Assistant response",
        detail: "Durable browser message with `code`.",
        data_json: %{reply_text: "Durable browser message with `code`."},
        at: DateTime.add(now, 1)
      })
  end

  defp seed_review(session_id, review_id) do
    SQLite.migrate!(Workbench.store!())

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("review"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :hitl,
        phase: :review_requested,
        status: :review,
        title: "Browser review requested",
        detail: "approve a browser action",
        data_json: %{
          stage: :review_requested,
          status: :review,
          data: %{
            id: review_id,
            kind: :browser_review,
            checkpoint: :pre_tool,
            resume_key: review_id,
            options: [:approve, :reject, :edit, :cancel],
            details: %{tool_name: "apply_patch"}
          }
        },
        at: DateTime.utc_now()
      })
  end

  defp seed_sparse_user_session(session_id, title, user_content) do
    SQLite.migrate!(Workbench.store!())

    now = DateTime.utc_now()

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("sparse-start"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :status,
        phase: :session,
        status: :running,
        title: "Workbench run queued",
        detail: title,
        data_json: %{
          run_id: session_id,
          cwd: File.cwd!(),
          objective: title,
          model: nil,
          approval: nil,
          mode: nil
        },
        at: now
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("sparse-user"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :message,
        phase: :user,
        status: :ok,
        title: "User follow-up",
        detail: user_content,
        data_json: %{
          role: "user",
          content: user_content,
          message_kind: "followup",
          presentation_group_id: session_id
        },
        at: DateTime.add(now, 1)
      })
  end

  defp seed_blocked_scorecard(session_id) do
    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("scorecard"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :summary,
        phase: :scorecard_completed,
        status: :blocked,
        title: "Objective scorecard blocked",
        detail: "source/provenance coverage was required but not present",
        data_json: %{
          scorecard: %{
            objective_status: :objective_incomplete,
            residual_risks: ["source/provenance coverage was required but not present"]
          }
        },
        at: DateTime.utc_now()
      })
  end

  defp seed_artifact(session_id) do
    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("artifact"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :summary,
        phase: :completed,
        status: :ok,
        title: "Artifact summary",
        detail: "diff artifact ready",
        data_json: %{
          artifacts: [
            %{
              path: "lib/example.ex",
              kind: "diff",
              action: "updated",
              payload: %{
                title: "Example diff",
                preview: "lib/example.ex",
                diff: "@@ -1 +1\n-old browser line\n+new browser line"
              }
            }
          ]
        },
        at: DateTime.utc_now()
      })
  end

  defp dom_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp unique_session_id(prefix \\ "test:web"),
    do: "#{prefix}:#{System.unique_integer([:positive])}"

  defp unique_event_id(label), do: "test:web:event:#{label}:#{System.unique_integer([:positive])}"

  def fake_landing_run(_cwd, objective, opts) do
    opts[:event_sink].(%{
      stage: :direct_response_completed,
      status: :ok,
      data: %{
        reply_text: "Landing run complete: #{objective}",
        output: %{text_preview: "Landing run complete: #{objective}"}
      }
    })

    {:ok,
     %{
       scorecard: %{objective_status: :objective_satisfied},
       artifacts: [],
       repair_history: []
     }}
  end
end
