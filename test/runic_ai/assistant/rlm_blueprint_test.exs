defmodule RunicAI.Assistant.RLMBlueprintTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.FunctionBlueprint
  alias RunicAI.Assistant.RLM.RepairLoop
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
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

  test "rejects artifact writers without concrete paths" do
    blueprint =
      WorkflowBlueprint.new!(
        "Write report",
        [
          ComponentBlueprint.new!("compose", :report_composer),
          ComponentBlueprint.new!("write", :artifact_writer, params: %{path: nil})
        ],
        edges: [%{from: "compose", to: "write"}],
        stop_conditions: ["artifact written"]
      )

    report = BlueprintValidator.report(blueprint)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :invalid_artifact_writer_path))
  end

  test "runtime repair removes blank artifact writers when no output path was requested" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Summarize",
        [
          ComponentBlueprint.new!("compose", :report_composer),
          ComponentBlueprint.new!("write", :artifact_writer, params: %{path: nil}),
          ComponentBlueprint.new!("score", :objective_scorecard)
        ],
        edges: [%{from: "compose", to: "write"}, %{from: "write", to: "score"}],
        stop_conditions: ["artifact written", "objective scorecard checked"]
      )

    error =
      Error.validation("artifact writer requires a non-empty path",
        details: %{path: nil}
      )

    assert {:ok, repair} = RepairLoop.runtime_repair(workspace, "Summarize", blueprint, error)

    assert repair.strategy == :runtime_diagnostic_repair
    assert Enum.map(repair.blueprint.components, & &1.id) == ["compose", "score"]
    assert repair.blueprint.edges == [%{from: "compose", to: "score"}]
    assert "final assistant output produced" in repair.blueprint.stop_conditions
    assert {:ok, report} = BlueprintValidator.validate(repair.blueprint)
    assert report.status == :accepted
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

  test "coordinator prefers curated ticket clustering recipe for common tabular tasks" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"ticket":"T1","theme":"login"}\n))
    workspace = Workspace.new!(root: root)

    client = fn _model, _prompt, _opts ->
      flunk("curated recipe should not call the blueprint generation client")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Cluster support tickets by theme",
               input_paths: ["tickets.jsonl"],
               output_path: ".docs/tickets.md",
               client: client,
               model: "test:model"
             )

    assert blueprint.metadata.proposal_kind == :curated_recipe
    assert blueprint.metadata.recipe == :parse_normalize_report

    assert %{type: :record_group, params: params} =
             Enum.find(blueprint.components, &(&1.type == :record_group))

    assert params.group_by == "theme"
    assert params.dedupe_by == ["ticket_id", "ticket", "id"]
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

  test "coordinator repair prompt accepts diagnostics containing nested errors" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)
    parent = self()

    client = fn _model, prompt, _opts ->
      blueprint =
        if prompt =~ "repairing an invalid" do
          send(parent, {:repair_prompt, prompt})

          %{
            id: "assistant:repaired_function",
            objective: "Pick repos",
            components: [
              %{
                id: "respond",
                type: "llm_leaf",
                params: %{
                  strategy: "llm_reduce",
                  group_prompt: "Use {{input}}",
                  prompt: "Respond from {{items}}",
                  max_group_items: 1
                }
              },
              %{id: "score", type: "objective_scorecard", params: %{}}
            ],
            edges: [%{from: "respond", to: "score"}],
            stop_conditions: ["response produced"],
            policies: %{generated_functions: %{max_tier: "tier1"}},
            metadata: %{}
          }
        else
          %{
            id: "assistant:bad_function",
            objective: "Pick repos",
            components: [
              %{
                id: "bad_transform",
                type: "blueprint_transform",
                params: %{function: %{tier: "tier0"}}
              },
              %{id: "score", type: "objective_scorecard", params: %{}}
            ],
            edges: [%{from: "bad_transform", to: "score"}],
            stop_conditions: ["response produced"],
            policies: %{generated_functions: %{max_tier: "tier1"}},
            metadata: %{}
          }
        end

      {:ok, TestClient.result(Jason.encode!(blueprint))}
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Pick repos",
               client: client,
               model: "test:model",
               fallback?: false
             )

    assert blueprint.id == "assistant:repaired_function"
    assert_receive {:repair_prompt, prompt}
    assert prompt =~ "tier0 function blueprints require a built-in operation"
    refute prompt =~ "%RunicAI.Error{"
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
