defmodule RunicAI.Coding.ToolsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  test "lists directories with stable metadata and hidden controls" do
    workspace = sample_workspace()

    assert {:ok, output} = Tools.list_dir(workspace, %{path: "."})
    assert Enum.map(output.entries, & &1.name) == ["README.md", "image.bin", "lib"]

    assert {:ok, output} = Tools.list_dir(workspace, %{path: ".", include_hidden: true})
    assert Enum.map(output.entries, & &1.name) == [".hidden", "README.md", "image.bin", "lib"]
  end

  test "finds files and searches text with context" do
    workspace = sample_workspace()

    assert {:ok, found} = Tools.find_files(workspace, %{query: "demo", include_hidden: true})
    assert Enum.map(found.files, & &1.path) == ["lib/demo.ex"]

    assert {:ok, searched} =
             Tools.search_text(workspace, %{
               query: "answer",
               path: "lib",
               context_lines: 1,
               limit: 5
             })

    assert [%{path: "lib/demo.ex", line: 2, before: [%{line: 1}]}] = searched.matches
  end

  test "uses rg for literal search when it is available and no context is requested" do
    workspace = sample_workspace()

    assert {:ok, searched} =
             Tools.search_text(workspace, %{
               query: "answer",
               path: "lib",
               limit: 5
             })

    assert [%{path: "lib/demo.ex", line: 2}] = searched.matches

    if System.find_executable("rg") do
      assert searched.backend == :rg
    else
      assert searched.backend == :elixir
    end
  end

  test "reads files, ranges, many files, and binary files with structured output" do
    workspace = sample_workspace()

    assert {:ok, file} = Tools.read_file(workspace, %{path: "lib/demo.ex", max_bytes: 20})
    assert file.path == "lib/demo.ex"
    assert file.truncated?
    assert file.sha256
    assert file.preview =~ "defmodule Demo"

    assert {:ok, range} =
             Tools.read_range(workspace, %{path: "lib/demo.ex", start_line: 2, end_line: 2})

    assert range.text =~ "answer"

    assert {:ok, many} =
             Tools.read_many(workspace, %{
               paths: ["README.md", "lib/demo.ex"],
               per_file_max_bytes: 20,
               total_max_bytes: 40
             })

    assert many.count == 2
    assert many.truncated?

    assert {:ok, binary} = Tools.read_file(workspace, %{path: "image.bin"})
    assert binary.binary?
    assert binary.content == nil
  end

  test "stores truncated read previews through workspace persistence" do
    {:ok, store} = InMemory.start_link()
    workspace = sample_workspace(persistence: {InMemory, store})

    assert {:ok, file} = Tools.read_file(workspace, %{path: "lib/demo.ex", max_bytes: 8})

    assert file.truncated?
    assert file.artifact_ref =~ "mem:"
    assert {:ok, artifact} = Persistence.get_artifact(workspace.persistence, file.artifact_ref)
    assert artifact.content =~ "defmodule Demo"
  end

  test "default registry exposes executable coding tool definitions" do
    workspace = sample_workspace()
    registry = Tools.default_registry(workspace)

    assert "read_file" in Registry.names(registry)

    definition = Registry.fetch!(registry, "read_file")
    assert %Definition{} = definition
    assert {:ok, output} = Definition.execute(definition, %{"path" => "README.md"})
    assert output.content =~ "hello"
  end

  test "profile task tools accept a single string arg from model calls" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Smoke.MixProject do
      use Mix.Project

      def project, do: [app: :smoke, version: "0.1.0", elixir: "~> 1.18", deps: []]
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/smoke_test.exs"), """
    defmodule SmokeTest do
      use ExUnit.Case, async: true
      test "ok", do: assert(true)
    end
    """)

    workspace = Workspace.new!(root: root)

    assert {:ok, result} =
             Tools.run_profile_task(
               workspace,
               :run_tests,
               %{args: "test/smoke_test.exs"},
               allowed_commands: ["mix"],
               timeout_ms: 30_000
             )

    assert result.status == :pass
  end

  defp sample_workspace(opts \\ []) do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "README.md"), "hello\n")
    File.write!(Path.join(root, ".hidden"), "hidden\n")

    File.write!(
      Path.join(root, "lib/demo.ex"),
      "defmodule Demo do\n  def answer, do: 42\nend\n"
    )

    File.write!(Path.join(root, "image.bin"), <<0, 1, 2, 3>>)
    Workspace.new!(Keyword.merge([root: root], opts))
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
