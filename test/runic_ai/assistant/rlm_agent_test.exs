defmodule RunicAI.Assistant.RLMAgentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.Agent
  alias RunicAI.Assistant.RLM.ComponentBlueprint
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
    assert Enum.any?(result.episodes, &(&1.node_id == "write"))
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

  defp report_blueprint(path) do
    WorkflowBlueprint.new!(
      "Write a report",
      [
        ComponentBlueprint.new!("split", :source_splitter,
          params: %{strategy: :paragraph, max_bytes: 100}
        ),
        ComponentBlueprint.new!("materialize", :source_materializer),
        ComponentBlueprint.new!("map", :llm_map),
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
        %{from: "map", to: "synthesize"},
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
