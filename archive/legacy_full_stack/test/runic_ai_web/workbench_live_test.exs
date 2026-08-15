defmodule RunicAIWeb.WorkbenchLiveTest do
  use RunicAIWeb.ConnCase, async: false

  require Runic

  alias Runic.Workflow
  alias RunicAI.Workbench
  alias RunicAI.Coding.TraceEvent
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.Schemas.WorkflowCompiledArtifact
  alias RunicAI.Persistence.Schemas.WorkflowRun
  alias RunicAI.Persistence.Term
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Persistence.WorkflowExecutor
  alias RunicAI.Terminal.Event, as: TerminalEvent
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.IR.Edge
  alias RunicAI.Workflows.IR.Node
  alias RunicAI.Workflows.IntentPlanner

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

  test "completed pinned workflow renders execution and acceptance proof from portable output", %{
    conn: conn
  } do
    session_id = unique_session_id()
    run_id = "#{session_id}:workflow"

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: "#{session_id}:running",
               session_id: session_id,
               run_id: run_id,
               agent: :assistant,
               kind: :summary,
               phase: :objective_loop_progress,
               status: :running,
               title: "Objective running",
               detail: "running",
               data_json: %{
                 objective: "Reuse the verified batch workflow",
                 objective_session: %{
                   objective: "Reuse the verified batch workflow",
                   status: :running,
                   decision: %{action: :continue}
                 }
               },
               at: DateTime.utc_now()
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: "#{session_id}:completed",
               session_id: session_id,
               run_id: run_id,
               agent: :assistant,
               kind: :summary,
               phase: :final,
               status: :ok,
               title: "Workflow completed",
               detail: "portable output persisted",
               data_json: %{},
               at: DateTime.add(DateTime.utc_now(), 1)
             })

    store = Workbench.store!()

    SQLite.with_repo(store, fn ->
      store.repo.get!(WorkflowRun, run_id)
      |> WorkflowRun.changeset(%{
        status: :completed,
        trigger: :intent_reuse,
        definition_revision_id: "revision:proof",
        definition_revision: 1,
        output_blob:
          Term.to_blob(%{
            scorecard: %{objective_status: :objective_satisfied},
            artifacts: [%{path: ".docs/reuse-proof.md"}],
            execution_metrics: %{nodes_executed: 6, record_map_calls: 4},
            dialect: :component
          })
      })
      |> store.repo.update!()
    end)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    plan_html =
      view
      |> element(~s([phx-click="set_workspace_tab"][phx-value-tab="plan"]))
      |> render_click()

    assert plan_html =~ "Pinned workflow execution completed"
    assert plan_html =~ "Acceptance proof satisfied"
    assert plan_html =~ ~s(data-session-status="completed")

    artifact_html =
      view
      |> element(~s([phx-click="set_inspector_tab"][phx-value-tab="artifacts"]))
      |> render_click()

    assert artifact_html =~ "Outcome objective_satisfied"
    assert artifact_html =~ ".docs/reuse-proof.md"
    assert artifact_html =~ ~s(data-objective-status="objective_satisfied")
  end

  test "root route renders the chat input landing page", %{conn: conn} do
    session_id = unique_session_id()
    seed_session(session_id, "Show recent session")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(src="/images/runic-tome-logo.png")
    assert html =~ "Ask RunicAI to research, explain, inspect, plan, or make a local change"
    assert html =~ "Standard"
    assert html =~ "Assistant"
    assert html =~ "Workflow RLM"
    assert html =~ "Sandbox"
    refute html =~ "Show recent session"
    refute html =~ "Recent sessions"
    refute html =~ "Agent workbench"
  end

  test "session pages bound the recent session sidebar", %{conn: conn} do
    prefix = unique_session_id()

    session_ids =
      for index <- 1..20 do
        session_id = "#{prefix}:#{index}"
        seed_session(session_id, "Sidebar bounded session #{index}")
        session_id
      end

    latest_session_id = List.last(session_ids)

    {:ok, _view, html} = live(conn, ~p"/sessions/#{latest_session_id}")

    assert html =~ "Sidebar bounded session 20"
    assert html =~ "Sidebar bounded session 5"
    refute html =~ "Sidebar bounded session 4\n"
    refute html =~ "Sidebar bounded session 1\n"
  end

  test "well-known OAuth probe routes return lightweight responses", %{conn: conn} do
    for path <- [
          "/.well-known/oauth-authorization-server",
          "/.well-known/oauth-authorization-server/tidewave/mcp"
        ] do
      conn = conn |> recycle() |> get(path)
      body = response(conn, 404)

      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert byte_size(body) < 256
      assert body =~ "not_found"
      refute body =~ "Phoenix.Router.NoRouteError"
    end
  end

  test "root agent mode selector keeps launch fields in sync", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert landing_form_value(html, "agent") == "assistant"
    assert landing_form_value(html, "mode") == "verify"
    assert landing_form_value(html, "write_policy") == "docs_only"

    view
    |> element("button[phx-click='select_landing_agent'][phx-value-agent='rlm']")
    |> render_click()

    html = render(view)

    assert landing_form_value(html, "agent") == "rlm"
    assert landing_form_value(html, "mode") == "patch"
    assert landing_form_value(html, "write_policy") == "workspace_review"
    assert landing_mode_pressed?(html, "rlm")

    view
    |> element("button[phx-click='select_landing_agent'][phx-value-agent='assistant']")
    |> render_click()

    html = render(view)

    assert landing_form_value(html, "agent") == "assistant"
    assert landing_form_value(html, "mode") == "verify"
    assert landing_form_value(html, "write_policy") == "docs_only"
    assert landing_mode_pressed?(html, "assistant")
  end

  test "root sandbox selector exposes usable and cold sandbox profiles", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Local Code"
    assert html =~ ~s(phx-value-sandbox="local_code")
    assert html =~ "Docker"
    assert html =~ ~s(phx-value-sandbox="docker")
    assert html =~ "Starts on demand" or html =~ "Needs setup"
    assert html =~ "runtimes bash"
    assert landing_form_value(html, "sandbox_profile") == "local_code"
    assert landing_form_value(html, "sandbox_backend") == "just_bash"
    assert landing_form_value(html, "sandbox_runtime") == "bash"
    assert landing_form_value(html, "sandbox_runtimes") == "bash"
    assert landing_form_value(html, "sandbox_network") == "disabled"
    assert landing_form_value(html, "sandbox_stateful") == "false"
    assert landing_form_value(html, "sandbox_pool_warm") == "0"
    assert landing_form_value(html, "sandbox_pool_max") == "1"

    view
    |> element("button[phx-click='select_landing_sandbox'][phx-value-sandbox='local_code']")
    |> render_click()

    html = render(view)

    assert landing_sandbox_pressed?(html, "local_code")
    assert landing_form_value(html, "sandbox_profile") == "local_code"
    assert landing_form_value(html, "sandbox_backend") == "just_bash"
    assert landing_form_value(html, "sandbox_runtime") == "bash"
    assert landing_form_value(html, "sandbox_runtimes") == "bash"
    assert landing_form_value(html, "sandbox_network") == "disabled"
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

  test "intent composer drafts a typed workflow for collaborative review and launch", %{
    conn: conn
  } do
    previous = Application.get_env(:runic_ai, :workbench, [])
    parent = self()

    planner = fn store, workspace, request, opts ->
      send(parent, :intent_planner_started)
      result = __MODULE__.fake_intent_planner(store, workspace, request, opts)
      send(parent, {:intent_planner_finished, result})
      result
    end

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:intent_planner_fun, planner)
      |> Keyword.put(:max_runtime_ms, 2_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("intent-workflow")
    {:ok, landing, html} = live(conn, ~p"/")

    assert html =~ "Auto: direct, reuse, adapt, or draft"
    assert html =~ "Input paths"
    assert html =~ "Required sections"

    landing
    |> element("#landing-run-form")
    |> render_submit(%{
      run: %{
        "session_id" => session_id,
        "objective" => "Analyze notes and write a cited risk report",
        "orchestration" => "workflow",
        "input_paths" => "notes/incidents.md, notes/roadmap.md",
        "output_path" => ".docs/risk-report.md",
        "required_sections" => "Summary, Risks, Actions"
      }
    })

    assert_redirect(landing, ~p"/sessions/#{session_id}")
    assert_receive :intent_planner_started, 2_000
    assert_receive {:intent_planner_finished, {:ok, _result}}, 10_000

    assert eventually(fn ->
             case Workbench.session_snapshot(session_id) do
               %{workflow_definitions: [definition], review_requests: reviews} ->
                 definition.latest_action == "review_requested" and length(reviews) == 1 and
                   hd(reviews).kind == "workflow_revision"

               _other ->
                 false
             end
           end)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-click='set_workspace_tab'][phx-value-tab='plan']")
      |> render_click()

    assert html =~ "draft route"
    assert html =~ "drafted because the task needs source fan-out and verified synthesis"
    assert html =~ "runic_ai/lambda_reduce"
    assert html =~ "runic_ai/llm_leaf"
    assert html =~ "model_call"
    assert html =~ "accepted validation"
    assert html =~ "Approve revision"
    assert html =~ "Typed operations before activation or launch"

    html =
      view
      |> element("form[phx-submit='apply_workflow_definition_operations']")
      |> render_submit(%{
        workflow_definition_edit: %{
          "operations" => ~s|[{"op":"set_policy","key":"max_runtime_ms","value":120000}]|
        }
      })

    assert html =~ "revision 2"
    assert html =~ "Latest semantic change"
    assert html =~ "Request review"

    html =
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='request_review'][phx-value-definition-id]"
      )
      |> render_click()

    assert html =~ "Approve revision"

    html =
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='approve'][phx-value-definition-id]"
      )
      |> render_click()

    assert html =~ "Activate revision"

    html =
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='activate'][phx-value-definition-id]"
      )
      |> render_click()

    assert html =~ "Create pinned run"

    html =
      view
      |> element("button[phx-click='launch_workflow_definition'][phx-value-definition-id]")
      |> render_click()

    assert html =~ "Start pinned revision"

    snapshot = Workbench.session_snapshot(session_id)

    assert Enum.any?(snapshot.runs, fn run ->
             run.definition_revision == 2 and run.status == "pending"
           end)

    persisted_run =
      Workbench.store!()
      |> Queries.workflow_runs_for_session(session_id)
      |> Enum.find(&(&1.definition_revision == 2))

    assert Term.from_blob(persisted_run.input_blob)["objective"] ==
             "Analyze notes and write a cited risk report"

    assert Term.from_blob(persisted_run.input_blob)["input_paths"] == [
             "notes/incidents.md",
             "notes/roadmap.md"
           ]

    definition = hd(snapshot.workflow_definitions)

    html =
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='archive'][phx-value-definition-id='#{definition.id}']"
      )
      |> render_click()

    assert html =~ "Workflow definition archived"
    assert html =~ "Archived · retained for audit, unavailable to routing and new launches"

    refute has_element?(
             view,
             "button[phx-click='launch_workflow_definition'][phx-value-definition-id='#{definition.id}']"
           )

    assert {:error, :no_active_revision} =
             Workbench.launch_workflow_definition(definition.id, session_id)

    archived = Workbench.session_snapshot(session_id) |> Map.fetch!(:workflow_definitions) |> hd()
    assert archived.status == "archived"
  end

  test "intent composer runs a bounded batch fan-out and aggregation workflow end to end", %{
    conn: conn
  } do
    previous = Application.get_env(:runic_ai, :workbench, [])

    planner = fn store, workspace, request, opts ->
      IntentPlanner.plan(
        store,
        workspace,
        request,
        Keyword.put(opts, :blueprint, batch_blueprint(request))
      )
    end

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:intent_planner_fun, planner)
      |> Keyword.put(:max_runtime_ms, 10_000)
    )

    root =
      Path.join(
        System.tmp_dir!(),
        "workbench-batch-golden-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "data"))

    File.write!(
      Path.join(root, "data/work-items.csv"),
      "id,team,status\n1,api,ready\n2,web,blocked\n3,api,ready\n4,ops,review\n"
    )

    on_exit(fn ->
      Application.put_env(:runic_ai, :workbench, previous)
      File.rm_rf!(root)
    end)

    session_id = unique_session_id("batch-golden")
    objective = "Transform each bounded work item in parallel and aggregate a verified summary"
    {:ok, landing, _html} = live(conn, ~p"/")

    landing
    |> element("#landing-run-form")
    |> render_submit(%{
      run: %{
        "session_id" => session_id,
        "objective" => objective,
        "orchestration" => "workflow",
        "input_paths" => "data/work-items.csv",
        "output_path" => ".docs/batch-transformation-summary.md",
        "required_sections" => "Transformed Records",
        "cwd" => root,
        "write_policy" => "docs_only"
      }
    })

    assert_redirect(landing, ~p"/sessions/#{session_id}")

    assert eventually(fn ->
             case Workbench.session_snapshot(session_id) do
               %{workflow_definitions: [definition]} ->
                 definition.latest_action == "review_requested" and
                   Map.get(definition.planning, :strategy, definition.planning["strategy"]) in [
                     :draft,
                     "draft"
                   ]

               _other ->
                 false
             end
           end)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-click='set_workspace_tab'][phx-value-tab='plan']")
      |> render_click()

    assert html =~ "runic_ai/tabular_parser"
    assert html =~ "runic_ai/record_map"
    assert html =~ "runic_ai/lambda_reduce"
    assert html =~ "max_concurrency"
    assert html =~ "Approve revision"

    for action <- ["approve", "activate"] do
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='#{action}'][phx-value-definition-id]"
      )
      |> render_click()
    end

    view
    |> element("button[phx-click='launch_workflow_definition'][phx-value-definition-id]")
    |> render_click()

    pending_run =
      Workbench.store!()
      |> Queries.workflow_runs_for_session(session_id)
      |> Enum.find(&(&1.status == "pending"))

    assert pending_run.definition_revision == 1

    view
    |> element("button[phx-click='start_workflow_run'][phx-value-run-id='#{pending_run.id}']")
    |> render_click()

    store = Workbench.store!()

    assert {:ok, completed} =
             WorkflowExecutor.await_terminal(store, pending_run.id, timeout: 10_000)

    assert completed.status == "completed", inspect(completed.error_json, pretty: true)
    result = Term.from_blob(completed.output_blob)
    assert result["execution_metrics"]["record_map_calls"] == 4
    assert result["execution_metrics"]["lambda_reduce_calls"] >= 1
    assert result["scorecard"]["objective_status"] == "objective_satisfied"

    assert eventually(fn ->
             Workbench.session_snapshot(session_id).session.status == "completed"
           end)

    report = File.read!(Path.join(root, ".docs/batch-transformation-summary.md"))
    assert report =~ "Batch Transformation Summary"
    assert report =~ "id=1 team=api status=ready"
    assert report =~ "id=2 team=web status=blocked"
    assert report =~ "id=4 team=ops status=review"
  end

  test "workflow intent planning has an outer runtime deadline" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    planner = fn _store, _workspace, _request, _opts ->
      Process.sleep(5_000)
      {:error, :unexpected_planner_completion}
    end

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:intent_planner_fun, planner)
      |> Keyword.put(:max_runtime_ms, 25)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("intent-timeout")

    assert {:ok, %{session_id: ^session_id}} =
             Workbench.start_workflow_intent(%{
               "session_id" => session_id,
               "objective" => "Draft a bounded report workflow",
               "orchestration" => "workflow"
             })

    assert eventually(fn ->
             case Workbench.session_snapshot(session_id) do
               %{session: %{status: "failed"}, events: events} ->
                 Enum.any?(events, fn event ->
                   event.phase == "workflow_intent_failed" and
                     event.detail == "Workflow planning exceeded its configured runtime budget"
                 end)

               _other ->
                 false
             end
           end)
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
    assert html =~ ~s(value="gpt-5.6")
    assert html =~ ~s(value="gpt-5.6-luna")
    assert html =~ ~s(value="gpt-5.6-terra")
    assert html =~ ~s(value="gpt-5.6-sol")

    html =
      view
      |> element("form[phx-submit='submit_objective']")
      |> render_change(%{
        run: %{
          "objective" => "Use selected model",
          "model_provider" => "openai",
          "model_id" => "gpt-5.6-terra"
        }
      })

    assert html =~ ~s(value="openai:gpt-5.6-terra")

    view
    |> element("form[phx-submit='submit_objective']")
    |> render_submit(%{
      run: %{
        "session_id" => session_id,
        "objective" => "Use selected model",
        "model_provider" => "openai",
        "model_id" => "gpt-5.6-terra"
      }
    })

    assert_redirect(view, ~p"/sessions/#{session_id}")

    assert %{session: %{model: model}} = Workbench.session_snapshot(session_id)
    assert model == "openai:gpt-5.6-terra"
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
             "runtime" => "python",
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
    assert html =~ "Proposal contract review"
    assert html =~ "workspace_write"
    assert html =~ "manual_reconciliation; manual reconciliation required"
    assert html =~ "compile passes"
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

  test "selected session launch metadata hydrates the follow-up composer", %{conn: conn} do
    session_id = unique_session_id("rlm-vmsan-session")
    seed_rlm_vmsan_session(session_id, "Implement a RayOps slice")

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ ~s(value="rlm" selected)
    assert html =~ ~s(value="patch" selected)
    assert html =~ ~s(value="always" selected)
    assert html =~ ~s(value="workspace_review" selected)
    assert html =~ ~s(value="vmsan" selected)
    assert html =~ ~s(value="elixir" selected)
    assert html =~ ~s(name="run[cwd]" value="#{File.cwd!()}")
  end

  test "trace panel renders sandbox execution proof", %{conn: conn} do
    session_id = unique_session_id("sandbox-proof")
    seed_session(session_id, "Show sandbox proof")
    seed_sandbox_execution(session_id)

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ "Sandbox executions"
    assert html =~ "docker / elixir / session sandbox-session-42"
    assert html =~ "microvm"
    assert html =~ "restricted"
    assert html =~ "security boundary"
    assert html =~ "copy-in request_files_uploaded"
    assert html =~ "copy-back files_changed"
    assert html =~ "1 changed"
  end

  test "trace panel renders child repair summaries without raw payload parsing", %{conn: conn} do
    session_id = unique_session_id("child-repair")
    seed_session(session_id, "Show child repair")
    seed_child_patch_repair(session_id)

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}")

    assert html =~ "Child repairs"
    assert html =~ "Malformed patch repaired"
    assert html =~ "Patch repair attempt 1 for child"
    assert html =~ "invalid patch operation"
    assert html =~ "op=make_file"
    assert html =~ "lib/malformed_patch_repair.ex"
    assert html =~ "Continue downstream verification or final objective proof"
  end

  test "artifact inspector renders exact workflow definition and compilation lineage", %{
    conn: conn
  } do
    session_id = unique_session_id("revision-lineage")
    workflow_key = "lineage-#{System.unique_integer([:positive])}"
    seed_session(session_id, "Show exact workflow revision lineage")
    store = Workbench.store!()

    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:#{workflow_key}", "Inspect revision lineage",
        nodes: %{discover.id => discover},
        acceptance: [%{id: "grounded", required: true}]
      )

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: workflow_key,
               ir: ir,
               catalog_hash: "catalog-lineage-v1"
             )

    assert {:ok, compiled} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{runtime: :runic},
               compiled_hash: "compiled-lineage-v1",
               catalog_hash: "catalog-lineage-v1"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

    assert {:ok, run} =
             WorkflowDefinitions.launch(store, workflow_key, %{
               id: "run:#{workflow_key}",
               session_id: session_id,
               status: :paused
             })

    assert run.compiled_artifact_id == compiled.id

    assert {:ok, child_run} =
             WorkflowDefinitions.launch(store, workflow_key, %{
               id: "run:#{workflow_key}:child",
               session_id: session_id,
               status: :completed,
               trigger: :workflow_task,
               metadata: %{
                 parent_run_id: run.id,
                 parent_definition_revision_id: run.definition_revision_id,
                 parent_node_id: "invoke_saved_workflow"
               }
             })

    assert child_run.definition_revision_id == run.definition_revision_id

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-click='set_inspector_tab'][phx-value-tab='artifacts']")
      |> render_click()

    assert html =~ workflow_key
    assert html =~ "revision 1"
    assert html =~ "definition #{String.slice(created.revision.semantic_hash, 0, 12)}"
    assert html =~ "compiled compiled-lin"
    assert html =~ "catalog catalog-line"
    assert html =~ "child of #{String.slice(workflow_key, 0, 12)}"
    assert html =~ "Resume pinned revision"
  end

  test "artifact inspector migrates stale catalog contracts through review without rewriting a pinned run",
       %{
         conn: conn
       } do
    session_id = unique_session_id("catalog-migration")
    workflow_key = "catalog-migration-#{System.unique_integer([:positive])}"
    seed_session(session_id, "Migrate a workflow catalog safely")
    store = Workbench.store!()

    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:#{workflow_key}", "Migrate a workflow catalog safely",
        nodes: %{discover.id => discover},
        acceptance: [%{"id" => "grounded", "required" => true}]
      )

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: workflow_key,
               ir: ir,
               scope_type: :session,
               scope_id: session_id,
               catalog_hash: "retired-catalog-v1"
             )

    assert {:ok, old_artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{runtime: :legacy},
               compiled_hash: "compiled-retired-v1",
               catalog_hash: "retired-catalog-v1"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

    assert {:ok, run} =
             WorkflowDefinitions.launch(store, workflow_key, %{
               id: "run:#{workflow_key}",
               session_id: session_id,
               status: :completed
             })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    _html =
      view
      |> element("button[phx-click='set_inspector_tab'][phx-value-tab='artifacts']")
      |> render_click()

    html =
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='migrate_catalog'][phx-value-run-id='#{run.id}']"
      )
      |> render_click()

    assert html =~ "migrated to the current catalog as a new revision"
    assert html =~ "latest revision 2"
    assert html =~ "Request revision review"

    [old_revision, migrated_revision] = WorkflowDefinitions.revisions(store, workflow_key)
    assert migrated_revision.parent_revision_id == old_revision.id
    assert migrated_revision.catalog_hash == Catalog.snapshot_hash()

    assert run.definition_revision_id == old_revision.id
    assert run.compiled_artifact_id == old_artifact.id

    for action <- ["request_review", "approve", "activate"] do
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='#{action}'][phx-value-run-id='#{run.id}']"
      )
      |> render_click()
    end

    workflow = WorkflowDefinitions.get(store, workflow_key)
    assert workflow.active_revision_id == migrated_revision.id

    view
    |> element("button[phx-click='fork_workflow_run'][phx-value-run-id='#{run.id}']")
    |> render_click()

    fork =
      Workbench.session_snapshot(session_id).runs
      |> Enum.find(&(&1.trigger == "fork"))

    assert fork.definition_revision_id == migrated_revision.id

    migrated_artifact =
      SQLite.with_repo(store, fn ->
        store.repo.get!(WorkflowCompiledArtifact, fork.compiled_artifact_id)
      end)

    assert migrated_artifact.metadata_json["catalog_compatibility"] == "strict_current_v1"
    assert run.definition_revision_id == old_revision.id
    assert run.compiled_artifact_id == old_artifact.id
  end

  test "artifact inspector applies, reviews, activates, and forks a typed workflow revision", %{
    conn: conn
  } do
    session_id = unique_session_id("revision-actions")
    workflow_key = "revision-actions-#{System.unique_integer([:positive])}"
    seed_session(session_id, "Operate a workflow revision")
    store = Workbench.store!()

    {:ok, discover} = Node.new("discover", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:#{workflow_key}", "Operate a workflow revision",
        nodes: %{discover.id => discover},
        acceptance: [%{"id" => "grounded", "required" => true}]
      )

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: workflow_key,
               ir: ir,
               catalog_hash: "catalog-actions-v1"
             )

    assert {:ok, _compiled} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{runtime: :runic},
               compiled_hash: "compiled-actions-v1",
               catalog_hash: "catalog-actions-v1"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

    assert {:ok, run} =
             WorkflowDefinitions.launch(store, workflow_key, %{
               id: "run:#{workflow_key}",
               session_id: session_id,
               status: :completed
             })

    assert {:error, _reason} =
             Workbench.apply_workflow_operations(
               run.id,
               Jason.encode!([
                 %{op: "add_hole", hole: %{id: "unresolved", need: "choose a component"}}
               ])
             )

    assert length(WorkflowDefinitions.revisions(store, workflow_key)) == 1

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    _html =
      view
      |> element("button[phx-click='set_inspector_tab'][phx-value-tab='artifacts']")
      |> render_click()

    form_id = "#workflow-edit-form-#{String.replace(run.id, ~r/[^A-Za-z0-9_-]/, "-")}"

    html =
      view
      |> form(form_id,
        workflow_edit: %{
          "run_id" => run.id,
          "operations" =>
            Jason.encode!([
              %{op: "set_policy", key: "max_runtime_ms", value: 5_000}
            ])
        }
      )
      |> render_submit()

    assert html =~ "latest revision 2"
    assert html =~ "Latest semantic change"
    assert html =~ "Set workflow policy max runtime ms"
    assert html =~ "New value: 5000."
    assert html =~ "Raw operation and diff data"
    assert html =~ "Undo latest operation batch"
    assert html =~ "Request revision review"
    assert html =~ "Fork onto latest revision"

    html =
      view
      |> element(
        "button[phx-click='workflow_definition_action'][phx-value-action='request_review']"
      )
      |> render_click()

    assert html =~ "Approve revision"

    html =
      view
      |> element("button[phx-click='workflow_definition_action'][phx-value-action='approve']")
      |> render_click()

    assert html =~ "Activate revision"

    html =
      view
      |> element("button[phx-click='workflow_definition_action'][phx-value-action='activate']")
      |> render_click()

    assert html =~ "lifecycle activated"

    html =
      view
      |> element("button[phx-click='fork_workflow_run'][phx-value-run-id='#{run.id}']")
      |> render_click()

    assert html =~ "Forked run"

    snapshot = Workbench.session_snapshot(session_id)
    assert Enum.count(snapshot.runs, &(&1.trigger == "fork")) == 1
    assert Enum.any?(snapshot.runs, &(&1.definition_revision == 2))

    fork = Enum.find(snapshot.runs, &(&1.trigger == "fork"))

    html =
      view
      |> element("button[phx-click='start_workflow_run'][phx-value-run-id='#{fork.id}']")
      |> render_click()

    assert html =~ "Workflow run started from its pinned revision"

    assert {:ok, completed} =
             RunicAI.Persistence.WorkflowExecutor.await_terminal(store, fork.id, timeout: 5_000)

    assert completed.status == "completed"

    html =
      view
      |> element("button[phx-click='undo_workflow_operations'][phx-value-run-id='#{run.id}']")
      |> render_click()

    assert html =~ "Reverted the latest operation batch as revision 3"
    [_, _, reverted] = WorkflowDefinitions.revisions(store, workflow_key)
    assert reverted.ir_json["policies"] == %{}

    html =
      view
      |> form(form_id,
        workflow_edit: %{
          "run_id" => run.id,
          "operations" =>
            Jason.encode!([
              %{op: "set_policy", key: "max_retries", value: 2}
            ])
        }
      )
      |> render_submit()

    assert html =~ "latest revision 4"
    [first, _second, _third, fourth] = WorkflowDefinitions.revisions(store, workflow_key)

    compare_form_id =
      "#workflow-compare-form-#{String.replace(run.id, ~r/[^A-Za-z0-9_-]/, "-")}"

    html =
      view
      |> form(compare_form_id,
        workflow_compare: %{
          "run_id" => run.id,
          "from_revision_id" => first.id,
          "to_revision_id" => fourth.id
        }
      )
      |> render_submit()

    assert html =~ "Compared workflow revisions 1 and 4"
    assert html =~ "Revision 1 → 4"
    assert html =~ "Workflow policy changed"
    assert html =~ "max_retries"

    assert {:ok, comparison} =
             Workbench.compare_workflow_revisions(run.id, first.id, fourth.id)

    assert comparison.diff.revision == %{from: 1, to: 4}
    assert comparison.diff.workflow_policy.changed?
    assert comparison.diff.workflow_policy.before == %{}
    assert comparison.diff.workflow_policy.after == %{"max_retries" => 2}

    assert {:error, :same_revision} =
             Workbench.compare_workflow_revisions(run.id, first.id, first.id)

    assert {:error, :not_found} =
             Workbench.compare_workflow_revisions(run.id, first.id, "revision:missing")

    html =
      render_submit(view, "apply_workflow_operations", %{
        "workflow_edit" => %{
          "run_id" => run.id,
          "action" => "suggest",
          "operations" =>
            Jason.encode!([
              %{op: "set_policy", key: "max_steps", value: 10}
            ])
        }
      })

    assert html =~ "Staged workflow edit suggestion"
    assert html =~ "Suggested semantic edit"
    assert html =~ "Set workflow policy max steps"
    assert html =~ "max_steps"
    assert html =~ "Apply suggested edit"

    snapshot = Workbench.session_snapshot(session_id)
    suggestion = Enum.find(snapshot.review_requests, &(&1.kind == "workflow_edit"))
    assert suggestion.status == "pending"

    html =
      render_submit(view, "review_decision", %{
        "review" => %{"id" => suggestion.id, "action" => "approve"}
      })

    assert html =~ "Review decision recorded"
    assert length(WorkflowDefinitions.revisions(store, workflow_key)) == 5

    accepted_batch = WorkflowDefinitions.operation_batches(store, workflow_key) |> List.last()

    assert accepted_batch.data_json["suggestion_review_id"] == suggestion.id
    assert accepted_batch.data_json["suggested_by"] == "workbench:agent"

    assert {:ok, stale_suggestion_result} =
             Workbench.suggest_workflow_operations(
               run.id,
               Jason.encode!([%{op: "set_policy", key: "stale_value", value: true}])
             )

    stale_suggestion = stale_suggestion_result.review

    assert {:ok, _newer_revision} =
             Workbench.apply_workflow_operations(
               run.id,
               Jason.encode!([%{op: "set_policy", key: "newer_value", value: true}])
             )

    assert {:error, stale_error} =
             Workbench.record_review_decision(session_id, stale_suggestion.id, %{
               "action" => "approve"
             })

    assert stale_error.details.code == :stale_suggested_revision

    snapshot = Workbench.session_snapshot(session_id)
    still_pending = Enum.find(snapshot.review_requests, &(&1.id == stale_suggestion.id))
    assert still_pending.status == "pending"

    assert {:ok, _rejection_event} =
             Workbench.record_review_decision(session_id, stale_suggestion.id, %{
               "action" => "deny"
             })

    assert length(WorkflowDefinitions.revisions(store, workflow_key)) == 6
  end

  test "artifact inspector pauses a running pinned workflow for review and resumes it", %{
    conn: conn
  } do
    session_id = unique_session_id("runtime-review")
    workflow_key = "runtime-review-#{System.unique_integer([:positive])}"
    seed_session(session_id, "Review a running durable workflow")
    store = Workbench.store!()

    {:ok, wait_node} = Node.new("wait", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:#{workflow_key}", "Wait for operator review",
        nodes: %{wait_node.id => wait_node},
        acceptance: [%{"id" => "operator approved", "required" => true}]
      )

    native_workflow =
      Workflow.new(name: :runtime_review_test)
      |> Workflow.add(
        Runic.step(&RunicAI.WorkflowTestStep.delayed_increment/1, name: :bounded_wait)
      )

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: workflow_key,
               workflow_name: "Runtime review fixture",
               ir: ir,
               catalog_hash: "catalog-runtime-review-v1"
             )

    assert {:ok, _artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{workflow: native_workflow},
               compiled_hash: "compiled-runtime-review-v1",
               catalog_hash: "catalog-runtime-review-v1",
               metadata: %{artifact_format: "native_external_fun_v1"}
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

    assert {:ok, run} =
             WorkflowDefinitions.launch(store, workflow_key, %{
               id: "run:#{workflow_key}",
               session_id: session_id,
               status: :pending,
               input: 400
             })

    assert {:ok, %{run: %{status: "running"}}} = Workbench.start_workflow_run(run.id)
    assert {:ok, _review_result} = Workbench.request_workflow_run_review(run.id)
    assert %{status: "review"} = WorkflowExecutor.get_run(store, run.id)

    [runtime_review] = Queries.review_requests(store, run.id)
    assert runtime_review.status == "pending"
    assert runtime_review.details_json["definition_hash"] == created.revision.semantic_hash

    {:ok, view, html} = live(conn, ~p"/sessions/#{session_id}")
    assert html =~ "Review required"

    html =
      view
      |> element("#review-form-#{dom_id(runtime_review.id)}")
      |> render_submit(%{
        review: %{"id" => runtime_review.id, "action" => "approve", "rewrite" => ""}
      })

    assert html =~ "Review decision recorded"
    assert %{status: "running"} = WorkflowExecutor.get_run(store, run.id)

    assert {:ok, completed} = WorkflowExecutor.await_terminal(store, run.id, timeout: 5_000)
    assert completed.status == "completed"
    assert completed.definition_revision_id == created.revision.id
  end

  test "artifact inspector restarts only a failed workflow child as a pinned new attempt", %{
    conn: conn
  } do
    session_id = unique_session_id("child-restart")
    workflow_key = "child-restart-#{System.unique_integer([:positive])}"
    seed_session(session_id, "Restart one failed reusable child")
    store = Workbench.store!()

    {:ok, placeholder} = Node.new("placeholder", :source_discovery)

    {:ok, ir} =
      IR.new("workflow:#{workflow_key}", "Increment a supplied integer",
        nodes: %{placeholder.id => placeholder},
        acceptance: [%{"id" => "incremented", "required" => true}]
      )

    public_contract = %{
      inputs: %{
        type: "object",
        required: ["n"],
        properties: %{"n" => %{type: "integer"}}
      },
      outputs: %{type: "integer"},
      effects: [],
      acceptance: [%{id: "incremented", required: true}]
    }

    native_workflow =
      Workflow.new(name: :child_restart_test)
      |> Workflow.add(Runic.step(fn %{n: n} -> n + 1 end, name: :increment))

    assert {:ok, created} =
             WorkflowDefinitions.create_draft(store,
               workflow_key: workflow_key,
               workflow_name: "Restartable child fixture",
               ir: ir,
               revision_metadata: %{public_contract: public_contract},
               catalog_hash: "catalog-child-restart-v1"
             )

    assert {:ok, _artifact} =
             WorkflowDefinitions.record_compilation(store, created.revision.id, %{
               artifact: %{workflow: native_workflow},
               compiled_hash: "compiled-child-restart-v1",
               catalog_hash: "catalog-child-restart-v1"
             })

    assert {:ok, _review} = WorkflowDefinitions.request_review(store, workflow_key)
    assert {:ok, _approval} = WorkflowDefinitions.approve(store, workflow_key)
    assert {:ok, _activation} = WorkflowDefinitions.activate(store, workflow_key)

    assert {:ok, parent} =
             WorkflowDefinitions.launch(store, workflow_key, %{
               id: "run:#{workflow_key}:parent",
               session_id: session_id,
               status: :running
             })

    assert {:ok, failed_child} =
             WorkflowDefinitions.launch(store, workflow_key, %{
               id: "run:#{workflow_key}:child:1",
               session_id: session_id,
               status: :failed,
               trigger: :workflow_task,
               input: %{n: 2},
               parent_run_id: parent.id,
               parent_node_id: "map_increment",
               invocation_key: "fixture:child-restart",
               attempt: 1,
               metadata: %{
                 parent_run_id: parent.id,
                 parent_node_id: "map_increment",
                 invocation_key: "fixture:child-restart"
               }
             })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}")

    html =
      view
      |> element("button[phx-click='set_inspector_tab'][phx-value-tab='artifacts']")
      |> render_click()

    assert html =~ "child of parent"
    assert html =~ "attempt 1"
    assert html =~ "Restart only this child"

    html =
      view
      |> element(
        "button[phx-click='restart_workflow_child_run'][phx-value-run-id='#{failed_child.id}']"
      )
      |> render_click()

    assert html =~ "Restarted only failed child as attempt 2"

    assert eventually(fn ->
             store
             |> Queries.workflow_runs_for_session(session_id)
             |> Enum.any?(fn run ->
               run.supersedes_run_id == failed_child.id and run.attempt == 2 and
                 run.status == "completed" and is_binary(run.output_blob) and
                 Term.from_blob(run.output_blob) == 3
             end)
           end)

    html = render(view)
    assert html =~ "attempt 2"
    assert html =~ "retries 1"
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

  defp seed_sandbox_execution(session_id) do
    trace_event =
      TraceEvent.sandbox(
        :coding_sandbox_completed,
        %{
          status: :pass,
          backend: :docker,
          isolation_level: :microvm,
          duration_ms: 42,
          exit_status: 0,
          output_bytes: 12,
          files_changed: [%{path: "lib/example.ex", kind: :created}],
          artifacts: [%{ref: "sandbox://lib/example.ex"}],
          diagnostics: [],
          metadata: %{
            session_id: "sandbox-session-42",
            workspace_mode: :copy_in,
            workspace_mount: "/workspace",
            security_boundary?: true
          }
        },
        status: :pass,
        input: %{
          sandbox: :local_code,
          runtime: :elixir,
          network: :restricted,
          file_paths: ["mix.exs"]
        },
        metadata: %{
          sandbox?: true,
          sandbox: :local_code,
          runtime: :elixir,
          network: :restricted,
          session_id: "sandbox-session-42"
        }
      )

    terminal_event =
      TerminalEvent.from_trace_event(trace_event,
        session_id: session_id,
        agent: :rlm
      )

    terminal_event = %{terminal_event | data: Map.put(terminal_event.data, :run_id, session_id)}

    {:ok, _event} = Workbench.record_terminal_event(terminal_event)
  end

  defp seed_child_patch_repair(session_id) do
    now = DateTime.utc_now()

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("child-patch-repair-started"),
        session_id: session_id,
        run_id: session_id,
        agent: :rlm,
        kind: :rlm_node,
        phase: :child_patch_repair_started,
        status: :running,
        title: "RLM child patch repair started",
        detail: "repairing patch",
        data_json: %{
          stage: :child_patch_repair_started,
          status: :running,
          data: %{
            node_id: "child",
            mode: :patch,
            attempt: 1,
            reason: :apply_patch_failed,
            diagnostics: [
              %{
                code: :invalid_patch,
                message: "invalid patch operation",
                details: %{op: "make_file"}
              }
            ]
          }
        },
        at: now
      })

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("child-patch-repair-completed"),
        session_id: session_id,
        run_id: session_id,
        agent: :rlm,
        kind: :rlm_node,
        phase: :child_patch_repair_completed,
        status: :ok,
        title: "RLM child patch repair completed",
        detail: "patched",
        data_json: %{
          stage: :child_patch_repair_completed,
          status: :ok,
          data: %{
            node_id: "child",
            mode: :patch,
            attempt: 1,
            changed_files: ["lib/malformed_patch_repair.ex"],
            repaired?: true
          }
        },
        at: DateTime.add(now, 1)
      })
  end

  defp seed_rlm_vmsan_session(session_id, objective) do
    SQLite.migrate!(Workbench.store!())

    {:ok, _event} =
      Workbench.record_terminal_event(%{
        id: unique_event_id("rlm-vmsan-start"),
        session_id: session_id,
        run_id: session_id <> ":run",
        agent: :rlm,
        kind: :status,
        phase: :session,
        status: :running,
        title: "Workbench run queued",
        detail: objective,
        data_json: %{
          run_id: session_id <> ":run",
          cwd: File.cwd!(),
          objective: objective,
          model: "openai:gpt-5.4-mini",
          approve: :always,
          mode: :patch,
          write_policy: :workspace_review,
          profile: :local_workbench,
          sandbox: %{
            sandbox: :local_code,
            backend: :vmsan,
            runtime: :elixir,
            runtimes: [:bash, :python, :node, :elixir, :lua],
            network: :disabled,
            stateful?: true,
            pool: %{warm: 0, max: 2}
          }
        },
        at: DateTime.utc_now()
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
                  %{
                    name: "acceptance_contract",
                    kind: "deterministic_step",
                    execution_shape: "step",
                    inputs: %{"context" => %{contract: %{type: "object"}}},
                    outputs: %{"context" => %{contract: %{type: "object"}}},
                    policy: %{},
                    metadata: %{
                      workflow_ir_effects: [],
                      workflow_ir_replay: %{strategy: :safe_replay, automatic_retry?: true}
                    }
                  },
                  %{
                    name: "compile_project",
                    kind: "command",
                    execution_shape: "side_effect_step",
                    inputs: %{"context" => %{contract: %{type: "object"}}},
                    outputs: %{"context" => %{contract: %{type: "object"}}},
                    policy: %{review: "safe"},
                    metadata: %{
                      workflow_ir_effects: ["workspace_write"],
                      workflow_ir_replay: %{
                        strategy: :manual_reconciliation,
                        automatic_retry?: false
                      }
                    }
                  }
                ],
                edgelist: [%{from: "acceptance_contract", to: "compile_project"}],
                serializers: %{
                  mermaid:
                    "flowchart TB\n  acceptance_contract[\"acceptance_contract\"] --> compile_project[\"compile_project\"]"
                }
              },
              stop_conditions: ["compile passes"]
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

  defp landing_form_value(html, field) do
    html
    |> tag_with_attr("name", "run[#{field}]")
    |> attr_value("value")
  end

  defp landing_mode_pressed?(html, agent) do
    html
    |> tag_with_attr("phx-value-agent", agent)
    |> attr_value("aria-pressed") == "true"
  end

  defp landing_sandbox_pressed?(html, sandbox) do
    html
    |> tag_with_attr("phx-value-sandbox", sandbox)
    |> attr_value("aria-pressed") == "true"
  end

  defp tag_with_attr(html, attr, value) do
    attr = Regex.escape(attr)
    value = Regex.escape(value)

    case Regex.run(~r/<[^>]+#{attr}="#{value}"[^>]*>/, html) do
      [tag] -> tag
      nil -> nil
    end
  end

  defp attr_value(nil, _attr), do: nil

  defp attr_value(tag, attr) do
    attr = Regex.escape(attr)

    case Regex.run(~r/#{attr}="([^"]*)"/, tag) do
      [_match, value] -> value
      nil -> nil
    end
  end

  defp eventually(fun, attempts \\ 250)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp batch_blueprint(request) do
    %{
      id: "workflow:bounded-batch-transformation",
      objective: request.objective,
      sources: Enum.map(request.input_paths, &%{id: Path.basename(&1), path: &1}),
      components: [
        %{
          id: "split",
          type: "source_splitter",
          params: %{paths: request.input_paths, max_bytes: 16_000, max_chunks: 1}
        },
        %{id: "materialize", type: "source_materializer", params: %{}},
        %{id: "parse", type: "tabular_parser", params: %{format: "csv"}},
        %{
          id: "transform_each",
          type: "record_map",
          params: %{
            max_items: 10,
            max_concurrency: 4,
            function: %{
              tier: "tier1",
              expr: %{
                op: "template",
                template: "id={{id}} team={{team}} status={{status}}",
                from: %{op: "input"}
              }
            }
          }
        },
        %{id: "aggregate", type: "lambda_reduce", params: %{strategy: "join"}},
        %{
          id: "compose",
          type: "lambda_generate",
          params: %{title: "Batch Transformation Summary", sections: request.required_sections}
        },
        %{id: "write", type: "artifact_writer", params: %{path: request.output_path}},
        %{
          id: "verify",
          type: "objective_scorecard",
          params: %{
            artifact_path: request.output_path,
            required_sections: request.required_sections
          }
        }
      ],
      edges: [
        %{from: "split", output: "out", to: "materialize", input: "in"},
        %{from: "materialize", output: "out", to: "parse", input: "in"},
        %{from: "parse", output: "out", to: "transform_each", input: "in"},
        %{from: "transform_each", output: "out", to: "aggregate", input: "in"},
        %{from: "aggregate", output: "out", to: "compose", input: "in"},
        %{from: "compose", output: "out", to: "write", input: "in"},
        %{from: "write", output: "out", to: "verify", input: "in"}
      ],
      stop_conditions: ["all bounded records transformed", "summary artifact verified"],
      policies: %{max_concurrency: 4, max_items: 10},
      metadata: %{proposal_kind: "bounded_batch_golden_fixture"}
    }
  end

  def fake_intent_planner(store, _workspace, request, opts) do
    {:ok, analyze} =
      Node.new("analyze_notes", :lambda_map,
        arguments: %{
          prompt: "Extract evidence from {{content}}",
          model: Keyword.get(opts, :model, "openai:gpt-5.6-luna")
        }
      )

    {:ok, reduce} = Node.new("join_notes", :lambda_reduce, arguments: %{strategy: :join})

    {:ok, synthesize} =
      Node.new("synthesize", :llm_leaf,
        arguments: %{prompt: "Write a cited report from {{items}}"}
      )

    {:ok, map_edge} =
      Edge.new(
        %{node: analyze.id, port: "out"},
        %{node: reduce.id, port: "in"}
      )

    {:ok, synthesis_edge} =
      Edge.new(
        %{node: reduce.id, port: "out"},
        %{node: synthesize.id, port: "in"}
      )

    planning = %{
      strategy: :draft,
      rationale: "drafted because the task needs source fan-out and verified synthesis",
      reasons: [:forced_workflow_strategy],
      considered_candidates: []
    }

    {:ok, ir} =
      IR.new("workflow:test-intent", request.objective,
        nodes: %{
          analyze.id => analyze,
          reduce.id => reduce,
          synthesize.id => synthesize
        },
        edges: %{
          map_edge.id => map_edge,
          synthesis_edge.id => synthesis_edge
        },
        acceptance: [%{id: "cited_report", required: true, description: "report is cited"}],
        policies: %{max_llm_calls: 4},
        metadata: %{planning: planning}
      )

    {:ok, created} =
      WorkflowDefinitions.create_draft(store,
        workflow_key: Keyword.fetch!(opts, :workflow_key),
        workflow_name: request.objective,
        scope_type: Keyword.fetch!(opts, :scope_type),
        scope_id: Keyword.fetch!(opts, :scope_id),
        ir: ir,
        actor: "test:planner",
        catalog_hash: "test-catalog-hash",
        revision_metadata: %{
          planning: %{
            strategy: planning.strategy,
            rationale: planning.rationale,
            reasons: planning.reasons,
            considered_candidates: [],
            request: request
          }
        }
      )

    {:ok, artifact} =
      WorkflowDefinitions.record_compilation(store, created.revision.id, %{
        artifact: %{runtime: :runic, ir: ir},
        compiled_hash: "test-compiled-hash",
        catalog_hash: "test-catalog-hash",
        source_map: %{
          "analyze_notes" => %{},
          "join_notes" => %{},
          "synthesize" => %{}
        },
        metadata: %{artifact_format: "recompile_from_ir_v1"}
      })

    {:ok,
     %{
       status: :drafted,
       strategy: :draft,
       route: %{
         strategy: :draft,
         rationale: planning.rationale,
         reasons: planning.reasons,
         candidates: []
       },
       ir: ir,
       compiled: %{compiled_hash: "test-compiled-hash"},
       definition: created,
       artifact: artifact
     }}
  end

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
