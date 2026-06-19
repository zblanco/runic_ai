defmodule Mix.Tasks.RunicAi.Rlm.Robustness do
  @moduledoc """
  Run RLM robustness project-generation smoke scenarios.

      mix runic_ai.rlm.robustness --list
      mix runic_ai.rlm.robustness --matrix general_dynamic_workflow
      mix runic_ai.rlm.robustness --scenario field_service_dispatch
      mix runic_ai.rlm.robustness --lane browser_tidewave --label browser-probe
      mix runic_ai.rlm.robustness --live-agent-lanes --scenario field_service_dispatch

  By default, `standard`, `assistant`, and `rlm` lanes are scaffold/baseline
  probes only. Pass `--live-agent-lanes` to run real agent routes.
  """

  use Mix.Task

  alias RunicAI.RLM.Robustness
  alias RunicAI.RLM.Robustness.ProjectScenario

  @shortdoc "Run RLM robustness smoke scenarios"

  @impl true
  def run(args) do
    {opts, _rest, invalid} = parse_args(args)

    if invalid != [] do
      Mix.raise("invalid runic_ai.rlm.robustness options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    if Keyword.get(opts, :list, false) do
      Robustness.scenarios()
      |> Enum.each(fn %ProjectScenario{} = scenario ->
        Mix.shell().info("#{scenario.id} - #{scenario.title}")
      end)
    else
      ids = scenario_ids(opts)
      lanes = lanes(Keyword.get_values(opts, :lane))

      run_opts =
        [
          lanes: lanes,
          run_label: Keyword.get(opts, :label),
          live_agent_lanes?: Keyword.get(opts, :live_agent_lanes, false),
          browser_probe?: not Keyword.get(opts, :no_browser_probe, false),
          browser_ui_launch?: Keyword.get(opts, :browser_ui_launch, false),
          browser_ui_capture?: Keyword.get(opts, :browser_ui_capture, false),
          browser_workbench_url: Keyword.get(opts, :browser_workbench_url),
          browser_capture_timeout_ms: Keyword.get(opts, :browser_capture_timeout_ms),
          llm_judge?: Keyword.get(opts, :llm_judge, false),
          model: Keyword.get(opts, :model),
          client_label: Keyword.get(opts, :client),
          client: client_module(Keyword.get(opts, :client)),
          progress_sink: progress_sink(Keyword.get(opts, :trace_live, false)),
          max_runtime_ms: Keyword.get(opts, :max_runtime_ms),
          proposal_timeout_ms: Keyword.get(opts, :proposal_timeout_ms)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Robustness.run_matrix(ids, run_opts) do
        {:ok, %{matrix_path: path, results: results}} ->
          Mix.shell().info("RLM robustness matrix: #{Path.relative_to_cwd(path)}")
          Mix.shell().info("Rows: #{length(results)}")

        {:error, error} ->
          Mix.raise(error.message)
      end
    end
  end

  @doc false
  def parse_args(args) when is_list(args) do
    OptionParser.parse(args,
      strict: [
        scenario: :keep,
        lane: :keep,
        label: :string,
        list: :boolean,
        live_agent_lanes: :boolean,
        no_browser_probe: :boolean,
        browser_ui_launch: :boolean,
        browser_ui_capture: :boolean,
        browser_workbench_url: :string,
        browser_capture_timeout_ms: :integer,
        llm_judge: :boolean,
        matrix: :string,
        trace_live: :boolean,
        model: :string,
        client: :string,
        max_runtime_ms: :integer,
        proposal_timeout_ms: :integer
      ]
    )
  end

  defp scenario_ids(opts) do
    explicit = Keyword.get_values(opts, :scenario)

    cond do
      explicit != [] ->
        explicit

      matrix = Keyword.get(opts, :matrix) ->
        case Robustness.scenario_matrix(matrix) do
          {:ok, ids} -> ids
          {:error, error} -> Mix.raise(error.message)
        end

      true ->
        nil
    end
  end

  defp lanes([]), do: [:standard, :assistant, :rlm, :browser_tidewave]

  defp lanes(values) do
    Enum.map(values, fn value ->
      value
      |> String.replace("-", "_")
      |> String.to_existing_atom()
    end)
  rescue
    ArgumentError ->
      Mix.raise("invalid lane; expected standard, assistant, rlm, or browser_tidewave")
  end

  defp client_module("codex"), do: RunicAI.Coding.Codex.Client
  defp client_module(_other), do: nil

  defp progress_sink(false), do: nil

  defp progress_sink(true) do
    fn event ->
      Mix.shell().info(progress_line(event))
    end
  end

  defp progress_line(%{scenario_id: scenario, lane: lane, event: :terminal_output, data: data}) do
    line =
      data
      |> Map.get(:line, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, 240)

    "[#{scenario}/#{lane}] #{line}"
  end

  defp progress_line(%{scenario_id: scenario, lane: lane, event: event, data: data}) do
    detail =
      data
      |> Map.take([:lane_status, :trail_path, :jsonl_path, :workspace, :error])
      |> inspect(limit: 8)

    "[#{scenario}/#{lane}] #{event} #{detail}"
  end
end
