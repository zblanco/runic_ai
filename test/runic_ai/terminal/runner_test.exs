defmodule RunicAI.Terminal.RunnerTest do
  use ExUnit.Case, async: false

  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Error
  alias RunicAI.LLM.TestClient
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.ReviewRequest
  alias RunicAI.RLM.Episode
  alias RunicAI.Terminal.AgentRunner
  alias RunicAI.Terminal.AssistantRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.RLMRunner
  alias RunicAI.Terminal.StandardRunner

  test "standard runner executes a scripted standard-agent session and emits events" do
    Application.ensure_all_started(:runic_ai)
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    assert {:ok, result} =
             StandardRunner.run("Explain this empty repo.",
               cwd: root,
               mode: :read_only,
               model: "test:model",
               client: TestClient.client("This repo is empty."),
               objective_gate?: false,
               session_id: "terminal-standard-#{System.unique_integer([:positive])}",
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.agent == :standard
    assert result.status == :completed
    assert result.summary.reply == "This repo is empty."

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.title == "Standard agent started"))
    assert Enum.any?(emitted, &(&1.kind == :message))
  end

  test "RLM runner renders live stage events and final artifacts from a run function" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)
    caller = self()

    run_fun = fn _cwd, _objective, opts ->
      send(caller, {:rlm_runner_opts, opts[:session_id], opts[:run_id]})

      opts[:event_sink].(
        RunicAI.Event.new!(:rlm_node,
          session_id: opts[:session_id],
          run_id: opts[:session_id],
          agent: :rlm,
          phase: :legacy_stage,
          status: :running,
          title: "Legacy stage",
          data: %{"run_id" => opts[:session_id], run_id: opts[:session_id]}
        )
      )

      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :proposal_received,
        status: :ok,
        data: %{message: "proposal ready"}
      })

      {:ok, rlm_result()}
    end

    assert {:ok, result} =
             RLMRunner.run("Explain Demo",
               cwd: root,
               session_id: "terminal-rlm-session",
               run_id: "terminal-rlm-run",
               run_fun: run_fun,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.agent == :rlm
    assert result.status == :ok
    assert result.session_id == "terminal-rlm-session"
    assert result.run_id == "terminal-rlm-run"
    assert_receive {:rlm_runner_opts, "terminal-rlm-session", "terminal-rlm-run"}

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.phase == :proposal_received))
    assert Enum.any?(emitted, &(&1.phase == :proposed))

    assert Enum.any?(
             emitted,
             &(&1.kind == :message and &1.data["message_kind"] == "workflow_output" and
                 &1.data["content"] == "RLM visible final output.")
           )

    assert Enum.any?(emitted, &(&1.phase == :scorecard))
    assert Enum.all?(emitted, &(event_run_id(&1) == "terminal-rlm-run"))
  end

  test "RLM runner objective loop continues and emits objective summary events" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)
    caller = self()

    run_fun = fn _cwd, objective, opts ->
      iteration = Keyword.fetch!(opts, :objective_iteration)
      send(caller, {:objective_loop_iteration, iteration, objective})

      case iteration do
        1 ->
          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_incomplete},
             context: %{
               repair_needs: [
                 %{id: "tests", reason: "meaningful tests missing", target: "test_project"}
               ]
             }
           }}

        2 ->
          {:ok, rlm_result()}
      end
    end

    assert {:ok, result} =
             RLMRunner.run("Build OpsLogic",
               cwd: root,
               session_id: "terminal-rlm-objective-session",
               run_id: "terminal-rlm-objective-run",
               objective_loop?: true,
               max_objective_iterations: 3,
               run_fun: run_fun,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.status == :ok
    assert result.objective_session.status == :objective_satisfied
    assert result.objective_decision.action == :complete
    assert_receive {:objective_loop_iteration, 1, "Build OpsLogic"}
    assert_receive {:objective_loop_iteration, 2, repair_objective}
    assert repair_objective =~ "meaningful tests missing"

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &(&1.phase == :objective_loop_progress and
                 &1.title == "Objective iteration started" and
                 json_field(&1.data, :current_iteration) == 1)
           )

    assert Enum.any?(
             emitted,
             &(&1.phase == :objective_loop_progress and
                 &1.title == "Objective iteration completed" and
                 json_field(&1.data, :current_iteration) == 2 and
                 objective_progress_session_status(&1) in [
                   :objective_satisfied,
                   "objective_satisfied"
                 ])
           )

    assert Enum.any?(
             emitted,
             &(&1.phase == :objective_loop and &1.title == "Objective satisfied")
           )

    assert Enum.any?(emitted, &(&1.phase == :scorecard and &1.status == :ok))
  end

  test "RLM runner objective loop reports budget approval status" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, _objective, _opts ->
      {:ok,
       %{
         repair_status: :exhausted,
         objective_scorecard: %{objective_status: :objective_incomplete},
         context: %{
           repair_needs: [
             %{id: "compile", reason: "mix compile still fails", target: "compile_project"}
           ]
         }
       }}
    end

    assert {:ok, result} =
             RLMRunner.run("Build OpsLogic",
               cwd: root,
               objective_loop?: true,
               max_objective_iterations: 3,
               run_fun: run_fun,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.status == :needs_budget_approval
    assert result.objective_decision.action == :request_budget_approval

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &(&1.phase == :objective_loop and &1.status == :review and
                 &1.title == "Objective budget approval required")
           )
  end

  test "RLM runner objective loop summary includes latest error detail" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, _objective, _opts ->
      {:error, Error.timeout("RLM runtime budget exhausted", details: %{stage: :repair})}
    end

    assert {:ok, result} =
             RLMRunner.run("Build OpsLogic",
               cwd: root,
               objective_loop?: true,
               max_objective_iterations: 3,
               run_fun: run_fun,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.status == :needs_budget_approval
    assert result.objective_session.latest_error.kind == :timeout
    assert result.objective_decision.action == :request_budget_approval

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &(&1.phase == :objective_loop and
                 &1.title == "Objective budget approval required" and
                 &1.detail =~ "error: timeout: RLM runtime budget exhausted")
           )
  end

  test "RLM runner objective loop reports review approval status" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:terminal:plan",
        details: %{path: "tmp/ops_logic/PLAN.md"}
      )

    run_fun = fn _cwd, _objective, _opts ->
      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_satisfied},
         review_request: request,
         context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
       }}
    end

    assert {:ok, result} =
             RLMRunner.run("Plan OpsLogic",
               cwd: root,
               objective_loop?: true,
               max_objective_iterations: 3,
               run_fun: run_fun,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.status == :review
    assert result.objective_session.status == :needs_review_approval
    assert result.objective_decision.action == :request_review_approval
    assert result.objective_decision.request.resume_key == "review:terminal:plan"

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &(&1.phase == :objective_loop and &1.status == :review and
                 &1.title == "Objective review approval required" and
                 &1.data
                 |> Map.get(
                   :objective_session_state,
                   Map.get(&1.data, "objective_session_state", %{})
                 )
                 |> Map.get("status") == "needs_review_approval" and
                 &1.data
                 |> Map.get(:review_requests, Map.get(&1.data, "review_requests", []))
                 |> List.first()
                 |> Map.get("resume_key") == "review:terminal:plan")
           )
  end

  test "agent runner renders RLM final report with WorkflowScorecard structs" do
    root = tmp_dir()
    output = []
    caller = self()

    run_fun = fn _cwd, _objective, opts ->
      send(
        caller,
        {:rlm_agent_runner_opts, opts[:repair?], opts[:max_repair_iterations],
         opts[:seed_project_generation?]}
      )

      {:ok, rlm_result()}
    end

    {:ok, options} =
      CliOptions.parse([
        "Explain Demo",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn line ->
                 Process.put(:rlm_report_output, [line | Process.get(:rlm_report_output, output)])
               end
             )

    assert result.status == :ok
    assert_receive {:rlm_agent_runner_opts, true, nil, nil}

    rendered =
      :rlm_report_output
      |> Process.get([])
      |> Enum.reverse()
      |> Enum.join("\n")

    assert rendered =~ "Final report"
    assert rendered =~ "objective_satisfied"
  end

  test "agent runner derives role-specific RLM models and reasoning from tool config" do
    root = tmp_dir()
    caller = self()

    run_fun = fn _cwd, _objective, opts ->
      send(
        caller,
        {:rlm_role_opts, opts[:proposal_model], opts[:agent_model], opts[:agent_fallback_model],
         opts[:semantic_model], opts[:proposal_llm_opts], opts[:agent_llm_opts],
         opts[:agent_fallback_llm_opts], opts[:semantic_llm_opts], opts[:max_child_runtime_ms],
         opts[:child_noop_repair_attempts], opts[:agent_review_gates?]}
      )

      {:ok, rlm_result()}
    end

    {:ok, options} =
      CliOptions.parse([
        "Build a general Elixir library",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none",
        "--tool-config",
        "rlm.proposal_model=openai:gpt-5.6-sol",
        "--tool-config",
        "rlm.agent_model=openai:gpt-5.6-terra",
        "--tool-config",
        "rlm.agent_fallback_model=openai:gpt-5.6-sol",
        "--tool-config",
        "rlm.judge_model=openai:gpt-5.6-sol",
        "--tool-config",
        "rlm.proposal_reasoning_effort=high",
        "--tool-config",
        "rlm.proposal_max_completion_tokens=12000",
        "--tool-config",
        "rlm.agent_reasoning_effort=medium",
        "--tool-config",
        "rlm.agent_max_completion_tokens=16000",
        "--tool-config",
        "rlm.agent_fallback_reasoning_effort=high",
        "--tool-config",
        "rlm.agent_fallback_max_completion_tokens=16000",
        "--tool-config",
        "rlm.judge_reasoning_effort=high",
        "--tool-config",
        "rlm.judge_max_completion_tokens=8000",
        "--tool-config",
        "rlm.max_child_runtime_ms=240000",
        "--tool-config",
        "rlm.child_noop_repair_attempts=3"
      ])

    assert {:ok, _result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn _line -> :ok end
             )

    assert_receive {:rlm_role_opts, "openai:gpt-5.6-sol", "openai:gpt-5.6-terra",
                    "openai:gpt-5.6-sol", "openai:gpt-5.6-sol",
                    [max_completion_tokens: 12_000, reasoning_effort: :high],
                    [max_completion_tokens: 16_000, reasoning_effort: :medium],
                    [max_completion_tokens: 16_000, reasoning_effort: :high],
                    [max_completion_tokens: 8_000, reasoning_effort: :high], 240_000, 3, true}
  end

  test "agent runner avoids redundant child review gates after session-wide approval" do
    root = tmp_dir()
    caller = self()

    run_fun = fn _cwd, _objective, opts ->
      send(caller, {:child_review_gates, opts[:agent_review_gates?]})
      {:ok, rlm_result()}
    end

    {:ok, options} =
      CliOptions.parse([
        "Build a general library",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--approve",
        "always",
        "--cwd",
        root,
        "--persistence",
        "none"
      ])

    assert {:ok, _result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn _line -> :ok end
             )

    assert_receive {:child_review_gates, false}
  end

  test "agent runner passes objective-loop controls into the RLM runner" do
    root = tmp_dir()
    caller = self()

    run_fun = fn _cwd, objective, opts ->
      send(caller, {:agent_runner_objective_iteration, opts[:objective_iteration], objective})

      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_satisfied},
         context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
       }}
    end

    {:ok, options} =
      CliOptions.parse([
        "Build OpsLogic",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none",
        "--objective-loop",
        "--max-objective-iterations",
        "2"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn _line -> :ok end
             )

    assert result.status == :ok
    assert result.objective_session.status == :objective_satisfied
    assert_receive {:agent_runner_objective_iteration, 1, "Build OpsLogic"}
  end

  test "agent runner prompts and resumes RLM objective budget approvals" do
    root = tmp_dir()
    caller = self()
    {:ok, output} = Elixir.Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, objective, opts ->
      iteration = Keyword.fetch!(opts, :objective_iteration)
      send(caller, {:agent_runner_budget_iteration, iteration, objective})

      case iteration do
        1 ->
          {:ok,
           %{
             repair_status: :exhausted,
             objective_scorecard: %{objective_status: :objective_incomplete},
             context: %{
               repair_needs: [
                 %{id: "implementation", reason: "implementation still missing"}
               ]
             }
           }}

        2 ->
          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_satisfied},
             context: %{changed_files: ["tmp/ops_logic/lib/ops_logic.ex"]}
           }}
      end
    end

    {:ok, options} =
      CliOptions.parse([
        "Build OpsLogic",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none",
        "--objective-loop",
        "--max-objective-iterations",
        "1",
        "--approve",
        "ask"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               input_fun: fn _prompt ->
                 send(caller, :agent_runner_budget_prompted)
                 "approve\n"
               end,
               output_fun: fn line -> Elixir.Agent.update(output, &(&1 ++ [line])) end
             )

    assert result.status == :ok
    assert result.objective_session.status == :objective_satisfied
    assert result.objective_decision.action == :complete

    assert_receive {:agent_runner_budget_iteration, 1, "Build OpsLogic"}
    assert_receive {:agent_runner_budget_iteration, 2, resumed_objective}
    assert resumed_objective =~ "operator budget approval"
    assert_receive :agent_runner_budget_prompted

    rendered = output |> Elixir.Agent.get(& &1) |> Enum.join("\n")
    assert rendered =~ "Review required: objective_budget_approval"
    assert rendered =~ "repair budget exhausted before objective satisfaction"
    assert rendered =~ "Objective satisfied"
  end

  test "agent runner stops blocked when terminal objective budget approval is cancelled" do
    root = tmp_dir()
    caller = self()

    run_fun = fn _cwd, objective, opts ->
      iteration = Keyword.fetch!(opts, :objective_iteration)
      send(caller, {:agent_runner_budget_cancel_iteration, iteration, objective})

      {:ok,
       %{
         repair_status: :exhausted,
         objective_scorecard: %{objective_status: :objective_incomplete},
         context: %{
           repair_needs: [
             %{id: "implementation", reason: "implementation still missing"}
           ]
         }
       }}
    end

    {:ok, options} =
      CliOptions.parse([
        "Build OpsLogic",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none",
        "--objective-loop",
        "--max-objective-iterations",
        "1",
        "--approve",
        "ask"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               input_fun: fn _prompt ->
                 send(caller, :agent_runner_budget_cancel_prompted)
                 "stop\n"
               end,
               output_fun: fn _line -> :ok end
             )

    assert result.status == :blocked
    assert result.objective_session.status == :blocked
    assert result.objective_decision.action == :stop_blocked
    assert result.objective_session.max_iterations == 1
    assert length(result.objective_session.iterations) == 1
    assert [%{status: :cancelled}] = result.objective_session.budget_requests

    assert_receive {:agent_runner_budget_cancel_iteration, 1, "Build OpsLogic"}
    refute_receive {:agent_runner_budget_cancel_iteration, 2, _objective}, 100
    assert_receive :agent_runner_budget_cancel_prompted
  end

  test "agent runner reports when objective auto-resume approval limit is reached" do
    root = tmp_dir()
    jsonl_path = Path.join(root, "auto-resume-limit.jsonl")
    caller = self()
    {:ok, output} = Elixir.Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, objective, opts ->
      iteration = Keyword.fetch!(opts, :objective_iteration)
      send(caller, {:agent_runner_limit_iteration, iteration, objective})

      {:ok,
       %{
         repair_status: :exhausted,
         objective_scorecard: %{objective_status: :objective_incomplete},
         context: %{
           repair_needs: [
             %{id: "implementation", reason: "implementation still missing"}
           ]
         }
       }}
    end

    {:ok, options} =
      CliOptions.parse([
        "Build OpsLogic",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none",
        "--objective-loop",
        "--max-objective-iterations",
        "1",
        "--jsonl",
        jsonl_path,
        "--approve",
        "ask"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               max_objective_auto_resumes: 1,
               input_fun: fn _prompt ->
                 send(caller, :agent_runner_limit_prompted)
                 "approve\n"
               end,
               output_fun: fn line -> Elixir.Agent.update(output, &(&1 ++ [line])) end
             )

    assert result.status == :needs_budget_approval
    assert result.objective_auto_resume_exhausted?
    assert result.objective_resume_attempts == 1
    assert result.objective_resume_limit == 1
    assert result.objective_resume_kind == :budget

    assert_receive {:agent_runner_limit_iteration, 1, "Build OpsLogic"}
    assert_receive {:agent_runner_limit_iteration, 2, resumed_objective}
    assert resumed_objective =~ "operator budget approval"
    assert_receive :agent_runner_limit_prompted
    refute_receive :agent_runner_limit_prompted, 100

    rendered = output |> Elixir.Agent.get(& &1) |> Enum.join("\n")
    assert rendered =~ "Objective auto-resume limit reached"
    assert rendered =~ "objective resume: limit reached after 1/1 automatic budget resumes"

    events =
      jsonl_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(events, fn event ->
             get_in(event, ["phase"]) == "objective_loop_resume" and
               get_in(event, ["title"]) == "Objective auto-resume limit reached" and
               get_in(event, ["data", "objective_session", "status"]) ==
                 "needs_budget_approval" and
               get_in(event, ["data", "objective_decision", "action"]) ==
                 "request_budget_approval" and
               get_in(event, ["data", "budget_requests"]) != []
           end)

    assert Enum.any?(events, fn event ->
             get_in(event, ["phase"]) == "final" and
               get_in(event, ["data", "result_status"]) == "needs_budget_approval" and
               get_in(event, ["data", "objective_status"]) == "needs_budget_approval"
           end)
  end

  test "agent runner prompts and resumes RLM objective plan approvals" do
    root = tmp_dir()
    caller = self()
    {:ok, output} = Elixir.Agent.start_link(fn -> [] end)

    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:terminal:opslogic-plan",
        details: %{path: "tmp/ops_logic/PLAN.md", reason: "OpsLogic plan is ready"}
      )

    run_fun = fn _cwd, objective, opts ->
      iteration = Keyword.fetch!(opts, :objective_iteration)
      send(caller, {:agent_runner_review_iteration, iteration, objective})

      case iteration do
        1 ->
          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_satisfied},
             review_request: review_request,
             context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
           }}

        2 ->
          {:ok,
           %{
             objective_scorecard: %{objective_status: :objective_satisfied},
             context: %{changed_files: ["tmp/ops_logic/lib/ops_logic.ex"]}
           }}
      end
    end

    {:ok, options} =
      CliOptions.parse([
        "Plan and build OpsLogic",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none",
        "--objective-loop",
        "--max-objective-iterations",
        "3",
        "--approve",
        "ask"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               input_fun: fn _prompt ->
                 send(caller, :agent_runner_review_prompted)
                 "approve\n"
               end,
               output_fun: fn line -> Elixir.Agent.update(output, &(&1 ++ [line])) end
             )

    assert result.status == :ok
    assert result.objective_session.status == :objective_satisfied
    assert result.objective_decision.action == :complete

    assert_receive {:agent_runner_review_iteration, 1, "Plan and build OpsLogic"}
    assert_receive {:agent_runner_review_iteration, 2, resumed_objective}
    assert resumed_objective =~ "operator approval"
    assert_receive :agent_runner_review_prompted

    rendered = output |> Elixir.Agent.get(& &1) |> Enum.join("\n")
    assert rendered =~ "Review required: objective_plan_approval"
    assert rendered =~ "OpsLogic plan is ready"
    assert rendered =~ "Objective satisfied"
  end

  test "agent runner stops blocked when terminal objective plan approval is denied" do
    root = tmp_dir()
    caller = self()

    review_request =
      ReviewRequest.new!(:objective_plan_approval,
        checkpoint: :plan_review,
        resume_key: "review:terminal:opslogic-plan-deny",
        details: %{path: "tmp/ops_logic/PLAN.md", reason: "OpsLogic plan is ready"}
      )

    run_fun = fn _cwd, objective, opts ->
      iteration = Keyword.fetch!(opts, :objective_iteration)
      send(caller, {:agent_runner_review_deny_iteration, iteration, objective})

      {:ok,
       %{
         objective_scorecard: %{objective_status: :objective_satisfied},
         review_request: review_request,
         context: %{changed_files: ["tmp/ops_logic/PLAN.md"]}
       }}
    end

    {:ok, options} =
      CliOptions.parse([
        "Plan and build OpsLogic",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--persistence",
        "none",
        "--objective-loop",
        "--max-objective-iterations",
        "3",
        "--approve",
        "ask"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               input_fun: fn _prompt ->
                 send(caller, :agent_runner_review_denied_prompted)
                 "deny\n"
               end,
               output_fun: fn _line -> :ok end
             )

    assert result.status == :blocked
    assert result.objective_session.status == :blocked
    assert result.objective_decision.action == :stop_blocked
    assert length(result.objective_session.iterations) == 1
    assert [%{status: :rejected}] = result.objective_session.review_requests

    assert_receive {:agent_runner_review_deny_iteration, 1, "Plan and build OpsLogic"}
    refute_receive {:agent_runner_review_deny_iteration, 2, _objective}, 100
    assert_receive :agent_runner_review_denied_prompted
  end

  test "agent runner persists model/client preflight and passes resolved Codex model" do
    root = tmp_dir()
    jsonl_path = Path.join(root, "preflight.jsonl")
    caller = self()

    run_fun = fn _cwd, _objective, opts ->
      send(caller, {:resolved_launch, opts[:model], opts[:client_label], opts[:model_resolution]})
      {:ok, rlm_result()}
    end

    {:ok, options} =
      CliOptions.parse([
        "Explain Demo",
        "--agent",
        "rlm",
        "--mode",
        "patch",
        "--cwd",
        root,
        "--client",
        "codex",
        "--model",
        "openai:gpt-5.4-mini",
        "--jsonl",
        jsonl_path,
        "--persistence",
        "none"
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn _line -> :ok end
             )

    assert result.status == :ok

    assert_receive {:resolved_launch, nil, "codex", resolution}
    assert resolution.decision == "codex_account_default"
    assert resolution.effective_model == "codex-account-default"

    events =
      jsonl_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(
             events,
             &(get_in(&1, ["phase"]) == "model_client_preflight" and
                 get_in(&1, ["data", "model_resolution", "decision"]) ==
                   "codex_account_default")
           )
  end

  test "agent runner requires tool use for explicit standard command objectives" do
    root = tmp_dir()
    caller = self()

    client = fn _model, _prompt, opts ->
      send(caller, {:tool_choice, Keyword.get(opts, :tool_choice)})
      {:ok, TestClient.result("plain text fallback")}
    end

    {:ok, options} =
      CliOptions.parse([
        "Run this exact local command: printf runic_ai_required_tool",
        "--agent",
        "standard",
        "--cwd",
        root,
        "--profile",
        "local-workbench",
        "--persistence",
        "none"
      ])

    options = %{options | client: client, model: "test:model"}

    assert {:ok, _result} =
             AgentRunner.run(options,
               output_fun: fn _line -> :ok end
             )

    assert_receive {:tool_choice, :required}
  end

  test "assistant runner renders live stage events and final artifacts from a run function" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, _objective, opts ->
      opts[:event_sink].(
        RunicAI.Event.new!(:rlm_node,
          session_id: opts[:session_id],
          run_id: opts[:session_id],
          agent: :assistant,
          phase: :legacy_stage,
          status: :running,
          title: "Legacy assistant stage",
          data: %{"run_id" => opts[:session_id], run_id: opts[:session_id]}
        )
      )

      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :blueprint_proposed,
        status: :ok,
        data: %{message: "blueprint ready"}
      })

      {:ok, assistant_result()}
    end

    assert {:ok, result} =
             AssistantRunner.run("Summarize chapter",
               cwd: root,
               session_id: "terminal-assistant",
               run_id: "terminal-assistant-run",
               input_paths: ["chapter.md"],
               output_path: ".docs/chapter.md",
               run_fun: run_fun,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.agent == :assistant
    assert result.status == :ok

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.agent == :assistant and &1.phase == :blueprint_proposed))
    assert Enum.any?(emitted, &(&1.agent == :assistant and &1.phase == :proposed))
    assert Enum.any?(emitted, &(&1.agent == :assistant and &1.phase == :scorecard))
    assert Enum.all?(emitted, &(event_run_id(&1) == "terminal-assistant-run"))
  end

  test "agent runner writes matching live JSONL and SQLite terminal event counts" do
    root = tmp_dir()
    jsonl_path = Path.join(root, "trace.jsonl")
    sqlite_path = Path.join(root, "runs.db")

    run_fun = fn _cwd, _objective, opts ->
      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :node_started,
        status: :running,
        data: %{
          runnable: %{
            id: "runnable:1",
            node: "assistant_node_1_plan",
            component_id: "plan",
            component_type: "blueprint_proposer"
          },
          input: %{objective: "persist this"}
        }
      })

      {:ok, assistant_result()}
    end

    {:ok, options} =
      CliOptions.parse([
        "persist this",
        "--agent",
        "assistant",
        "--cwd",
        root,
        "--jsonl",
        jsonl_path,
        "--sqlite",
        sqlite_path
      ])

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn _line -> :ok end
             )

    {:ok, store} = SQLite.open(database: sqlite_path)
    on_exit(fn -> SQLite.close(store) end)

    jsonl_count =
      jsonl_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> length()

    assert jsonl_count == length(Queries.run_timeline(store, result.run_id))
    assert Queries.runnable_events(store, result.run_id) != []
    assert Queries.scorecards_for_run(store, result.run_id) != []
    assert Queries.artifacts_for_run(store, result.run_id) != []
  end

  test "agent runner uses default workspace SQLite persistence for local harness runs" do
    root = tmp_dir()
    sqlite_path = Path.join([root, ".runic_ai", "runs.db"])

    run_fun = fn _cwd, _objective, opts ->
      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :node_started,
        status: :running,
        data: %{
          runnable: %{
            id: "runnable:default",
            node: "assistant_node_1_plan",
            component_id: "plan",
            component_type: "blueprint_proposer"
          },
          input: %{objective: "persist by default"}
        }
      })

      {:ok, assistant_result()}
    end

    {:ok, options} =
      CliOptions.parse([
        "persist by default",
        "--agent",
        "assistant",
        "--cwd",
        root
      ])

    assert options.persistence == :sqlite
    assert options.sqlite_path == sqlite_path

    assert {:ok, result} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn _line -> :ok end
             )

    assert File.exists?(sqlite_path)

    {:ok, store} = SQLite.open(database: sqlite_path)
    on_exit(fn -> SQLite.close(store) end)

    assert Queries.run_timeline(store, result.run_id) != []
    assert Queries.runnable_events(store, result.run_id) != []
  end

  test "agent runner persists artifact-not-written outcomes on failed assistant runs" do
    root = tmp_dir()
    sqlite_path = Path.join(root, "runs.db")
    session_id = "terminal-artifact-denied"

    run_fun = fn _cwd, _objective, _opts ->
      {:error,
       Error.validation("artifact write denied by review",
         details: %{
           artifact_outcome: %{
             status: "artifact_not_written",
             reason: "denied",
             path: ".docs/report.md",
             suggested_paths: [".docs/report.md"]
           }
         }
       )}
    end

    {:ok, options} =
      CliOptions.parse([
        "write a report",
        "--agent",
        "assistant",
        "--cwd",
        root,
        "--session-id",
        session_id,
        "--sqlite",
        sqlite_path
      ])

    assert {:error, _error} =
             AgentRunner.run(options,
               run_fun: run_fun,
               output_fun: fn _line -> :ok end
             )

    {:ok, store} = SQLite.open(database: sqlite_path)
    on_exit(fn -> SQLite.close(store) end)

    messages = Queries.messages_for_session(store, session_id)

    assert Enum.any?(
             messages,
             &(&1.content =~ "artifact_not_written: denied" and
                 get_in(&1.content_json, ["artifact_outcome", "status"]) ==
                   "artifact_not_written")
           )
  end

  defp rlm_result do
    proposal =
      WorkflowProposal.new!(
        "Explain Demo",
        [ProposalNode.new!("inspect", :tool, params: %{tool: "find_files"})],
        stop_conditions: ["reported"]
      )

    scorecard =
      WorkflowScorecard.new!(
        objective_status: :objective_satisfied,
        changed_files: []
      )

    %{
      proposal: proposal,
      validation_report: WorkflowValidationReport.accept(),
      compiled: %{workflow_id: "compiled"},
      objective_scorecard: scorecard,
      context: %{
        episodes: [
          Episode.new!(:satisfied, "RLM visible final output.",
            id: "episode:answer",
            parent_node_id: "answer",
            artifacts: ["RLM visible final output."]
          )
        ]
      }
    }
  end

  defp event_run_id(event), do: event.data["run_id"] || event.data[:run_id]

  defp json_field(map, key, default \\ nil)

  defp json_field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp json_field(_map, _key, default), do: default

  defp objective_progress_session_status(event) do
    event.data
    |> json_field(:objective_session, %{})
    |> json_field(:status)
  end

  defp assistant_result do
    blueprint =
      RunicAI.Assistant.RLM.WorkflowBlueprint.new!(
        "Summarize chapter",
        [
          RunicAI.Assistant.RLM.ComponentBlueprint.new!("split", :source_splitter),
          RunicAI.Assistant.RLM.ComponentBlueprint.new!("write", :artifact_writer,
            params: %{path: ".docs/chapter.md"}
          )
        ],
        edges: [%{from: "split", to: "write"}],
        stop_conditions: ["artifact written"]
      )

    scorecard = %{
      objective_status: :objective_satisfied,
      artifact_path: ".docs/chapter.md",
      residual_risks: []
    }

    %{
      agent: :assistant,
      proposal: blueprint,
      blueprint: blueprint,
      validation_report: %{status: :accepted, diagnostics: []},
      compiled: %{workflow_id: "compiled"},
      scorecard: scorecard,
      objective_scorecard: scorecard,
      artifacts: [%{path: ".docs/chapter.md"}],
      episodes: []
    }
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-terminal-runner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
