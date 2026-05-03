defmodule RunicAI.Assistant.RLMAgentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.Agent
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.SmokeRunner
  alias RunicAI.Assistant.RLM.WorkflowCompiler
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient

  test "compiles and executes a generated split/map/reduce/write workflow" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    blueprint = report_blueprint(".docs/report.md")

    assert {:ok, result} =
             WorkflowCompiler.run(blueprint, workspace, %{},
               client: scripted_client(),
               model: "test:model",
               write_policy: :docs_only
             )

    assert result.scorecard.objective_status == :objective_satisfied
    assert File.read!(Path.join(root, ".docs/report.md")) =~ "High Level Overview"
    assert result.intermediate_outputs["write"].status == :written
  end

  test "assistant agent builds the generic fallback workflow and emits stages" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               input_paths: ["chapter.md"],
               output_path: ".docs/report.md",
               client: scripted_client(),
               model: "test:model",
               write_policy: :docs_only,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.agent == :assistant
    assert result.status == :ok
    assert File.exists?(Path.join(root, ".docs/report.md"))

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :blueprint_proposed))
    assert Enum.any?(emitted, &(&1.stage == :node_completed))
    assert Enum.any?(emitted, &(&1.stage == :scorecard_completed))
  end

  test "assistant fallback uses the default model when --model is omitted" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    parent = self()

    client = fn model, prompt, _opts ->
      send(parent, {:model_used, model})

      text =
        if prompt =~ "Merged notes:" do
          "# High Level Overview\n\nDefault model path worked."
        else
          "slice note"
        end

      {:ok, TestClient.result(text)}
    end

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               input_paths: ["chapter.md"],
               output_path: ".docs/report.md",
               client: client,
               write_policy: :docs_only
             )

    assert result.status == :ok
    assert_receive {:model_used, "openai:gpt-5.4-mini"}
    refute_receive {:model_used, nil}
  end

  test "assistant attempts one scorecard repair when source cues are missing" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    {:ok, reduce_calls} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn _model, prompt, _opts ->
      text =
        cond do
          prompt =~ "Merged notes:" ->
            call = Elixir.Agent.get_and_update(reduce_calls, &{&1, &1 + 1})

            if call == 0 do
              "# High Level Overview\n\nAda arrived."
            else
              "# High Level Overview\n\nAda arrived and Bea found the key."
            end

          true ->
            "slice note"
        end

      {:ok, TestClient.result(text)}
    end

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               input_paths: ["chapter.md"],
               output_path: ".docs/report.md",
               required_sections: ["High Level Overview"],
               required_source_cues: ["Bea found the key"],
               require_artifact_quality?: true,
               client: client,
               model: "test:model",
               write_policy: :docs_only,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.status == :ok
    assert result.scorecard.objective_status == :objective_satisfied
    assert [%{strategy: :scorecard_diagnostic_repair}] = result.repair_history

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :scorecard_repair_started))
  end

  test "assistant repairs runtime writer failures with a bounded fallback blueprint" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    blueprint =
      WorkflowBlueprint.new!(
        "Write a high level report",
        [
          ComponentBlueprint.new!("split", :source_splitter,
            params: %{strategy: :paragraph, max_bytes: 100}
          ),
          ComponentBlueprint.new!("materialize", :source_materializer),
          ComponentBlueprint.new!("map", :llm_map),
          ComponentBlueprint.new!("join", :blueprint_reduce),
          ComponentBlueprint.new!("synthesize", :llm_leaf),
          ComponentBlueprint.new!("write", :artifact_writer,
            params: %{path: "tmp/report.md", write_policy: :docs_only}
          ),
          ComponentBlueprint.new!("verify", :verification)
        ],
        sources: ["chapter.md"],
        edges: [
          %{from: "split", to: "materialize"},
          %{from: "materialize", to: "map"},
          %{from: "map", to: "join"},
          %{from: "join", to: "synthesize"},
          %{from: "synthesize", to: "write"},
          %{from: "write", to: "verify"}
        ],
        stop_conditions: ["artifact written"]
      )

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               blueprint: blueprint,
               input_paths: ["chapter.md"],
               client: scripted_client(),
               model: "test:model",
               write_policy: :docs_only,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.status == :ok
    refute File.exists?(Path.join(root, "tmp/report.md"))
    assert [%{strategy: :runtime_fallback_blueprint}] = result.repair_history

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :execution_failed))
    assert Enum.any?(emitted, &(&1.stage == :repair_attempt_started))
    assert Enum.any?(emitted, &(&1.stage == :repair_completed))
  end

  test "smoke runner writes a scenario report with comparable trace summary" do
    root = tmp_dir()

    assert {:ok, smoke} =
             SmokeRunner.run_scenario(root, :meeting_actions,
               client: scripted_client(),
               model: "test:model",
               proposal_strategy: :fallback
             )

    assert smoke.summary.nodes_generated > 0
    assert smoke.matrix_entry.expectation_status in [:pass, :review, :fail]
    assert File.exists?(Path.join(root, smoke.report_path))
    assert File.exists?(Path.join(root, smoke.run_path))
    report = File.read!(Path.join(root, smoke.report_path))
    assert report =~ "Trace Summary"
    assert report =~ "Runic Graph"
    assert report =~ "Native Runtime Nodes"
    assert report =~ "Mermaid"
    assert report =~ "Expected Vs Observed"

    assert {:ok, run_details} = Jason.decode(File.read!(Path.join(root, smoke.run_path)))
    assert is_map(run_details["graph_summary"])
    assert is_map(run_details["intermediate_outputs"])
    assert run_details["trace_summary"]["nodes_executed"] > 0
    assert run_details["execution_metrics"]["nodes_executed"] > 0
    assert is_list(run_details["native_nodes"])

    assert Enum.any?(
             run_details["native_nodes"],
             &(&1["production_count"] > 0)
           )

    assert Enum.any?(
             run_details["events"],
             &(get_in(&1, ["data", "runnable", "node"]) != nil)
           )

    assert File.read!(Path.join(root, "tmp/assistant_research_brief.md")) =~
             "Recursive Language Models"
  end

  defp report_blueprint(path) do
    WorkflowBlueprint.new!(
      "Write a report",
      [
        ComponentBlueprint.new!("split", :source_splitter,
          params: %{strategy: :paragraph, max_bytes: 100}
        ),
        ComponentBlueprint.new!("materialize", :source_materializer),
        ComponentBlueprint.new!("map", :llm_map),
        ComponentBlueprint.new!("join", :blueprint_reduce),
        ComponentBlueprint.new!("synthesize", :llm_leaf),
        ComponentBlueprint.new!("write", :artifact_writer,
          params: %{path: path, write_policy: :docs_only}
        ),
        ComponentBlueprint.new!("verify", :verification, params: %{artifact_path: path})
      ],
      sources: ["chapter.md"],
      edges: [
        %{from: "split", to: "materialize"},
        %{from: "materialize", to: "map"},
        %{from: "map", to: "join"},
        %{from: "join", to: "synthesize"},
        %{from: "synthesize", to: "write"},
        %{from: "write", to: "verify"}
      ],
      stop_conditions: ["artifact written"]
    )
  end

  defp scripted_client do
    fn _model, prompt, _opts ->
      text =
        cond do
          prompt =~ "Merged notes:" ->
            "# High Level Overview\n\nAda arrived and Bea found the key.\n\n## Takeaways\n\nThe plot moved forward."

          prompt =~ "Partial notes group" ->
            "Ada arrived. Bea found the key."

          true ->
            "slice note: #{String.slice(prompt, 0, 40)}"
        end

      {:ok, TestClient.result(text)}
    end
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-assistant-agent-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
