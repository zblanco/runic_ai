defmodule RunicAI.RLM.SandboxEvalTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.RunicAi.Rlm.SandboxEval

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Task.clear()

    on_exit(fn ->
      Mix.shell(previous_shell)
      Mix.Task.clear()
    end)

    :ok
  end

  test "parses list, scenario, output directory, and basename options" do
    assert {
             [
               list: true,
               scenario: "strategy_family_report",
               output_dir: "tmp/sandbox_eval",
               basename: "strategy"
             ],
             [],
             []
           } =
             SandboxEval.parse_args([
               "--list",
               "--scenario",
               "strategy_family_report",
               "--output-dir",
               "tmp/sandbox_eval",
               "--basename",
               "strategy"
             ])
  end

  test "parses live lane options" do
    assert {
             [
               live_lanes: true,
               execute_live_lanes: true,
               docker_image: "runic-ai/sandbox:test",
               sprites_token_env: "RUNIC_SPRITES_TOKEN"
             ],
             [],
             []
           } =
             SandboxEval.parse_args([
               "--live-lanes",
               "--execute-live-lanes",
               "--docker-image",
               "runic-ai/sandbox:test",
               "--sprites-token-env",
               "RUNIC_SPRITES_TOKEN"
             ])
  end

  test "parses same-task strategy comparison options" do
    assert {
             [
               compare_strategies: true,
               execute_comparison: false,
               include_generated_component: true,
               comparison_harness: "lambda-workflow",
               comparison_harness: "sandbox-repl"
             ],
             [],
             []
           } =
             SandboxEval.parse_args([
               "--compare-strategies",
               "--no-execute-comparison",
               "--include-generated-component",
               "--comparison-harness",
               "lambda-workflow",
               "--comparison-harness",
               "sandbox-repl"
             ])
  end

  test "lists deterministic sandbox evaluation fixtures" do
    output =
      capture_io(fn ->
        SandboxEval.run(["--list"])
        flush_shell()
      end)

    assert output =~ "strategy_family_report - Strategy Family Report Comparison"
    assert output =~ "repl_unknown_schema - Unknown Schema REPL Exploration"
  end

  test "writes JSON and Markdown reports for a selected fixture" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-sandbox-eval-task-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    output =
      capture_io(fn ->
        SandboxEval.run([
          "--scenario",
          "strategy_family_report",
          "--output-dir",
          tmp_dir,
          "--basename",
          "strategy-family"
        ])

        flush_shell()
      end)

    json_path = Path.join(tmp_dir, "strategy-family.json")
    markdown_path = Path.join(tmp_dir, "strategy-family.md")

    assert output =~ "Sandbox/RLM evaluation: strategy_family_report"
    assert output =~ "Harnesses: 6"
    assert File.exists?(json_path)
    assert File.exists?(markdown_path)

    json = json_path |> File.read!() |> Jason.decode!()
    markdown = File.read!(markdown_path)

    assert get_in(json, ["metadata", "router_decision", "strategy"]) == "lambda_workflow"
    assert get_in(json, ["aggregate", "cases"]) == 6
    assert markdown =~ "Sandbox/RLM Strategy Evaluation"
    assert markdown =~ "| lambda_workflow | lambda_workflow | passed |"
  end

  test "hyphenated scenario ids are normalized for CLI ergonomics" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-sandbox-eval-task-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    capture_io(fn ->
      SandboxEval.run([
        "--scenario",
        "repl-unknown-schema",
        "--output-dir",
        tmp_dir
      ])

      flush_shell()
    end)

    assert File.exists?(Path.join(tmp_dir, "sandbox-eval-repl_unknown_schema.json"))
    assert File.exists?(Path.join(tmp_dir, "sandbox-eval-repl_unknown_schema.md"))
  end

  test "multi-scenario runs suffix explicit basenames to avoid overwriting reports" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-sandbox-eval-task-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    capture_io(fn ->
      SandboxEval.run([
        "--scenario",
        "lambda-codebase-risk-inventory",
        "--scenario",
        "repl-context-discovery",
        "--output-dir",
        tmp_dir,
        "--basename",
        "phase8-expanded"
      ])

      flush_shell()
    end)

    assert File.exists?(Path.join(tmp_dir, "phase8-expanded-lambda_codebase_risk_inventory.json"))
    assert File.exists?(Path.join(tmp_dir, "phase8-expanded-lambda_codebase_risk_inventory.md"))
    assert File.exists?(Path.join(tmp_dir, "phase8-expanded-repl_context_discovery.json"))
    assert File.exists?(Path.join(tmp_dir, "phase8-expanded-repl_context_discovery.md"))
  end

  defp flush_shell do
    receive do
      {:mix_shell, :info, [message]} ->
        IO.puts(message)
        flush_shell()
    after
      0 ->
        :ok
    end
  end
end
