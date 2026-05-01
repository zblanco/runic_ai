defmodule Mix.Tasks.RunicAi.Assistant.Smoke do
  @moduledoc """
  Run the assistant RLM smoke scenario matrix.

      mix runic_ai.assistant.smoke --cwd . --strategy fallback
      mix runic_ai.assistant.smoke --cwd . --strategy dynamic --scenario research_brief
      mix runic_ai.assistant.smoke --cwd . --compare
      mix runic_ai.assistant.smoke --list
  """

  use Mix.Task

  alias RunicAI.Assistant.RLM.SmokeRunner
  alias RunicAI.Assistant.RLM.SmokeScenario

  @shortdoc "Run assistant RLM smoke scenarios"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          compare: :boolean,
          comparison_path: :string,
          dynamic_matrix_path: :string,
          fallback: :boolean,
          fallback_matrix_path: :string,
          label: :string,
          list: :boolean,
          matrix_path: :string,
          max_file_bytes: :integer,
          max_llm_calls: :integer,
          max_llm_map_calls: :integer,
          max_llm_map_concurrency: :integer,
          max_runtime_ms: :integer,
          max_slice_bytes: :integer,
          max_source_bytes: :integer,
          model: :string,
          scenario: :string,
          strategy: :string,
          write_policy: :string
        ],
        aliases: [c: :cwd, s: :scenario]
      )

    if invalid != [] do
      Mix.raise("invalid assistant smoke options: #{inspect(invalid)}")
    end

    cond do
      Keyword.get(opts, :list, false) ->
        list_scenarios()

      Keyword.get(opts, :compare, false) and comparison_only?(opts, rest) ->
        compare_matrices(opts)

      true ->
        run_matrix(opts, rest)
    end
  end

  defp list_scenarios do
    SmokeScenario.all()
    |> Enum.each(fn scenario ->
      Mix.shell().info("#{scenario.id}: #{scenario.objective}")
    end)
  end

  defp run_matrix(opts, rest) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    strategy = Keyword.get(opts, :strategy, "dynamic")
    ids = scenario_ids(opts, rest)

    run_opts =
      opts
      |> runner_opts(strategy)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, _apps} <- Application.ensure_all_started(:runic_ai),
         {:ok, result} <- SmokeRunner.run_matrix(cwd, ids, run_opts) do
      Mix.shell().info("Matrix: #{result.matrix_path}")

      Enum.each(result.results, fn scenario_result ->
        entry = scenario_result.matrix_entry

        Mix.shell().info(
          "#{entry.id}: expectation=#{entry.expectation_status} scorecard=#{entry.status} report=#{entry.report_path}"
        )
      end)
    else
      {:error, error} ->
        Mix.raise(error_message(error))
    end
  end

  defp compare_matrices(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    compare_opts =
      [
        comparison_path: Keyword.get(opts, :comparison_path),
        dynamic_matrix_path: Keyword.get(opts, :dynamic_matrix_path),
        fallback_matrix_path: Keyword.get(opts, :fallback_matrix_path),
        max_file_bytes: Keyword.get(opts, :max_file_bytes)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, _apps} <- Application.ensure_all_started(:runic_ai),
         {:ok, result} <- SmokeRunner.compare_matrices(cwd, compare_opts) do
      Mix.shell().info("Comparison: #{result.comparison_path}")
    else
      {:error, error} ->
        Mix.raise(error_message(error))
    end
  end

  defp runner_opts(opts, strategy) do
    [
      fallback?: Keyword.get(opts, :fallback),
      matrix_path: Keyword.get(opts, :matrix_path),
      max_file_bytes: Keyword.get(opts, :max_file_bytes),
      max_llm_calls: Keyword.get(opts, :max_llm_calls),
      max_llm_map_calls: Keyword.get(opts, :max_llm_map_calls),
      max_llm_map_concurrency: Keyword.get(opts, :max_llm_map_concurrency),
      max_runtime_ms: Keyword.get(opts, :max_runtime_ms),
      max_slice_bytes: Keyword.get(opts, :max_slice_bytes),
      max_total_source_bytes: Keyword.get(opts, :max_source_bytes),
      model: Keyword.get(opts, :model),
      proposal_strategy: proposal_strategy(strategy),
      run_label: Keyword.get(opts, :label, strategy_label(strategy)),
      write_policy: Keyword.get(opts, :write_policy, :workspace_review)
    ]
  end

  defp proposal_strategy(strategy) when strategy in ["fallback", "generic"], do: :fallback
  defp proposal_strategy(_strategy), do: nil

  defp strategy_label(strategy) when strategy in [nil, ""], do: "dynamic"
  defp strategy_label(strategy), do: strategy

  defp scenario_ids(opts, rest) do
    ids =
      opts
      |> Keyword.get_values(:scenario)
      |> Kernel.++(rest)
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == "all"))

    if ids == [], do: nil, else: ids
  end

  defp comparison_only?(opts, rest) do
    rest == [] and Keyword.get_values(opts, :scenario) == []
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
