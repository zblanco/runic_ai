defmodule RunicAI.Assistant.RLMBlueprintTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.FunctionBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient

  test "constructs and validates a workflow blueprint" do
    split = ComponentBlueprint.new!("split", :source_splitter)
    write = ComponentBlueprint.new!("write", :artifact_writer, params: %{path: ".docs/out.md"})

    blueprint =
      WorkflowBlueprint.new!("Write report", [split, write],
        id: "assistant-test",
        sources: ["tmp/source.md"],
        edges: [%{from: "split", to: "write"}],
        stop_conditions: ["artifact written"]
      )

    assert blueprint.id == "assistant-test"
    assert [%{path: "tmp/source.md"}] = blueprint.sources
    assert {:ok, report} = BlueprintValidator.validate(blueprint)
    assert report.status == :accepted
  end

  test "rejects duplicate ids, unknown edges, and missing stop conditions" do
    blueprint =
      WorkflowBlueprint.new!(
        "Bad graph",
        [
          ComponentBlueprint.new!("same", :source_splitter),
          ComponentBlueprint.new!("same", :llm_map)
        ],
        edges: [%{from: "missing", to: "same"}],
        stop_conditions: []
      )

    report = BlueprintValidator.report(blueprint)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :duplicate_component_ids))
    assert Enum.any?(report.diagnostics, &(&1.code == :unknown_edge_source))
    assert Enum.any?(report.diagnostics, &(&1.code == :missing_stop_conditions))
  end

  test "rejects generated functions above policy tier" do
    function = FunctionBlueprint.new!(:tier2, source: "fn input -> input end")

    blueprint =
      WorkflowBlueprint.new!(
        "Transform",
        [
          ComponentBlueprint.new!("transform", :blueprint_transform,
            params: %{function: function}
          )
        ],
        stop_conditions: ["transformed"]
      )

    report = BlueprintValidator.report(blueprint, max_generated_function_tier: :tier1)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :function_tier_rejected))
  end

  test "round-trips generated blueprints through JSON-safe maps" do
    blueprint =
      WorkflowBlueprint.new!("Round trip", [ComponentBlueprint.new!("split", "source_splitter")],
        sources: [%{"id" => "chapter", "path" => "tmp/chapter.md"}],
        stop_conditions: ["done"]
      )

    json = Jason.encode!(blueprint)
    decoded = Jason.decode!(json)

    assert {:ok, decoded_blueprint} = WorkflowBlueprint.from_input(decoded)
    assert decoded_blueprint.objective == "Round trip"
    assert hd(decoded_blueprint.components).type == :source_splitter
  end

  test "coordinator accepts a generated non-report workflow blueprint" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"theme":"login"}\n))
    workspace = Workspace.new!(root: root)

    client = fn _model, _prompt, _opts ->
      blueprint =
        %{
          id: "assistant:ticket_clusters",
          objective: "Cluster tickets",
          sources: [%{id: "tickets", path: "tickets.jsonl"}],
          components: [
            %{id: "discover", type: "source_discovery", params: %{paths: ["tickets.jsonl"]}},
            %{id: "parse", type: "tabular_parser", params: %{format: "jsonl"}},
            %{id: "group", type: "record_group", params: %{group_by: "theme"}},
            %{id: "compose", type: "report_composer", params: %{title: "Ticket Themes"}},
            %{id: "write", type: "artifact_writer", params: %{path: ".docs/tickets.md"}},
            %{
              id: "score",
              type: "objective_scorecard",
              params: %{artifact_path: ".docs/tickets.md"}
            }
          ],
          edges: [
            %{from: "discover", to: "parse"},
            %{from: "parse", to: "group"},
            %{from: "group", to: "compose"},
            %{from: "compose", to: "write"},
            %{from: "write", to: "score"}
          ],
          stop_conditions: ["artifact written", "scorecard satisfied"],
          policies: %{generated_functions: %{max_tier: "tier1"}, budgets: %{max_nodes: 12}},
          metadata: %{}
        }

      {:ok, TestClient.result(Jason.encode!(blueprint))}
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Cluster tickets",
               input_paths: ["tickets.jsonl"],
               output_path: ".docs/tickets.md",
               client: client,
               model: "test:model"
             )

    assert Enum.map(blueprint.components, & &1.type) == [
             :source_discovery,
             :tabular_parser,
             :record_group,
             :report_composer,
             :artifact_writer,
             :objective_scorecard
           ]
  end

  test "coordinator repairs invalid generated blueprint diagnostics" do
    root = tmp_dir()
    File.write!(Path.join(root, "input.md"), "hello\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, prompt, _opts ->
      blueprint =
        if prompt =~ "repairing an invalid" do
          %{
            id: "assistant:repaired",
            objective: "Write report",
            sources: [%{id: "input", path: "input.md"}],
            components: [
              %{id: "split", type: "source_splitter", params: %{}},
              %{id: "compose", type: "report_composer", params: %{title: "Report"}},
              %{id: "score", type: "objective_scorecard", params: %{}}
            ],
            edges: [%{from: "split", to: "compose"}, %{from: "compose", to: "score"}],
            stop_conditions: ["scorecard satisfied"],
            policies: %{generated_functions: %{max_tier: "tier1"}},
            metadata: %{}
          }
        else
          %{
            id: "assistant:bad",
            objective: "Write report",
            components: [%{id: "split", type: "source_splitter", params: %{}}],
            edges: [%{from: "missing", to: "split"}],
            stop_conditions: ["done"],
            policies: %{},
            metadata: %{}
          }
        end

      {:ok, TestClient.result(Jason.encode!(blueprint))}
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Write report",
               input_paths: ["input.md"],
               client: client,
               model: "test:model",
               fallback?: false
             )

    assert blueprint.id == "assistant:repaired"
    assert blueprint.metadata.proposal_kind == :validation_repair
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-assistant-blueprint-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
