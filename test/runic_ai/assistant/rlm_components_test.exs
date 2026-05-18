defmodule RunicAI.Assistant.RLMComponentsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.Event
  alias RunicAI.LLM.TestClient
  alias RunicAI.RLM.Components.ArtifactWriter
  alias RunicAI.RLM.Components.BlueprintTransform
  alias RunicAI.RLM.Components.BudgetLedger
  alias RunicAI.RLM.Components.DocumentCompare
  alias RunicAI.RLM.Components.LLMMap
  alias RunicAI.RLM.Components.ObjectiveScorecard
  alias RunicAI.RLM.Components.RecordGroup
  alias RunicAI.RLM.Components.ReportComposer
  alias RunicAI.RLM.Components.SourceDiscovery
  alias RunicAI.RLM.Components.SourceMaterializer
  alias RunicAI.RLM.Components.SourceSplitter
  alias RunicAI.RLM.Components.TabularParser

  test "source splitter returns text slices with provenance" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "# One\n\nA happened.\n\n# Two\n\nB happened.\n")
    workspace = Workspace.new!(root: root)

    assert {:ok, result} =
             SourceSplitter.run(workspace, ["chapter.md"], %{
               strategy: :markdown_heading,
               max_bytes: 40
             })

    assert result.count >= 2
    assert Enum.all?(result.slices, &(&1.path == "chapter.md"))
    assert Enum.all?(result.slices, &(is_list(&1.provenance) and &1.start_line <= &1.end_line))
  end

  test "source splitter truncates broad source sets instead of failing the workflow" do
    root = tmp_dir()
    File.write!(Path.join(root, "a.md"), "A\n")
    File.write!(Path.join(root, "b.md"), "B\n")
    File.write!(Path.join(root, "c.md"), "C\n")
    workspace = Workspace.new!(root: root)

    assert {:ok, result} =
             SourceSplitter.run(workspace, ["a.md", "b.md", "c.md"], %{max_sources: 2})

    assert result.truncated?
    assert result.input_source_count == 3
    assert result.resolved_source_count == 2
    assert result.source_count == 2
    assert Enum.map(result.sources, & &1.path) == ["a.md", "b.md"]
    assert Enum.all?(result.slices, &(&1.path in ["a.md", "b.md"]))
  end

  test "source discovery finds explicit files, directories, and extension-filtered sources" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join(root, "notes/a.md"), "# A\n")
    File.write!(Path.join(root, "notes/b.txt"), "B\n")
    File.write!(Path.join(root, "notes/c.bin"), <<0, 1, 2>>)
    workspace = Workspace.new!(root: root)

    assert {:ok, result} =
             SourceDiscovery.run(workspace, ["notes"], %{
               extensions: ["md", "txt"],
               max_files: 8
             })

    assert result.count == 2
    assert Enum.map(result.sources, & &1.path) == ["notes/a.md", "notes/b.txt"]
    assert Enum.all?(result.sources, &(is_list(&1.provenance) and &1.byte_size > 0))
  end

  test "source discovery can read explicit external directories when policy allows read escapes" do
    root = tmp_dir()
    external = tmp_dir()
    File.write!(Path.join(external, "workflow.ex"), "defmodule ExternalWorkflow do\nend\n")

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(read_root_jail: false)
      )

    assert {:ok, result} =
             SourceDiscovery.run(workspace, [external], %{
               extensions: ["ex"],
               max_files: 8
             })

    assert result.count == 1
    assert [%{path: path, absolute_path: absolute_path, discovery: :directory}] = result.sources
    assert path == absolute_path
    assert path == Path.join(external, "workflow.ex")
  end

  test "source discovery skips policy-blocked files during broad directory scans" do
    root = tmp_dir()
    File.write!(Path.join(root, "README.md"), "# Safe project notes\n")
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/prod.secret.exs"), "import Config\n")
    workspace = Workspace.new!(root: root)

    assert {:ok, result} =
             SourceDiscovery.run(workspace, ["."], %{
               extensions: ["md", "exs"],
               max_depth: 3,
               max_files: 8
             })

    assert result.count == 1
    assert [%{path: "README.md"}] = result.sources

    assert {:error, error} =
             SourceDiscovery.run(workspace, ["config/prod.secret.exs"], %{extensions: ["exs"]})

    assert error.message == "credential-looking paths are not allowed"
  end

  test "source materializer enforces total byte caps" do
    slices = [
      %{id: "a", text: String.duplicate("a", 10)},
      %{id: "b", text: String.duplicate("b", 10)}
    ]

    assert {:ok, result} =
             SourceMaterializer.run(%{slices: slices}, %{max_slice_bytes: 8, max_total_bytes: 10})

    assert result.count == 1
    assert result.truncated?
    assert byte_size(hd(result.slices).text) == 8
  end

  test "LLM map enforces call limits while accepting scripted clients and concurrency params" do
    parent = self()

    client = fn _model, prompt, _opts ->
      send(parent, {:mapped, prompt})
      {:ok, RunicAI.LLM.TestClient.result("mapped")}
    end

    input = %{slices: [%{id: "a", text: "A"}, %{id: "b", text: "B"}, %{id: "c", text: "C"}]}

    assert {:ok, result} =
             LLMMap.run(input, %{limit: 2, max_concurrency: 2},
               client: client,
               model: "test:model"
             )

    assert result.count == 2
    assert result.input_count == 3
    assert result.truncated?
    assert_receive {:mapped, _prompt}
    assert_receive {:mapped, _prompt}
    refute_receive {:mapped, _prompt}
  end

  test "LLM map emits transient stream stages for mapped items" do
    parent = self()
    sink = fn stage -> send(parent, {:llm_stream, stage}) end

    input = %{slices: [%{id: "a", text: "A"}]}

    assert {:ok, item} =
             LLMMap.map_item(hd(input.slices), 1, input, %{},
               client: TestClient,
               model: "test:model",
               stream_sink: sink,
               run_id: "run:map",
               component_id: "map_facts",
               presentation_group_id: "run:map",
               stream_chunk_size: 99
             )

    assert item.id == "a"
    assert item.text =~ "I received:"

    assert_receive {:llm_stream,
                    %Event{
                      kind: :chunk,
                      run_id: "run:map",
                      data: %{
                        "message_id" => "stream:assistant:run:map:map_facts:item:1",
                        "message_kind" => "analysis",
                        "workflow_node" => "map_facts",
                        "transient" => true
                      }
                    }}

    assert_receive {:llm_stream,
                    %Event{
                      kind: :message,
                      data: %{
                        "message_id" => "stream:assistant:run:map:map_facts:item:1",
                        "stream_complete" => true
                      }
                    }}
  end

  test "LLM map keeps concurrent item streams attached to stable message ids" do
    parent = self()
    sink = fn stage -> send(parent, {:llm_stream, stage}) end

    input = %{slices: [%{id: "a", text: "A"}, %{id: "b", text: "B"}]}

    assert {:ok, result} =
             LLMMap.run(input, %{limit: 2, max_concurrency: 2},
               client: TestClient,
               model: "test:model",
               stream_sink: sink,
               run_id: "run:parallel-map",
               component_id: "map_parallel",
               stream_chunk_size: 10_000
             )

    assert result.count == 2

    events = collect_stream_events(4)
    completed_ids = events |> completed_stream_ids() |> Enum.sort()
    chunk_ids = events |> chunk_stream_ids() |> Enum.sort()

    assert completed_ids == [
             "stream:assistant:run:parallel-map:map_parallel:item:1",
             "stream:assistant:run:parallel-map:map_parallel:item:2"
           ]

    assert chunk_ids == completed_ids
  end

  test "LLM map exposes structured records as prompt text when no text field exists" do
    parent = self()

    client = fn _model, prompt, _opts ->
      send(parent, {:mapped, prompt})
      {:ok, RunicAI.LLM.TestClient.result("mapped")}
    end

    input = %{
      comparisons: [
        %{
          added: ["Response target is one business day."],
          removed: ["Response target is two business days."]
        }
      ]
    }

    assert {:ok, result} =
             LLMMap.run(input, %{prompt: "Extract from {{text}}"},
               client: client,
               model: "test:model"
             )

    assert result.count == 1
    assert_receive {:mapped, prompt}
    assert prompt =~ "one business day"
    assert prompt =~ "two business days"
  end

  test "tabular parser and record group process JSONL records" do
    input = """
    {"ticket":"T1","theme":"login","severity":"high"}
    {"ticket":"T2","theme":"billing","severity":"medium"}
    {"ticket":"T3","theme":"login","severity":"high"}
    """

    assert {:ok, parsed} = TabularParser.run(input, %{format: :jsonl})
    assert parsed.count == 3

    assert {:ok, grouped} =
             RecordGroup.run(parsed, %{group_by: "theme", dedupe_by: ["ticket"]})

    assert grouped.group_count == 2
    assert Enum.find(grouped.groups, &(&1.key == "login")).count == 2
  end

  test "record group preserves ticket_id records with fallback identity keys" do
    input = """
    {"ticket_id":"T1","theme":"login","severity":"high"}
    {"ticket_id":"T2","theme":"billing","severity":"medium"}
    {"ticket_id":"T3","theme":"login","severity":"high"}
    """

    assert {:ok, parsed} = TabularParser.run(input, %{format: :jsonl})

    assert {:ok, grouped} =
             RecordGroup.run(parsed, %{
               group_by: "theme",
               dedupe_by: ["ticket_id", "ticket", "id"]
             })

    assert grouped.count == 3
    assert grouped.record_ids == ["T1", "T2", "T3"]
    assert grouped.dropped_record_ids == []
    assert Enum.find(grouped.groups, &(&1.key == "login")).count == 2
    assert Enum.find(grouped.groups, &(&1.key == "billing")).count == 1
  end

  test "record group does not collapse records when configured identity keys are missing" do
    records = [%{name: "Ada"}, %{name: "Bea"}]

    assert {:ok, grouped} = RecordGroup.run(records, %{dedupe_by: ["ticket_id"]})

    assert grouped.count == 2
    assert grouped.dedupe.missing_identity_key_count == 2
  end

  test "document compare emits added and removed candidates" do
    input = %{
      sources: [
        %{id: "old", path: "old.md", text: "A\nB\n"},
        %{id: "new", path: "new.md", text: "A\nC\nD\n"}
      ]
    }

    assert {:ok, result} = DocumentCompare.run(input)
    assert [%{added: added, removed: removed}] = result.comparisons
    assert "D" in added
    assert "B" in removed
  end

  test "comparison-required scorecard fails when no comparable pair exists" do
    workspace = Workspace.new!(root: tmp_dir())

    assert {:ok, compared} =
             DocumentCompare.run(%{
               sources: [%{id: "old", path: "old.md", text: "Response target is two days."}]
             })

    assert compared.count == 0

    assert {:ok, report} = ReportComposer.run(compared, %{title: "Comparison Report"})

    assert {:ok, scorecard} =
             ObjectiveScorecard.run(workspace, %{sources: compared.sources}, report, %{
               comparison_required?: true,
               require_provenance?: true
             })

    assert scorecard.objective_status == :objective_incomplete

    assert "comparison was required but fewer than two comparable sources were available" in scorecard.residual_risks
  end

  test "report composer and objective scorecard verify required sections" do
    root = tmp_dir()

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    assert {:ok, report} =
             ReportComposer.run(%{text: "Ada shipped the trace summary."}, %{
               title: "Smoke",
               sections: [%{title: "Summary", template: "{{content}}"}]
             })

    assert {:ok, artifact} =
             ArtifactWriter.run(workspace, report, %{
               path: ".docs/smoke.md",
               write_policy: :docs_only
             })

    context = %{sources: [%{path: "input.md"}], artifacts: [artifact], budget_ledger: nil}

    assert {:ok, scorecard} =
             ObjectiveScorecard.run(workspace, context, report, %{
               artifact_path: ".docs/smoke.md",
               required_sections: ["Summary"]
             })

    assert scorecard.objective_status == :objective_satisfied
    assert scorecard.artifact_status == :present

    assert {:ok, failed} =
             ObjectiveScorecard.run(workspace, context, report, %{
               artifact_path: ".docs/smoke.md",
               required_sections: ["Risks"]
             })

    assert failed.objective_status == :objective_incomplete
    assert "Risks" in failed.missing_sections

    assert {:ok, cue_failed} =
             ObjectiveScorecard.run(workspace, context, report, %{
               artifact_path: ".docs/smoke.md",
               required_source_cues: ["trace summary", "missing cue"]
             })

    assert cue_failed.objective_status == :objective_incomplete
    assert cue_failed.source_cue_status == :missing
    assert "missing cue" in cue_failed.missing_source_cues

    assert {:ok, provenance_failed} =
             ObjectiveScorecard.run(workspace, %{sources: [], artifacts: []}, report, %{
               require_provenance?: true
             })

    assert provenance_failed.objective_status == :objective_incomplete
    assert provenance_failed.source_coverage == :missing

    assert "source/provenance coverage was required but not present" in provenance_failed.residual_risks

    assert {:ok, quality_failed} =
             ObjectiveScorecard.run(workspace, context, "%{a => b}\n\n%{c => d}", %{
               require_artifact_quality?: true
             })

    assert quality_failed.objective_status == :objective_incomplete
    assert quality_failed.artifact_quality.status == :questionable
  end

  test "objective scorecard accepts structured provenance from assistant components" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    comparison = %{
      comparisons: [
        %{
          left: "old.md",
          right: "new.md",
          added: ["Response target is one business day."],
          removed: ["Response target is two business days."],
          provenance: [%{left: "old.md", right: "new.md"}]
        }
      ],
      sources: [%{path: "old.md"}, %{path: "new.md"}]
    }

    assert {:ok, report} = ReportComposer.run(comparison, %{title: "Comparison Report"})
    assert report.provenance == [%{left: "old.md", right: "new.md"}]

    assert {:ok, scorecard} =
             ObjectiveScorecard.run(workspace, %{sources: comparison.sources}, report, %{
               require_provenance?: true
             })

    assert scorecard.objective_status == :objective_satisfied
    assert scorecard.source_coverage == :present
    assert scorecard.provenance_count > 0
  end

  test "budget ledger records component metrics and reports budget errors" do
    component = RunicAI.Assistant.RLM.ComponentBlueprint.new!("map", :llm_map)
    ledger = BudgetLedger.new!(%{max_llm_map_calls: 1})

    assert {:error, error} = BudgetLedger.record(ledger, component, %{count: 2})
    assert error.message =~ "budget exceeded"
  end

  test "tier0 and tier1 function blueprints execute nested data transforms" do
    input = %{
      "items" => [
        %{"name" => "Ada", "role" => "engineer"},
        %{"name" => "Ada", "role" => "engineer"},
        %{"name" => "Bea", "role" => "designer"}
      ]
    }

    function = %{
      tier: :tier1,
      expr: %{
        op: "template",
        template: "Names: {{names}}",
        data: %{
          names: %{
            op: "join",
            separator: ", ",
            from: %{
              op: "map",
              from: %{op: "dedupe_by", from: %{op: "get", path: ["items"]}, keys: ["name"]},
              expr: %{op: "get", path: ["name"]}
            }
          }
        }
      }
    }

    assert {:ok, "Names: Ada, Bea"} = BlueprintTransform.apply(function, input)

    assert {:ok, "Ada"} =
             BlueprintTransform.apply(
               %{tier: :tier0, op: :get, expr: %{path: ["items", 0, "name"]}},
               input
             )
  end

  test "artifact writer allows .docs and blocks unsafe docs-only writes" do
    root = tmp_dir()

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    assert {:ok, artifact} =
             ArtifactWriter.run(workspace, %{text: "# Report\n"}, %{
               path: ".docs/report.md",
               write_policy: :docs_only
             })

    assert artifact.path == ".docs/report.md"
    assert File.read!(Path.join(root, ".docs/report.md")) == "# Report\n"

    assert {:error, error} =
             ArtifactWriter.run(workspace, "bad", %{
               path: "tmp/report.md",
               write_policy: :docs_only
             })

    assert error.message =~ "write policy"
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-assistant-components-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp collect_stream_events(count, acc \\ [])
  defp collect_stream_events(0, acc), do: Enum.reverse(acc)

  defp collect_stream_events(count, acc) do
    receive do
      {:llm_stream, stage} -> collect_stream_events(count - 1, [stage | acc])
    after
      1_000 -> flunk("expected #{count} more stream event(s)")
    end
  end

  defp completed_stream_ids(events) do
    for %Event{kind: :message, data: %{"message_id" => id}} <- events, do: id
  end

  defp chunk_stream_ids(events) do
    for %Event{kind: :chunk, data: %{"message_id" => id}} <- events, do: id
  end
end
