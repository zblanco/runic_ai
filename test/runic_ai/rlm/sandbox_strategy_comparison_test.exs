defmodule RunicAI.RLM.SandboxStrategyComparisonTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM.SandboxStrategyComparison

  test "runs same-task comparison across the core strategy harnesses" do
    comparison =
      SandboxStrategyComparison.run("strategy_family_report",
        sandbox_exec: &fake_sandbox_exec/2
      )

    assert Enum.map(comparison.executions, & &1.harness) ==
             SandboxStrategyComparison.core_harnesses()

    assert comparison.aggregate.same_task?
    assert comparison.aggregate.local_execution_calls == 5
    assert comparison.aggregate.local_execution_failures == 0
    assert comparison.aggregate.best_harness == :lambda_workflow
    assert comparison.run.aggregate.cases == 5

    assert Enum.all?(comparison.run.results, fn result ->
             result.metrics.local_execution_status == :pass and
               result.metrics.local_execution_calls == 1 and
               result.metrics.backend == :just_bash
           end)
  end

  test "can include generated component lane when requested" do
    comparison =
      SandboxStrategyComparison.run("strategy_family_report",
        include_generated_component?: true,
        sandbox_exec: &fake_sandbox_exec/2
      )

    assert Enum.map(comparison.executions, & &1.harness) ==
             SandboxStrategyComparison.core_harnesses() ++ [:generated_sandbox_component]

    assert comparison.run.aggregate.cases == 6
  end

  test "writes JSON and Markdown reports" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-sandbox-strategy-comparison-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{json_path: json_path, markdown_path: markdown_path} =
      SandboxStrategyComparison.write_report!("strategy_family_report", tmp_dir,
        basename: "strategy-compare",
        sandbox_exec: &fake_sandbox_exec/2
      )

    assert File.exists?(json_path)
    assert File.exists?(markdown_path)

    json = json_path |> File.read!() |> Jason.decode!()
    markdown = File.read!(markdown_path)

    assert get_in(json, ["aggregate", "same_task?"])
    assert get_in(json, ["aggregate", "local_execution_calls"]) == 5
    assert get_in(json, ["evaluation_run", "aggregate", "cases"]) == 5
    assert markdown =~ "Sandbox/RLM Same-Task Strategy Comparison"
    assert markdown =~ "| lambda_workflow | lambda_workflow | passed |"
  end

  test "can produce a non-executing comparison plan" do
    comparison =
      SandboxStrategyComparison.run("strategy_family_report",
        execute?: false,
        sandbox_exec: fn _request, _opts -> flunk("sandbox should not be called") end
      )

    assert comparison.execute? == false
    assert comparison.aggregate.local_execution_calls == 0
    assert Enum.all?(comparison.executions, &(&1.local_execution_status == :skipped))
    assert Enum.all?(comparison.run.results, &(&1.metrics.local_execution_status == :skipped))
  end

  defp fake_sandbox_exec(request, _opts) do
    {:ok,
     %{
       status: :pass,
       stdout: heredoc_payload(request.source) <> "\n",
       stderr: "",
       duration_ms: 7,
       backend: :just_bash,
       isolation_level: :in_process_virtual
     }}
  end

  defp heredoc_payload(source) do
    [_, payload] = Regex.run(~r/RUNIC_COMPARE_JSON'\n(.+)\nRUNIC_COMPARE_JSON/s, source)
    payload
  end
end
