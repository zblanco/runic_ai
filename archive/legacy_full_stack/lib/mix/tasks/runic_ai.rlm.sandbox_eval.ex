defmodule Mix.Tasks.RunicAi.Rlm.SandboxEval do
  @moduledoc """
  Write deterministic sandbox/RLM strategy evaluation fixture reports.

      mix runic_ai.rlm.sandbox_eval --list
      mix runic_ai.rlm.sandbox_eval --scenario strategy_family_report
      mix runic_ai.rlm.sandbox_eval --scenario repl_unknown_schema --output-dir tmp/sandbox_eval
      mix runic_ai.rlm.sandbox_eval --compare-strategies
      mix runic_ai.rlm.sandbox_eval --live-lanes
      mix runic_ai.rlm.sandbox_eval --live-lanes --execute-live-lanes

  Fixture reports are deterministic artifacts. Live-lane reports preflight real
  backend availability and only execute local smoke checks when
  `--execute-live-lanes` is provided. Strategy comparisons execute safe local
  sandbox smokes unless `--no-execute-comparison` is passed.
  """

  use Mix.Task

  alias RunicAI.RLM.SandboxEvaluationFixtures
  alias RunicAI.RLM.SandboxLiveLanes
  alias RunicAI.RLM.SandboxStrategyComparison

  @shortdoc "Write sandbox/RLM strategy evaluation fixture reports"

  @default_output_dir "tmp/rlm_sandbox_eval/reports"

  @impl true
  def run(args) do
    {opts, _rest, invalid} = parse_args(args)

    if invalid != [] do
      Mix.raise("invalid runic_ai.rlm.sandbox_eval options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    cond do
      Keyword.get(opts, :list, false) ->
        list_scenarios()

      Keyword.get(opts, :compare_strategies, false) ->
        write_strategy_comparisons(opts)

      Keyword.get(opts, :live_lanes, false) or Keyword.get(opts, :execute_live_lanes, false) ->
        write_live_lanes(opts)

      true ->
        write_reports(opts)
    end
  end

  @doc false
  def parse_args(args) when is_list(args) do
    OptionParser.parse(args,
      strict: [
        basename: :string,
        compare_strategies: :boolean,
        comparison_harness: :keep,
        docker_image: :string,
        execute_comparison: :boolean,
        execute_live_lanes: :boolean,
        include_generated_component: :boolean,
        list: :boolean,
        live_lanes: :boolean,
        output_dir: :string,
        scenario: :keep,
        sprites_token_env: :string
      ],
      aliases: [s: :scenario, o: :output_dir]
    )
  end

  defp list_scenarios do
    SandboxEvaluationFixtures.scenarios()
    |> Enum.each(fn scenario ->
      Mix.shell().info("#{scenario.id} - #{scenario.title}")
    end)
  end

  defp write_reports(opts) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    scenario_ids = scenario_ids(opts)

    scenario_ids
    |> Enum.map(fn scenario_id ->
      basename = basename(opts, scenario_id, length(scenario_ids), "sandbox-eval")

      SandboxEvaluationFixtures.write_evaluation_artifacts!(scenario_id, output_dir,
        basename: basename
      )
    end)
    |> Enum.each(fn %{run: run, json_path: json_path, markdown_path: markdown_path} ->
      Mix.shell().info("Sandbox/RLM evaluation: #{run.metadata.fixture_id}")
      Mix.shell().info("  JSON: #{Path.relative_to_cwd(json_path)}")
      Mix.shell().info("  Markdown: #{Path.relative_to_cwd(markdown_path)}")
      Mix.shell().info("  Harnesses: #{length(run.results)}")
    end)
  end

  defp write_live_lanes(opts) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)

    live_opts =
      [
        basename: Keyword.get(opts, :basename, "sandbox-live-lanes"),
        docker_image: Keyword.get(opts, :docker_image),
        execute?: Keyword.get(opts, :execute_live_lanes, false),
        sprites_token_env: Keyword.get(opts, :sprites_token_env)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    %{report: report, json_path: json_path, markdown_path: markdown_path} =
      SandboxLiveLanes.write_report!(output_dir, live_opts)

    Mix.shell().info("Sandbox live lane preflight")
    Mix.shell().info("  JSON: #{Path.relative_to_cwd(json_path)}")
    Mix.shell().info("  Markdown: #{Path.relative_to_cwd(markdown_path)}")
    Mix.shell().info("  Ready: #{report.summary.ready}")
    Mix.shell().info("  Passed: #{report.summary.passed}")
    Mix.shell().info("  Skipped: #{report.summary.skipped}")
    Mix.shell().info("  Blocked: #{report.summary.blocked}")
  end

  defp write_strategy_comparisons(opts) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    scenario_ids = scenario_ids(opts)

    scenario_ids
    |> Enum.map(fn scenario_id ->
      basename = basename(opts, scenario_id, length(scenario_ids), "sandbox-strategy-compare")

      comparison_opts =
        [
          basename: basename,
          execute?: Keyword.get(opts, :execute_comparison, true),
          include_generated_component?: Keyword.get(opts, :include_generated_component, false),
          harnesses: comparison_harnesses(opts)
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, []] end)

      SandboxStrategyComparison.write_report!(scenario_id, output_dir, comparison_opts)
    end)
    |> Enum.each(fn %{
                      run: run,
                      aggregate: aggregate,
                      json_path: json_path,
                      markdown_path: markdown_path
                    } ->
      Mix.shell().info("Sandbox/RLM same-task strategy comparison: #{run.metadata.fixture_id}")
      Mix.shell().info("  JSON: #{Path.relative_to_cwd(json_path)}")
      Mix.shell().info("  Markdown: #{Path.relative_to_cwd(markdown_path)}")
      Mix.shell().info("  Harnesses: #{run.aggregate.cases}")
      Mix.shell().info("  Passed: #{run.aggregate.passed}")
      Mix.shell().info("  Local smoke calls: #{aggregate.local_execution_calls}")
      Mix.shell().info("  Local smoke failures: #{aggregate.local_execution_failures}")
      Mix.shell().info("  Best harness: #{aggregate.best_harness}")
    end)
  end

  defp scenario_ids(opts) do
    case Keyword.get_values(opts, :scenario) do
      [] -> ["strategy_family_report"]
      ids -> Enum.map(ids, &normalize_scenario_id/1)
    end
  end

  defp normalize_scenario_id(id) when is_binary(id), do: String.replace(id, "-", "_")

  defp comparison_harnesses(opts) do
    opts
    |> Keyword.get_values(:comparison_harness)
    |> Enum.map(&String.replace(&1, "-", "_"))
  end

  defp basename(opts, scenario_id, scenario_count, default_prefix) do
    case Keyword.get(opts, :basename) do
      nil -> "#{default_prefix}-#{scenario_id}"
      basename when scenario_count > 1 -> "#{basename}-#{scenario_id}"
      basename -> basename
    end
  end
end
