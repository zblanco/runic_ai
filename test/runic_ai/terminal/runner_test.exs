defmodule RunicAI.Terminal.RunnerTest do
  use ExUnit.Case, async: false

  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.LLM.TestClient
  alias RunicAI.Terminal.AssistantRunner
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
    assert result.summary.reply == "This repo is empty."

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.title == "Standard agent started"))
    assert Enum.any?(emitted, &(&1.kind == :message))
  end

  test "RLM runner renders live stage events and final artifacts from a run function" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, _objective, opts ->
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
               session_id: "terminal-rlm",
               run_fun: run_fun,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert result.agent == :rlm
    assert result.status == :ok

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.phase == :proposal_received))
    assert Enum.any?(emitted, &(&1.phase == :proposed))
    assert Enum.any?(emitted, &(&1.phase == :scorecard))
  end

  test "assistant runner renders live stage events and final artifacts from a run function" do
    root = tmp_dir()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    run_fun = fn _cwd, _objective, opts ->
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
      context: %{episodes: []}
    }
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
