defmodule RunicAI.RLM.RobustnessTest do
  use ExUnit.Case, async: false

  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.ElixirProjectGenerator
  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.Robustness
  alias RunicAI.RLM.Robustness.Catalog
  alias RunicAI.RLM.Robustness.DeterministicChecks
  alias RunicAI.RLM.Robustness.Judge
  alias RunicAI.RLM.Robustness.ProjectScenario
  alias RunicAI.RLM.Robustness.WorkspaceFactory

  test "robustness Mix task preserves repeated scenario and lane flags" do
    {opts, [], []} =
      Mix.Tasks.RunicAi.Rlm.Robustness.parse_args([
        "--scenario",
        "rlm_semantic_repair_loop",
        "--scenario",
        "rlm_llm_judge_repair_loop",
        "--lane",
        "rlm",
        "--lane",
        "browser_tidewave"
      ])

    assert Keyword.get_values(opts, :scenario) == [
             "rlm_semantic_repair_loop",
             "rlm_llm_judge_repair_loop"
           ]

    assert Keyword.get_values(opts, :lane) == ["rlm", "browser_tidewave"]
  end

  test "deterministic command checks persist bounded stdout and stderr excerpts" do
    root =
      Path.join(
        System.tmp_dir!(),
        "rlm-deterministic-output-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    scenario =
      ProjectScenario.new!(
        id: "output_capture",
        title: "Output Capture",
        prompt: "Capture command output.",
        deterministic_checks: [
          %{
            type: :command_passes,
            argv: [
              "sh",
              "-c",
              "printf 'stdout-start'; printf '%05000d' 1; printf 'stderr-start' >&2; exit 7"
            ]
          }
        ],
        judge_rubric: %{},
        browser_user_story: "As a tester, I want bounded command output evidence.",
        browser_validation_tasks: ["Inspect stdout and stderr excerpts."],
        metadata: %{}
      )

    result = DeterministicChecks.evaluate(scenario, root)

    assert %{status: :fail, details: details} = hd(result.checks)
    assert details.status == 7
    assert details.output =~ "stderr-start"
    assert details.stdout_excerpt =~ "...000"
    assert details.stderr_excerpt == "stderr-start"
    assert details.output_truncated? == true
    assert details.stdout_truncated? == true
    assert details.stderr_truncated? == false
    assert byte_size(details.stdout_excerpt) <= 4_003

    File.rm_rf(root)
  end

  test "optional deterministic command checks are review-grade skipped unless their env is enabled" do
    root =
      Path.join(
        System.tmp_dir!(),
        "rlm-optional-command-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    env = "RUNIC_AI_OPTIONAL_CHECK_TEST_#{System.unique_integer([:positive])}"
    System.delete_env(env)

    on_exit(fn ->
      System.delete_env(env)
      File.rm_rf(root)
    end)

    scenario =
      ProjectScenario.new!(
        id: "optional_command",
        title: "Optional Command",
        prompt: "Exercise optional command checks.",
        deterministic_checks: [
          %{type: :command_passes_if_env, env: env, argv: ["sh", "-c", "exit 17"]}
        ],
        judge_rubric: %{},
        browser_user_story: "As a tester, I want optional checks to be explicit.",
        browser_validation_tasks: ["Inspect optional check status."],
        metadata: %{}
      )

    skipped = DeterministicChecks.evaluate(scenario, root)
    assert skipped.status == :review
    assert skipped.skipped == 1
    assert [%{status: :skipped, details: %{skipped?: true, optional?: true}}] = skipped.checks

    System.put_env(env, "1")

    enabled = DeterministicChecks.evaluate(scenario, root)
    assert enabled.status == :fail
    assert [%{status: :fail, details: %{optional_env: ^env}}] = enabled.checks
  end

  test "catalog exposes project-generation scenarios with browser user stories" do
    scenarios = Robustness.scenarios()

    assert length(scenarios) >= 7
    assert Enum.any?(scenarios, &(&1.id == "field_service_dispatch"))
    assert Enum.any?(scenarios, &(&1.id == "field_service_repair_followup"))
    assert Enum.any?(scenarios, &(&1.id == "field_service_review_approval"))
    assert Enum.any?(scenarios, &(&1.id == "opslogic_objective_loop_approval_resume"))
    assert Enum.any?(scenarios, &(&1.id == "opslogic_objective_loop_budget_resume"))
    assert Enum.any?(scenarios, &(&1.id == "browser_progress_observability"))
    assert Enum.any?(scenarios, &(&1.id == "rlm_internal_repair_loop"))
    assert Enum.any?(scenarios, &(&1.id == "rlm_child_agent_repair_loop"))
    assert Enum.any?(scenarios, &(&1.id == "rlm_semantic_repair_loop"))
    assert Enum.any?(scenarios, &(&1.id == "rlm_llm_judge_repair_loop"))
    assert Enum.any?(scenarios, &(&1.id == "rlm_runtime_smoke_repair_loop"))
    assert Enum.all?(scenarios, &is_binary(&1.browser_user_story))
    assert Enum.all?(scenarios, &(length(&1.browser_validation_tasks) > 0))
  end

  test "OpsLogic approval-resume scenario gates plan and product-shape artifacts" do
    {:ok, scenario} = Catalog.get("opslogic_objective_loop_approval_resume")
    label = "test-opslogic-approval-resume-#{System.unique_integer([:positive])}"
    {:ok, workspace} = WorkspaceFactory.create(scenario, :rlm, run_label: label)
    coding_workspace = Workspace.new!(root: workspace.root)

    plan =
      EditPatchSet.new!(
        "Write OpsLogic implementation plan",
        [
          RunicAI.Coding.RLM.EditOperation.new!(:create_file,
            params: %{
              path: "tmp/ops_logic/PLAN.md",
              overwrite: true,
              content:
                "# OpsLogic Implementation Plan\n\nBuild the Phoenix LiveView and Postgres field-service SaaS in ./tmp/ops_logic.\n"
            }
          )
        ],
        expected_changed_files: ["tmp/ops_logic/PLAN.md"]
      )

    assert {:ok, %{status: :ok}} = EditPatchSet.apply(coding_workspace, plan)

    objective = """
    Implement OpsLogic (`ops_logic`) under ./tmp/ops_logic from the approved plan.
    Include field service dispatch, Phoenix LiveView dispatcher and worker flows,
    Postgres persistence boundaries, webhook routes, tests, compile, and runtime smoke.
    """

    assert {:ok, %{status: :ok}} =
             EditPatchSet.apply(coding_workspace, ElixirProjectGenerator.patch_set(objective))

    result = DeterministicChecks.evaluate(scenario, workspace.root)

    assert result.status == :pass,
           inspect(Enum.filter(result.checks, &(&1.status != :pass)), pretty: true)
  end

  test "workspace factory creates an isolated Mix project under tmp robustness root" do
    {:ok, scenario} = Catalog.get("field_service_dispatch")
    label = "test-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             WorkspaceFactory.create(scenario, :standard, run_label: label)

    assert String.contains?(workspace.root, "/tmp/rlm_robustness/")
    assert File.exists?(Path.join(workspace.root, "mix.exs"))
    assert File.exists?(Path.join(workspace.root, "test/test_helper.exs"))
  end

  test "workspace factory can seed a broken field-service repair fixture" do
    {:ok, scenario} = Catalog.get("field_service_repair_followup")
    label = "test-broken-repair-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             WorkspaceFactory.create(scenario, :browser_tidewave, run_label: label)

    assert File.exists?(Path.join(workspace.root, "lib/field_service_dispatch.ex"))
    refute File.exists?(Path.join(workspace.root, "test/field_service_repair_followup_test.exs"))

    result = DeterministicChecks.evaluate(scenario, workspace.root)

    assert result.status == :fail
    assert Enum.any?(result.checks, &(&1.status == :fail and &1.message =~ "command failed"))
  end

  test "workspace factory can seed a semantic RLM repair-loop fixture" do
    {:ok, scenario} = Catalog.get("rlm_semantic_repair_loop")
    label = "test-semantic-repair-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             WorkspaceFactory.create(scenario, :rlm, run_label: label)

    source = File.read!(Path.join(workspace.root, "lib/work_order.ex"))
    assert source =~ "def complete"
    refute source =~ "history"

    result = DeterministicChecks.evaluate(scenario, workspace.root)

    assert result.status == :fail
    assert Enum.any?(result.checks, &(&1.status == :fail and &1.message =~ "source text"))
    assert Enum.any?(result.checks, &(&1.status == :pass and &1.message =~ "command passed"))
  end

  test "workspace factory can seed an internal RLM repair-loop fixture" do
    {:ok, scenario} = Catalog.get("rlm_internal_repair_loop")
    label = "test-internal-repair-#{System.unique_integer([:positive])}"

    assert scenario.title == "RLM Parent-Loop Repair Fixture"
    assert scenario.metadata[:parent_loop_fixture?] == true
    assert scenario.metadata[:child_agent_repair_loop?] == false

    assert {:ok, workspace} =
             WorkspaceFactory.create(scenario, :rlm, run_label: label)

    assert File.read!(Path.join(workspace.root, "lib/internal_repair_demo.ex")) =~ "do: 41"

    result = DeterministicChecks.evaluate(scenario, workspace.root)

    assert result.status == :fail
    assert Enum.any?(result.checks, &(&1.status == :fail and &1.message =~ "command failed"))
  end

  test "workspace factory can seed a runtime-smoke RLM repair-loop fixture" do
    {:ok, scenario} = Catalog.get("rlm_runtime_smoke_repair_loop")
    label = "test-runtime-smoke-repair-#{System.unique_integer([:positive])}"

    assert {:ok, workspace} =
             WorkspaceFactory.create(scenario, :rlm, run_label: label)

    source = File.read!(Path.join(workspace.root, "lib/dispatch_runtime.ex"))
    assert source =~ ":supervision_not_started"
    refute source =~ "runtime_smoke_pass"

    result = DeterministicChecks.evaluate(scenario, workspace.root)

    assert result.status == :fail
    assert Enum.any?(result.checks, &(&1.status == :fail and &1.message =~ "source text"))
    assert Enum.any?(result.checks, &(&1.status == :fail and &1.message =~ "command failed"))
  end

  test "deterministic checks fail scaffold-only workspaces with actionable gaps" do
    {:ok, scenario} = Catalog.get("field_service_dispatch")
    label = "test-checks-#{System.unique_integer([:positive])}"
    {:ok, workspace} = WorkspaceFactory.create(scenario, :standard, run_label: label)

    result = DeterministicChecks.evaluate(scenario, workspace.root)

    assert result.status == :fail
    assert result.failed > 0
    assert Enum.any?(result.checks, &(&1.status == :fail and &1.message =~ "source text"))
  end

  test "deterministic changed-file checks ignore runtime smoke artifacts" do
    {:ok, scenario} = Catalog.get("existing_app_feature")
    label = "test-changed-files-#{System.unique_integer([:positive])}"
    {:ok, workspace} = WorkspaceFactory.create(scenario, :browser_tidewave, run_label: label)

    baseline_files =
      workspace.root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, workspace.root))
      |> Enum.sort()

    File.mkdir_p!(Path.join(workspace.root, "tmp/browser-ui-launch/chrome-cdp-profile/Default"))
    File.write!(Path.join(workspace.root, "tmp/browser-evidence-existing_app_feature.json"), "{}")

    File.write!(
      Path.join(workspace.root, "tmp/browser-ui-launch/chrome-cdp-profile/Default/Cache"),
      "cache"
    )

    File.mkdir_p!(Path.join(workspace.root, "lib/existing_app"))

    File.write!(
      Path.join(workspace.root, "lib/existing_app/reporting.ex"),
      "defmodule ExistingApp.Reporting do\nend\n"
    )

    result =
      DeterministicChecks.evaluate(scenario, workspace.root, baseline_files: baseline_files)

    changed_file_check =
      Enum.find(result.checks, &(&1.check.type == :changed_file_count_between))

    assert changed_file_check.status == :pass
    assert changed_file_check.details.changed_files == ["lib/existing_app/reporting.ex"]
  end

  test "existing app feature checks reject untouched seeded app and pass bounded feature slice" do
    {:ok, scenario} = Catalog.get("existing_app_feature")
    label = "test-existing-app-feature-#{System.unique_integer([:positive])}"
    {:ok, workspace} = WorkspaceFactory.create(scenario, :rlm, run_label: label)
    baseline_files = DeterministicChecks.workspace_files(workspace.root)
    baseline_fingerprints = DeterministicChecks.workspace_fingerprints(workspace.root)

    check_opts = [
      baseline_files: baseline_files,
      baseline_file_fingerprints: baseline_fingerprints
    ]

    untouched = DeterministicChecks.evaluate(scenario, workspace.root, check_opts)

    assert untouched.status == :fail
    assert Enum.any?(untouched.checks, &(&1.status == :fail and &1.message =~ "source text"))

    assert Enum.any?(
             untouched.checks,
             &(&1.status == :fail and &1.message =~ "changed file count 0 outside range")
           )

    assert {:ok, _output} =
             [root: workspace.root]
             |> Workspace.new!()
             |> EditPatchSet.apply(
               ElixirProjectGenerator.patch_set(
                 "Add one bounded existing app feature slice that adapts to ExistingApp.Accounts and includes an integration smoke"
               )
             )

    repaired = DeterministicChecks.evaluate(scenario, workspace.root, check_opts)

    assert repaired.status == :pass
    assert Enum.any?(repaired.checks, &(&1.message == "command passed"))

    changed_file_check =
      Enum.find(repaired.checks, &(&1.check.type == :changed_file_count_between))

    assert "lib/existing_app_feature.ex" in changed_file_check.details.changed_files
    assert "test/existing_app_feature_test.exs" in changed_file_check.details.changed_files
  end

  test "judge treats failed lane status as blocking even when deterministic checks pass" do
    {:ok, scenario} = Catalog.get("field_service_dispatch")

    judge =
      Judge.evaluate(scenario, %{
        lane: :browser_tidewave,
        lane_status: "failed",
        deterministic: %{status: :pass, passed: 1, failed: 0, total: 1, checks: []},
        final_output: "Error: failed after follow-up",
        ui_gaps: []
      })

    assert judge.overall == "fail"
    assert "lane execution failed" in judge.blocking_failures
  end

  test "LLM judge accepts a known-good fixture and records audit evidence" do
    {:ok, scenario} = Catalog.get("field_service_dispatch")

    response =
      Jason.encode!(%{
        overall: "pass",
        scores: all_judge_scores(1),
        blocking_failures: [],
        notable_strengths: ["domain flow is implemented"],
        evidence: ["mix test passed", "runtime smoke passed"]
      })

    judge =
      Judge.evaluate(scenario, passing_judge_evidence(),
        llm_judge?: true,
        model: "test:judge",
        client: RunicAI.LLM.TestClient.client(response)
      )

    assert judge.overall == "pass"
    assert judge.scores.intent_translation == 1
    assert judge.blocking_failures == []
    assert judge.audit.source == :llm
    assert judge.audit.model == "test:judge"
    assert judge.audit.fallback? == false
    assert judge.audit.prompt_sha256 =~ ~r/^[a-f0-9]{64}$/
    assert judge.audit.prompt_excerpt =~ "You are judging a RunicAI RLM robustness smoke"
    assert judge.audit.prompt_excerpt =~ scenario.prompt
    assert judge.audit.response_excerpt =~ "runtime smoke passed"
  end

  test "LLM judge cannot pass scaffold-only deterministic failures" do
    {:ok, scenario} = Catalog.get("field_service_dispatch")

    response =
      Jason.encode!(%{
        overall: "pass",
        scores: all_judge_scores(1),
        blocking_failures: [],
        notable_strengths: ["looks complete"],
        evidence: ["agent claimed success"]
      })

    judge =
      Judge.evaluate(scenario, scaffold_only_judge_evidence(),
        llm_judge?: true,
        client: RunicAI.LLM.TestClient.client(response)
      )

    assert judge.overall == "fail"
    assert "deterministic gates failed; LLM pass downgraded" in judge.blocking_failures
    assert judge.audit.source == :llm
    assert judge.audit.fallback? == false
  end

  test "LLM judge preserves partially-correct review and over-engineered failure fixtures" do
    {:ok, scenario} = Catalog.get("field_service_dispatch")

    partial =
      Jason.encode!(%{
        overall: "review",
        scores: all_judge_scores(1) |> Map.put("domain_correctness", 0),
        blocking_failures: ["assignment lifecycle is incomplete"],
        notable_strengths: ["project compiles"],
        evidence: ["WorkOrder exists, dispatch flow missing"]
      })

    over_engineered =
      Jason.encode!(%{
        overall: "fail",
        scores:
          all_judge_scores(1)
          |> Map.put("architecture_quality", 0)
          |> Map.put("dependency_selection", 0),
        blocking_failures: ["introduced unnecessary distributed queue dependency"],
        notable_strengths: [],
        evidence: ["solution exceeds scenario scope"]
      })

    partial_judge =
      Judge.evaluate(scenario, passing_judge_evidence(),
        llm_judge?: true,
        client: RunicAI.LLM.TestClient.client(partial)
      )

    over_engineered_judge =
      Judge.evaluate(scenario, passing_judge_evidence(),
        llm_judge?: true,
        client: RunicAI.LLM.TestClient.client(over_engineered)
      )

    assert partial_judge.overall == "review"
    assert partial_judge.scores.domain_correctness == 0
    assert "assignment lifecycle is incomplete" in partial_judge.blocking_failures

    assert over_engineered_judge.overall == "fail"
    assert over_engineered_judge.scores.architecture_quality == 0
    assert over_engineered_judge.scores.dependency_selection == 0

    assert "introduced unnecessary distributed queue dependency" in over_engineered_judge.blocking_failures
  end

  test "LLM judge fallback is explicit when provider output cannot be decoded" do
    {:ok, scenario} = Catalog.get("field_service_dispatch")

    judge =
      Judge.evaluate(scenario, scaffold_only_judge_evidence(),
        llm_judge?: true,
        model: "test:judge",
        client: RunicAI.LLM.TestClient.client("not json")
      )

    assert judge.overall == "fail"
    assert judge.audit.source == :heuristic_fallback
    assert judge.audit.llm_judge? == true
    assert judge.audit.fallback? == true
    assert judge.audit.fallback_reason == :decode_failed
    assert judge.audit.model == "test:judge"
    assert judge.audit.response_excerpt == "not json"
    assert judge.audit.error =~ "Jason.DecodeError"
  end

  test "runner persists LLM judge audit metadata in JSON report" do
    label = "test-llm-judge-audit-#{System.unique_integer([:positive])}"

    response =
      Jason.encode!(%{
        overall: "pass",
        scores: all_judge_scores(1),
        blocking_failures: [],
        notable_strengths: ["agent claimed success"],
        evidence: ["judge response persisted"]
      })

    assert {:ok, result} =
             Robustness.run_matrix(["existing_app_feature"],
               lanes: [:standard],
               run_label: label,
               llm_judge?: true,
               model: "test:judge",
               client: RunicAI.LLM.TestClient.client(response)
             )

    json_report = result.matrix_path |> Path.rootname() |> Kernel.<>(".json")
    assert File.exists?(json_report)

    [%{"status" => "fail", "judge" => %{"audit" => audit}}] =
      json_report |> File.read!() |> Jason.decode!()

    assert audit["source"] == "llm"
    assert audit["model"] == "test:judge"
    assert audit["fallback?"] == false
    assert audit["prompt_sha256"] =~ ~r/^[a-f0-9]{64}$/
    assert audit["prompt_excerpt"] =~ "You are judging a RunicAI RLM robustness smoke"
    assert audit["response_excerpt"] =~ "judge response persisted"
  end

  test "runner writes a browser/backend matrix report" do
    label = "test-matrix-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["field_service_dispatch"],
               lanes: [:browser_tidewave],
               run_label: label,
               browser_probe?: true
             )

    assert File.exists?(result.matrix_path)
    assert File.exists?(Path.rootname(result.matrix_path) <> ".json")

    assert [
             %{
               lane: :browser_tidewave,
               evidence: %{
                 browser_evidence_path: browser_evidence_path,
                 browser_ui_checks: browser_ui_checks,
                 ui_gaps: ui_gaps
               }
             }
           ] = result.results

    assert File.exists?(browser_evidence_path)

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "visible_state_present" and &1.status == "pass")
           )

    assert Enum.any?(ui_gaps, &(&1 =~ "DOM snapshot capture is missing"))

    browser_evidence = browser_evidence_path |> File.read!() |> Jason.decode!()

    assert browser_evidence["session_url"] =~ "/sessions/"
    assert get_in(browser_evidence, ["visible_state", "selected_agent"]) == "rlm"
    assert Enum.any?(browser_evidence["ui_checks"], &(&1["id"] == "dom_snapshot_captured"))
  end

  test "runner can merge browser UI capture artifacts into browser evidence" do
    label = "test-browser-ui-capture-#{System.unique_integer([:positive])}"

    capture_fun = fn request ->
      dom_path = Path.join(request.output_dir, "session-dom.txt")
      screenshot_path = Path.join(request.output_dir, "session.png")
      File.write!(dom_path, "RunicAI\nworkflow rlm\nrlm - completed")
      File.write!(screenshot_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

      %{
        status: "ok",
        dom_snapshot_path: dom_path,
        screenshot_path: screenshot_path,
        console_captured?: false,
        tidewave_interaction_captured?: false
      }
    end

    assert {:ok, result} =
             Robustness.run_matrix(["field_service_dispatch"],
               lanes: [:browser_tidewave],
               run_label: label,
               browser_probe?: true,
               browser_ui_capture?: true,
               browser_ui_capture_fun: capture_fun
             )

    assert [
             %{
               evidence: %{
                 browser_evidence_path: browser_evidence_path,
                 browser_ui_checks: browser_ui_checks,
                 ui_gaps: ui_gaps
               }
             }
           ] = result.results

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "dom_snapshot_captured" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "browser_screenshot_captured" and &1.status == "pass")
           )

    assert Enum.any?(ui_gaps, &(&1 =~ "Browser console capture"))

    browser_evidence = browser_evidence_path |> File.read!() |> Jason.decode!()

    assert get_in(browser_evidence, ["browser_ui_capture", "dom_snapshot_path"]) =~
             "session-dom.txt"
  end

  test "runner can launch browser lane through injected UI interaction evidence" do
    label = "test-browser-ui-launch-#{System.unique_integer([:positive])}"

    launch_fun = fn request ->
      assert request.launch["agent"] == "rlm"
      assert request.launch["mode"] == "patch"
      assert request.follow_up_prompt =~ "same session"

      {:ok, %{session_id: session_id, run_id: run_id}} =
        RunicAI.Workbench.start_agent_run(request.launch)

      assert {:ok, _event} =
               RunicAI.Workbench.record_terminal_event(%{
                 id: "terminal:browser-progress:#{System.unique_integer([:positive])}",
                 session_id: session_id,
                 run_id: run_id,
                 agent: :rlm,
                 kind: :rlm_node,
                 phase: :child_budget_selected,
                 status: :running,
                 title: "RLM child budget selected",
                 detail: "progress",
                 data_json: %{
                   stage: :child_budget_selected,
                   status: :running,
                   data: %{
                     node_id: "implement_project",
                     child_agent_id: "codex-child",
                     remaining_ms: 42_000,
                     selected_timeout_ms: 30_000
                   }
                 },
                 at: DateTime.utc_now()
               })

      assert {:ok, _event} =
               RunicAI.Workbench.record_terminal_event(%{
                 id: "terminal:browser-contract:#{System.unique_integer([:positive])}",
                 session_id: session_id,
                 run_id: run_id,
                 agent: :rlm,
                 kind: :message,
                 phase: :assistant,
                 status: :ok,
                 title: "RLM final output",
                 detail: "done",
                 data_json: %{
                   role: "assistant",
                   message_kind: "workflow_output",
                   content: "RLM completed.",
                   objective_contract: %{
                     id: "objective-contract:test",
                     metadata: %{evidence_required: ["source", "tests"]},
                     requirements: [%{id: "implementation_artifacts"}]
                   }
                 },
                 at: DateTime.utc_now()
               })

      dom_path = Path.join(request.output_dir, "session-dom.txt")
      screenshot_path = Path.join(request.output_dir, "session.png")
      console_path = Path.join(request.output_dir, "console.json")
      network_path = Path.join(request.output_dir, "network.json")

      File.write!(dom_path, "RunicAI\nworkflow rlm\nrlm - completed\nPlan")
      File.write!(screenshot_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
      File.write!(console_path, Jason.encode!([]))
      File.write!(network_path, Jason.encode!([]))

      %{
        :status => "ok",
        :session_id => session_id,
        :session_url => "#{request.base_url}/sessions/#{URI.encode_www_form(session_id)}",
        :dom_snapshot_path => dom_path,
        :screenshot_path => screenshot_path,
        :console_path => console_path,
        "console_captured?" => true,
        :network_path => network_path,
        "network_captured?" => true,
        "ui_launch_captured?" => true,
        "plan_visibility_captured?" => true,
        "workflow_stage_plan_visible?" => true,
        "live_progress_visible?" => true,
        "active_progress_snapshot_captured?" => true,
        "active_progress_current_context_visible?" => true,
        "active_progress_child_visible?" => true,
        "active_progress_remaining_visible?" => true,
        "active_progress_budget_visible?" => true,
        "active_progress_pre_final_visible?" => false,
        :active_plan_text_preview =>
          "LIVE PROGRESS\nRLM Node budget selected running\nCHILD\nimplement_project:edit\nREMAINING\n42.0s",
        :plan_stage_labels => [
          "objective",
          "planning",
          "implementation",
          "verification",
          "repair",
          "review"
        ],
        "browser_follow_up_captured?" => true,
        "tidewave_interaction_captured?" => true,
        :follow_up_state => %{
          "liveViewSubmit" => %{"ok" => true},
          "prompt" => request.follow_up_prompt
        }
      }
    end

    assert {:ok, result} =
             Robustness.run_matrix(["field_service_dispatch"],
               lanes: [:browser_tidewave],
               run_label: label,
               browser_probe?: true,
               browser_ui_launch?: true,
               browser_ui_launch_fun: launch_fun
             )

    assert [
             %{
               evidence: %{
                 browser_ui_checks: browser_ui_checks,
                 ui_gaps: ui_gaps,
                 browser_evidence_path: browser_evidence_path
               }
             }
           ] = result.results

    assert Enum.any?(browser_ui_checks, &(&1.id == "ui_launch_captured" and &1.status == "pass"))

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "browser_follow_up_captured" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "browser_console_captured" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "browser_network_captured" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "workflow_stage_plan_visible" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "live_progress_summary_visible" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "active_progress_budget_details_visible" and &1.status == "pass")
           )

    assert ui_gaps == []

    browser_evidence = browser_evidence_path |> File.read!() |> Jason.decode!()
    assert get_in(browser_evidence, ["browser_ui_capture", "ui_launch_captured?"]) == true

    assert get_in(browser_evidence, ["browser_ui_capture", "workflow_stage_plan_visible?"]) ==
             true

    assert get_in(browser_evidence, ["browser_ui_capture", "browser_follow_up_captured?"]) == true
  end

  test "browser lane can force and capture a review-card approval decision" do
    label = "test-browser-review-approval-#{System.unique_integer([:positive])}"

    launch_fun = fn request ->
      assert request.launch["agent"] == "rlm"
      assert request.launch["approve"] == "ask"
      assert is_nil(request.follow_up_prompt)

      assert request.review_decision[:action] == "approve" or
               request.review_decision["action"] == "approve"

      {:ok, %{session_id: session_id, run_id: run_id}} =
        RunicAI.Workbench.start_agent_run(request.launch)

      review = wait_for_review_request(session_id)

      assert {:ok, _event} =
               RunicAI.Workbench.record_review_decision(session_id, review.id, %{
                 "action" => "approve"
               })

      wait_for_terminal_event(session_id, "browser_probe_completed")

      workspace = Workspace.new!(root: request.launch["cwd"])

      assert {:ok, _output} =
               EditPatchSet.apply(
                 workspace,
                 ElixirProjectGenerator.patch_set(request.launch["objective"])
               )

      assert {:ok, _event} =
               RunicAI.Workbench.record_terminal_event(%{
                 id: "terminal:browser-review-contract:#{System.unique_integer([:positive])}",
                 session_id: session_id,
                 run_id: run_id,
                 agent: :rlm,
                 kind: :message,
                 phase: :assistant,
                 status: :ok,
                 title: "RLM final output",
                 detail: "done",
                 data_json: %{
                   role: "assistant",
                   message_kind: "workflow_output",
                   content: "RLM completed.",
                   objective_contract: %{
                     id: "objective-contract:test",
                     metadata: %{evidence_required: ["source", "tests"]},
                     requirements: [%{id: "implementation_artifacts"}]
                   }
                 },
                 at: DateTime.utc_now()
               })

      dom_path = Path.join(request.output_dir, "session-dom.txt")
      screenshot_path = Path.join(request.output_dir, "session.png")
      console_path = Path.join(request.output_dir, "console.json")
      network_path = Path.join(request.output_dir, "network.json")

      File.write!(dom_path, "RunicAI\nworkflow rlm\nReview required\nrlm - completed\nPlan")
      File.write!(screenshot_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
      File.write!(console_path, Jason.encode!([]))
      File.write!(network_path, Jason.encode!([]))

      %{
        :status => "ok",
        :session_id => session_id,
        :session_url => "#{request.base_url}/sessions/#{URI.encode_www_form(session_id)}",
        :dom_snapshot_path => dom_path,
        :screenshot_path => screenshot_path,
        :console_path => console_path,
        "console_captured?" => true,
        :network_path => network_path,
        "network_captured?" => true,
        "ui_launch_captured?" => true,
        "plan_visibility_captured?" => true,
        "workflow_stage_plan_visible?" => true,
        "live_progress_visible?" => true,
        "active_progress_snapshot_captured?" => true,
        "active_progress_current_context_visible?" => true,
        "active_progress_child_visible?" => true,
        "active_progress_remaining_visible?" => true,
        "active_progress_budget_visible?" => true,
        "active_progress_pre_final_visible?" => true,
        :active_plan_text_preview =>
          "LIVE PROGRESS\nReview required: rlm_node_execution\nCHILD\nimplement_project:edit\nREMAINING\n42.0s",
        :plan_stage_labels => [
          "objective",
          "planning",
          "implementation",
          "verification",
          "repair",
          "review"
        ],
        "review_decision_required?" => true,
        "review_card_captured?" => true,
        "review_decision_captured?" => true,
        :review_decision_state => %{
          "found" => true,
          "submitted" => true,
          "id" => review.id,
          "action" => "approve"
        },
        "browser_follow_up_required?" => false,
        "browser_follow_up_captured?" => false,
        "tidewave_interaction_captured?" => false
      }
    end

    assert {:ok, result} =
             Robustness.run_matrix(["field_service_review_approval"],
               lanes: [:browser_tidewave],
               run_label: label,
               browser_probe?: true,
               browser_ui_launch?: true,
               browser_ui_launch_fun: launch_fun
             )

    assert [
             %{
               evidence: %{
                 browser_ui_checks: browser_ui_checks,
                 ui_gaps: [],
                 browser_evidence_path: browser_evidence_path
               }
             }
           ] = result.results

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "browser_review_decision_captured" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "active_progress_budget_details_visible" and &1.status == "pass")
           )

    assert Enum.any?(
             browser_ui_checks,
             &(&1.id == "active_progress_pre_final_visible" and &1.status == "pass")
           )

    browser_evidence = browser_evidence_path |> File.read!() |> Jason.decode!()
    assert get_in(browser_evidence, ["browser_ui_capture", "review_decision_required?"]) == true
    assert get_in(browser_evidence, ["browser_ui_capture", "review_decision_captured?"]) == true
    assert get_in(browser_evidence, ["visible_state", "review_request_count"]) >= 1
  end

  test "live lane writes an event trail and emits progress callbacks" do
    label = "test-live-trail-#{System.unique_integer([:positive])}"
    {:ok, progress} = Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, _objective, opts ->
      assert opts[:proposal_timeout_ms] == 10_000
      assert opts[:repair?] == true
      assert opts[:max_repair_iterations] == 2

      opts[:event_sink].(%{
        stage: :node_started,
        status: :running,
        data: %{node_id: "fake-node", kind: :agent}
      })

      {:ok,
       %{
         output: %{text: "done"},
         context: %{},
         episodes: [],
         trace: [],
         objective_scorecard: %{objective_status: :objective_satisfied}
       }}
    end

    assert {:ok, result} =
             Robustness.run_matrix(["field_service_dispatch"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               run_fun: run_fun,
               progress_sink: fn event -> Agent.update(progress, &(&1 ++ [event])) end,
               max_runtime_ms: 5_000
             )

    assert [%{evidence: %{event_trail_path: trail_path, jsonl_path: jsonl_path}}] =
             result.results

    assert [%{evidence: %{event_trail_summary: %{latest_progress: latest}}}] = result.results
    assert latest.node_id == "fake-node"

    assert File.exists?(trail_path)
    assert File.exists?(jsonl_path)
    assert File.read!(result.matrix_path) =~ Path.relative_to_cwd(trail_path)
    assert File.read!(result.matrix_path) =~ "node_started fake-node"

    trail =
      trail_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(trail, &(&1["event"] == "lane_started"))
    assert Enum.any?(trail, &(&1["event"] == "terminal_output"))
    assert Enum.any?(trail, &(&1["event"] == "lane_completed"))

    emitted = Agent.get(progress, & &1)
    assert Enum.any?(emitted, &(&1.event == :lane_started))
    assert Enum.any?(emitted, &(&1.event == :terminal_output))
  end

  test "live OpsLogic objective-loop lane writes plan, captures approval, resumes, and verifies" do
    label = "test-opslogic-objective-live-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["opslogic_objective_loop_approval_resume"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               max_runtime_ms: 60_000
             )

    assert [
             %{
               status: :review,
               deterministic: %{status: :review, skipped: 2},
               evidence: %{
                 objective_loop: %{
                   status: :review_approved_and_resumed,
                   initial: %{status: :review, decision_action: :request_review_approval},
                   resumed: %{status: :ok, decision_action: :complete}
                 },
                 event_trail_path: trail_path,
                 jsonl_path: jsonl_path
               },
               workspace: root
             }
           ] = result.results

    assert File.exists?(Path.join(root, "tmp/ops_logic/PLAN.md"))
    assert File.exists?(Path.join(root, "tmp/ops_logic/lib/ops_logic/scheduling.ex"))

    assert File.exists?(Path.join(root, "tmp/ops_logic/lib/ops_logic_web/dispatcher_live.ex"))

    trail = File.read!(trail_path)
    assert trail =~ "objective_loop_review_approved"
    assert trail =~ "objective_loop_resume_event"

    jsonl = File.read!(jsonl_path)
    assert jsonl =~ "Objective review approval required"

    assert File.read!(result.matrix_path) =~
             "| opslogic_objective_loop_approval_resume | rlm | review"
  end

  test "live OpsLogic objective-loop lane requests budget, resumes, and verifies" do
    label = "test-opslogic-objective-budget-live-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["opslogic_objective_loop_budget_resume"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               max_runtime_ms: 60_000
             )

    assert [
             %{
               status: :review,
               deterministic: %{status: :review, skipped: 2},
               evidence: %{
                 objective_loop: %{
                   status: :budget_approved_and_resumed,
                   initial: %{
                     status: :needs_budget_approval,
                     decision_action: :request_budget_approval
                   },
                   resumed: %{status: :ok, decision_action: :complete}
                 },
                 event_trail_path: trail_path,
                 jsonl_path: jsonl_path
               },
               workspace: root
             }
           ] = result.results

    assert File.exists?(Path.join(root, "tmp/ops_logic/PLAN.md"))
    assert File.exists?(Path.join(root, "tmp/ops_logic/lib/ops_logic_web/worker_live.ex"))

    trail = File.read!(trail_path)
    assert trail =~ "objective_loop_budget_approved"
    assert trail =~ "objective_loop_resume_event"

    jsonl = File.read!(jsonl_path)
    assert jsonl =~ "Objective budget approval required"

    assert File.read!(result.matrix_path) =~
             "| opslogic_objective_loop_budget_resume | rlm | review"
  end

  test "live lane errors fail with explicit lane blocking evidence" do
    label = "test-live-error-#{System.unique_integer([:positive])}"

    run_fun = fn _cwd, _objective, _opts ->
      {:error, RunicAI.Error.validation("synthetic lane failure")}
    end

    assert {:ok, result} =
             Robustness.run_matrix(["existing_app_feature"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               run_fun: run_fun,
               max_runtime_ms: 5_000
             )

    assert [%{status: :fail, deterministic: %{status: :fail}, judge: judge}] = result.results
    assert "lane execution errored" in judge.blocking_failures
  end

  test "live RLM lane can force the internal repair loop to consume failing command evidence" do
    label = "test-internal-repair-live-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["rlm_internal_repair_loop"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               max_runtime_ms: 60_000
             )

    assert [
             %{
               status: :pass,
               deterministic: %{status: :pass},
               evidence: %{repair_count: 1, repair_summary: repair_summary}
             }
           ] = result.results

    assert repair_summary.repair_status == :satisfied
    assert [%{repair_plan: repair_plan}] = repair_summary.repair_history
    assert repair_plan.observed_failure =~ "mix test"
    assert repair_plan.verification_command == "mix test"
    assert File.read!(result.matrix_path) =~ "rlm_internal_repair_loop"
    assert File.read!(result.matrix_path) =~ "| rlm_internal_repair_loop | rlm | pass"
  end

  test "live RLM repair loop can delegate command repair to a real child agent" do
    label = "test-child-agent-repair-live-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["rlm_child_agent_repair_loop"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               max_runtime_ms: 60_000
             )

    assert [
             %{
               status: :pass,
               deterministic: %{status: :pass},
               evidence: %{repair_count: 1, repair_summary: repair_summary}
             }
           ] = result.results

    assert repair_summary.repair_status == :satisfied
    assert [%{repair_plan: repair_plan, child_status: :completed}] = repair_summary.repair_history
    assert repair_plan.observed_failure =~ "mix test"
    assert repair_plan.verification_command == "mix test"

    assert [%{changed_files: ["lib/internal_repair_demo.ex"]}] = repair_summary.repair_history

    [%{evidence: %{jsonl_path: jsonl_path}}] = result.results
    jsonl = File.read!(jsonl_path)
    assert jsonl =~ "standard_coding_agent"
    assert jsonl =~ "apply_patch"
    assert File.read!(result.matrix_path) =~ "rlm_child_agent_repair_loop"
    assert File.read!(result.matrix_path) =~ "| rlm_child_agent_repair_loop | rlm | pass"
  end

  test "live RLM lane can force the internal repair loop to consume semantic judge evidence" do
    label = "test-semantic-repair-live-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["rlm_semantic_repair_loop"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               max_runtime_ms: 60_000
             )

    assert [
             %{
               status: :pass,
               deterministic: %{status: :pass},
               evidence: %{repair_count: 1, repair_summary: repair_summary}
             }
           ] = result.results

    assert repair_summary.repair_status == :satisfied
    assert [%{repair_plan: repair_plan}] = repair_summary.repair_history
    assert repair_plan.observed_failure =~ "semantic requirement"
    assert repair_plan.observed_failure =~ "transition history"
    assert repair_plan.planned_edit =~ "Add a history field"
    assert repair_plan.verification_command == "mix test"

    [%{evidence: %{jsonl_path: jsonl_path}}] = result.results
    jsonl = File.read!(jsonl_path)
    assert jsonl =~ "standard_coding_agent"
    assert jsonl =~ "apply_patch"
    assert jsonl =~ "lib/work_order.ex"
    assert File.read!(result.matrix_path) =~ "rlm_semantic_repair_loop"
    assert File.read!(result.matrix_path) =~ "| rlm_semantic_repair_loop | rlm | pass"
  end

  test "live RLM lane can force the internal repair loop to consume LLM judge evidence" do
    label = "test-llm-judge-repair-live-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["rlm_llm_judge_repair_loop"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               max_runtime_ms: 60_000
             )

    assert [
             %{
               status: :pass,
               deterministic: %{status: :pass},
               evidence: %{repair_count: 1, repair_summary: repair_summary}
             }
           ] = result.results

    assert repair_summary.repair_status == :satisfied
    assert [%{repair_plan: repair_plan}] = repair_summary.repair_history
    assert repair_plan.observed_failure =~ "semantic requirement"
    assert repair_plan.observed_failure =~ "LLM semantic judge"
    assert repair_plan.observed_failure =~ "test:semantic-judge"
    assert repair_plan.observed_failure =~ "transition_history"
    assert repair_plan.planned_edit =~ "Add a history field"
    assert repair_plan.verification_command == "mix test"

    [%{evidence: %{jsonl_path: jsonl_path}}] = result.results
    jsonl = File.read!(jsonl_path)
    assert jsonl =~ "standard_coding_agent"
    assert jsonl =~ "apply_patch"
    assert jsonl =~ "lib/work_order.ex"
    assert File.read!(result.matrix_path) =~ "rlm_llm_judge_repair_loop"
    assert File.read!(result.matrix_path) =~ "| rlm_llm_judge_repair_loop | rlm | pass"
  end

  test "live RLM lane can force the internal repair loop to consume runtime smoke evidence" do
    label = "test-runtime-smoke-repair-live-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Robustness.run_matrix(["rlm_runtime_smoke_repair_loop"],
               lanes: [:rlm],
               run_label: label,
               live_agent_lanes?: true,
               max_runtime_ms: 60_000
             )

    assert [
             %{
               status: :pass,
               deterministic: %{status: :pass},
               evidence: %{repair_count: 1, repair_summary: repair_summary}
             }
           ] = result.results

    assert repair_summary.repair_status == :satisfied
    assert [%{repair_plan: repair_plan}] = repair_summary.repair_history
    assert repair_plan.observed_failure =~ "runtime_smoke"
    assert repair_plan.observed_failure =~ "dispatch_flow"
    assert repair_plan.verification_command =~ "DispatchRuntime.runtime_smoke"

    [%{evidence: %{jsonl_path: jsonl_path}}] = result.results
    jsonl = File.read!(jsonl_path)
    assert jsonl =~ "standard_coding_agent"
    assert jsonl =~ "apply_patch"
    assert jsonl =~ "lib/dispatch_runtime.ex"
    assert File.read!(result.matrix_path) =~ "rlm_runtime_smoke_repair_loop"
    assert File.read!(result.matrix_path) =~ "| rlm_runtime_smoke_repair_loop | rlm | pass"
  end

  defp all_judge_scores(value) do
    %{
      "intent_translation" => value,
      "workflow_planning" => value,
      "dependency_selection" => value,
      "architecture_quality" => value,
      "domain_correctness" => value,
      "test_quality" => value,
      "verification_honesty" => value,
      "repair_effectiveness" => value,
      "user_output_quality" => value
    }
  end

  defp passing_judge_evidence do
    %{
      lane: :rlm,
      lane_status: :completed,
      deterministic: %{status: :pass, passed: 3, failed: 0, total: 3, checks: []},
      final_output: "Implemented WorkOrder, Technician, Dispatch, tests, and runtime smoke.",
      repair_count: 1,
      ui_gaps: []
    }
  end

  defp scaffold_only_judge_evidence do
    %{
      lane: :standard,
      lane_status: :skipped,
      deterministic: %{
        status: :fail,
        passed: 1,
        failed: 2,
        total: 3,
        checks: [
          %{
            status: :fail,
            check: %{type: :source_contains},
            message: "source text not found: WorkOrder"
          },
          %{
            status: :fail,
            check: %{type: :command_passes},
            message: "command failed: mix test"
          }
        ]
      },
      final_output: "Scaffold only.",
      ui_gaps: []
    }
  end

  defp wait_for_review_request(session_id, attempts \\ 80)

  defp wait_for_review_request(session_id, 0) do
    flunk("timed out waiting for review request in #{session_id}")
  end

  defp wait_for_review_request(session_id, attempts) do
    snapshot = RunicAI.Workbench.session_snapshot(session_id)

    review =
      snapshot && Enum.find(snapshot.review_requests, &(&1.status in ["pending", "waiting"]))

    if review do
      review
    else
      Process.sleep(50)
      wait_for_review_request(session_id, attempts - 1)
    end
  end

  defp wait_for_terminal_event(session_id, phase, attempts \\ 80)

  defp wait_for_terminal_event(session_id, phase, 0) do
    flunk("timed out waiting for terminal event #{phase} in #{session_id}")
  end

  defp wait_for_terminal_event(session_id, phase, attempts) do
    snapshot = RunicAI.Workbench.session_snapshot(session_id)
    event = snapshot && Enum.find(snapshot.events, &(&1.phase == phase))

    if event do
      event
    else
      Process.sleep(50)
      wait_for_terminal_event(session_id, phase, attempts - 1)
    end
  end
end
