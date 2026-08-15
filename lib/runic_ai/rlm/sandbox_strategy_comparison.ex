defmodule RunicAI.RLM.SandboxStrategyComparison do
  @moduledoc """
  Same-task strategy-family comparison runner for sandbox/RLM Phase 8.

  This runner sits between deterministic fixture reports and expensive live
  agent runs. It compares the same objective across the core coordinator
  strategies, executes a safe local sandbox smoke for each lane, and persists
  the result through the existing `RunicAI.Evaluation.Run` contract.
  """

  alias RunicAI.RLM.SandboxEvaluationFixtures

  @core_harnesses [
    :direct_standard_agent,
    :dynamic_workflow_coordinator,
    :lambda_workflow,
    :subagent_delegation,
    :sandbox_repl
  ]

  @generated_harness :generated_sandbox_component

  @spec core_harnesses() :: [atom()]
  def core_harnesses, do: @core_harnesses

  @spec run(String.t() | atom() | map(), keyword()) :: map()
  def run(scenario_or_id \\ "strategy_family_report", opts \\ []) when is_list(opts) do
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())
    scenario = selected_scenario(scenario_or_id, opts)
    router_decision = SandboxEvaluationFixtures.route(scenario)
    execute? = Keyword.get(opts, :execute?, true)

    executions =
      Enum.map(scenario.comparison_harnesses, fn harness ->
        spec = Map.fetch!(scenario.harness_specs, harness)
        execute_harness(scenario, router_decision, harness, spec, execute?, opts)
      end)

    actual_by_harness = Map.new(executions, &{&1.harness, &1.actual})
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now())

    run =
      SandboxEvaluationFixtures.evaluation_run(scenario,
        actual_by_harness: actual_by_harness,
        id: Keyword.get(opts, :id, "sandbox-strategy-compare:#{scenario.id}"),
        started_at: started_at,
        completed_at: completed_at
      )

    %{
      scenario: scenario,
      run: run,
      executions: executions,
      aggregate: comparison_aggregate(run, executions),
      started_at: started_at,
      completed_at: completed_at,
      execute?: execute?
    }
  end

  @spec write_report!(Path.t(), keyword()) :: map()
  def write_report!(output_dir, opts) when is_binary(output_dir) and is_list(opts) do
    write_report!("strategy_family_report", output_dir, opts)
  end

  @spec write_report!(String.t() | atom() | map(), Path.t(), keyword()) :: map()
  def write_report!(scenario_or_id, output_dir, opts)
      when is_binary(output_dir) and is_list(opts) do
    comparison = run(scenario_or_id, opts)
    File.mkdir_p!(output_dir)

    basename = Keyword.get(opts, :basename, "sandbox-strategy-comparison")
    json_path = Path.join(output_dir, "#{basename}.json")
    markdown_path = Path.join(output_dir, "#{basename}.md")

    File.write!(json_path, Jason.encode!(payload(comparison), pretty: true))
    File.write!(markdown_path, markdown(comparison))

    Map.merge(comparison, %{json_path: json_path, markdown_path: markdown_path})
  end

  @spec payload(map()) :: map()
  def payload(%{run: run} = comparison) do
    %{
      generated_at: timestamp(comparison.completed_at),
      execute?: comparison.execute?,
      scenario_id: comparison.scenario.id,
      objective: comparison.scenario.objective,
      harnesses: comparison.scenario.comparison_harnesses,
      aggregate: comparison.aggregate,
      executions: comparison.executions,
      evaluation_run: SandboxEvaluationFixtures.run_payload(run)
    }
  end

  @spec markdown(map()) :: String.t()
  def markdown(%{run: run} = comparison) do
    rows =
      Enum.map(run.results, fn result ->
        execution = Enum.find(comparison.executions, &(&1.harness == result.metadata.harness))

        [
          result.metadata.harness,
          result.metadata.strategy,
          result.status,
          result.scores.overall,
          result.metrics.model_calls,
          result.metrics.sandbox_calls,
          result.metrics.local_execution_status,
          execution && execution.backend,
          result.metrics.local_execution_ms,
          result.metadata.quality.note
        ]
        |> Enum.map(&to_string/1)
        |> Enum.join(" | ")
      end)

    """
    # Sandbox/RLM Same-Task Strategy Comparison

    Scenario: `#{comparison.scenario.id}`

    Objective: #{comparison.scenario.objective}

    Execute sandbox lane smokes: #{comparison.execute?}

    Same task verified: #{comparison.aggregate.same_task?}

    | Harness | Strategy | Status | Quality | Model calls | Sandbox calls | Local smoke | Backend | Smoke ms | Note |
    | --- | --- | --- | ---: | ---: | ---: | --- | --- | ---: | --- |
    #{Enum.map_join(rows, "\n", &("| " <> &1 <> " |"))}

    ## Aggregate

    - cases: #{run.aggregate.cases}
    - passed: #{run.aggregate.passed}
    - failed: #{run.aggregate.failed}
    - success_rate: #{run.aggregate.success_rate}
    - average_quality: #{run.aggregate.average_quality}
    - model_calls: #{run.aggregate.model_calls}
    - sandbox_calls: #{run.aggregate.sandbox_calls}
    - local_execution_calls: #{comparison.aggregate.local_execution_calls}
    - local_execution_failures: #{comparison.aggregate.local_execution_failures}
    - best_harness: #{comparison.aggregate.best_harness}
    """
  end

  defp selected_scenario(scenario_or_id, opts) do
    scenario =
      case scenario_or_id do
        scenario when is_map(scenario) -> scenario
        id -> SandboxEvaluationFixtures.get!(id)
      end

    harnesses = selected_harnesses(scenario, opts)

    scenario
    |> Map.put(:comparison_harnesses, harnesses)
    |> Map.update!(:harness_specs, &Map.take(&1, harnesses))
  end

  defp selected_harnesses(scenario, opts) do
    requested =
      opts
      |> Keyword.get(:harnesses)
      |> normalize_harnesses()

    harnesses =
      cond do
        requested != [] ->
          requested

        Keyword.get(opts, :include_generated_component?, false) ->
          @core_harnesses ++ [@generated_harness]

        true ->
          @core_harnesses
      end

    unknown = harnesses -- Map.keys(scenario.harness_specs)

    if unknown != [] do
      raise ArgumentError,
            "unknown comparison harnesses #{inspect(unknown)} for scenario #{scenario.id}"
    end

    harnesses
  end

  defp normalize_harnesses(nil), do: []
  defp normalize_harnesses(harnesses) when is_list(harnesses), do: Enum.map(harnesses, &to_atom/1)
  defp normalize_harnesses(harness), do: [to_atom(harness)]

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    value
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> raise ArgumentError, "unknown comparison harness #{inspect(value)}"
  end

  defp execute_harness(scenario, router_decision, harness, spec, false, _opts) do
    execution = base_execution(scenario, router_decision, harness, spec, :skipped)

    Map.put(execution, :actual, local_actual(spec.actual, execution))
  end

  defp execute_harness(scenario, router_decision, harness, spec, true, opts) do
    started = System.monotonic_time(:millisecond)
    request = request(scenario, router_decision, harness, spec)

    execution =
      case sandbox_exec(opts, request, sandbox_opts(opts)) do
        {:ok, result} ->
          duration_ms = max(System.monotonic_time(:millisecond) - started, duration(result))
          decoded = decode_stdout(result)

          base_execution(scenario, router_decision, harness, spec, status(result))
          |> Map.merge(%{
            backend: field(result, :backend),
            isolation_level: field(result, :isolation_level),
            local_execution_ms: duration_ms,
            stdout: field(result, :stdout, ""),
            stderr: field(result, :stderr, ""),
            decoded: decoded
          })

        {:error, error} ->
          base_execution(scenario, router_decision, harness, spec, :error)
          |> Map.merge(%{
            local_execution_ms: System.monotonic_time(:millisecond) - started,
            error: error_message(error)
          })
      end

    Map.put(execution, :actual, local_actual(spec.actual, execution))
  end

  defp base_execution(scenario, router_decision, harness, spec, status) do
    %{
      scenario_id: scenario.id,
      objective_hash: objective_hash(scenario.objective),
      harness: harness,
      strategy: spec.strategy,
      router_strategy: router_decision.strategy,
      router_fallback: router_decision.fallback,
      local_execution_status: status,
      local_execution_ms: 0,
      backend: nil,
      isolation_level: nil
    }
  end

  defp request(scenario, router_decision, harness, spec) do
    payload =
      %{
        scenario_id: scenario.id,
        objective_hash: objective_hash(scenario.objective),
        harness: harness,
        strategy: spec.strategy,
        router_strategy: router_decision.strategy,
        planned: spec.planned,
        expected_quality: spec.quality
      }
      |> Jason.encode!()

    %{
      sandbox: :local_code,
      runtime: :bash,
      source: "cat <<'RUNIC_COMPARE_JSON'\n#{payload}\nRUNIC_COMPARE_JSON\n",
      network: :disabled,
      timeout_ms: 5_000,
      max_output_bytes: 8_192
    }
  end

  defp sandbox_opts(opts) do
    Keyword.get(opts, :sandbox_opts,
      profile: [
        backend: :just_bash,
        runtimes: [:bash],
        network: :disabled,
        workspace: [mode: :copy_in, persist?: false]
      ]
    )
  end

  defp sandbox_exec(opts, request, exec_opts) do
    Keyword.get(opts, :sandbox_exec, &LitterBox.exec/2).(request, exec_opts)
  end

  defp local_actual(actual, execution) do
    actual
    |> Map.put(:local_execution_calls, local_execution_calls(execution.local_execution_status))
    |> Map.put(:local_execution_status, execution.local_execution_status)
    |> Map.put(:local_execution_ms, execution.local_execution_ms)
    |> Map.put(:latency_ms, max(Map.get(actual, :latency_ms, 0), execution.local_execution_ms))
    |> Map.put(:backend, execution.backend)
    |> Map.put(:isolation_level, execution.isolation_level)
    |> Map.put(
      :success?,
      Map.get(actual, :success?, true) and execution_success_or_skipped?(execution)
    )
  end

  defp local_execution_calls(:skipped), do: 0
  defp local_execution_calls(_status), do: 1

  defp execution_success?(%{local_execution_status: status}), do: status in [:pass, "pass"]
  defp execution_success_or_skipped?(%{local_execution_status: :skipped}), do: true
  defp execution_success_or_skipped?(execution), do: execution_success?(execution)

  defp status(result), do: field(result, :status, :error)
  defp duration(result), do: field(result, :duration_ms, 0) || 0

  defp decode_stdout(result) do
    result
    |> field(:stdout, "")
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, decoded} -> decoded
      {:error, _error} -> nil
    end
  end

  defp field(map, key, default \\ nil)
  defp field(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp field(struct, key, default), do: Map.get(Map.from_struct(struct), key, default)

  defp comparison_aggregate(run, executions) do
    Map.merge(run.aggregate, %{
      same_task?: same_task?(executions),
      local_execution_calls:
        Enum.reduce(executions, 0, &(&2 + local_execution_calls(&1.local_execution_status))),
      local_execution_failures:
        Enum.count(executions, &(&1.local_execution_status not in [:pass, "pass", :skipped])),
      best_harness: best_harness(run),
      compared_harnesses: Enum.map(executions, & &1.harness)
    })
  end

  defp same_task?(executions) do
    executions
    |> Enum.map(&{&1.scenario_id, &1.objective_hash})
    |> Enum.uniq()
    |> length() == 1
  end

  defp best_harness(run) do
    run.results
    |> Enum.sort_by(fn result ->
      {-result.scores.overall, result.metrics.model_calls, result.metrics.sandbox_calls}
    end)
    |> List.first()
    |> case do
      nil -> nil
      result -> result.metadata.harness
    end
  end

  defp objective_hash(objective),
    do: :crypto.hash(:sha256, objective) |> Base.encode16(case: :lower)

  defp error_message(%{message: message}), do: message
  defp error_message(error), do: inspect(error)

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_other), do: nil
end
