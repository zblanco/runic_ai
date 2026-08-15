defmodule RunicAI.RLM.Robustness.Runner do
  @moduledoc """
  Runs RLM robustness scenario matrices and writes reports.
  """

  alias RunicAI.Error
  alias RunicAI.Ids
  alias RunicAI.Persistence.SQLite
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Coding.RLM.EditOperation
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.RLM.Robustness.Catalog
  alias RunicAI.RLM.Robustness.DeterministicChecks
  alias RunicAI.RLM.Robustness.Judge
  alias RunicAI.RLM.Robustness.OpsLogicFixture
  alias RunicAI.RLM.Robustness.ProjectScenario
  alias RunicAI.RLM.Robustness.WorkspaceFactory
  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.ObjectiveSession
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Terminal.AgentRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.RLMRunner
  alias RunicAI.Workbench

  @default_lanes [:standard, :assistant, :rlm, :browser_tidewave]

  @spec run_matrix([String.t()] | nil, keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run_matrix(ids \\ nil, opts \\ []) when is_list(opts) do
    with {:ok, scenarios} <- scenarios(ids),
         lanes <- Keyword.get(opts, :lanes, @default_lanes),
         {:ok, results} <- run_all(scenarios, lanes, opts) do
      matrix_path = matrix_path(opts)
      write_matrix!(matrix_path, results, opts)
      {:ok, %{results: results, matrix_path: matrix_path}}
    end
  end

  @spec run_scenario(ProjectScenario.t(), [atom()], keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def run_scenario(%ProjectScenario{} = scenario, lanes, opts \\ []) when is_list(lanes) do
    lanes = Enum.filter(lanes, &(&1 in scenario.lanes))

    results =
      Enum.map(lanes, fn lane ->
        run_lane(scenario, lane, opts)
      end)

    {:ok, results}
  end

  defp scenarios(nil), do: {:ok, Catalog.all()}
  defp scenarios([]), do: {:ok, Catalog.all()}

  defp scenarios(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Catalog.get(id) do
        {:ok, scenario} -> {:cont, {:ok, acc ++ [scenario]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp run_all(scenarios, lanes, opts) do
    results =
      Enum.flat_map(scenarios, fn scenario ->
        {:ok, scenario_results} = run_scenario(scenario, lanes, opts)
        scenario_results
      end)

    {:ok, results}
  end

  defp run_lane(%ProjectScenario{} = scenario, :browser_tidewave = lane, opts) do
    with {:ok, workspace} <- WorkspaceFactory.create(scenario, lane, opts) do
      baseline_files = DeterministicChecks.workspace_files(workspace.root)
      baseline_fingerprints = DeterministicChecks.workspace_fingerprints(workspace.root)

      check_opts =
        opts
        |> Keyword.put(:baseline_files, baseline_files)
        |> Keyword.put(:baseline_file_fingerprints, baseline_fingerprints)

      browser = browser_probe(scenario, workspace, opts)
      deterministic = DeterministicChecks.evaluate(scenario, workspace.root, check_opts)
      evidence = base_evidence(scenario, lane, workspace, deterministic, browser)
      judge = Judge.evaluate(scenario, evidence, opts)

      result(scenario, lane, workspace, deterministic, judge, evidence)
    else
      {:error, %Error{} = error} -> error_result(scenario, lane, error)
    end
  end

  defp run_lane(%ProjectScenario{} = scenario, lane, opts)
       when lane in [:standard, :assistant, :rlm] do
    with {:ok, workspace} <- WorkspaceFactory.create(scenario, lane, opts) do
      baseline_files = DeterministicChecks.workspace_files(workspace.root)
      baseline_fingerprints = DeterministicChecks.workspace_fingerprints(workspace.root)

      check_opts =
        opts
        |> Keyword.put(:baseline_files, baseline_files)
        |> Keyword.put(:baseline_file_fingerprints, baseline_fingerprints)

      agent_result = maybe_run_agent(scenario, lane, workspace, opts)
      deterministic = DeterministicChecks.evaluate(scenario, workspace.root, check_opts)
      evidence = base_evidence(scenario, lane, workspace, deterministic, agent_result)
      judge = Judge.evaluate(scenario, evidence, opts)

      result(scenario, lane, workspace, deterministic, judge, evidence)
    else
      {:error, %Error{} = error} -> error_result(scenario, lane, error)
    end
  end

  defp maybe_run_agent(%ProjectScenario{} = scenario, lane, workspace, opts) do
    if Keyword.get(opts, :live_agent_lanes?, false) do
      run_agent(scenario, lane, workspace, opts)
    else
      %{
        lane_status: :skipped,
        reason: "live agent lane execution disabled",
        final_output: nil,
        events: [],
        run_result: nil
      }
    end
  end

  defp run_agent(%ProjectScenario{} = scenario, lane, workspace, opts) do
    session_id = "rlm-robustness:#{scenario.id}:#{lane}:#{System.unique_integer([:positive])}"
    jsonl_path = Path.join(workspace.root, "tmp/#{lane}.jsonl")
    trail_path = Path.join(workspace.root, "tmp/#{lane}-event-trail.jsonl")
    File.mkdir_p!(Path.dirname(jsonl_path))
    File.rm(trail_path)

    args =
      ([
         "--agent",
         Atom.to_string(lane),
         "--cwd",
         workspace.root,
         "--mode",
         "patch",
         "--profile",
         "local-workbench",
         "--approve",
         "safe",
         "--renderer",
         "text",
         "--color",
         "never",
         "--persistence",
         "memory",
         "--jsonl",
         jsonl_path,
         "--session-id",
         session_id,
         "--max-runtime-ms",
         Integer.to_string(
           Keyword.get(opts, :max_runtime_ms) ||
             get_in(scenario.budgets, [:max_runtime_ms]) ||
             1_800_000
         ),
         "--repair",
         "--max-repairs",
         Integer.to_string(get_in(scenario.budgets, [:max_repairs]) || 2)
       ] ++
         objective_loop_args(scenario) ++
         proposal_timeout_args(scenario, lane, opts) ++ [scenario_objective(scenario)])
      |> maybe_append("--model", Keyword.get(opts, :model))
      |> maybe_append("--client", Keyword.get(opts, :client_label))

    case CliOptions.parse(args) do
      {:ok, cli_options} ->
        output = Agent.start_link(fn -> [] end)

        append_trail(trail_path, :lane_started, %{
          scenario_id: scenario.id,
          lane: lane,
          workspace: workspace.root,
          jsonl_path: jsonl_path,
          session_id: session_id
        })

        emit_progress(opts, scenario, lane, :lane_started, %{
          workspace: workspace.root,
          jsonl_path: jsonl_path,
          trail_path: trail_path,
          session_id: session_id
        })

        {output_agent, output_fun} =
          case output do
            {:ok, pid} ->
              {pid,
               fn line ->
                 Agent.update(pid, &(&1 ++ [line]))
                 append_trail(trail_path, :terminal_output, %{line: line})
                 emit_progress(opts, scenario, lane, :terminal_output, %{line: line})
               end}

            _error ->
              {nil, fn _line -> :ok end}
          end

        result =
          AgentRunner.run(
            cli_options,
            live_lane_runner_opts(scenario, opts, output_fun)
          )

        {result, objective_loop} =
          maybe_resume_objective_loop_approval(
            scenario,
            lane,
            workspace,
            result,
            output_fun,
            trail_path,
            opts
          )

        lines = if output_agent, do: Agent.get(output_agent, & &1), else: []
        if output_agent, do: Agent.stop(output_agent)
        lane_status = lane_status(result)

        append_trail(trail_path, :lane_completed, %{
          lane_status: lane_status,
          result: inspect_result(result)
        })

        emit_progress(opts, scenario, lane, :lane_completed, %{
          lane_status: lane_status,
          jsonl_path: jsonl_path,
          trail_path: trail_path
        })

        %{
          lane_status: lane_status,
          final_output: Enum.join(lines, "\n"),
          run_result: inspect_result(result),
          objective_loop: objective_loop,
          repair_count: terminal_repair_count(result),
          repair_summary: terminal_repair_summary(result),
          jsonl_path: jsonl_path,
          event_trail_path: trail_path,
          event_trail_summary: summarize_event_trail(trail_path)
        }

      {:error, %Error{} = error} ->
        append_trail(trail_path, :lane_failed, %{error: error.message})
        emit_progress(opts, scenario, lane, :lane_failed, %{error: error.message})

        %{
          lane_status: :error,
          final_output: error.message,
          run_result: %{error: error.message},
          event_trail_path: trail_path,
          event_trail_summary: summarize_event_trail(trail_path)
        }
    end
  end

  defp browser_probe(%ProjectScenario{} = scenario, workspace, opts) do
    if Keyword.get(opts, :browser_probe?, true) do
      previous = Application.get_env(:runic_ai, :workbench, [])
      session_id = Ids.unique("browser-rlm-robustness:#{scenario.id}")

      default_run_fun = fn _cwd, objective, run_opts ->
        event_sink = Keyword.fetch!(run_opts, :event_sink)

        with {:ok, review_summary} <- maybe_browser_probe_review(scenario, objective, run_opts) do
          event_sink.(%{
            stage: :child_budget_selected,
            status: :running,
            data: %{
              node_id: "browser_#{scenario.id}_implementation",
              child_agent_id: "browser-probe-child",
              remaining_ms: 45_000,
              selected_timeout_ms: 30_000,
              max_runtime_ms: Keyword.get(run_opts, :max_runtime_ms)
            }
          })

          event_sink.(%{
            stage: :node_started,
            status: :running,
            data: %{
              node_id: "browser_#{scenario.id}_implementation",
              kind: :agent,
              status: :started
            }
          })

          output_text =
            "Browser probe accepted objective: #{objective}" <>
              browser_probe_review_output(review_summary)

          event_sink.(%{
            stage: :browser_probe_completed,
            status: :ok,
            data: %{
              output_text: output_text,
              artifact_paths: [],
              scorecard: browser_probe_scorecard(review_summary),
              review_summary: review_summary
            }
          })

          {:ok,
           %{
             status: browser_probe_result_status(review_summary),
             output_text: output_text,
             scorecard: browser_probe_scorecard(review_summary),
             artifacts: [],
             repair_history: [],
             review_summary: review_summary
           }}
        end
      end

      run_fun = Keyword.get(opts, :browser_probe_run_fun, default_run_fun)

      try do
        SQLite.migrate!(Workbench.store!())
        Application.put_env(:runic_ai, :workbench, Keyword.put(previous, :run_fun, run_fun))

        launch =
          %{
            "session_id" => session_id,
            "objective" => scenario_objective(scenario),
            "agent" => "rlm",
            "cwd" => workspace.root,
            "approve" => browser_approval_policy(scenario),
            "mode" => browser_mode(scenario),
            "profile" => "local-workbench",
            "toolsets" => browser_toolsets(scenario),
            "tool_config" => browser_tool_config(scenario)
          }
          |> put_browser_model(Keyword.get(opts, :model))
          |> maybe_put("max_objective_iterations", browser_max_objective_iterations(scenario))

        {session_id, start, launch_snapshot, snapshot, browser_ui_capture} =
          launch_browser_probe(session_id, launch, workspace, scenario, opts)

        browser_evidence =
          browser_evidence(
            session_id,
            launch,
            start,
            launch_snapshot,
            snapshot,
            workspace,
            scenario,
            opts,
            browser_ui_capture
          )

        browser_evidence_path =
          write_browser_evidence!(workspace.root, scenario.id, browser_evidence)

        %{
          lane_status: status_from_snapshot(snapshot),
          session_id: session_id,
          session_url: browser_evidence.session_url,
          launch_result: inspect_result(start),
          final_output: browser_probe_final_output(snapshot, browser_evidence),
          browser_snapshot: summarize_snapshot(snapshot),
          failure_attribution: failure_attribution(snapshot),
          repair_count: snapshot_repair_count(snapshot),
          browser_evidence_path: browser_evidence_path,
          browser_ui_checks: browser_evidence.ui_checks,
          ui_gaps: browser_ui_gaps(browser_evidence)
        }
      after
        Application.put_env(:runic_ai, :workbench, previous)
      end
    else
      %{
        lane_status: :skipped,
        reason: "browser probe disabled",
        final_output: nil,
        browser_snapshot: %{},
        ui_gaps: ["browser probe disabled"]
      }
    end
  end

  defp maybe_browser_probe_review(%ProjectScenario{} = scenario, objective, run_opts) do
    case map_value(scenario.metadata, :browser_review_decision) do
      decision when is_map(decision) ->
        case Keyword.get(run_opts, :review_decider) do
          decider when is_function(decider, 2) ->
            request =
              RunicAI.ReviewRequest.new!(:rlm_node_execution,
                checkpoint: :pre_tool,
                resume_key:
                  "review:browser-probe:#{scenario.id}:#{System.unique_integer([:positive])}",
                options: [:approve, :reject, :edit, :cancel],
                subject: %{
                  scenario_id: scenario.id,
                  operation: :browser_probe_side_effect,
                  objective: objective
                },
                details: %{
                  scenario_id: scenario.id,
                  reason: :browser_probe_review_fixture,
                  safe?: false,
                  risk: :medium
                },
                metadata: %{
                  scenario_id: scenario.id,
                  requires_review?: true,
                  source: :rlm_robustness_browser_probe
                }
              )

            case decider.(request, %{scenario: scenario, objective: objective}) do
              {:ok, %RunicAI.ReviewDecision{} = review_decision} ->
                {:ok,
                 %{
                   required?: true,
                   requested_action: map_value(decision, :action),
                   decision_status: review_decision.status,
                   resume_key: request.resume_key
                 }}

              {:error, %Error{} = error} ->
                {:error, error}
            end

          _other ->
            {:ok, %{required?: true, decision_status: :missing_decider}}
        end

      _other ->
        {:ok, %{required?: false}}
    end
  end

  defp scenario_objective(%ProjectScenario{} = scenario) do
    checks = acceptance_check_lines(scenario.deterministic_checks)

    if checks == [] do
      scenario.prompt
    else
      """
      #{scenario.prompt}

      Acceptance checks to satisfy before claiming completion:
      #{Enum.map_join(checks, "\n", &("- " <> &1))}
      """
      |> String.trim()
    end
  end

  defp acceptance_check_lines(checks) do
    checks
    |> List.wrap()
    |> Enum.map(&acceptance_check_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp acceptance_check_line(%{type: :file_exists, path: path}),
    do: "file exists at #{path}"

  defp acceptance_check_line(%{type: :source_contains, path: path, text: text}),
    do: "#{path} contains #{inspect(text)}"

  defp acceptance_check_line(%{type: :source_contains, glob: glob, text: text}),
    do: "some file matching #{glob} contains #{inspect(text)}"

  defp acceptance_check_line(%{type: :source_not_contains, path: path, text: text}),
    do: "#{path} does not contain #{inspect(text)}"

  defp acceptance_check_line(%{type: :source_not_contains, glob: glob, text: text}),
    do: "files matching #{glob} do not contain #{inspect(text)}"

  defp acceptance_check_line(%{type: :test_count_min, min: min}),
    do: "test suite contains at least #{min} objective-specific tests"

  defp acceptance_check_line(%{type: :command_passes, argv: argv}) when is_list(argv),
    do: "command passes: #{Enum.join(argv, " ")}"

  defp acceptance_check_line(%{type: :command_passes_without_warnings, argv: argv})
       when is_list(argv),
       do: "command passes without warning output: #{Enum.join(argv, " ")}"

  defp acceptance_check_line(%{type: :command_passes_if_env, env: env, argv: argv})
       when is_list(argv),
       do: "if #{env} is enabled, command passes: #{Enum.join(argv, " ")}"

  defp acceptance_check_line(%{type: :changed_file_count_between, min: min, max: max}),
    do: "changed file count is between #{min} and #{max}"

  defp acceptance_check_line(check) when is_map(check) do
    type = map_value(check, :type)
    if is_nil(type), do: nil, else: "deterministic check #{inspect(type)} passes"
  end

  defp acceptance_check_line(_check), do: nil

  defp live_lane_runner_opts(%ProjectScenario{} = scenario, opts, output_fun) do
    [
      output_fun: output_fun,
      input_fun: objective_loop_terminal_input_fun(scenario),
      run_fun: Keyword.get(opts, :run_fun) || objective_loop_approval_resume_run_fun(scenario)
    ]
    |> Keyword.merge(live_repair_loop_opts(scenario))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp objective_loop_terminal_input_fun(%ProjectScenario{} = scenario) do
    if map_value(scenario.metadata, :objective_loop_budget_resume?) == true or
         map_value(scenario.metadata, :objective_loop_approval_resume?) == true do
      fn _prompt -> "approve\n" end
    end
  end

  defp objective_loop_args(%ProjectScenario{} = scenario) do
    cond do
      map_value(scenario.metadata, :objective_loop_budget_resume?) == true ->
        ["--objective-loop", "--max-objective-iterations", "1"]

      map_value(scenario.metadata, :objective_loop_approval_resume?) == true ->
        ["--objective-loop", "--max-objective-iterations", "3"]

      true ->
        []
    end
  end

  defp objective_loop_approval_resume_run_fun(%ProjectScenario{} = scenario) do
    cond do
      map_value(scenario.metadata, :objective_loop_budget_resume?) == true ->
        fn cwd, objective, opts ->
          run_opslogic_objective_loop_budget_fixture(cwd, objective, opts)
        end

      map_value(scenario.metadata, :objective_loop_approval_resume?) == true ->
        fn cwd, objective, opts ->
          run_opslogic_objective_loop_fixture(cwd, objective, opts)
        end

      true ->
        nil
    end
  end

  defp maybe_resume_objective_loop_approval(
         %ProjectScenario{} = scenario,
         lane,
         workspace,
         result,
         output_fun,
         trail_path,
         opts
       ) do
    cond do
      map_value(scenario.metadata, :objective_loop_budget_resume?) == true ->
        resume_objective_loop_budget(
          scenario,
          lane,
          workspace,
          result,
          output_fun,
          trail_path,
          opts
        )

      map_value(scenario.metadata, :objective_loop_approval_resume?) == true ->
        resume_objective_loop_approval(
          scenario,
          lane,
          workspace,
          result,
          output_fun,
          trail_path,
          opts
        )

      true ->
        {result, nil}
    end
  end

  defp resume_objective_loop_approval(
         scenario,
         lane,
         workspace,
         {:ok, %{status: :review, objective_session: session}} = result,
         output_fun,
         trail_path,
         opts
       ) do
    case List.last(session.review_requests || []) do
      request when is_map(request) ->
        resume_key = map_value(request, :resume_key)

        decision =
          ReviewDecision.new!(resume_key, :approved,
            actor: :rlm_robustness_runner,
            metadata: %{scenario_id: scenario.id, lane: lane, source: :objective_loop_fixture}
          )

        append_trail(trail_path, :objective_loop_review_approved, %{
          resume_key: resume_key,
          session_id: session.id
        })

        emit_progress(opts, scenario, lane, :objective_loop_review_approved, %{
          resume_key: resume_key,
          session_id: session.id
        })

        resume_result =
          RLMRunner.resume_after_review(session, decision,
            cwd: workspace.root,
            session_id: session.id,
            run_id: session.id,
            run_fun: objective_loop_approval_resume_run_fun(scenario),
            event_sink:
              objective_loop_resume_event_sink(scenario, lane, trail_path, output_fun, opts)
          )

        objective_loop = %{
          status: :review_approved_and_resumed,
          review_resume_key: resume_key,
          initial: objective_loop_result_summary(result),
          resumed: objective_loop_result_summary(resume_result)
        }

        {resume_result, objective_loop}

      _other ->
        {result,
         %{
           status: :missing_review_request,
           initial: objective_loop_result_summary(result)
         }}
    end
  end

  defp resume_objective_loop_approval(
         scenario,
         lane,
         _workspace,
         {:ok, %{status: :ok, objective_session: session}} = result,
         _output_fun,
         trail_path,
         opts
       ) do
    if objective_session_progress_event?(session, :review_completed) do
      resume_key = latest_request_key(session.review_requests)

      append_trail(trail_path, :objective_loop_review_approved, %{
        resume_key: resume_key,
        session_id: session.id,
        source: :terminal_auto_resume
      })

      append_trail(trail_path, :objective_loop_resume_event, %{
        status: :ok,
        source: :terminal_auto_resume,
        session_id: session.id
      })

      emit_progress(opts, scenario, lane, :objective_loop_review_approved, %{
        resume_key: resume_key,
        session_id: session.id,
        source: :terminal_auto_resume
      })

      {result,
       %{
         status: :review_approved_and_resumed,
         review_resume_key: resume_key,
         initial: %{status: :review, decision_action: :request_review_approval},
         resumed: objective_loop_result_summary(result)
       }}
    else
      {result, %{status: :not_waiting_for_review, initial: objective_loop_result_summary(result)}}
    end
  end

  defp resume_objective_loop_approval(
         _scenario,
         _lane,
         _workspace,
         result,
         _output_fun,
         _trail_path,
         _opts
       ) do
    {result, %{status: :not_waiting_for_review, initial: objective_loop_result_summary(result)}}
  end

  defp resume_objective_loop_budget(
         scenario,
         lane,
         workspace,
         {:ok, %{status: :needs_budget_approval, objective_session: session}} = result,
         output_fun,
         trail_path,
         opts
       ) do
    case List.last(session.budget_requests || []) do
      request when is_map(request) ->
        resume_key = map_value(request, :resume_key) || map_value(request, :id)

        decision =
          ReviewDecision.new!(resume_key, :approved,
            actor: :rlm_robustness_runner,
            metadata: %{
              scenario_id: scenario.id,
              lane: lane,
              source: :objective_loop_budget_fixture,
              additional_iterations: 2
            }
          )

        append_trail(trail_path, :objective_loop_budget_approved, %{
          resume_key: resume_key,
          session_id: session.id
        })

        emit_progress(opts, scenario, lane, :objective_loop_budget_approved, %{
          resume_key: resume_key,
          session_id: session.id
        })

        resume_result =
          RLMRunner.resume_after_budget(session, decision,
            cwd: workspace.root,
            session_id: session.id,
            run_id: session.id,
            run_fun: objective_loop_approval_resume_run_fun(scenario),
            event_sink:
              objective_loop_resume_event_sink(scenario, lane, trail_path, output_fun, opts)
          )

        objective_loop = %{
          status: :budget_approved_and_resumed,
          budget_resume_key: resume_key,
          initial: objective_loop_result_summary(result),
          resumed: objective_loop_result_summary(resume_result)
        }

        {resume_result, objective_loop}

      _other ->
        {result,
         %{
           status: :missing_budget_request,
           initial: objective_loop_result_summary(result)
         }}
    end
  end

  defp resume_objective_loop_budget(
         scenario,
         lane,
         _workspace,
         {:ok, %{status: :ok, objective_session: session}} = result,
         _output_fun,
         trail_path,
         opts
       ) do
    if objective_session_progress_event?(session, :budget_completed) do
      resume_key = latest_request_key(session.budget_requests)

      append_trail(trail_path, :objective_loop_budget_approved, %{
        resume_key: resume_key,
        session_id: session.id,
        source: :terminal_auto_resume
      })

      append_trail(trail_path, :objective_loop_resume_event, %{
        status: :ok,
        source: :terminal_auto_resume,
        session_id: session.id
      })

      emit_progress(opts, scenario, lane, :objective_loop_budget_approved, %{
        resume_key: resume_key,
        session_id: session.id,
        source: :terminal_auto_resume
      })

      {result,
       %{
         status: :budget_approved_and_resumed,
         budget_resume_key: resume_key,
         initial: %{status: :needs_budget_approval, decision_action: :request_budget_approval},
         resumed: objective_loop_result_summary(result)
       }}
    else
      {result, %{status: :not_waiting_for_budget, initial: objective_loop_result_summary(result)}}
    end
  end

  defp resume_objective_loop_budget(
         _scenario,
         _lane,
         _workspace,
         result,
         _output_fun,
         _trail_path,
         _opts
       ) do
    {result, %{status: :not_waiting_for_budget, initial: objective_loop_result_summary(result)}}
  end

  defp objective_session_progress_event?(%ObjectiveSession{} = session, event) do
    Enum.any?(session.progress_log || [], fn entry ->
      map_value(entry, :event) == event or map_value(entry, :event) == Atom.to_string(event)
    end)
  end

  defp objective_session_progress_event?(_session, _event), do: false

  defp latest_request_key(requests) do
    requests
    |> List.wrap()
    |> List.last()
    |> case do
      request when is_map(request) -> map_value(request, :resume_key) || map_value(request, :id)
      _other -> nil
    end
  end

  defp objective_loop_resume_event_sink(scenario, lane, trail_path, output_fun, opts) do
    fn event ->
      json = RunicAI.Terminal.Event.to_json_map(event)
      append_trail(trail_path, :objective_loop_resume_event, json)
      emit_progress(opts, scenario, lane, :objective_loop_resume_event, json)
      output_fun.("[objective-loop] #{event.title}")
    end
  end

  defp objective_loop_result_summary({:ok, result}) when is_map(result) do
    session = Map.get(result, :objective_session)
    decision = Map.get(result, :objective_decision) || %{}

    %{
      status: Map.get(result, :status),
      session_status: map_value(session, :status),
      decision_action: map_value(decision, :action),
      iteration_count: session |> map_value(:iterations) |> List.wrap() |> length(),
      review_request_count: session |> map_value(:review_requests) |> List.wrap() |> length(),
      budget_request_count: session |> map_value(:budget_requests) |> List.wrap() |> length()
    }
  end

  defp objective_loop_result_summary({:error, %Error{} = error}) do
    %{status: :error, error: error.message}
  end

  defp objective_loop_result_summary(_result), do: %{status: :unknown}

  defp run_opslogic_objective_loop_fixture(cwd, objective, opts) do
    case Keyword.fetch!(opts, :objective_iteration) do
      1 ->
        with :ok <- write_opslogic_plan(cwd) do
          request =
            ReviewRequest.new!(:objective_plan_approval,
              checkpoint: :plan_review,
              resume_key: "review:objective-plan:#{opts[:objective_session_id]}",
              options: [:approve, :reject, :edit, :cancel],
              details: %{
                path: "tmp/ops_logic/PLAN.md",
                objective_preview: objective
              },
              metadata: %{
                safe?: false,
                risk: :medium,
                source: :opslogic_objective_loop_fixture
              }
            )

          {:ok,
           %{
             output_text: "OpsLogic plan written and waiting for operator approval.",
             objective_scorecard: %{objective_status: :objective_incomplete},
             review_request: request,
             context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
           }}
        end

      _iteration ->
        workspace = Workspace.new!(root: cwd)

        case EditPatchSet.apply(workspace, OpsLogicFixture.patch_set(objective)) do
          {:ok, %{status: :ok} = result} ->
            changed_files =
              Map.get(result, :changed_files) || Map.get(result, :changed_paths) || []

            {:ok,
             %{
               output_text: "OpsLogic implementation generated after plan approval.",
               objective_scorecard: %{objective_status: :objective_satisfied},
               context: %{changed_files: changed_files}
             }}

          {:ok, result} ->
            {:error,
             Error.validation("OpsLogic fixture patch did not apply cleanly",
               source: __MODULE__,
               details: %{result: result}
             )}

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  defp run_opslogic_objective_loop_budget_fixture(cwd, objective, opts) do
    case Keyword.fetch!(opts, :objective_iteration) do
      1 ->
        with :ok <- write_opslogic_plan(cwd) do
          {:ok,
           %{
             output_text:
               "OpsLogic plan written; implementation needs another objective iteration.",
             objective_scorecard: %{objective_status: :objective_incomplete},
             context: %{
               changed_files: ["tmp/ops_logic/PLAN.md"],
               task_updates: [
                 %{id: "plan", title: "Write OpsLogic implementation plan", status: :completed}
               ],
               repair_needs: [
                 %{
                   id: "implementation",
                   reason: "OpsLogic implementation requires another objective iteration",
                   target: "tmp/ops_logic"
                 }
               ]
             }
           }}
        end

      _iteration ->
        workspace = Workspace.new!(root: cwd)

        case EditPatchSet.apply(workspace, OpsLogicFixture.patch_set(objective)) do
          {:ok, %{status: :ok} = result} ->
            changed_files =
              Map.get(result, :changed_files) || Map.get(result, :changed_paths) || []

            {:ok,
             %{
               output_text: "OpsLogic implementation generated after budget approval.",
               objective_scorecard: %{objective_status: :objective_satisfied},
               context: %{changed_files: changed_files}
             }}

          {:ok, result} ->
            {:error,
             Error.validation("OpsLogic fixture patch did not apply cleanly",
               source: __MODULE__,
               details: %{result: result}
             )}

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  defp write_opslogic_plan(cwd) do
    workspace = Workspace.new!(root: cwd)

    plan =
      EditPatchSet.new!(
        "Write OpsLogic implementation plan",
        [
          EditOperation.new!(:create_file,
            params: %{
              path: "tmp/ops_logic/PLAN.md",
              overwrite: true,
              content: OpsLogicFixture.plan_markdown()
            }
          )
        ],
        expected_changed_files: ["tmp/ops_logic/PLAN.md"]
      )

    case EditPatchSet.apply(workspace, plan) do
      {:ok, %{status: :ok}} ->
        :ok

      {:ok, result} ->
        {:error, Error.validation("OpsLogic plan write was not accepted", details: result)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp live_repair_loop_opts(%ProjectScenario{} = scenario) do
    cond do
      map_value(scenario.metadata, :internal_repair_loop?) == true ->
        [
          proposal: internal_repair_loop_proposal(),
          repair_executor: internal_repair_loop_executor()
        ]

      map_value(scenario.metadata, :child_agent_repair_loop?) == true ->
        [
          proposal: internal_repair_loop_proposal(),
          repair_opts: [
            agent_opts: [
              model: "test:repair-child",
              client: child_agent_repair_loop_client(),
              max_turns: 4,
              max_tool_calls: 8
            ]
          ]
        ]

      map_value(scenario.metadata, :semantic_repair_loop?) == true ->
        [
          proposal: semantic_repair_loop_proposal(),
          semantic_progress?: true,
          objective_contract: semantic_repair_loop_contract(),
          semantic_judge: semantic_repair_loop_judge(),
          repair_opts: [
            agent_opts: [
              model: "test:semantic-repair-child",
              client: semantic_child_agent_repair_loop_client(),
              max_turns: 4,
              max_tool_calls: 8
            ],
            verification_commands: [
              AcceptanceCheck.new!(:command_passes,
                id: "semantic-repair-test-command",
                params: %{argv: ["mix", "test"]}
              )
            ]
          ]
        ]

      map_value(scenario.metadata, :llm_judge_repair_loop?) == true ->
        [
          proposal: semantic_repair_loop_proposal(),
          semantic_progress?: true,
          objective_contract: semantic_repair_loop_contract(),
          semantic_judge_generation: :json_text,
          semantic_model: "test:semantic-judge",
          semantic_client: llm_semantic_repair_loop_client(),
          repair_opts: [
            agent_opts: [
              model: "test:semantic-repair-child",
              client: semantic_child_agent_repair_loop_client(),
              max_turns: 4,
              max_tool_calls: 8
            ],
            verification_commands: [
              AcceptanceCheck.new!(:command_passes,
                id: "llm-semantic-repair-test-command",
                params: %{argv: ["mix", "test"]}
              )
            ]
          ]
        ]

      map_value(scenario.metadata, :runtime_smoke_repair_loop?) == true ->
        [
          proposal: runtime_smoke_repair_loop_proposal(),
          repair_opts: [
            agent_opts: [
              model: "test:runtime-smoke-repair-child",
              client: runtime_smoke_child_agent_repair_loop_client(),
              max_turns: 4,
              max_tool_calls: 8
            ]
          ]
        ]

      true ->
        []
    end
  end

  defp internal_repair_loop_proposal do
    WorkflowProposal.new!(
      "Repair InternalRepairDemo and prove mix test passes",
      [
        ProposalNode.new!("initial_test", :command,
          params: %{
            args: %{
              argv: ["mix", "test"],
              metadata: %{safe?: true, requires_review?: false}
            }
          }
        ),
        ProposalNode.new!("verify_repaired", :verification_gate,
          params: %{
            checks: [
              %{
                id: "internal-repair-source",
                type: "source_contains",
                params: %{path: "lib/internal_repair_demo.ex", text: "def repaired?"}
              },
              %{
                id: "internal-repair-test-command",
                type: "command_passes",
                params: %{argv: ["mix", "test"]}
              }
            ]
          }
        )
      ],
      edges: [%{from: "initial_test", to: "verify_repaired"}],
      expected_artifacts: [:source_implementation, :verification_evidence],
      stop_conditions: ["InternalRepairDemo.repaired?/0 exists and mix test passes"],
      metadata: %{recipe: :internal_repair_loop_fixture}
    )
  end

  defp internal_repair_loop_executor do
    fn workspace, objective, _opts ->
      unless String.contains?(objective, "Structured repair plan") and
               String.contains?(objective, "mix test") do
        {:error,
         Error.validation("internal repair fixture did not receive structured failure evidence",
           source: __MODULE__,
           details: %{objective_preview: String.slice(objective, 0, 500)}
         )}
      else
        File.write!(
          Path.join(workspace.root, "lib/internal_repair_demo.ex"),
          """
          defmodule InternalRepairDemo do
            @moduledoc false

            def answer, do: 42
            def repaired?, do: true
          end
          """
        )

        {:ok,
         ChildResult.new!(:completed,
           id: "internal-repair-loop",
           changed_files: ["lib/internal_repair_demo.ex"],
           summary: "Patched InternalRepairDemo from structured failing test evidence"
         )}
      end
    end
  end

  defp child_agent_repair_loop_client do
    fn
      _model, %RunicAI.Prompt{messages: messages}, _opts ->
        if tool_count(messages) == 0 do
          {:ok,
           child_tool_response([
             child_tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{
                     op: "update",
                     path: "lib/internal_repair_demo.ex",
                     content: """
                     defmodule InternalRepairDemo do
                       @moduledoc false

                       def answer, do: 42
                       def repaired?, do: true
                     end
                     """
                   }
                 ]
               },
               id: "repair_apply_patch"
             )
           ])}
        else
          {:ok,
           child_result(
             "Changed files: lib/internal_repair_demo.ex. Verification is delegated to parent repair gates."
           )}
        end

      _model, _prompt, _opts ->
        {:ok, child_result("No repair action available.")}
    end
  end

  defp semantic_child_agent_repair_loop_client do
    fn
      _model, %RunicAI.Prompt{messages: messages} = prompt, _opts ->
        cond do
          tool_count(messages) > 0 ->
            {:ok,
             child_result(
               "Changed files: lib/work_order.ex, test/work_order_test.exs. Verification is delegated to parent repair gates."
             )}

          semantic_repair_handoff?(prompt) ->
            {:ok, semantic_child_tool_response()}

          true ->
            {:ok,
             child_result(
               "No patch emitted because the parent repair handoff did not include semantic transition-history evidence."
             )}
        end

      _model, _prompt, _opts ->
        {:ok, child_result("No semantic repair action available.")}
    end
  end

  defp semantic_repair_handoff?(prompt) do
    prompt_contains_all?(prompt, [
      "Structured repair plan",
      "semantic requirement",
      "transition history",
      "mix test"
    ])
  end

  defp semantic_child_tool_response do
    child_tool_response([
      child_tool_call(
        "apply_patch",
        %{
          operations: [
            %{
              op: "update",
              path: "lib/work_order.ex",
              content: """
              defmodule WorkOrder do
                @moduledoc false

                defstruct [:id, :status, history: []]

                def new(id), do: %__MODULE__{id: id, status: :open, history: []}
                def complete(order), do: transition(order, :completed)

                def transition(%__MODULE__{} = order, next_status) do
                  entry = %{
                    from: order.status,
                    to: next_status,
                    transitioned_at: DateTime.utc_now()
                  }

                  %{order | status: next_status, history: order.history ++ [entry]}
                end
              end
              """
            },
            %{
              op: "update",
              path: "test/work_order_test.exs",
              content: """
              defmodule WorkOrderTest do
                use ExUnit.Case, async: true

                test "completes a work order and records transition history" do
                  order = WorkOrder.new("wo-1")
                  completed = WorkOrder.complete(order)

                  assert %WorkOrder{status: :completed} = completed
                  assert [%{from: :open, to: :completed, transitioned_at: %DateTime{}}] = completed.history
                end
              end
              """
            }
          ]
        },
        id: "semantic_repair_apply_patch"
      )
    ])
  end

  defp runtime_smoke_child_agent_repair_loop_client do
    fn
      _model, %RunicAI.Prompt{messages: messages} = prompt, _opts ->
        cond do
          tool_count(messages) > 0 ->
            {:ok,
             child_result(
               "Changed files: lib/dispatch_runtime.ex, test/dispatch_runtime_test.exs. Verification is delegated to parent runtime smoke gates."
             )}

          runtime_smoke_repair_handoff?(prompt) ->
            {:ok, runtime_smoke_child_tool_response()}

          true ->
            {:ok,
             child_result(
               "No patch emitted because the parent repair handoff did not include runtime-smoke dispatch_flow evidence."
             )}
        end

      _model, _prompt, _opts ->
        {:ok, child_result("No runtime-smoke repair action available.")}
    end
  end

  defp runtime_smoke_repair_handoff?(prompt) do
    prompt_contains_all?(prompt, [
      "Structured repair plan",
      "runtime smoke",
      "dispatch_flow"
    ])
  end

  defp runtime_smoke_child_tool_response do
    child_tool_response([
      child_tool_call(
        "apply_patch",
        %{
          operations: [
            %{
              op: "update",
              path: "lib/dispatch_runtime.ex",
              content: """
              defmodule DispatchRuntime do
                @moduledoc false

                def new_work_order(id), do: %{id: id, status: :new}

                def runtime_smoke do
                  runtime_supervisor_started = true

                  if runtime_supervisor_started do
                    {:ok, %{status: :runtime_smoke_pass, assigned: true}}
                  else
                    {:error, :supervision_not_started}
                  end
                end
              end
              """
            },
            %{
              op: "update",
              path: "test/dispatch_runtime_test.exs",
              content: """
              defmodule DispatchRuntimeTest do
                use ExUnit.Case, async: true

                test "creates a work order" do
                  assert %{status: :new} = DispatchRuntime.new_work_order("wo-1")
                end

                test "runtime smoke returns runnable dispatch evidence" do
                  assert {:ok, %{status: :runtime_smoke_pass, assigned: true}} =
                           DispatchRuntime.runtime_smoke()
                end
              end
              """
            }
          ]
        },
        id: "runtime_smoke_repair_apply_patch"
      )
    ])
  end

  defp child_result(text) when is_binary(text) do
    RunicAI.LLM.Result.new!(RunicAI.Message.new!(:assistant, text),
      finish_reason: :stop,
      usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    )
  end

  defp child_tool_call(name, arguments, opts) when is_binary(name) and is_map(arguments) do
    ReqLLM.ToolCall.new(Keyword.get(opts, :id), name, Jason.encode!(arguments))
  end

  defp child_tool_response(tool_calls) when is_list(tool_calls) do
    message = ReqLLM.Context.assistant("", tool_calls: tool_calls)

    %ReqLLM.Response{
      id: "repair-child-#{System.unique_integer([:positive])}",
      model: "test:repair-child",
      context: ReqLLM.Context.new([message]),
      message: message,
      usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
      finish_reason: :tool_calls
    }
  end

  defp tool_count(messages) when is_list(messages) do
    Enum.count(messages, &(&1.role == :tool))
  end

  defp tool_count(_messages), do: 0

  defp semantic_repair_loop_proposal do
    WorkflowProposal.new!(
      "Repair WorkOrder transition history and prove mix test plus semantic judge pass",
      [
        ProposalNode.new!("initial_test", :command,
          params: %{
            args: %{
              argv: ["mix", "test"],
              metadata: %{safe?: true, requires_review?: false}
            }
          }
        ),
        ProposalNode.new!("verify_tests", :verification_gate,
          params: %{
            checks: [
              %{
                id: "semantic-repair-test-command",
                type: "command_passes",
                params: %{argv: ["mix", "test"]}
              }
            ]
          }
        )
      ],
      edges: [%{from: "initial_test", to: "verify_tests"}],
      expected_artifacts: [:source_implementation, :verification_evidence],
      stop_conditions: [
        "WorkOrder records transition history",
        "mix test passes",
        "semantic judge marks transition_history satisfied"
      ],
      metadata: %{recipe: :semantic_repair_loop_fixture}
    )
  end

  defp semantic_repair_loop_contract do
    ObjectiveContract.new!(
      "Repair WorkOrder transition history and prove mix test plus semantic judge pass",
      requirements: [
        %{
          id: "transition_history",
          kind: "behavior",
          description: "Work orders record transition history entries for status changes.",
          required: true,
          evidence_needed: ["source", "tests", "command_result"],
          acceptance_criteria: [
            "source stores a history collection",
            "completion appends a transition entry with timestamp evidence",
            "tests or command output verify the repaired behavior"
          ]
        }
      ],
      metadata: %{source: :semantic_repair_loop_fixture}
    )
  end

  defp semantic_repair_loop_judge do
    fn _contract, evidence, _opts ->
      source =
        evidence
        |> Map.get(:files, [])
        |> Enum.map_join("\n", &Map.get(&1, :content, ""))
        |> String.downcase()

      status =
        if String.contains?(source, "history") and
             String.contains?(source, "transitioned_at") do
          "satisfied"
        else
          "incomplete"
        end

      {:ok,
       %{
         status: status,
         summary: "transition history semantic requirement evaluated from source evidence",
         requirement_results: [
           %{
             requirement_id: "transition_history",
             status: status,
             message: "WorkOrder must record transition history entries for status changes.",
             rationale: "Source evidence must show history storage and transitioned_at entries.",
             evidence_refs: ["lib/work_order.ex"],
             repair_instruction:
               "Add a history field, append transition entries with transitioned_at timestamps, and cover it with tests."
           }
         ]
       }}
    end
  end

  defp llm_semantic_repair_loop_client do
    fn _model, prompt, _opts ->
      status =
        if prompt_contains_all?(prompt, ["history", "transitioned_at"]) do
          "satisfied"
        else
          "incomplete"
        end

      response =
        Jason.encode!(%{
          status: status,
          summary: "LLM-style judge evaluated transition history from evidence",
          requirement_results: [
            %{
              requirement_id: "transition_history",
              status: status,
              message: "LLM judge requires WorkOrder transition history with timestamp evidence.",
              rationale:
                "Evidence must show history storage, transition append behavior, and a test.",
              evidence_refs: ["lib/work_order.ex", "test/work_order_test.exs"],
              repair_instruction:
                "Add a history field, append transition entries with transitioned_at timestamps, and cover it with tests."
            }
          ],
          risks: []
        })

      {:ok,
       RunicAI.LLM.Result.new!(RunicAI.Message.new!(:assistant, response),
         finish_reason: :stop,
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       )}
    end
  end

  defp prompt_contains_all?(prompt, terms) when is_binary(prompt) do
    prompt = String.downcase(prompt)
    Enum.all?(terms, &String.contains?(prompt, String.downcase(&1)))
  end

  defp prompt_contains_all?(%RunicAI.Prompt{} = prompt, terms) do
    prompt
    |> prompt_text()
    |> prompt_contains_all?(terms)
  end

  defp prompt_contains_all?(prompt, terms) do
    prompt
    |> inspect(limit: :infinity)
    |> prompt_contains_all?(terms)
  end

  defp prompt_text(%RunicAI.Prompt{messages: messages}) do
    messages
    |> List.wrap()
    |> Enum.map_join("\n", fn
      %{content: content} when is_binary(content) -> content
      other -> inspect(other)
    end)
  end

  defp runtime_smoke_repair_loop_proposal do
    runtime_argv = runtime_smoke_repair_argv()

    WorkflowProposal.new!(
      "Repair DispatchRuntime runtime smoke and prove runtime evidence passes",
      [
        ProposalNode.new!("initial_test", :command,
          params: %{
            args: %{
              argv: ["mix", "test"],
              metadata: %{safe?: true, requires_review?: false}
            }
          }
        ),
        ProposalNode.new!("runtime_smoke", :command,
          params: %{
            args: %{
              argv: runtime_argv,
              metadata: %{
                safe?: true,
                requires_review?: false,
                purpose: :runtime_smoke,
                smoke_id: "dispatch_flow"
              }
            }
          },
          metadata: %{purpose: :runtime_smoke, smoke_id: "dispatch_flow"}
        ),
        ProposalNode.new!("verify_runtime", :verification_gate,
          params: %{
            checks: [
              %{
                id: "dispatch-runtime-smoke",
                type: "runtime_smoke",
                params: %{id: "dispatch_flow", argv: runtime_argv}
              }
            ]
          }
        )
      ],
      edges: [
        %{from: "initial_test", to: "runtime_smoke"},
        %{from: "runtime_smoke", to: "verify_runtime"}
      ],
      expected_artifacts: [:source_implementation, :runtime_smoke_evidence],
      stop_conditions: [
        "DispatchRuntime.runtime_smoke/0 returns {:ok, %{status: :runtime_smoke_pass}}",
        "runtime smoke dispatch_flow passes"
      ],
      metadata: %{recipe: :runtime_smoke_repair_loop_fixture}
    )
  end

  defp runtime_smoke_repair_argv do
    [
      "mix",
      "run",
      "-e",
      "case DispatchRuntime.runtime_smoke() do {:ok, _} -> IO.puts(\"runtime_smoke_pass\"); other -> IO.inspect(other); System.halt(1) end"
    ]
  end

  defp browser_probe_review_output(%{required?: true, decision_status: status}) do
    "\n\nReview decision evidence: #{inspect(status)}"
  end

  defp browser_probe_review_output(_summary), do: ""

  defp browser_probe_scorecard(%{requested_action: action, decision_status: status})
       when action in [:deny, "deny"] and status in [:rejected, "rejected", :denied, "denied"] do
    %{objective_status: :objective_satisfied}
  end

  defp browser_probe_scorecard(_summary), do: %{objective_status: :objective_incomplete}

  defp browser_probe_result_status(%{requested_action: action, decision_status: status})
       when action in [:deny, "deny"] and status in [:rejected, "rejected", :denied, "denied"],
       do: :completed

  defp browser_probe_result_status(_summary), do: :blocked

  defp wait_for_snapshot(session_id, attempts \\ 80)
  defp wait_for_snapshot(session_id, 0), do: Workbench.session_snapshot(session_id)

  defp wait_for_snapshot(session_id, attempts) do
    snapshot = Workbench.session_snapshot(session_id)

    cond do
      is_nil(snapshot) ->
        Process.sleep(50)
        wait_for_snapshot(session_id, attempts - 1)

      Enum.any?(snapshot.events, &(&1.phase in ["final", "browser_probe_completed"])) ->
        snapshot

      true ->
        Process.sleep(50)
        wait_for_snapshot(session_id, attempts - 1)
    end
  end

  defp launch_browser_probe(session_id, launch, workspace, scenario, opts) do
    if Keyword.get(opts, :browser_ui_launch?, false) do
      launch_browser_ui_probe(session_id, launch, workspace, scenario, opts)
    else
      start = Workbench.start_agent_run(launch)
      launch_snapshot = Workbench.session_snapshot(session_id)
      snapshot = wait_for_snapshot(session_id)

      {session_id, start, launch_snapshot, snapshot, nil}
    end
  end

  defp launch_browser_ui_probe(session_id, launch, workspace, scenario, opts) do
    if browser_review_prelaunch?(scenario) do
      start = Workbench.start_agent_run(launch)
      launch_snapshot = Workbench.session_snapshot(session_id)

      browser_ui_capture =
        launch_browser_ui(
          launch,
          workspace,
          scenario,
          Keyword.put(opts, :browser_open_session_url, workbench_session_url(session_id, opts))
        )

      launched_session_id = map_value(browser_ui_capture, :session_id) || session_id
      snapshot = wait_for_browser_snapshot(launched_session_id, scenario, opts)

      {launched_session_id, start, launch_snapshot, snapshot, browser_ui_capture}
    else
      browser_ui_capture = launch_browser_ui(launch, workspace, scenario, opts)
      launched_session_id = map_value(browser_ui_capture, :session_id) || session_id
      launch_snapshot = Workbench.session_snapshot(launched_session_id)
      snapshot = wait_for_browser_snapshot(launched_session_id, scenario, opts)

      {launched_session_id, {:ok, browser_ui_capture}, launch_snapshot, snapshot,
       browser_ui_capture}
    end
  end

  defp wait_for_browser_snapshot(session_id, %ProjectScenario{} = scenario, opts) do
    wait_ms =
      (map_value(scenario.metadata, :browser_terminal_wait_ms) ||
         Keyword.get(opts, :browser_terminal_wait_ms, 90_000))
      |> normalize_wait_ms(90_000)

    wait_for_browser_snapshot_until(
      session_id,
      System.monotonic_time(:millisecond) + wait_ms,
      nil
    )
  end

  defp normalize_wait_ms(value, _default) when is_integer(value) and value >= 0, do: value

  defp normalize_wait_ms(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> default
    end
  end

  defp normalize_wait_ms(_value, default), do: default

  defp wait_for_browser_snapshot_until(session_id, deadline_ms, last_snapshot) do
    snapshot = Workbench.session_snapshot(session_id) || last_snapshot

    cond do
      is_nil(snapshot) and System.monotonic_time(:millisecond) < deadline_ms ->
        Process.sleep(250)
        wait_for_browser_snapshot_until(session_id, deadline_ms, snapshot)

      is_nil(snapshot) ->
        nil

      browser_snapshot_checkpoint?(snapshot) ->
        snapshot

      System.monotonic_time(:millisecond) >= deadline_ms ->
        snapshot

      true ->
        Process.sleep(250)
        wait_for_browser_snapshot_until(session_id, deadline_ms, snapshot)
    end
  end

  defp browser_snapshot_checkpoint?(snapshot) when is_map(snapshot) do
    session_status = get_in(snapshot, [:session, :status])
    completion_proof = Map.get(snapshot, :completion_proof, %{})

    terminal_session? =
      session_status in [
        "completed",
        "objective_satisfied",
        "blocked",
        "failed",
        "cancelled",
        "stopped",
        "review"
      ]

    terminal_session? or
      (map_value(completion_proof, :terminal?) == true and session_status != "running") or
      (is_nil(session_status) and
         Enum.any?(
           Map.get(snapshot, :events, []),
           &(&1.phase in ["final", "browser_probe_completed"])
         )) or
      Enum.any?(
        Map.get(snapshot, :review_requests, []),
        &(map_value(&1, :status) in ["pending", "waiting", "review"])
      )
  end

  defp browser_evidence(
         session_id,
         launch,
         launch_result,
         launch_snapshot,
         final_snapshot,
         workspace,
         scenario,
         opts,
         existing_browser_ui_capture
       ) do
    visible_state = browser_visible_state(final_snapshot)

    browser_ui_capture =
      maybe_capture_browser_ui(session_id, workspace, scenario, opts, existing_browser_ui_capture)
      |> normalize_terminal_wait_capture(visible_state)

    evidence = %{
      generated_at: DateTime.utc_now(),
      session_id: session_id,
      task_shape: scenario_task_shape(scenario),
      session_url: workbench_session_url(session_id, opts),
      launch: launch_summary(launch),
      launch_result: inspect_result(launch_result),
      snapshots: %{
        after_launch: summarize_snapshot(launch_snapshot),
        final: summarize_snapshot(final_snapshot)
      },
      visible_state: visible_state,
      browser_ui_capture: browser_ui_capture
    }

    Map.put(evidence, :ui_checks, browser_ui_checks(evidence))
  end

  defp normalize_terminal_wait_capture(browser_ui_capture, visible_state)
       when is_map(browser_ui_capture) and is_map(visible_state) do
    proof = Map.get(visible_state, :completion_proof, %{})

    if map_value(proof, :terminal?) == true and
         map_value(browser_ui_capture, :terminal_wait_observed?) != true do
      wait_state =
        browser_ui_capture
        |> map_value(:terminal_wait_state)
        |> case do
          state when is_map(state) -> state
          _state -> %{}
        end
        |> put_json_field(:observed, true)
        |> put_json_field(:source, "persisted_completion_proof")
        |> put_json_field(:reason, "terminal completion proof observed after browser wait")

      browser_ui_capture
      |> put_json_field(:terminal_wait_observed?, true)
      |> put_json_field(:terminal_wait_state, wait_state)
    else
      browser_ui_capture
    end
  end

  defp normalize_terminal_wait_capture(browser_ui_capture, _visible_state), do: browser_ui_capture

  defp put_json_field(map, key, value) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    map
    |> Map.delete(key)
    |> Map.delete(string_key)
    |> Map.put(string_key, value)
  end

  defp write_browser_evidence!(workspace_root, scenario_id, evidence) do
    path =
      workspace_root
      |> Path.join("tmp/browser-evidence-#{safe_label(scenario_id)}.json")
      |> Path.expand()

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(evidence, pretty: true))
    path
  end

  defp browser_ui_gaps(%{ui_checks: checks}) do
    checks
    |> Enum.filter(&(&1.status == "fail"))
    |> Enum.map(& &1.message)
  end

  defp browser_ui_gaps(_evidence), do: ["browser evidence checks missing"]

  defp browser_ui_checks(evidence) do
    visible_state = evidence.visible_state
    final_snapshot = evidence.snapshots.final
    launch_snapshot = evidence.snapshots.after_launch
    browser_ui_capture = Map.get(evidence, :browser_ui_capture, %{})

    [
      ui_check(
        "session_url_present",
        is_binary(evidence.session_url) and evidence.session_url != "",
        "Workbench session URL captured",
        "Workbench session URL was not captured",
        %{session_url: evidence.session_url}
      ),
      ui_check(
        "launch_projection_present",
        map_size(launch_snapshot) > 0,
        "Launch snapshot captured from Workbench projection",
        "Launch snapshot was not captured from Workbench projection",
        %{message_count: Map.get(launch_snapshot, :message_count, 0)}
      ),
      ui_check(
        "final_projection_present",
        map_size(final_snapshot) > 0,
        "Final Workbench projection captured",
        "Final Workbench projection was not captured",
        %{status: visible_state.session_status}
      ),
      ui_check(
        "agent_route_visible",
        visible_state.selected_agent == evidence.launch.agent,
        "Requested RLM agent remained visible in session projection",
        "Requested agent did not remain visible in session projection",
        %{
          requested_agent: evidence.launch.agent,
          selected_agent: visible_state.selected_agent
        }
      ),
      ui_check(
        "visible_state_present",
        visible_state.message_count > 0 and visible_state.event_count > 0,
        "Visible message and event state captured",
        "Visible message and event state was not captured",
        %{
          message_count: visible_state.message_count,
          event_count: visible_state.event_count
        }
      ),
      final_output_visible_check(visible_state, browser_ui_capture),
      ui_check(
        "review_state_captured",
        is_integer(visible_state.review_request_count),
        "Review request state captured",
        "Review request state was not captured",
        %{
          review_request_count: visible_state.review_request_count,
          review_statuses: visible_state.review_statuses
        }
      ),
      ui_check(
        "artifact_state_captured",
        is_integer(visible_state.artifact_count),
        "Artifact state captured",
        "Artifact state was not captured",
        %{
          artifact_count: visible_state.artifact_count,
          artifact_paths: visible_state.artifact_paths
        }
      ),
      structured_contract_check(visible_state, browser_ui_capture),
      blocked_evidence_check(visible_state),
      ui_check(
        "dom_snapshot_captured",
        capture_file_exists?(browser_ui_capture, :dom_snapshot_path),
        "Browser DOM snapshot captured",
        "DOM snapshot capture is missing; enable --browser-ui-capture with a running workbench",
        %{
          dom_snapshot_path: map_value(browser_ui_capture, :dom_snapshot_path),
          status: map_value(browser_ui_capture, :status)
        }
      ),
      ui_check(
        "browser_screenshot_captured",
        capture_file_exists?(browser_ui_capture, :screenshot_path),
        "Browser screenshot captured",
        "Browser screenshot capture is missing; enable --browser-ui-capture with a running workbench",
        %{
          screenshot_path: map_value(browser_ui_capture, :screenshot_path),
          status: map_value(browser_ui_capture, :status)
        }
      ),
      ui_check(
        "browser_console_captured",
        map_value(browser_ui_capture, :console_captured?) == true,
        "Browser console errors captured",
        "Browser console capture is missing; enable --browser-ui-launch with a running workbench",
        %{
          console_path: map_value(browser_ui_capture, :console_path),
          status: map_value(browser_ui_capture, :status)
        }
      ),
      ui_check(
        "browser_network_captured",
        map_value(browser_ui_capture, :network_captured?) == true,
        "Browser network activity captured",
        "Browser network capture is missing; enable --browser-ui-launch with a running workbench",
        %{
          network_path: map_value(browser_ui_capture, :network_path),
          status: map_value(browser_ui_capture, :status)
        }
      ),
      ui_check(
        "ui_launch_captured",
        map_value(browser_ui_capture, :ui_launch_captured?) == true,
        "Workbench composer launch captured through browser UI",
        "Workbench composer launch was not driven through browser UI controls",
        %{status: map_value(browser_ui_capture, :status)}
      ),
      ui_check(
        "plan_visibility_captured",
        map_value(browser_ui_capture, :plan_visibility_captured?) == true,
        "Workbench plan tab visibility captured",
        "Workbench plan tab visibility was not captured through browser UI controls",
        %{
          status: map_value(browser_ui_capture, :status),
          plan_stage_labels: map_value(browser_ui_capture, :plan_stage_labels)
        }
      ),
      ui_check(
        "workflow_stage_plan_visible",
        map_value(browser_ui_capture, :workflow_stage_plan_visible?) == true,
        "Workflow planning, implementation, verification, and repair stages are visible",
        "Workflow-specific planning, implementation, verification, and repair stages are not visible in the plan tab",
        %{
          status: map_value(browser_ui_capture, :status),
          plan_stage_labels: map_value(browser_ui_capture, :plan_stage_labels),
          plan_text_preview: map_value(browser_ui_capture, :plan_text_preview)
        }
      ),
      live_progress_check(visible_state, browser_ui_capture),
      active_progress_context_check(visible_state, browser_ui_capture),
      active_progress_budget_details_check(visible_state, browser_ui_capture),
      active_progress_pre_final_check(browser_ui_capture),
      completion_proof_check(evidence),
      review_decision_check(browser_ui_capture),
      repair_failure_injection_check(browser_ui_capture),
      browser_follow_up_check(browser_ui_capture),
      tidewave_interaction_check(browser_ui_capture)
    ]
  end

  defp ui_check(id, true, pass_message, _fail_message, evidence) do
    %{id: id, status: "pass", message: pass_message, evidence: evidence}
  end

  defp ui_check(id, false, _pass_message, fail_message, evidence) do
    %{id: id, status: "fail", message: fail_message, evidence: evidence}
  end

  defp final_output_visible_check(visible_state, browser_ui_capture) do
    final_output? =
      is_binary(visible_state.final_output_preview) and
        visible_state.final_output_preview != ""

    terminal_failed_with_evidence? =
      terminal_failed_with_evidence?(visible_state, browser_ui_capture)

    cond do
      review_decision_captured?(browser_ui_capture) or final_output? ->
        %{
          id: "final_output_visible",
          status: "pass",
          message: "Final assistant-visible output captured",
          evidence: final_output_visible_evidence(visible_state, browser_ui_capture)
        }

      terminal_failed_with_evidence? ->
        %{
          id: "final_output_visible",
          status: "pass",
          message: "Terminal failed state captured with blocked evidence; final output pending",
          evidence: final_output_visible_evidence(visible_state, browser_ui_capture)
        }

      true ->
        %{
          id: "final_output_visible",
          status: "fail",
          message: "Final assistant-visible output was not captured",
          evidence: final_output_visible_evidence(visible_state, browser_ui_capture)
        }
    end
  end

  defp final_output_visible_evidence(visible_state, browser_ui_capture) do
    proof = Map.get(visible_state, :completion_proof, %{})

    %{
      final_output_preview: visible_state.final_output_preview,
      review_decision_captured?: review_decision_captured?(browser_ui_capture),
      session_status: visible_state.session_status,
      terminal?: map_value(proof, :terminal?),
      blocked_evidence_present?: visible_state.blocked_evidence_present?,
      dom_snapshot_captured?: capture_file_exists?(browser_ui_capture, :dom_snapshot_path),
      screenshot_captured?: capture_file_exists?(browser_ui_capture, :screenshot_path),
      console_captured?: map_value(browser_ui_capture, :console_captured?),
      network_captured?: map_value(browser_ui_capture, :network_captured?)
    }
  end

  defp terminal_failed_with_evidence?(visible_state, browser_ui_capture) do
    proof = Map.get(visible_state, :completion_proof, %{})

    map_value(proof, :terminal?) == true and
      visible_state.session_status in ["failed", "blocked", :failed, :blocked] and
      visible_state.blocked_evidence_present? == true and
      capture_file_exists?(browser_ui_capture, :dom_snapshot_path) and
      capture_file_exists?(browser_ui_capture, :screenshot_path) and
      map_value(browser_ui_capture, :console_captured?) == true and
      map_value(browser_ui_capture, :network_captured?) == true
  end

  defp structured_contract_check(visible_state, browser_ui_capture) do
    requires_contract? = visible_state.selected_agent in ["rlm", :rlm]

    ui_check(
      "structured_contract_requirements_visible",
      not requires_contract? or
        review_decision_captured?(browser_ui_capture) or
        (visible_state.objective_contract_present? == true and
           visible_state.objective_contract_requirement_count > 0),
      "Structured objective contract requirements captured",
      "Structured objective contract requirements were not captured",
      %{
        selected_agent: visible_state.selected_agent,
        review_decision_captured?: review_decision_captured?(browser_ui_capture),
        objective_contract_present?: visible_state.objective_contract_present?,
        requirement_count: visible_state.objective_contract_requirement_count,
        evidence_required: visible_state.objective_contract_evidence_required
      }
    )
  end

  defp blocked_evidence_check(visible_state) do
    blocked? = visible_state.session_status in ["blocked", "failed", :blocked, :failed]

    ui_check(
      "blocked_next_action_evidence_visible",
      not blocked? or
        (visible_state.blocked_evidence_present? == true and visible_state.next_action_count > 0),
      "Blocked-run next-action evidence captured",
      "Blocked-run next-action evidence was not captured",
      %{
        session_status: visible_state.session_status,
        blocked_evidence_present?: visible_state.blocked_evidence_present?,
        current_node: visible_state.blocked_current_node,
        next_action_count: visible_state.next_action_count
      }
    )
  end

  defp live_progress_check(visible_state, browser_ui_capture) do
    ui_check(
      "live_progress_summary_visible",
      visible_state.progress_summary_present? == true and
        visible_state.progress_event_count > 0 and
        map_value(browser_ui_capture, :live_progress_visible?) == true,
      "Live progress summary captured in Workbench UI",
      "Live progress summary was not visible in the Workbench plan tab",
      %{
        progress_summary_present?: visible_state.progress_summary_present?,
        progress_event_count: visible_state.progress_event_count,
        latest_progress_title: visible_state.latest_progress_title,
        current_node: visible_state.progress_current_node,
        remaining_ms: visible_state.progress_remaining_ms,
        live_progress_visible?: map_value(browser_ui_capture, :live_progress_visible?),
        plan_text_preview: map_value(browser_ui_capture, :plan_text_preview)
      }
    )
  end

  defp active_progress_context_check(visible_state, browser_ui_capture) do
    ui_launched? = map_value(browser_ui_capture, :ui_launch_captured?) == true
    review_context? = review_card_captured?(browser_ui_capture)

    current_context_visible? =
      progress_capture_value(browser_ui_capture, :current_context_visible?) == true

    ui_check(
      "active_progress_context_visible",
      not ui_launched? or
        review_context? or
        current_context_visible? or
        not is_nil(visible_state.progress_current_node),
      "Active progress current node/child context captured",
      "Active progress current node/child context was not visible in the Workbench plan tab",
      %{
        ui_launch_captured?: ui_launched?,
        active_progress_snapshot_captured?:
          map_value(browser_ui_capture, :active_progress_snapshot_captured?),
        active_progress_current_context_visible?: current_context_visible?,
        active_progress_budget_visible?:
          map_value(browser_ui_capture, :active_progress_budget_visible?),
        review_card_captured?: review_context?,
        current_node: visible_state.progress_current_node,
        remaining_ms: visible_state.progress_remaining_ms,
        active_plan_text_preview: map_value(browser_ui_capture, :active_plan_text_preview)
      }
    )
  end

  defp active_progress_budget_details_check(visible_state, browser_ui_capture) do
    ui_launched? = map_value(browser_ui_capture, :ui_launch_captured?) == true
    review_context? = review_card_captured?(browser_ui_capture)

    current_context_visible? =
      progress_capture_value(browser_ui_capture, :current_context_visible?) == true

    remaining_visible? = progress_capture_value(browser_ui_capture, :remaining_visible?) == true

    ui_check(
      "active_progress_budget_details_visible",
      not ui_launched? or
        review_context? or
        (current_context_visible? and remaining_visible?),
      "Active progress node/child and remaining budget are visible",
      "Active progress node/child and remaining budget were not visible in the Workbench plan tab",
      %{
        ui_launch_captured?: ui_launched?,
        active_progress_snapshot_captured?:
          map_value(browser_ui_capture, :active_progress_snapshot_captured?),
        active_progress_current_context_visible?: current_context_visible?,
        active_progress_child_visible?:
          map_value(browser_ui_capture, :active_progress_child_visible?),
        active_progress_remaining_visible?: remaining_visible?,
        active_progress_budget_visible?:
          map_value(browser_ui_capture, :active_progress_budget_visible?),
        review_card_captured?: review_context?,
        current_node: visible_state.progress_current_node,
        remaining_ms: visible_state.progress_remaining_ms,
        active_plan_text_preview: map_value(browser_ui_capture, :active_plan_text_preview)
      }
    )
  end

  defp active_progress_pre_final_check(browser_ui_capture) do
    required? =
      map_value(browser_ui_capture, :review_decision_required?) == true or
        map_value(browser_ui_capture, :active_progress_pre_final_required?) == true

    ui_check(
      "active_progress_pre_final_visible",
      not required? or
        review_card_captured?(browser_ui_capture) or
        (map_value(browser_ui_capture, :active_progress_snapshot_captured?) == true and
           map_value(browser_ui_capture, :active_progress_pre_final_visible?) == true),
      "Required active progress was captured before final completion",
      "Required active progress was not captured before final completion",
      %{
        pre_final_required?: required?,
        review_decision_required?: map_value(browser_ui_capture, :review_decision_required?),
        active_progress_pre_final_required?:
          map_value(browser_ui_capture, :active_progress_pre_final_required?),
        review_card_captured?: review_card_captured?(browser_ui_capture),
        active_progress_snapshot_captured?:
          map_value(browser_ui_capture, :active_progress_snapshot_captured?),
        active_progress_pre_final_visible?:
          map_value(browser_ui_capture, :active_progress_pre_final_visible?),
        active_plan_text_preview: map_value(browser_ui_capture, :active_plan_text_preview)
      }
    )
  end

  defp review_card_captured?(browser_ui_capture) do
    map_value(browser_ui_capture, :review_card_captured?) == true
  end

  defp review_decision_captured?(browser_ui_capture) do
    review_card_captured?(browser_ui_capture) and
      map_value(browser_ui_capture, :review_decision_captured?) == true
  end

  defp progress_capture_value(browser_ui_capture, key) do
    active_key =
      key
      |> Atom.to_string()
      |> then(&:"active_progress_#{&1}")

    map_value(browser_ui_capture, active_key) ||
      browser_ui_capture
      |> map_value(:terminal_wait_state)
      |> map_value(:planEvidence)
      |> map_value(key)
  end

  defp completion_proof_check(evidence) do
    visible_state = evidence.visible_state
    proof = Map.get(visible_state, :completion_proof, %{})
    task_shape = Map.get(evidence, :task_shape) || "unspecified"
    completed? = map_value(proof, :completed?) == true
    terminal? = map_value(proof, :terminal?) == true
    evidence = completion_proof_check_evidence(proof, task_shape, completed?, terminal?)

    cond do
      completed? and completion_proof_satisfies_task_shape?(proof, task_shape) ->
        %{
          id: "completion_proof_visible",
          status: "pass",
          message: "Mode-appropriate completion proof captured",
          evidence: evidence
        }

      completed? ->
        %{
          id: "completion_proof_visible",
          status: "fail",
          message: "Completed session is missing mode-appropriate proof",
          evidence: evidence
        }

      terminal? ->
        %{
          id: "completion_proof_visible",
          status: "pass",
          message: "Session ended without completion; completion proof not required",
          evidence: evidence
        }

      true ->
        %{
          id: "completion_proof_visible",
          status: "pass",
          message: "Session still running; completion proof pending",
          evidence: evidence
        }
    end
  end

  defp completion_proof_check_evidence(proof, task_shape, completed?, terminal?) do
    %{
      task_shape: task_shape,
      terminal?: terminal?,
      completed?: completed?,
      ready?: map_value(proof, :ready?),
      missing: map_value(proof, :missing) || [],
      proof_categories: map_value(proof, :proof_categories) || [],
      changed_file_count: map_value(proof, :changed_file_count),
      artifact_count: map_value(proof, :artifact_count),
      sandbox_execution_count: map_value(proof, :sandbox_execution_count),
      review_statuses: map_value(proof, :review_statuses) || [],
      final_output?: map_value(proof, :final_output?),
      scorecard_satisfied?: map_value(proof, :scorecard_satisfied?)
    }
  end

  defp completion_proof_satisfies_task_shape?(proof, task_shape) do
    map_value(proof, :ready?) == true and
      case to_string(task_shape) do
        "empty_app_creation" ->
          completion_changed_files?(proof) and completion_score_or_sandbox?(proof)

        "existing_app_feature" ->
          completion_changed_files?(proof) and completion_score_or_sandbox?(proof)

        "refactor" ->
          completion_changed_files?(proof) and completion_score_or_sandbox?(proof)

        "research_report" ->
          completion_artifact_or_changed_files?(proof)

        "denied_tool_review" ->
          map_value(proof, :denied_review?) == true and map_value(proof, :final_output?) == true

        _other ->
          map_value(proof, :scorecard_satisfied?) == true or
            completion_changed_files?(proof) or completion_artifact_or_changed_files?(proof) or
            map_value(proof, :denied_review?) == true
      end
  end

  defp completion_changed_files?(proof),
    do: positive_count?(map_value(proof, :changed_file_count))

  defp completion_artifact_or_changed_files?(proof) do
    completion_changed_files?(proof) or positive_count?(map_value(proof, :artifact_count))
  end

  defp completion_score_or_sandbox?(proof) do
    map_value(proof, :scorecard_satisfied?) == true or
      positive_count?(map_value(proof, :sandbox_execution_count))
  end

  defp positive_count?(value) when is_integer(value), do: value > 0
  defp positive_count?(_value), do: false

  defp repair_failure_injection_check(browser_ui_capture) do
    if map_value(browser_ui_capture, :repair_failure_injection_enabled?) == true do
      ui_check(
        "browser_repair_failure_observed",
        map_value(browser_ui_capture, :repair_failure_injected?) == true and
          map_value(browser_ui_capture, :repair_failure_observed?) == true,
        "Browser repair follow-up had concrete failing smoke evidence",
        "Browser repair follow-up did not capture a failing smoke before repair",
        %{
          status: map_value(browser_ui_capture, :status),
          injected_failure_state: map_value(browser_ui_capture, :injected_failure_state)
        }
      )
    else
      ui_check(
        "browser_repair_failure_not_required",
        true,
        "Browser repair failure injection not required for this scenario",
        "Browser repair failure injection unexpectedly required",
        %{status: map_value(browser_ui_capture, :status)}
      )
    end
  end

  defp review_decision_check(browser_ui_capture) do
    if map_value(browser_ui_capture, :review_decision_required?) == true do
      ui_check(
        "browser_review_decision_captured",
        map_value(browser_ui_capture, :review_card_captured?) == true and
          map_value(browser_ui_capture, :review_decision_captured?) == true,
        "Browser review card and approval decision captured",
        "Browser review-card approval was required but not captured",
        %{
          status: map_value(browser_ui_capture, :status),
          review_decision_state: map_value(browser_ui_capture, :review_decision_state)
        }
      )
    else
      ui_check(
        "browser_review_decision_not_required",
        true,
        "Browser review decision not required for this scenario",
        "Browser review decision unexpectedly required",
        %{status: map_value(browser_ui_capture, :status)}
      )
    end
  end

  defp browser_follow_up_check(browser_ui_capture) do
    required? = map_value(browser_ui_capture, :browser_follow_up_required?) == true

    ui_check(
      "browser_follow_up_captured",
      not required? or map_value(browser_ui_capture, :browser_follow_up_captured?) == true,
      if(required?,
        do: "Browser follow-up interaction captured",
        else: "Browser follow-up interaction not required for this scenario"
      ),
      "Browser follow-up interaction was not driven after initial launch",
      %{
        required?: required?,
        status: map_value(browser_ui_capture, :status),
        follow_up_state: map_value(browser_ui_capture, :follow_up_state)
      }
    )
  end

  defp tidewave_interaction_check(browser_ui_capture) do
    required? = map_value(browser_ui_capture, :browser_follow_up_required?) == true

    ui_check(
      "tidewave_interaction_captured",
      not required? or map_value(browser_ui_capture, :tidewave_interaction_captured?) == true,
      if(required?,
        do: "Tidewave web interaction captured",
        else: "Tidewave follow-up interaction not required for this scenario"
      ),
      "Tidewave/browser follow-up interaction is not driven by the browser probe",
      %{required?: required?, status: map_value(browser_ui_capture, :status)}
    )
  end

  defp browser_visible_state(nil) do
    %{
      session_status: nil,
      selected_agent: nil,
      message_count: 0,
      event_count: 0,
      tool_call_count: 0,
      run_count: 0,
      review_request_count: 0,
      artifact_count: 0,
      scorecard_count: 0,
      event_phases: [],
      event_statuses: [],
      run_statuses: [],
      review_statuses: [],
      artifact_paths: [],
      tool_names: [],
      final_output_preview: nil,
      completion_proof: %{},
      objective_contract_present?: false,
      objective_contract_requirement_count: 0,
      objective_contract_evidence_required: [],
      blocked_evidence_present?: false,
      blocked_current_node: nil,
      next_action_count: 0,
      progress_summary_present?: false,
      progress_event_count: 0,
      latest_progress_title: nil,
      progress_current_node: nil,
      progress_remaining_ms: nil
    }
  end

  defp browser_visible_state(snapshot) do
    metrics = Map.get(snapshot, :metrics, %{})
    objective_contract = Map.get(snapshot, :objective_contract)
    blocked_evidence = Map.get(snapshot, :blocked_evidence)
    completion_proof = Map.get(snapshot, :completion_proof, %{})
    progress_summary = Map.get(snapshot, :progress_summary)
    final_message = final_message_map(snapshot)

    %{
      session_status: get_in(snapshot, [:session, :status]),
      selected_agent: get_in(snapshot, [:session, :agent]),
      message_count: metric(metrics, :messages, snapshot.messages),
      event_count: metric(metrics, :events, snapshot.events),
      tool_call_count: metric(metrics, :tool_calls, snapshot.tool_calls),
      run_count: metric(metrics, :runs, snapshot.runs),
      review_request_count: metric(metrics, :review_requests, snapshot.review_requests),
      artifact_count: metric(metrics, :artifacts, snapshot.artifacts),
      scorecard_count: metric(metrics, :scorecards, snapshot.scorecards),
      event_phases: compact_values(snapshot.events, :phase),
      event_statuses: compact_values(snapshot.events, :status),
      run_statuses: ordered_values(snapshot.runs, :status),
      review_statuses: compact_values(snapshot.review_requests, :status),
      artifact_paths: compact_values(snapshot.artifacts, :path),
      tool_names: compact_values(snapshot.tool_calls, :tool_name),
      final_output_preview: preview(final_message_text(final_message), 400),
      completion_proof: completion_proof,
      objective_contract_present?: not is_nil(objective_contract),
      objective_contract_requirement_count:
        objective_contract |> map_value(:requirements) |> List.wrap() |> length(),
      objective_contract_evidence_required:
        objective_contract |> map_value(:metadata) |> map_value(:evidence_required) |> List.wrap(),
      blocked_evidence_present?: not is_nil(blocked_evidence),
      blocked_current_node: map_value(blocked_evidence, :current_node),
      next_action_count:
        (map_value(blocked_evidence, :next_actions) ||
           final_message |> map_value(:content_json) |> map_value(:next_actions))
        |> List.wrap()
        |> length(),
      progress_summary_present?: is_map(progress_summary) and map_size(progress_summary) > 0,
      progress_event_count: map_value(progress_summary, :event_count) || 0,
      latest_progress_title: progress_summary |> map_value(:latest_event) |> map_value(:title),
      progress_current_node: map_value(progress_summary, :current_node),
      progress_remaining_ms: map_value(progress_summary, :remaining_ms)
    }
  end

  defp launch_summary(launch) do
    %{
      session_id: map_value(launch, :session_id),
      agent: map_value(launch, :agent),
      cwd: map_value(launch, :cwd),
      approve: map_value(launch, :approve),
      mode: map_value(launch, :mode),
      profile: map_value(launch, :profile),
      model: map_value(launch, :model),
      client: map_value(launch, :client),
      objective_preview: preview(map_value(launch, :objective), 500)
    }
  end

  defp put_browser_model(launch, nil), do: launch

  defp put_browser_model(launch, model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        launch
        |> Map.put("model", model)
        |> Map.put("model_provider", provider)
        |> Map.put("model_id", model_id)

      _other ->
        Map.put(launch, "model", model)
    end
  end

  defp maybe_capture_browser_ui(
         _session_id,
         _workspace,
         _scenario,
         _opts,
         existing_browser_ui_capture
       )
       when is_map(existing_browser_ui_capture) do
    normalize_browser_ui_capture(existing_browser_ui_capture, %{
      session_url: map_value(existing_browser_ui_capture, :session_url)
    })
  end

  defp maybe_capture_browser_ui(
         session_id,
         workspace,
         scenario,
         opts,
         _existing_browser_ui_capture
       ) do
    if Keyword.get(opts, :browser_ui_capture?, false) do
      output_dir = Path.join(workspace.root, "tmp/browser-ui")
      File.mkdir_p!(output_dir)

      request = %{
        session_id: session_id,
        session_url: workbench_session_url(session_id, opts),
        scenario_id: scenario.id,
        scenario_title: scenario.title,
        workspace_root: workspace.root,
        output_dir: output_dir
      }

      case Keyword.get(opts, :browser_ui_capture_fun) do
        fun when is_function(fun, 1) ->
          request |> fun.() |> normalize_browser_ui_capture(request)

        _other ->
          capture_browser_ui_with_chrome(request, opts)
      end
    else
      %{
        enabled: false,
        status: "skipped",
        message: "browser UI capture disabled"
      }
    end
  end

  defp launch_browser_ui(launch, workspace, scenario, opts) do
    output_dir = Path.join(workspace.root, "tmp/browser-ui-launch")
    File.mkdir_p!(output_dir)

    request = %{
      base_url: workbench_base_url(opts),
      launch: launch,
      follow_up_prompt: browser_follow_up_prompt(scenario),
      repair_failure_injection: browser_repair_failure_injection(scenario),
      review_decision: browser_review_decision(scenario),
      open_session_url: Keyword.get(opts, :browser_open_session_url),
      active_progress_capture_delay_ms:
        map_value(scenario.metadata, :active_progress_capture_delay_ms),
      active_progress_wait_ms:
        map_value(scenario.metadata, :active_progress_wait_ms) ||
          Keyword.get(opts, :browser_active_progress_wait_ms, 10_000),
      terminal_wait_ms:
        map_value(scenario.metadata, :browser_terminal_wait_ms) ||
          Keyword.get(opts, :browser_terminal_wait_ms, 90_000),
      active_progress_pre_final_required?:
        map_value(scenario.metadata, :active_progress_pre_final_required?) == true,
      final_inspector_tab: map_value(scenario.metadata, :final_inspector_tab),
      inspector_text_needle: map_value(scenario.metadata, :inspector_text_needle),
      scenario_id: scenario.id,
      scenario_title: scenario.title,
      workspace_root: workspace.root,
      session_url: Keyword.get(opts, :browser_open_session_url),
      output_dir: output_dir
    }

    case Keyword.get(opts, :browser_ui_launch_fun) do
      fun when is_function(fun, 1) ->
        request |> fun.() |> normalize_browser_ui_capture(request)

      _other ->
        launch_browser_ui_with_cdp(request, opts)
    end
  end

  defp launch_browser_ui_with_cdp(request, opts) do
    with {:ok, node} <- node_executable(),
         {:ok, chrome} <- chrome_executable_result(opts) do
      request_path = Path.join(request.output_dir, "browser-ui-request.json")

      request =
        request
        |> Map.put(:chrome_executable, chrome)
        |> Map.put(:timeout_ms, Keyword.get(opts, :browser_capture_timeout_ms, 30_000))

      File.write!(request_path, Jason.encode!(request, pretty: true))

      script_path = Path.expand("priv/robustness/browser_ui_runner.js", File.cwd!())
      timeout_ms = browser_ui_process_timeout_ms(request, opts)
      {output, status} = run_with_timeout(node, [script_path, request_path], timeout_ms)

      case decode_last_json(output) do
        {:ok, decoded} ->
          decoded
          |> Map.put_new("exit_status", status)
          |> normalize_browser_ui_capture(request)

        :error ->
          %{
            enabled: true,
            status: "failed",
            base_url: request.base_url,
            message: "browser UI CDP runner failed",
            exit_status: status,
            raw_output_path: write_raw_browser_output!(request.output_dir, output),
            error_preview: preview(output, 800)
          }
      end
    else
      {:error, message} ->
        %{
          enabled: true,
          status: "missing_runtime",
          base_url: request.base_url,
          message: message
        }
    end
  end

  defp browser_ui_process_timeout_ms(request, opts) do
    base = Keyword.get(opts, :browser_capture_timeout_ms, 30_000)
    active_wait = map_value(request, :active_progress_wait_ms) |> normalize_wait_ms(10_000)
    terminal_wait = map_value(request, :terminal_wait_ms) |> normalize_wait_ms(30_000)

    if is_binary(map_value(request, :follow_up_prompt)) do
      base * 2 + active_wait + terminal_wait + 20_000
    else
      base + active_wait + terminal_wait + 10_000
    end
  end

  defp capture_browser_ui_with_chrome(request, opts) do
    case chrome_executable(opts) do
      nil ->
        %{
          enabled: true,
          status: "missing_browser",
          session_url: request.session_url,
          message: "google-chrome/chromium executable not found"
        }

      chrome ->
        do_capture_browser_ui_with_chrome(chrome, request, opts)
    end
  end

  defp do_capture_browser_ui_with_chrome(chrome, request, opts) do
    prefix = safe_label(request.scenario_id)
    html_path = Path.join(request.output_dir, "#{prefix}-session.html")
    dom_snapshot_path = Path.join(request.output_dir, "#{prefix}-session-dom.txt")
    screenshot_path = Path.join(request.output_dir, "#{prefix}-session.png")
    raw_output_path = Path.join(request.output_dir, "#{prefix}-chrome-output.txt")
    profile_dir = Path.join(request.output_dir, "chrome-profile")
    File.mkdir_p!(profile_dir)

    args = [
      "--headless=new",
      "--disable-gpu",
      "--no-sandbox",
      "--disable-background-networking",
      "--disable-sync",
      "--disable-extensions",
      "--hide-scrollbars",
      "--window-size=1440,1000",
      "--user-data-dir=#{profile_dir}",
      "--screenshot=#{screenshot_path}",
      "--dump-dom",
      request.session_url
    ]

    timeout_ms = Keyword.get(opts, :browser_capture_timeout_ms, 20_000)

    case run_with_timeout(chrome, args, timeout_ms) do
      {output, 0} ->
        html = extract_html(output)
        File.write!(raw_output_path, output)
        File.write!(html_path, html)
        File.write!(dom_snapshot_path, RunicAI.Web.html_to_markdown(html))

        %{
          enabled: true,
          status: "ok",
          session_url: request.session_url,
          html_path: html_path,
          dom_snapshot_path: dom_snapshot_path,
          screenshot_path: existing_path(screenshot_path),
          raw_output_path: raw_output_path,
          screenshot_byte_size: file_size(screenshot_path),
          console_captured?: false,
          tidewave_interaction_captured?: false,
          chrome_executable: chrome
        }

      {output, status} ->
        File.write!(raw_output_path, output)

        %{
          enabled: true,
          status: "failed",
          session_url: request.session_url,
          raw_output_path: raw_output_path,
          exit_status: status,
          error_preview: preview(output, 800),
          console_captured?: false,
          tidewave_interaction_captured?: false,
          chrome_executable: chrome
        }
    end
  end

  defp normalize_browser_ui_capture(result, request) when is_map(result) do
    result
    |> Map.put_new(:enabled, true)
    |> Map.put_new(:status, "ok")
    |> Map.put_new(
      :session_url,
      map_value(request, :session_url) || map_value(request, :base_url)
    )
    |> capture_put_new(:console_captured?, false)
    |> capture_put_new(:network_captured?, false)
    |> capture_put_new(:ui_launch_captured?, false)
    |> capture_put_new(:plan_visibility_captured?, false)
    |> capture_put_new(:workflow_stage_plan_visible?, false)
    |> capture_put_new(:live_progress_visible?, false)
    |> capture_put_new(:active_progress_snapshot_captured?, false)
    |> capture_put_new(:active_progress_current_context_visible?, false)
    |> capture_put_new(:active_progress_child_visible?, false)
    |> capture_put_new(:active_progress_remaining_visible?, false)
    |> capture_put_new(:active_progress_budget_visible?, false)
    |> capture_put_new(:active_progress_pre_final_visible?, false)
    |> capture_put_new(:active_progress_pre_final_required?, false)
    |> capture_put_new(:repair_failure_injection_enabled?, false)
    |> capture_put_new(:repair_failure_injected?, false)
    |> capture_put_new(:repair_failure_observed?, false)
    |> capture_put_new(:review_decision_required?, false)
    |> capture_put_new(:review_card_captured?, false)
    |> capture_put_new(:review_decision_captured?, false)
    |> capture_put_new(:browser_follow_up_required?, false)
    |> capture_put_new(:browser_follow_up_captured?, false)
    |> capture_put_new(:tidewave_interaction_captured?, false)
  end

  defp normalize_browser_ui_capture(result, request) do
    %{
      enabled: true,
      status: "failed",
      session_url: request.session_url,
      message: "browser_ui_capture_fun returned #{inspect(result, limit: 20)}"
    }
  end

  defp chrome_executable(opts) do
    Keyword.get(opts, :browser_executable) ||
      System.find_executable("google-chrome") ||
      System.find_executable("google-chrome-stable") ||
      System.find_executable("chromium") ||
      System.find_executable("chromium-browser")
  end

  defp chrome_executable_result(opts) do
    case chrome_executable(opts) do
      nil -> {:error, "google-chrome/chromium executable not found"}
      executable -> {:ok, executable}
    end
  end

  defp node_executable do
    case System.find_executable("node") do
      nil -> {:error, "node executable not found"}
      executable -> {:ok, executable}
    end
  end

  defp capture_put_new(map, key, default) do
    if is_nil(map_value(map, key)) do
      Map.put(map, key, default)
    else
      map
    end
  end

  defp run_with_timeout(command, args, timeout_ms) do
    timeout = System.find_executable("timeout")

    if timeout && is_integer(timeout_ms) && timeout_ms > 0 do
      seconds = timeout_ms |> div(1_000) |> max(1)
      System.cmd(timeout, ["#{seconds}s", command | args], stderr_to_stdout: true)
    else
      System.cmd(command, args, stderr_to_stdout: true)
    end
  end

  defp extract_html(output) when is_binary(output) do
    case Regex.run(~r/(<!DOCTYPE html[\s\S]*|<html[\s\S]*)/i, output) do
      [html | _] -> html
      _other -> output
    end
  end

  defp existing_path(path) do
    if File.exists?(path), do: path
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
    end
  end

  defp capture_file_exists?(capture, key) do
    case map_value(capture, key) do
      path when is_binary(path) ->
        case File.stat(path) do
          {:ok, %{size: size}} when size > 0 -> true
          _other -> false
        end

      _other ->
        false
    end
  end

  defp decode_last_json(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      case Jason.decode(line) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        _other -> nil
      end
    end)
  end

  defp write_raw_browser_output!(output_dir, output) do
    path = Path.join(output_dir, "browser-ui-runner-output.txt")
    File.write!(path, output)
    path
  end

  defp workbench_session_url(session_id, opts) do
    base_uri = opts |> workbench_base_url() |> URI.parse()

    base_uri
    |> Map.put(:path, "/sessions/#{URI.encode_www_form(session_id)}")
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp workbench_base_url(opts) do
    (Keyword.get(opts, :browser_workbench_url) ||
       :runic_ai
       |> Application.get_env(:workbench, [])
       |> Keyword.get(:base_url, "http://localhost:4000"))
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp browser_follow_up_prompt(%ProjectScenario{} = scenario) do
    if map_value(scenario.metadata, :browser_follow_up?) == false do
      nil
    else
      metadata_prompt =
        case map_value(scenario.metadata, :browser_follow_up_prompt) do
          prompt when is_binary(prompt) and prompt != "" -> prompt
          _prompt -> nil
        end

      validation_task =
        Enum.find(scenario.browser_validation_tasks, fn task ->
          task |> String.downcase() |> String.contains?("follow-up")
        end) ||
          Enum.find(scenario.browser_validation_tasks, fn task ->
            task |> String.downcase() |> String.contains?("repair")
          end)

      [
        "Continue in this same session using the prior run evidence.",
        "Original objective: #{String.trim(scenario.prompt)}",
        metadata_prompt || validation_task ||
          "Inspect the previous run and repair missing acceptance evidence if needed.",
        "If the objective is already satisfied, summarize changed files, compile/test/runtime evidence, and residual risks instead of repeating a repository dump."
      ]
      |> Enum.join(" ")
    end
  end

  defp browser_repair_failure_injection(%ProjectScenario{} = scenario) do
    case map_value(scenario.metadata, :browser_repair_failure_injection) do
      injection when is_map(injection) -> injection
      _other -> nil
    end
  end

  defp browser_review_decision(%ProjectScenario{} = scenario) do
    case map_value(scenario.metadata, :browser_review_decision) do
      decision when is_map(decision) -> decision
      _other -> nil
    end
  end

  defp browser_review_prelaunch?(%ProjectScenario{} = scenario) do
    map_value(scenario.metadata, :browser_review_prelaunch?) == true
  end

  defp browser_approval_policy(%ProjectScenario{} = scenario) do
    case map_value(scenario.metadata, :browser_approval) do
      policy when policy in ["ask", "safe", "never", "approve", "always", "all"] ->
        policy

      policy when policy in [:ask, :safe, :never, :approve, :always, :all] ->
        Atom.to_string(policy)

      _other ->
        "safe"
    end
  end

  defp browser_mode(%ProjectScenario{} = scenario) do
    case map_value(scenario.metadata, :browser_mode) do
      mode when mode in ["patch", "verify", "read_only"] -> mode
      mode when mode in [:patch, :verify, :read_only] -> Atom.to_string(mode)
      _other -> "patch"
    end
  end

  defp browser_max_objective_iterations(%ProjectScenario{} = scenario) do
    case map_value(scenario.metadata, :browser_max_objective_iterations) do
      value when is_integer(value) and value > 0 -> Integer.to_string(value)
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp browser_toolsets(%ProjectScenario{} = scenario) do
    scenario.metadata
    |> map_value(:browser_toolsets)
    |> case do
      values when is_list(values) -> Enum.join(values, ",")
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp browser_tool_config(%ProjectScenario{} = scenario) do
    case map_value(scenario.metadata, :browser_tool_config) do
      config when is_binary(config) -> config
      config when is_map(config) -> flatten_browser_tool_config(config) |> Enum.join(",")
      _other -> ""
    end
  end

  defp flatten_browser_tool_config(config, prefix \\ nil) do
    Enum.flat_map(config, fn {key, value} ->
      key = if prefix, do: "#{prefix}.#{key}", else: to_string(key)

      if is_map(value) do
        flatten_browser_tool_config(value, key)
      else
        ["#{key}=#{value}"]
      end
    end)
  end

  defp metric(metrics, key, fallback) do
    value = map_value(metrics, key)

    cond do
      is_integer(value) -> value
      is_list(fallback) -> length(fallback)
      true -> 0
    end
  end

  defp compact_values(items, key) when is_list(items) do
    items
    |> Enum.map(&map_value(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp compact_values(_items, _key), do: []

  defp ordered_values(items, key) when is_list(items) do
    items
    |> Enum.map(&map_value(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp ordered_values(_items, _key), do: []

  defp preview(nil, _limit), do: nil

  defp preview(value, limit) do
    value
    |> to_string()
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp base_evidence(%ProjectScenario{} = scenario, lane, workspace, deterministic, lane_result) do
    %{
      scenario_id: scenario.id,
      lane: lane,
      lane_status: Map.get(lane_result, :lane_status),
      expected_lane_status: expected_lane_status(scenario),
      workspace: workspace.root,
      deterministic: deterministic,
      deterministic_failures: deterministic_failure_summaries(deterministic),
      final_output: Map.get(lane_result, :final_output),
      agent_result: Map.get(lane_result, :run_result),
      objective_loop: Map.get(lane_result, :objective_loop),
      jsonl_path: Map.get(lane_result, :jsonl_path),
      event_trail_path: Map.get(lane_result, :event_trail_path),
      event_trail_summary: Map.get(lane_result, :event_trail_summary),
      browser_snapshot: Map.get(lane_result, :browser_snapshot),
      failure_attribution: Map.get(lane_result, :failure_attribution, no_failure_attribution()),
      browser_evidence_path: Map.get(lane_result, :browser_evidence_path),
      browser_ui_checks: Map.get(lane_result, :browser_ui_checks, []),
      repair_count: repair_count(lane_result),
      repair_summary: Map.get(lane_result, :repair_summary),
      ui_gaps: Map.get(lane_result, :ui_gaps, [])
    }
  end

  defp deterministic_failure_summaries(%{checks: checks}) when is_list(checks) do
    checks
    |> Enum.reject(&deterministic_check_passed_or_optional?/1)
    |> Enum.map(&deterministic_failure_summary/1)
  end

  defp deterministic_failure_summaries(_deterministic), do: []

  defp deterministic_check_passed_or_optional?(%{status: :pass}), do: true
  defp deterministic_check_passed_or_optional?(%{status: "pass"}), do: true

  defp deterministic_check_passed_or_optional?(%{status: status, details: details})
       when status in [:skipped, "skipped"] and is_map(details) do
    map_value(details, :optional?) == true
  end

  defp deterministic_check_passed_or_optional?(_check), do: false

  defp deterministic_failure_summary(result) when is_map(result) do
    check = map_value(result, :check) || %{}
    details = map_value(result, :details) || %{}

    %{
      id: map_value(check, :id),
      type: map_value(check, :type),
      status: map_value(result, :status),
      message: map_value(result, :message),
      target: deterministic_check_target(check),
      command: deterministic_check_command(check),
      output_preview: deterministic_output_preview(details),
      details: deterministic_failure_details(details)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp deterministic_check_target(check) when is_map(check) do
    cond do
      is_binary(map_value(check, :path)) -> map_value(check, :path)
      is_binary(map_value(check, :glob)) -> map_value(check, :glob)
      is_list(map_value(check, :paths)) -> Enum.join(map_value(check, :paths), ", ")
      is_integer(map_value(check, :min)) -> "min=#{map_value(check, :min)}"
      true -> nil
    end
  end

  defp deterministic_check_target(_check), do: nil

  defp deterministic_check_command(check) when is_map(check) do
    case map_value(check, :argv) do
      argv when is_list(argv) -> Enum.join(argv, " ")
      _other -> nil
    end
  end

  defp deterministic_check_command(_check), do: nil

  defp deterministic_output_preview(details) when is_map(details) do
    details
    |> map_value(:output)
    |> case do
      output when is_binary(output) and output != "" -> preview(output, 1_000)
      _other -> nil
    end
  end

  defp deterministic_output_preview(_details), do: nil

  defp deterministic_failure_details(details) when is_map(details) do
    details
    |> Map.take([
      :actual,
      :changed_files,
      :status,
      :stdout_excerpt,
      :stderr_excerpt,
      :warning_count
    ])
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp deterministic_failure_details(_details), do: %{}

  defp result(scenario, lane, workspace, deterministic, judge, evidence) do
    %{
      scenario_id: scenario.id,
      scenario_title: scenario.title,
      task_shape: scenario_task_shape(scenario),
      lane: lane,
      status: combined_status(deterministic, judge, evidence),
      workspace: workspace.root,
      deterministic: deterministic,
      judge: judge,
      evidence: evidence,
      report_path: nil
    }
  end

  defp error_result(%ProjectScenario{} = scenario, lane, %Error{} = error) do
    %{
      scenario_id: scenario.id,
      scenario_title: scenario.title,
      task_shape: scenario_task_shape(scenario),
      lane: lane,
      status: :error,
      workspace: nil,
      deterministic: %{status: :error, checks: []},
      judge: %{overall: "fail", blocking_failures: [error.message], scores: %{}, evidence: []},
      evidence: %{error: error.message},
      report_path: nil
    }
  end

  defp combined_status(deterministic, judge, evidence) do
    if expected_lane_status?(evidence) do
      do_combined_status(deterministic, judge, evidence)
    else
      if Map.get(evidence, :lane_status) in [
           :error,
           "error",
           :blocked,
           "blocked",
           :failed,
           "failed"
         ] do
        :fail
      else
        do_combined_status(deterministic, judge, evidence)
      end
    end
  end

  defp do_combined_status(%{status: :pass}, %{overall: "pass"}, evidence) do
    status = Map.get(evidence, :lane_status)

    cond do
      expected_lane_status?(evidence, status) -> :pass
      status in [:error, "error", :blocked, "blocked", :failed, "failed"] -> :fail
      status in [:skipped, "skipped"] -> :review
      true -> :pass
    end
  end

  defp do_combined_status(%{status: :pass}, %{overall: "fail"}, _evidence), do: :fail
  defp do_combined_status(%{status: :pass}, _judge, _evidence), do: :review
  defp do_combined_status(%{status: :review}, _judge, _evidence), do: :review
  defp do_combined_status(_deterministic, _judge, _evidence), do: :fail

  defp write_matrix!(path, results, opts) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, matrix_markdown(results, opts))

    json_path = Path.rootname(path) <> ".json"
    File.write!(json_path, Jason.encode!(results, pretty: true))
  end

  defp matrix_markdown(results, opts) do
    generated_at = DateTime.utc_now() |> DateTime.to_iso8601()
    live? = Keyword.get(opts, :live_agent_lanes?, false)

    rows =
      Enum.map(results, fn result ->
        [
          result.scenario_id,
          result.task_shape || "unspecified",
          result.lane,
          result.status,
          get_in(result, [:deterministic, :status]),
          get_in(result, [:judge, :overall]),
          get_in(result, [:deterministic, :passed]),
          get_in(result, [:deterministic, :failed]),
          get_in(result, [:evidence, :repair_count]) || 0,
          run_attempt_count(result),
          run_status_history(result),
          failure_layer(result),
          current_progress(result),
          evidence_path(result),
          main_gap(result)
        ]
        |> Enum.map(&to_string/1)
        |> Enum.join(" | ")
      end)

    """
    # RLM Robustness Matrix

    Generated: #{generated_at}

    Live agent lanes: #{live?}

    | Scenario | Task shape | Lane | Status | Deterministic | Judge | Passed | Failed | Repairs | Attempts | Run statuses | Failure layer | Current | Evidence | Main gap |
    | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- |
    #{Enum.map_join(rows, "\n", &("| " <> &1 <> " |"))}

    ## Notes

    - `standard`, `assistant`, and `rlm` lanes only execute real agents when
      `live_agent_lanes?` is enabled. Otherwise they still create isolated
      workspaces and run deterministic checks against the scaffold baseline.
    - `browser_tidewave` exercises the browser-owned Workbench path. With
      `--browser-ui-launch`, it launches through the rendered composer, submits
      a same-session follow-up, and records DOM, screenshot, console, network,
      Workbench projection, and final-output evidence. Without that flag, it
      records backend-visible Workbench state only.
    - Attempt counts, run-status history, and failure-layer attribution remain
      visible when a later same-session attempt recovers an earlier failure.
    """
  end

  defp scenario_task_shape(%ProjectScenario{} = scenario) do
    scenario.metadata
    |> map_value(:task_shape)
    |> case do
      nil -> "unspecified"
      value -> to_string(value)
    end
  end

  defp expected_lane_status(%ProjectScenario{} = scenario) do
    scenario.metadata
    |> map_value(:expected_lane_status)
    |> case do
      nil -> nil
      status -> to_string(status)
    end
  end

  defp expected_lane_status?(evidence) do
    expected_lane_status?(evidence, Map.get(evidence, :lane_status))
  end

  defp expected_lane_status?(evidence, status) do
    expected = Map.get(evidence, :expected_lane_status)
    is_binary(expected) and expected != "" and to_string(status) == expected
  end

  defp main_gap(result) do
    case get_in(result, [:evidence, :deterministic_failures]) do
      [failure | _rest] ->
        deterministic_main_gap(failure)

      _other ->
        result
        |> get_in([:judge, :blocking_failures])
        |> List.wrap()
        |> List.first()
        |> case do
          nil -> "none"
          gap -> gap
        end
    end
  end

  defp deterministic_main_gap(failure) when is_map(failure) do
    [
      "deterministic #{map_value(failure, :type)} failed",
      map_value(failure, :target),
      map_value(failure, :command),
      map_value(failure, :message)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(": ")
  end

  defp deterministic_main_gap(_failure), do: "deterministic acceptance check failed"

  defp current_progress(result) do
    summary = get_in(result, [:evidence, :event_trail_summary]) || %{}
    latest = Map.get(summary, :latest_progress) || Map.get(summary, "latest_progress")

    cond do
      is_map(latest) and latest[:node_id] ->
        "#{latest[:stage]} #{latest[:node_id]}"

      is_map(latest) and latest["node_id"] ->
        "#{latest["stage"]} #{latest["node_id"]}"

      is_map(latest) and (latest[:stage] || latest["stage"]) ->
        to_string(latest[:stage] || latest["stage"])

      true ->
        "none"
    end
  end

  defp run_attempt_count(result) do
    get_in(result, [:evidence, :browser_snapshot, :run_count]) || 0
  end

  defp run_status_history(result) do
    result
    |> get_in([:evidence, :browser_snapshot, :run_statuses])
    |> List.wrap()
    |> Enum.join(" -> ")
    |> case do
      "" -> "none"
      history -> history
    end
  end

  defp failure_layer(result) do
    attribution = get_in(result, [:evidence, :failure_attribution]) || %{}
    layer = map_value(attribution, :layer) || "none"

    if map_value(attribution, :recovered?) == true do
      "#{layer} (recovered)"
    else
      to_string(layer)
    end
  end

  defp evidence_path(result) do
    event_path = get_in(result, [:evidence, :event_trail_path])
    browser_path = get_in(result, [:evidence, :browser_evidence_path])

    cond do
      is_binary(event_path) -> Path.relative_to_cwd(event_path)
      is_binary(browser_path) -> Path.relative_to_cwd(browser_path)
      true -> "none"
    end
  end

  defp matrix_path(opts) do
    label = Keyword.get(opts, :run_label, default_label())

    Path.join(
      File.cwd!(),
      "tmp/rlm_robustness/reports/rlm-robustness-matrix-#{safe_label(label)}.md"
    )
  end

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, _flag, ""), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, to_string(value)]

  defp proposal_timeout_args(_scenario, lane, _opts) when lane != :rlm, do: []

  defp proposal_timeout_args(scenario, :rlm, opts) do
    timeout_ms =
      Keyword.get(opts, :proposal_timeout_ms) ||
        default_proposal_timeout_ms(scenario, opts)

    if is_integer(timeout_ms) and timeout_ms > 0 do
      ["--proposal-timeout-ms", Integer.to_string(timeout_ms)]
    else
      []
    end
  end

  defp default_proposal_timeout_ms(scenario, opts) do
    runtime_ms =
      Keyword.get(opts, :max_runtime_ms) ||
        get_in(scenario.budgets, [:max_runtime_ms])

    if is_integer(runtime_ms) and runtime_ms > 0 do
      runtime_ms
      |> div(3)
      |> max(10_000)
      |> min(45_000)
    end
  end

  defp append_trail(path, event, data) do
    File.mkdir_p!(Path.dirname(path))

    line =
      %{
        at: DateTime.utc_now() |> DateTime.to_iso8601(),
        event: event,
        data: data
      }
      |> Jason.encode!()

    File.write!(path, line <> "\n", [:append])
  end

  defp emit_progress(opts, %ProjectScenario{} = scenario, lane, event, data) do
    case Keyword.get(opts, :progress_sink) do
      sink when is_function(sink, 1) ->
        sink.(%{
          scenario_id: scenario.id,
          lane: lane,
          event: event,
          at: DateTime.utc_now(),
          data: data
        })

      _other ->
        :ok
    end
  end

  defp summarize_event_trail(path) do
    if is_binary(path) and File.exists?(path) do
      events =
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, event} -> [event]
            {:error, _reason} -> []
          end
        end)

      %{
        event_count: length(events),
        latest_progress: latest_progress(events)
      }
    else
      %{event_count: 0, latest_progress: nil}
    end
  end

  defp latest_progress(events) do
    parsed =
      events
      |> Enum.reverse()
      |> Enum.flat_map(fn
        %{"event" => "terminal_output", "data" => %{"line" => line}} when is_binary(line) ->
          case parse_progress_line(line) do
            nil -> []
            progress -> [progress]
          end

        _event ->
          []
      end)

    Enum.find(parsed, &(not is_nil(&1.node_id) and &1.status in ["blocked", "error"])) ||
      Enum.find(parsed, &(not is_nil(&1.node_id) and meaningful_progress?(&1))) ||
      Enum.find(parsed, &meaningful_progress?/1) ||
      List.first(parsed)
  end

  defp meaningful_progress?(%{stage: stage})
       when stage in [
              nil,
              "final",
              "run",
              "session",
              "failed",
              "execution_completed",
              "proposed",
              "validated",
              "compiled"
            ],
       do: false

  defp meaningful_progress?(_progress), do: true

  defp parse_progress_line(line) do
    stage =
      case Regex.run(~r/\s\S+\/([a-zA-Z0-9_]+)\s/, line) do
        [_match, value] -> value
        _other -> nil
      end

    node_id = parse_node_id(line)

    status =
      case Regex.run(~r/\]\s+([A-Z]+)/, line) do
        [_match, value] -> String.downcase(value)
        _other -> nil
      end

    if stage || node_id || status do
      %{stage: stage, node_id: node_id, status: status}
    end
  end

  defp parse_node_id(line) do
    cond do
      match = Regex.run(~r/node_id:\s+"([^"]+)"/, line) ->
        List.last(match)

      match = Regex.run(~r/episode:([a-zA-Z0-9_\-.]+)/, line) ->
        List.last(match)

      true ->
        nil
    end
  end

  defp inspect_result({:ok, result}), do: %{status: :ok, result: inspect(result, limit: 20)}
  defp inspect_result({:error, %Error{} = error}), do: %{status: :error, error: error.message}
  defp inspect_result(other), do: %{value: inspect(other, limit: 20)}

  defp lane_status({:ok, %{status: status}}), do: status
  defp lane_status({:ok, _result}), do: :ok
  defp lane_status({:error, _error}), do: :error

  defp terminal_repair_count({:ok, result}) do
    result
    |> terminal_repair_history()
    |> length()
  end

  defp terminal_repair_count(_result), do: 0

  defp terminal_repair_summary({:ok, result}) do
    %{
      repair_status: get_in(result, [:result, :repair_status]),
      repair_history: terminal_repair_history(result)
    }
  end

  defp terminal_repair_summary(_result), do: %{repair_status: nil, repair_history: []}

  defp terminal_repair_history(result) when is_map(result) do
    get_in(result, [:result, :repair_iterations]) ||
      get_in(result, [:result, :repair_history]) ||
      get_in(result, [:result, :context, :repair_attempts]) ||
      []
  end

  defp terminal_repair_history(_result), do: []

  defp repair_count(result) do
    case Map.get(result, :repair_count) do
      count when is_integer(count) ->
        count

      _other ->
        result
        |> Map.get(:run_result)
        |> repair_count_from_run_result()
    end
  end

  defp repair_count_from_run_result(run_result) do
    case run_result do
      %{repair_history: history} when is_list(history) -> length(history)
      _other -> 0
    end
  end

  defp status_from_snapshot(nil), do: :error
  defp status_from_snapshot(%{session: %{status: status}}), do: status
  defp status_from_snapshot(_snapshot), do: :unknown

  defp browser_probe_final_output(snapshot, browser_evidence) do
    final_message_text(snapshot) ||
      browser_evidence
      |> map_value(:visible_state)
      |> map_value(:final_output_preview)
  end

  defp final_message_text(nil), do: nil
  defp final_message_text(%{content: content}), do: content
  defp final_message_text(message) when is_map(message), do: map_value(message, :content)

  defp final_message_text(snapshot), do: snapshot |> final_message_map() |> final_message_text()

  defp final_message_map(nil), do: nil

  defp final_message_map(%{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      if message.role in ["assistant", :assistant], do: message
    end)
  end

  defp summarize_snapshot(nil), do: %{}

  defp summarize_snapshot(snapshot) do
    run_statuses = ordered_values(snapshot.runs, :status)

    %{
      session: snapshot.session,
      message_count: length(snapshot.messages),
      event_count: length(snapshot.events),
      review_count: length(snapshot.review_requests),
      artifact_count: length(snapshot.artifacts),
      run_count: length(snapshot.runs),
      run_statuses: run_statuses,
      failed_run_count: Enum.count(run_statuses, &(&1 in ["failed", "error"])),
      completed_run_count:
        Enum.count(run_statuses, &(&1 in ["completed", "objective_satisfied"])),
      final_output: final_message_text(snapshot),
      objective_contract_present?: not is_nil(Map.get(snapshot, :objective_contract)),
      blocked_evidence_present?: not is_nil(Map.get(snapshot, :blocked_evidence))
    }
  end

  defp failure_attribution(nil), do: no_failure_attribution()

  defp failure_attribution(snapshot) do
    run_statuses = ordered_values(Map.get(snapshot, :runs, []), :status)
    failed_run_count = Enum.count(run_statuses, &(&1 in ["failed", "error"]))

    failure_events =
      snapshot
      |> Map.get(:events, [])
      |> Enum.filter(fn event ->
        map_value(event, :status) in ["failed", "error", :failed, :error] or
          map_value(event, :phase) in ["failed", :failed]
      end)

    failure_text =
      Enum.map_join(failure_events, " ", fn event ->
        [
          map_value(event, :title),
          map_value(event, :detail),
          map_value(event, :data_json)
        ]
        |> inspect(limit: 40, printable_limit: 2_000)
      end)

    session_status = get_in(snapshot, [:session, :status])

    if failed_run_count == 0 and failure_events == [] do
      no_failure_attribution()
    else
      %{
        layer: classify_failure_layer(failure_text),
        recovered?: session_status in ["completed", "objective_satisfied"],
        failed_run_count: failed_run_count,
        run_statuses: run_statuses,
        summary: failure_text |> String.replace(~r/\s+/, " ") |> String.slice(0, 500)
      }
    end
  end

  defp no_failure_attribution do
    %{layer: :none, recovered?: false, failed_run_count: 0, run_statuses: [], summary: nil}
  end

  defp classify_failure_layer(text) do
    text = String.downcase(text)

    cond do
      String.contains?(text, ["workflowvalidator", "workflow validator", "validation_error"]) ->
        :validator

      String.contains?(text, ["rate limit", "ratelimit", "quota", "provider", "reqllm"]) ->
        :provider

      String.contains?(text, ["workflowcompiler", "workflow compiler", "compile proposal"]) ->
        :compiler

      String.contains?(text, ["scorecard", "acceptance", "verification", "proof"]) ->
        :proof

      String.contains?(text, ["proposal", "planning", "planner"]) ->
        :planner

      String.contains?(text, ["browser", "liveview", "javascript", "dom", "ui "]) ->
        :ui

      true ->
        :runtime
    end
  end

  defp snapshot_repair_count(nil), do: 0

  defp snapshot_repair_count(snapshot) do
    snapshot
    |> Map.get(:events, [])
    |> Enum.count(fn event ->
      map_value(event, :kind) in ["repair", :repair] and
        map_value(event, :phase) in ["repair_attempt_completed", :repair_attempt_completed]
    end)
  end

  defp default_label do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
  end

  defp safe_label(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
