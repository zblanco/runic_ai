defmodule RunicAI.Assistant.RLMComponentsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.Components.ArtifactWriter
  alias RunicAI.RLM.Components.BlueprintTransform
  alias RunicAI.RLM.Components.SourceMaterializer
  alias RunicAI.RLM.Components.SourceSplitter

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
