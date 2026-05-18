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

  test "agent runner renders RLM final report with WorkflowScorecard structs" do
    root = tmp_dir()
    output = []

    run_fun = fn _cwd, _objective, _opts -> {:ok, rlm_result()} end

    {:ok, options} =
      CliOptions.parse([
        "Explain Demo",
        "--agent",
        "rlm",
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

    rendered =
      :rlm_report_output
      |> Process.get([])
      |> Enum.reverse()
      |> Enum.join("\n")

    assert rendered =~ "Final report"
    assert rendered =~ "objective_satisfied"
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
