defmodule RunicAI.Coding.StandardAgentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.Patch
  alias RunicAI.Coding.Prompt
  alias RunicAI.Coding.Recipe
  alias RunicAI.Coding.StandardAgent.ObjectiveGate
  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient
  alias RunicAI.Prompt, as: TurnPrompt
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  test "assembles prompt context with AGENTS.md and workspace summary" do
    root = tmp_dir()
    File.write!(Path.join(root, "AGENTS.md"), "Prefer focused tests.\n")
    File.write!(Path.join(root, "README.md"), "demo\n")

    workspace = Workspace.new!(root: root)
    recipe = Recipe.named(:read_only)

    system = Prompt.system(workspace, recipe)
    user = Prompt.user("Explain this repo.", workspace, recipe)

    assert system =~ "Prefer focused tests."
    assert system =~ "Mode: read_only"
    assert user =~ "Workspace summary"
    assert user =~ "README.md"
  end

  test "read-only agent exposes only read/search/git-read tools and answers after search/read" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("search_text", %{query: "answer", path: "lib"}, id: "call_1")
           ])}

        1 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("read_file", %{path: "lib/demo.ex"}, id: "call_2")
           ])}

        _ ->
          {:ok, TestClient.result("Demo.answer/0 is defined in lib/demo.ex.")}
      end
    end

    workflow =
      Agent.read_only(workspace, "Where is the answer function?",
        model: "test:model",
        client: client
      )

    summary = Agent.summary(workflow)

    assert summary.reply == "Demo.answer/0 is defined in lib/demo.ex."
    assert summary.tools_used == ["search_text", "read_file"]
    refute "apply_patch" in summary.visible_tools
    refute "run_tests" in summary.visible_tools
    refute "run_command" in summary.visible_tools

    kinds = Agent.trace_events(workflow) |> Enum.map(& &1.kind)
    assert :coding_tool_visibility in kinds
    assert :coding_tool_call in kinds
    assert :coding_tool_observation in kinds
  end

  test "patch agent repairs a bad patch from diagnostics and summarizes changed files" do
    root = sample_project()
    workspace = Workspace.new!(root: root)
    expected_hash = Patch.sha256(File.read!(Path.join(root, "lib/demo.ex")))

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
                     path: "lib/demo.ex",
                     content: demo_source(42),
                     expected_hash: "stale"
                   }
                 ]
               },
               id: "call_1"
             )
           ])}

        1 ->
          assert List.last(tool_messages(messages)).content =~ "expected hash"

          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{
                     op: "update",
                     path: "lib/demo.ex",
                     content: demo_source(42),
                     expected_hash: expected_hash
                   }
                 ]
               },
               id: "call_2"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/demo.ex. Verification: not run.")}
      end
    end

    workflow =
      Agent.patch(workspace, "Fix Demo.answer/0.",
        model: "test:model",
        client: client
      )

    summary = Agent.summary(workflow)

    assert File.read!(Path.join(root, "lib/demo.ex")) == demo_source(42)
    assert summary.changed_files == ["lib/demo.ex"]
    assert Enum.map(summary.patches, & &1.status) == ["error", "ok"]
  end

  test "dry-run patch sessions do not mutate the workspace" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 dry_run: false,
                 operations: [
                   %{op: "update", path: "lib/demo.ex", content: demo_source(42)}
                 ]
               },
               id: "call_1"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Dry-run patch prepared for lib/demo.ex.")}
      end
    end

    workflow =
      Agent.patch(workspace, "Plan the fix.",
        model: "test:model",
        client: client,
        dry_run?: true
      )

    summary = Agent.summary(workflow)

    assert File.read!(Path.join(root, "lib/demo.ex")) == demo_source(41)
    assert summary.changed_files == ["lib/demo.ex"]
    assert [%{status: "dry_run", dry_run?: true}] = summary.patches
  end

  test "agent patch registry preserves workspace path policy failures" do
    workspace = Workspace.new!(root: tmp_dir())
    registry = Agent.default_registry(workspace, mode: :patch)
    definition = Registry.fetch!(registry, "apply_patch")

    assert {:ok, result} =
             Definition.execute(definition, %{
               "operations" => [
                 %{"op" => "create", "path" => "../outside.txt", "content" => "no\n"}
               ]
             })

    assert result.status == :error
    assert hd(result.diagnostics).message =~ "escapes"
  end

  @tag timeout: 60_000
  test "verification agent repairs after failing targeted tests and stops after passing tests" do
    root = failing_mix_project()
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "run_tests",
               %{args: ["test/smoke_test.exs"]},
               id: "call_1"
             )
           ])}

        1 ->
          assert List.last(tool_messages(messages)).content =~ "\"status\":\"fail\""

          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{op: "update", path: "lib/smoke.ex", content: smoke_source(42)}
                 ]
               },
               id: "call_2"
             )
           ])}

        2 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "run_tests",
               %{args: ["test/smoke_test.exs"]},
               id: "call_3"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/smoke.ex. Verification: run_tests pass.")}
      end
    end

    workflow =
      Agent.verify(workspace, "Fix the failing test.",
        model: "test:model",
        client: client,
        command_timeout_ms: 30_000,
        command_max_output_bytes: 16_384
      )

    summary = Agent.summary(workflow)

    assert File.read!(Path.join(root, "lib/smoke.ex")) == smoke_source(42)
    assert summary.changed_files == ["lib/smoke.ex"]
    assert Enum.map(summary.verifications, & &1.status) == ["fail", "pass"]
    assert summary.risks == []
  end

  test "objective gate continues after premature final answer until evidence is satisfied" do
    root = passing_mix_project()
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case {tool_count(messages), assistant_count(messages)} do
        {0, _} ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("run_tests", %{args: ["test/smoke_test.exs"]}, id: "call_1")
           ])}

        {1, 1} ->
          {:ok, TestClient.result("Done.")}

        {1, _} ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{op: "update", path: "lib/smoke.ex", content: smoke_with_extra_source()}
                 ]
               },
               id: "call_2"
             )
           ])}

        {2, _} ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("run_tests", %{args: ["test/smoke_test.exs"]}, id: "call_3")
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/smoke.ex. Verification: run_tests pass.")}
      end
    end

    workflow =
      Agent.verify(workspace, "Add Smoke.extra/0.",
        model: "test:model",
        client: client,
        objective_gate?: true,
        max_turns: 6
      )

    summary = Agent.summary(workflow)
    evaluation = Agent.objective_evaluation(workflow, workspace, "Add Smoke.extra/0.")

    assert File.read!(Path.join(root, "lib/smoke.ex")) == smoke_with_extra_source()
    assert summary.changed_files == ["lib/smoke.ex"]
    assert "apply_patch" in summary.tools_used
    assert ObjectiveGate.satisfied?(evaluation)
  end

  test "standard objective gate uses shared scorecard latest command evidence" do
    root = passing_mix_project()
    workspace = Workspace.new!(root: root)

    context = %{
      changed_files: ["lib/smoke.ex"],
      command_results: [
        %{argv: ["mix", "test"], cwd: root, status: :fail, output_preview: "old failure"},
        %{argv: ["mix", "test"], cwd: root, status: :pass, output_preview: "1 test, 0 failures"}
      ]
    }

    evaluation = ObjectiveGate.evaluate(workspace, "Fix tests.", context)

    assert evaluation.status == :objective_satisfied
    assert evaluation.blocking_acceptance == []
  end

  test "standard objective gate normalizes malformed argv and relative cwd evidence" do
    root = passing_mix_project()
    workspace = Workspace.new!(root: root)

    context = %{
      changed_files: ["mix.exs"],
      command_results: [
        %{argv: ["mix test"], cwd: ".", status: :blocked, output_preview: "blocked by policy"},
        %{argv: ["mix", "test"], cwd: root, status: :pass, output_preview: "1 test, 0 failures"}
      ]
    }

    evaluation = ObjectiveGate.evaluate(workspace, "Verify project.", context)

    assert evaluation.status == :objective_satisfied
    assert evaluation.blocking_acceptance == []
    assert [%{argv: ["mix", "test"], status: :pass}] = evaluation.latest_command_results
  end

  test "standard objective gate treats wrong-directory failure as superseded repair evidence" do
    root = passing_mix_project()
    nested = Path.join(root, "field_service_poc")
    File.mkdir_p!(nested)
    workspace = Workspace.new!(root: root)

    context = %{
      changed_files: ["field_service_poc/lib/app.ex"],
      command_results: [
        %{argv: ["mix", "test"], cwd: root, status: :fail, output_preview: "no mix.exs"},
        %{
          argv: ["mix", "test"],
          cwd: nested,
          status: :pass,
          output_preview: "4 tests, 0 failures"
        }
      ]
    }

    evaluation = ObjectiveGate.evaluate(workspace, "Verify nested project.", context)

    assert evaluation.status == :objective_satisfied
    assert evaluation.blocking_acceptance == []

    assert [%{argv: ["mix", "test"], cwd: ^nested, status: :pass}] =
             evaluation.latest_command_results
  end

  test "standard objective gate keeps latest failed verification blocking" do
    root = passing_mix_project()
    workspace = Workspace.new!(root: root)

    context = %{
      changed_files: ["lib/smoke.ex"],
      command_results: [
        %{argv: ["mix", "test"], cwd: root, status: :pass, output_preview: "1 test, 0 failures"},
        %{argv: ["mix", "test"], cwd: root, status: :fail, output_preview: "1 failure"}
      ]
    }

    evaluation = ObjectiveGate.evaluate(workspace, "Fix tests.", context)

    assert evaluation.status == :objective_incomplete
    assert [%{status: :fail}] = evaluation.latest_command_results
    assert [%{status: :fail, type: :command_passes}] = evaluation.blocking_acceptance
  end

  defp tool_count(messages), do: messages |> tool_messages() |> length()
  defp assistant_count(messages), do: messages |> Enum.count(&(&1.role == :assistant))
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
        "runic-ai-standard-agent-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
