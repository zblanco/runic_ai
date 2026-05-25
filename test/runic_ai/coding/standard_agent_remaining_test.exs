defmodule RunicAI.Coding.StandardAgentRemainingTest do
  use ExUnit.Case, async: false

  alias Runic.Workflow
  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.Codex.EventNormalizer
  alias RunicAI.Coding.Evals
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Coding.Prompt
  alias RunicAI.Coding.Recipe
  alias RunicAI.Coding.RecipeRegistry
  alias RunicAI.Coding.Review
  alias RunicAI.Coding.Session
  alias RunicAI.Coding.SmokeReport
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.WorkspaceDelta
  alias RunicAI.Evaluation.Case
  alias RunicAI.LLM.TestClient
  alias RunicAI.Prompt, as: TurnPrompt
  alias RunicAI.Testing.ScriptedLLM

  test "review gate emits exact patch details and resumes after allow" do
    root = sample_project()
    File.write!(Path.join(root, "lib/old.ex"), "defmodule Old, do: nil\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "delete", path: "lib/old.ex"}]},
               id: "call_1"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/old.ex. Verification: not run.")}
      end
    end

    workflow =
      Agent.patch(workspace, "Remove the local secret fixture.",
        model: "test:model",
        client: client
      )

    review_request = Agent.latest_review_request(workflow)
    assert review_request.checkpoint == :pre_tool
    assert review_request.subject.calls |> hd() |> Map.get(:tool_name) == "apply_patch"

    review_payload = review_request.details.guard_decision.details.review_request
    assert review_payload.reason == :destructive_patch

    assert get_in(review_payload, [:calls, Access.at(0), :arguments, :operations]) == [
             %{"op" => "delete", "path" => "lib/old.ex"}
           ]

    workflow =
      Workflow.react_until_satisfied(workflow, %{review_decision: Review.allow(review_request)})

    refute File.exists?(Path.join(root, "lib/old.ex"))
    assert Agent.summary(workflow).changed_files == ["lib/old.ex"]
  end

  test "review rewrite executes the replacement execution plan" do
    root = sample_project()
    File.write!(Path.join(root, ".env"), "TOKEN=secret\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "delete", path: ".env"}]},
               id: "call_1"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/demo.ex. Verification: not run.")}
      end
    end

    workflow =
      Agent.patch(workspace, "Make the safer replacement.", model: "test:model", client: client)

    review_request = Agent.latest_review_request(workflow)
    original_plan = review_request.subject
    [call] = original_plan.calls

    replacement_plan = %{
      original_plan
      | calls: [
          %{
            call
            | arguments: %{
                operations: [%{op: "update", path: "lib/demo.ex", content: demo_source(42)}]
              }
          }
        ]
    }

    workflow =
      Workflow.react_until_satisfied(workflow, %{
        review_decision: Review.rewrite(review_request, replacement_plan)
      })

    assert File.exists?(Path.join(root, ".env"))
    assert File.read!(Path.join(root, "lib/demo.ex")) == demo_source(42)
    assert Agent.summary(workflow).changed_files == ["lib/demo.ex"]
  end

  test "command policy denial is returned as a model-visible tool observation" do
    workspace = Workspace.new!(root: sample_project())

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("run_command", %{argv: ["rm", "-rf", "tmp"]}, id: "call_1")
           ])}

        _ ->
          tool_message = List.last(tool_messages(messages))
          assert tool_message.content =~ "command is blocked by command policy"
          {:ok, TestClient.result("Blocked unsafe command; no files changed.")}
      end
    end

    workflow =
      Agent.run(workspace, "Try the unsafe command.",
        model: "test:model",
        client: client,
        visible_tools: ["run_command"],
        pre_tool_guard: nil,
        command_policy: [allowed_commands: ["git"]]
      )

    assert Agent.summary(workflow).reply == "Blocked unsafe command; no files changed."
  end

  test "named recipe registry and selector expose standard commands" do
    assert RecipeRegistry.names() == [:explain_repo, :fix_ci, :review, :triage_bug, :write_tests]

    assert %Recipe{name: :review, mode: :read_only} = RecipeRegistry.fetch!("/review")

    assert %Recipe{name: :fix_ci, mode: :verify} =
             Agent.select_recipe("ignored", classifier: fn _ -> :fix_ci end)

    assert %Recipe{name: :triage_bug, mode: :read_only} = Agent.select_recipe("/triage-bug crash")
  end

  test "coding sessions persist snapshots and resume review-gated work" do
    {:ok, store} = InMemory.start_link()
    root = sample_project()

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "update", path: "lib/demo.ex", content: demo_source(42)}]},
               id: "call_1"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/demo.ex.")}
      end
    end

    session =
      Session.new(root,
        mode: :patch,
        model: "test:model",
        client: client,
        review_gate_opts: [max_patch_bytes: 1]
      )
      |> Session.submit(%{agent_id: "coding", user: "Patch Demo.answer/0."})

    assert session.status == :review
    assert {:ok, ref} = Session.persist_snapshot(session, {InMemory, store})
    assert [_event] = InMemory.events(store)
    assert {:ok, _artifact} = InMemory.get_artifact(store, ref)

    review_request = List.last(session.outputs).latest_review_request
    resumed = Session.resume(session, %{review_decision: Review.allow(review_request)})

    assert resumed.status == :idle
    assert Session.snapshot(resumed).summary.changed_files == ["lib/demo.ex"]
  end

  test "session spec routes the coding agent through the integrated runtime contract" do
    spec =
      Session.spec(sample_project(),
        mode: :read_only,
        model: "test:model",
        client: ScriptedLLM.client(["ok"])
      )

    assert spec.kind == :integrated
    assert spec.recipe == Agent
    assert Keyword.fetch!(spec.recipe_opts, :workspace).root
  end

  @tag timeout: 60_000
  test "coding session resumes after failed verification pauses on risky repair" do
    root = failing_mix_project()

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("run_tests", %{args: ["test/smoke_test.exs"]}, id: "call_1")
           ])}

        1 ->
          assert List.last(tool_messages(messages)).content =~ "\"status\":\"fail\""

          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "update", path: "lib/smoke.ex", content: smoke_source(42)}]},
               id: "call_2"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/smoke.ex. Verification was repaired.")}
      end
    end

    session =
      Session.new(root,
        mode: :verify,
        model: "test:model",
        client: client,
        review_gate_opts: [max_patch_bytes: 1]
      )
      |> Session.submit(%{agent_id: "coding", user: "Fix the failing smoke test."})

    assert session.status == :review
    assert [%{status: "fail"}] = Session.snapshot(session).summary.verifications

    review_request = List.last(session.outputs).latest_review_request
    resumed = Session.resume(session, %{review_decision: Review.allow(review_request)})

    assert resumed.status == :idle
    assert File.read!(Path.join(root, "lib/smoke.ex")) == smoke_source(42)
    snapshot = Session.snapshot(resumed)
    assert snapshot.summary.changed_files == ["lib/smoke.ex"]

    assert [%{status: :completed, changed_files: ["lib/smoke.ex"]}] =
             snapshot.summary.repair_attempts
  end

  test "workspace delta excludes build and dependency directories" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    before = WorkspaceDelta.snapshot(workspace)

    File.write!(Path.join(root, "lib/demo.ex"), demo_source(42))
    File.mkdir_p!(Path.join(root, "_build/dev"))
    File.mkdir_p!(Path.join(root, "deps/example"))
    File.mkdir_p!(Path.join(root, "tmp"))
    File.mkdir_p!(Path.join(root, ".runic_ai"))
    File.write!(Path.join(root, "_build/dev/ignored.beam"), "ignored")
    File.write!(Path.join(root, "deps/example/mix.exs"), "ignored")
    File.write!(Path.join(root, "tmp/rlm-event-trail.jsonl"), "ignored")
    File.write!(Path.join(root, ".runic_ai/runs.db"), "ignored")

    delta = WorkspaceDelta.diff(before, WorkspaceDelta.snapshot(workspace))

    assert delta.modified == ["lib/demo.ex"]
    assert WorkspaceDelta.changed_paths(delta) == ["lib/demo.ex"]
  end

  test "prompt OODA and scorecard language stays scoped to verification mode" do
    workspace = Workspace.new!(root: sample_project())

    read_only = Prompt.system(workspace, Recipe.named(:read_only))
    patch = Prompt.system(workspace, Recipe.new!(mode: :patch))
    verify = Prompt.system(workspace, Recipe.new!(mode: :verify))

    refute read_only =~ "OODA"
    refute patch =~ "OODA"
    refute read_only =~ "generated scaffold tests"
    refute patch =~ "generated scaffold tests"

    assert verify =~ "OODA loop"
    assert verify =~ "generated scaffold tests"
    assert verify =~ "project's directory"
  end

  @tag timeout: 60_000
  test "scripted exhausted objective gate summary reports incomplete scorecard and salvageable changes" do
    root = passing_mix_project()
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{
                     op: "update",
                     path: "lib/smoke.ex",
                     content: smoke_with_extra_source()
                   }
                 ]
               },
               id: "call_patch"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Complete.")}
      end
    end

    workflow =
      Agent.verify(workspace, "Add Smoke.extra/0.",
        model: "test:model",
        client: client,
        objective_gate?: true,
        objective_gate_max_iterations: 0
      )

    summary = Agent.summary(workflow)

    assert summary.changed_files == ["lib/smoke.ex"]
    assert summary.modified_files == ["lib/smoke.ex"]
    assert [%{status: :completed, changed_files: ["lib/smoke.ex"]}] = summary.repair_attempts
    assert summary.objective_status == :objective_incomplete
    assert summary.objective_scorecard.objective_status == :objective_incomplete
    assert Enum.any?(summary.risks, &String.contains?(&1, "objective gate ended"))
  end

  @tag timeout: 60_000
  test "source assertions and runtime smokes appear in summaries and trace events" do
    root = failing_mix_project()
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "source_assert",
               %{
                 checks: [
                   %{
                     id: "smoke-source",
                     type: "source_contains",
                     params: %{path: "lib/smoke.ex", text: "def answer"}
                   }
                 ]
               },
               id: "call_source_assert"
             )
           ])}

        1 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "runtime_smoke",
               %{adapter: "mix", code: "IO.puts(Smoke.answer())", cwd: "."},
               id: "call_runtime_smoke"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Verified source assertion and runtime smoke.")}
      end
    end

    workflow =
      Agent.verify(workspace, "Verify the smoke module.",
        model: "test:model",
        client: client,
        pre_tool_guard: nil
      )

    summary = Agent.summary(workflow)

    assert [
             %{tool: "source_assert", status: "pass", results: [_result]},
             %{tool: "runtime_smoke", status: "pass", runtime_smoke?: true}
           ] = summary.verifications

    events = Agent.trace_events(workflow)
    assert Enum.any?(events, &(&1.kind == :coding_verification_observation))

    assert Enum.any?(
             events,
             &(&1.kind == :coding_tool_observation and &1.metadata.tool_name == "runtime_smoke")
           )
  end

  @tag timeout: 60_000
  test "scripted nested project verification runs from generated project directory" do
    root = nested_passing_mix_project()
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "run_tests",
               %{args: ["test/smoke_test.exs"], cwd: "field_service_poc"},
               id: "call_nested_tests"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Verification: run_tests pass in field_service_poc.")}
      end
    end

    workflow =
      Agent.verify(workspace, "Verify the generated project.",
        model: "test:model",
        client: client
      )

    assert [%{tool: "run_tests", status: "pass", cwd: cwd}] =
             Agent.summary(workflow).verifications

    assert String.ends_with?(cwd, "/field_service_poc")
  end

  test "FieldService regression fixtures run without live LLM and reports expose overclaims" do
    root = sample_project()
    cases = Evals.field_service_cases(workspace: root)
    run = Evals.run(cases)

    assert Enum.all?(cases, &(Map.get(&1.metadata, :representative_trajectory) != []))
    assert length(run.results) == 2
    assert Enum.all?(run.results, &(&1.status == :passed))

    [success, overclaim] = Evals.field_service_report_fixtures()
    report = Evals.compact_report(overclaim, compare_with: success)
    decoded_report = overclaim |> Jason.encode!() |> Jason.decode!() |> Evals.compact_report()

    assert SmokeReport.overclaim?(overclaim)
    assert report =~ "Overclaim warning"
    assert decoded_report =~ "Overclaim warning"
    assert report =~ "## Model Trajectory"
    assert report =~ "## Tool Evidence"
    assert report =~ "## Objective Scorecard"
    assert report =~ "## Independent Verification"
    assert report =~ "## Residual Risk"
    assert report =~ "## StandardAgent vs RLM"
  end

  test "Codex configuration is opt-in and JSONL events normalize deterministically" do
    assert Agent.client(:codex) == RunicAI.Coding.Codex.Client

    req_runtime = Agent.initial_runtime(workspace: sample_project(), model: "test:model")
    req_session = req_runtime.agents["coding"]

    refute Keyword.has_key?(get_in(req_session.metadata, [:turn_defaults, :llm_opts]), :workspace)
    refute Keyword.has_key?(get_in(req_session.metadata, [:turn_defaults, :llm_opts]), :root)

    codex_runtime =
      Agent.initial_runtime(workspace: sample_project(), model: "test:model", client: :codex)

    codex_session = codex_runtime.agents["coding"]

    assert Keyword.has_key?(
             get_in(codex_session.metadata, [:turn_defaults, :llm_opts]),
             :workspace
           )

    assert Keyword.has_key?(get_in(codex_session.metadata, [:turn_defaults, :llm_opts]), :root)

    jsonl = ~s({"type":"message","content":"working"}\n{"type":"result","message":"done"}\n)
    assert {:ok, normalized} = EventNormalizer.normalize_jsonl(jsonl)
    assert normalized.final == %{"type" => "result", "message" => "done"}
    assert Enum.map(normalized.trace_events, & &1.kind) == [:codex_exec_event, :codex_exec_event]
  end

  test "coding eval fixtures can run through the evaluation harness" do
    root = sample_project()

    evaluation_case =
      Case.new!(
        id: "coding:deterministic_smoke",
        input: %{agent_id: "coding", user: "Explain the fixture."},
        expected: [{:contains_text, "Done"}],
        metadata: %{
          workspace: root,
          command: :explain_repo,
          client: ScriptedLLM.client(["Done."])
        }
      )

    run = Evals.run([evaluation_case])

    assert length(Evals.cases(workspace: root)) == 4
    assert [%{status: :passed}] = run.results
    assert run.aggregate.cases_passed == 1
  end

  defp tool_count(messages), do: messages |> tool_messages() |> length()
  defp tool_messages(messages), do: Enum.filter(messages, &(&1.role == :tool))

  defp sample_project do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), demo_source(41))
    root
  end

  defp failing_mix_project do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Smoke.MixProject do
      use Mix.Project

      def project do
        [
          app: :smoke,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(root, "lib/smoke.ex"), smoke_source(41))
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/smoke_test.exs"), """
    defmodule SmokeTest do
      use ExUnit.Case, async: true

      test "answer" do
        assert Smoke.answer() == 42
      end
    end
    """)

    root
  end

  defp passing_mix_project do
    root = failing_mix_project()
    File.write!(Path.join(root, "lib/smoke.ex"), smoke_source(42))
    root
  end

  defp nested_passing_mix_project do
    root = tmp_dir()
    nested = Path.join(root, "field_service_poc")
    File.mkdir_p!(nested)

    source = passing_mix_project()

    File.cp_r!(Path.join(source, "lib"), Path.join(nested, "lib"))
    File.cp_r!(Path.join(source, "test"), Path.join(nested, "test"))
    File.cp!(Path.join(source, "mix.exs"), Path.join(nested, "mix.exs"))

    root
  end

  defp demo_source(answer) do
    """
    defmodule Demo do
      def answer, do: #{answer}
    end
    """
  end

  defp smoke_source(answer) do
    """
    defmodule Smoke do
      def answer, do: #{answer}
    end
    """
  end

  defp smoke_with_extra_source do
    """
    defmodule Smoke do
      def answer, do: 42
      def extra, do: :ok
    end
    """
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-standard-agent-remaining-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
