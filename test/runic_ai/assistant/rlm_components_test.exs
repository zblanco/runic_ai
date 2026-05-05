defmodule RunicAI.Assistant.RLMComponentsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
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
end
