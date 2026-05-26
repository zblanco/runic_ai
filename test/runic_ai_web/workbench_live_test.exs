defmodule RunicAIWeb.WorkbenchLiveTest do
  use RunicAIWeb.ConnCase, async: false

  alias RunicAI.Workbench
  alias RunicAI.LLM.ModelCatalog
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

  test "workbench composer exposes provider dependent model selection", %{conn: conn} do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_landing_run/3)
      |> Keyword.put(:max_runtime_ms, 2_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("model-picker")
    {:ok, view, html} = live(conn, ~p"/sessions/new")

    assert html =~ "Provider"
    assert html =~ "Model"
    assert html =~ "OpenAI"
    assert html =~ "gpt-5.4-mini"

    html =
      view
      |> element("form[phx-submit='submit_objective']")
      |> render_change(%{
        run: %{
          "objective" => "Use selected model",
          "model_provider" => "openai",
          "model_id" => "gpt-5.4-mini"
        }
      })

    assert html =~ ~s(value="openai:gpt-5.4-mini")

    view
    |> element("form[phx-submit='submit_objective']")
    |> render_submit(%{
      run: %{
        "session_id" => session_id,
        "objective" => "Use selected model",
        "model_provider" => "openai",
        "model_id" => "gpt-5.4-mini"
      }
    })

    assert_redirect(view, ~p"/sessions/#{session_id}")

    assert %{session: %{model: model}} = Workbench.session_snapshot(session_id)
    assert model == ModelCatalog.default_model_spec()
  end

  test "root composer persists selected capability profile and disabled tools", %{conn: conn} do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_landing_run/3)
      |> Keyword.put(:max_runtime_ms, 2_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("capabilities")
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#landing-run-form")
    |> render_submit(%{
      run: %{
        "session_id" => session_id,
        "objective" => "Inspect command tool capabilities",
        "profile" => "local-workbench",
        "toolsets" => "terminal,code-execution",
        "disabled_tools" => "run_command",
        "tool_config" => "terminal.timeout_ms=90000",
        "sandbox_backend" => "docker",
        "sandbox_runtime" => "python",
        "sandbox_network" => "restricted",
        "sandbox_stateful" => "true",
        "sandbox_pool_warm" => "1",
        "sandbox_pool_max" => "4"
      }
    })

    assert_redirect(view, ~p"/sessions/#{session_id}")

    profile_event =
      Workbench.store!()
      |> Queries.terminal_events_for_session(session_id)
      |> Enum.find(&(&1.phase == "capability_profile_updated"))

    assert profile_event
    profile = profile_event.data_json["capability_profile"]

    assert profile_event.data_json["profile"] == "local-workbench"
    assert profile["name"] == "local_workbench"
    assert "terminal" in profile["toolsets"]
    assert "code_execution" in profile["toolsets"]
    assert "execute_code" in profile["visible_tools"]
    refute "run_command" in profile["visible_tools"]
    assert "run_command" in profile["disabled_tools"]

    code_execution = profile["config"]["code_execution"]
    assert code_execution["default_backend"] == "docker"
    assert code_execution["allowed_runtimes"] == ["python"]
    assert code_execution["network"] == "restricted"
    assert code_execution["stateful?"]
    assert code_execution["pool"] == %{"warm" => 1, "max" => 4}

    assert profile_event.data_json["sandbox"] == %{
             "backend" => "docker",
             "network" => "restricted",
             "review" => "unsafe_actions",
             "runtimes" => ["python"],
             "sandbox" => "local_code",
             "stateful?" => true,
             "pool" => %{"warm" => 1, "max" => 4},
             "workspace" => %{"mode" => "copy_in", "persist?" => true}
           }
  end

  test "new session route starts with an empty objective state and sidebar launch affordance", %{
    conn: conn
  } do
    session_id = unique_session_id()
    seed_session(session_id, "Existing session remains in history")

    {:ok, view, html} = live(conn, ~p"/sessions/new")

    assert html =~ "New session"
    assert html =~ "Local agent workbench"
    assert html =~ "Start a local assistant run from the composer below."
    assert html =~ "Run setup"
    assert html =~ "local-workbench"
    assert html =~ "structured/source-grounded workflows"
    assert html =~ "patch / write"
    assert html =~ "safe auto-approve"
    assert html =~ "workspace writes gated"
    assert html =~ "Sandbox backend"
    assert html =~ "Sandbox runtime"
    assert html =~ "Pool warm"
    assert html =~ "pause in browser"
    assert html =~ "Existing session remains in history"

    plan_html =
      view
      |> element("button[phx-value-tab='plan']")
      |> render_click()

    assert plan_html =~ "Objective loop"
    assert plan_html =~ "Not captured"
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

  test "chat review controls prefer canonical browser resume key over trace review rows", %{
    conn: conn
  } do
    session_id = unique_session_id()
    canonical_id = "integrated:review:pre_tool:#{System.unique_integer([:positive])}"

    seed_session(session_id, "Approve the canonical pending browser review")
    seed_review(session_id, "review:trace:#{System.unique_integer([:positive])}", resume_key: nil)
    seed_review(session_id, canonical_id, resume_key: canonical_id)

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ "review-form-#{dom_id(canonical_id)}"
  end

  test "completed sessions ignore stale duplicate pending review projections", %{conn: conn} do
    session_id = unique_session_id()

    seed_session(session_id, "Completed run with stale review projections")
    seed_review(session_id, "review:terminal:hitl:stale", resume_key: "integrated:review:stale")
    mark_session_completed(session_id)

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ "Completed run with stale review projections"
    refute html =~ "review-form-review-terminal-hitl-stale"
  end

  test "blocked non-review events do not render disabled HITL controls in chat", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Summarize review-oriented architecture")
    seed_blocked_scorecard(session_id)

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    refute html =~ "Review required"
    refute html =~ "Approve once"
    assert html =~ "Objective scorecard blocked"
    assert html =~ "Repair implement_project with dispatch workflow artifacts"
  end

  test "plan tab renders objective contract and blocked next actions", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Build a field service dispatch app")
    seed_blocked_scorecard(session_id)
    seed_objective_loop(session_id)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-value-tab='plan']")
      |> render_click()

    assert html =~ "Objective contract"
    assert html =~ "Objective loop"
    assert html =~ "needs_budget_approval"
    assert html =~ "request_budget_approval"
    assert html =~ "mix compile still fails"
    assert html =~ "repair budget exhausted before objective satisfaction"
    assert html =~ "Live progress"
    assert html =~ "5 persisted events"
    assert html =~ "1.2s"
    assert html =~ "field_service"
    assert html =~ "implementation_artifacts"
    assert html =~ "changed_files"
    assert html =~ "WorkOrder"
    assert html =~ "Blocked evidence"
    assert html =~ "objective_incomplete"
    assert html =~ "implement_project"
    assert html =~ "Repair implement_project with dispatch workflow artifacts"
  end

  test "plan tab renders objective-loop live progress facts", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Build OpsLogic")
    seed_objective_progress(session_id)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-value-tab='plan']")
      |> render_click()

    assert html =~ "Live progress"
    assert html =~ "Objective iteration completed"
    assert html =~ "running"
    assert html =~ "continue"
    assert html =~ "2/3"
    assert html =~ "12.3s"
  end

  test "plan tab renders compiled RLM workflow graph", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Build an inspectable workflow")
    seed_compile_completed_graph(session_id)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-value-tab='plan']")
      |> render_click()

    assert html =~ "Compiled workflow graph"
    assert html =~ "2 nodes - 1 edges"
    assert html =~ "flowchart TB"
    assert html =~ "acceptance_contract"
    assert html =~ "compile_project"
    assert html =~ "Source fallback"
  end

  test "plan tab renders objective-loop error progress facts", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Build OpsLogic")
    seed_objective_error_progress(session_id)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-value-tab='plan']")
      |> render_click()

    assert html =~ "Live progress"
    assert html =~ "Objective loop"
    assert html =~ "Objective budget approval required"
    assert html =~ "needs_budget_approval"
    assert html =~ "request_budget_approval"
    assert html =~ "timeout: RLM runtime budget exhausted"
  end

  test "plan tab renders objective-loop review approval state", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Plan OpsLogic for review")
    seed_objective_review_loop(session_id)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-value-tab='plan']")
      |> render_click()

    assert html =~ "Objective loop"
    assert html =~ "needs_review_approval"
    assert html =~ "request_review_approval"
    assert html =~ "Review request"
    assert html =~ "objective_plan_approval"
    assert html =~ "review:opslogic:plan"
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

  defp seed_review(session_id, review_id, opts \\ []) do
    SQLite.migrate!(Workbench.store!())
    resume_key = Keyword.get(opts, :resume_key, review_id)
    checkpoint = Keyword.get(opts, :checkpoint, :pre_tool)

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
            checkpoint: checkpoint,
            resume_key: resume_key,
            options: [:approve, :reject, :edit, :cancel],
            details: %{tool_name: "apply_patch"}
          }
        },
        at: DateTime.utc_now()
      })
  end

  defp mark_session_completed(session_id) do
    store = Workbench.store!()
    now = DateTime.utc_now()

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("completed"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :status,
        phase: :session,
        status: :ok,
        title: "Session idle",
        detail: "completed",
        data_json: %{session_status: :completed},
        at: now
      })

    SQLite.with_repo(store, fn ->
      import Ecto.Query

      from(session in RunicAI.Persistence.Schemas.AgentSession,
        where: session.id == ^session_id
      )
      |> store.repo.update_all(set: [status: "completed", completed_at: now])
    end)
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
    objective_contract = %{
      metadata: %{
        domain: "field_service",
        generation_profile: "elixir_project",
        evidence_required: ["changed_files", "test_results", "compile_status"]
      },
      requirements: [
        %{
          id: "implementation_artifacts",
          description: "Produce WorkOrder, Technician, Dispatch assignment and lifecycle code."
        },
        %{
          id: "verification_evidence",
          description: "Run mix compile and mix test with visible results."
        }
      ]
    }

    blocked_evidence = %{
      status: :blocked,
      objective_status: :objective_incomplete,
      current_node: "implement_project",
      current_child: "elixir_codegen",
      elapsed_ms: 1_200,
      latest_event: %{title: "Objective scorecard blocked"},
      next_actions: [
        "Repair implement_project with dispatch workflow artifacts",
        "Run compile and focused tests before completing the session"
      ],
      objective_contract: objective_contract
    }

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("blocked-message"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        kind: :message,
        phase: :assistant,
        status: :blocked,
        title: "Blocked RLM output",
        detail: "Objective scorecard blocked",
        data_json: %{
          "blocked?" => true,
          reply_text: "Objective scorecard blocked",
          blocking_reason: "source/provenance coverage was required but not present",
          blocked_evidence: blocked_evidence,
          objective_contract: objective_contract
        },
        at: DateTime.utc_now()
      })

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
          objective_contract: objective_contract,
          blocked_evidence: blocked_evidence,
          next_actions: blocked_evidence.next_actions,
          scorecard: %{
            objective_status: :objective_incomplete,
            residual_risks: ["source/provenance coverage was required but not present"],
            metadata: %{objective_contract: objective_contract}
          }
        },
        at: DateTime.utc_now()
      })
  end

  defp seed_objective_loop(session_id) do
    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("objective-loop"),
        session_id: session_id,
        run_id: session_id,
        agent: :rlm,
        kind: :summary,
        phase: :objective_loop,
        status: :review,
        title: "Objective budget approval required",
        detail: "status: needs_budget_approval",
        data_json: %{
          run_id: session_id,
          objective_iteration_count: 2,
          objective_session: %{
            id: session_id,
            objective: "Build OpsLogic",
            status: :needs_budget_approval,
            iteration_count: 2,
            max_iterations: 2,
            decision: %{action: :request_budget_approval}
          },
          objective_decision: %{action: :request_budget_approval},
          open_tasks: [
            %{id: "compile", title: "mix compile still fails", status: :open}
          ],
          budget_requests: [
            %{reason: "repair budget exhausted before objective satisfaction"}
          ]
        },
        at: DateTime.utc_now()
      })
  end

  defp seed_objective_progress(session_id) do
    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("objective-progress"),
        session_id: session_id,
        run_id: session_id,
        agent: :rlm,
        kind: :summary,
        phase: :objective_loop_progress,
        status: :running,
        title: "Objective iteration completed",
        detail: "status: running, action: continue, iteration: 2",
        data_json: %{
          stage: :objective_loop,
          event: :iteration_completed,
          objective: "Build OpsLogic",
          current_iteration: 2,
          iteration_count: 2,
          max_iterations: 3,
          objective_session_id: session_id,
          objective_session: %{
            id: session_id,
            objective: "Build OpsLogic",
            status: :running,
            decision: %{action: :continue}
          },
          run_deadline_ms: 9_999_999,
          remaining_runtime_ms: 12_345,
          max_runtime_ms: 60_000,
          open_tasks: [%{id: "tests", title: "Add generated LiveView tests"}],
          completed_tasks: [%{id: "plan", title: "Write implementation plan"}]
        },
        at: DateTime.utc_now()
      })
  end

  defp seed_compile_completed_graph(session_id) do
    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("compile-completed"),
        session_id: session_id,
        run_id: session_id,
        agent: :rlm,
        kind: :rlm_plan,
        phase: :compile_completed,
        status: :ok,
        title: "RLM Compile completed",
        detail: "workflow compiled",
        data_json: %{
          compiled: %{
            metadata: %{source_count: 2},
            graph_summary: %{
              runic: %{
                native_nodes: [
                  %{name: "acceptance_contract", kind: "deterministic_step"},
                  %{name: "compile_project", kind: "command"}
                ],
                edgelist: [%{from: "acceptance_contract", to: "compile_project"}],
                serializers: %{
                  mermaid:
                    "flowchart TB\n  acceptance_contract[\"acceptance_contract\"] --> compile_project[\"compile_project\"]"
                }
              }
            }
          }
        },
        at: DateTime.utc_now()
      })
  end

  defp seed_objective_error_progress(session_id) do
    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("objective-error-progress"),
        session_id: session_id,
        run_id: session_id,
        agent: :rlm,
        kind: :summary,
        phase: :objective_loop,
        status: :review,
        title: "Objective budget approval required",
        detail: "status: needs_budget_approval, action: request_budget_approval",
        data_json: %{
          run_id: session_id,
          objective_iteration_count: 1,
          objective_session: %{
            id: session_id,
            objective: "Build OpsLogic",
            status: :needs_budget_approval,
            iteration_count: 1,
            max_iterations: 3,
            latest_error: %{
              kind: :timeout,
              message: "RLM runtime budget exhausted"
            },
            latest_error_kind: :timeout,
            latest_error_message: "RLM runtime budget exhausted",
            decision: %{action: :request_budget_approval}
          },
          objective_session_state: %{
            id: session_id,
            objective: "Build OpsLogic",
            status: :needs_budget_approval,
            iterations: [%{iteration: 1, status: :needs_budget_approval}],
            max_iterations: 3,
            latest_error: %{
              kind: :timeout,
              message: "RLM runtime budget exhausted"
            }
          },
          objective_decision: %{action: :request_budget_approval},
          budget_requests: [
            %{
              status: :pending,
              reason: "runtime budget exhausted during active workflow execution"
            }
          ]
        },
        at: DateTime.utc_now()
      })
  end

  defp seed_objective_review_loop(session_id) do
    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("objective-review-loop"),
        session_id: session_id,
        run_id: session_id,
        agent: :rlm,
        kind: :summary,
        phase: :objective_loop,
        status: :review,
        title: "Objective review approval required",
        detail: "status: needs_review_approval",
        data_json: %{
          run_id: session_id,
          objective_iteration_count: 1,
          objective_session: %{
            id: session_id,
            objective: "Plan OpsLogic",
            status: :needs_review_approval,
            iteration_count: 1,
            max_iterations: 2,
            latest_review_request: %{
              kind: :objective_plan_approval,
              resume_key: "review:opslogic:plan",
              checkpoint: :plan_review
            },
            decision: %{action: :request_review_approval}
          },
          objective_decision: %{action: :request_review_approval},
          review_requests: [
            %{
              kind: :objective_plan_approval,
              resume_key: "review:opslogic:plan",
              checkpoint: :plan_review
            }
          ]
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
