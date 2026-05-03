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

  test "bounds search match previews from very long generated lines" do
    workspace = sample_workspace()
    File.mkdir_p!(Path.join(workspace.root, "doc/dist"))

    File.write!(
      Path.join(workspace.root, "doc/dist/search_data.js"),
      String.duplicate("generated docs payload ", 20_000) <> "general agent shape"
    )

    assert {:ok, searched} =
             Tools.search_text(workspace, %{
               query: "general agent shape",
               path: ".",
               context_lines: 1,
               limit: 10
             })

    assert Enum.any?(searched.matches, & &1.text_truncated?)
    assert byte_size(Jason.encode!(searched)) < 20_000
  end

  test "renders Mermaid fences through the read-only mmdflux tool" do
    workspace = sample_workspace()

    File.write!(Path.join(workspace.root, "diagram.md"), """
    # Diagram

    ```mermaid
    flowchart TD
      A[Guide] --> B[Terminal]
    ```
    """)

    assert {:ok, output} =
             Tools.render_mermaid(workspace, %{
               path: "diagram.md",
               diagram_index: 1,
               format: "text",
               color: "off"
             })

    assert output.status in [:pass, :blocked]
    assert output.diagram_count == 1
    assert output.diagram_index == 1
    assert output.source_preview =~ "flowchart TD"
    assert output.command =~ "mmdflux"

    if output.status == :pass do
      assert is_binary(output.rendered)
      assert output.rendered != ""
      assert output.exit_status == 0
    else
      assert output.error =~ "mmdflux executable"
    end
  end

  test "selects a Mermaid fence by nearby query text before rendering" do
    workspace = sample_workspace()

    File.write!(Path.join(workspace.root, "diagrams.md"), """
    # Diagrams

    Other diagram:

    ```mermaid
    flowchart TD
      A[Other] --> B[Diagram]
    ```

    The general agent shape is:

    ```mermaid
    flowchart LR
      user[User input] --> request[TurnRequest]
      request --> prompt[Prompt]
    ```
    """)

    assert {:ok, output} =
             Tools.render_mermaid(workspace, %{
               path: "diagrams.md",
               query: "general agent shape",
               format: "text",
               color: "off"
             })

    assert output.diagram_count == 2
    assert output.source_preview =~ "User input"
    refute output.source_preview =~ "Other"
  end

  test "extracts Livebook Kino.Mermaid diagrams with renderability metadata" do
    workspace = sample_workspace()

    File.write!(Path.join(workspace.root, "agent.livemd"), """
    # RLM Coding Agent

    ## Architecture

    The RLM agent has two important workflow shapes.

    ```elixir
    Kino.Mermaid.new(\"\"\"
    flowchart TD
      objective["Coding objective"] --> prepare["Prepare CodebaseEnvironment"]
      prepare --> coordinator["Coordinator proposes WorkflowProposal"]
    \"\"\")
    ```

    ## Planned Workflow From A Recipe Seed

    ```elixir
    Kino.Layout.tabs(
      "Proposal graph": Kino.Mermaid.new(RunicAI.Livebook.CodingDemo.proposal_mermaid(proposal))
    )
    ```

    ## Tool Boundaries

    ```elixir
    Kino.Mermaid.new(\"\"\"
    flowchart LR
      proposal["Accepted proposal node"] --> kind{"kind"}
      kind --> registry["Tool registry"]
    \"\"\")
    ```
    """)

    assert {:ok, output} =
             Tools.extract_diagrams(workspace, %{
               path: "agent.livemd",
               query: "RLM agents",
               include_source: true
             })

    assert output.count == 3
    assert output.selected_diagram_index == 1

    assert [
             %{
               container: :kino_mermaid_literal,
               renderable?: true,
               heading: "Architecture",
               source: source
             },
             %{container: :kino_mermaid_dynamic, renderable?: false},
             %{container: :kino_mermaid_literal, renderable?: true, heading: "Tool Boundaries"}
           ] = output.diagrams

    assert source =~ "Coding objective"
  end

  test "renders static Kino.Mermaid Livebook diagrams selected by loose query" do
    workspace = sample_workspace()

    File.write!(Path.join(workspace.root, "agent.livemd"), """
    # RLM Coding Agent

    ## Architecture

    The RLM agent has two important workflow shapes.

    ```elixir
    Kino.Mermaid.new(\"\"\"
    flowchart TD
      objective["Coding objective"] --> prepare["Prepare CodebaseEnvironment"]
    \"\"\")
    ```

    ## Tool Boundaries

    ```elixir
    Kino.Mermaid.new(\"\"\"
    flowchart LR
      proposal["Accepted proposal node"] --> kind{"kind"}
    \"\"\")
    ```
    """)

    assert {:ok, output} =
             Tools.render_mermaid(workspace, %{
               path: "agent.livemd",
               query: "RLM agents",
               format: "text",
               color: "off"
             })

    assert output.status in [:pass, :blocked]
    assert output.diagram_count == 2
    assert output.diagram_index == 1
    assert output.container == :kino_mermaid_literal
    assert output.heading == "Architecture"
    assert output.source_preview =~ "Coding objective"
    refute output.source_preview =~ "Accepted proposal node"
  end

  test "extracts diagrams from bounded project directories while ignoring generated docs" do
    workspace = sample_workspace()
    File.mkdir_p!(Path.join(workspace.root, "guides"))
    File.mkdir_p!(Path.join(workspace.root, "doc/dist"))
    File.mkdir_p!(Path.join(workspace.root, "_build"))

    File.write!(Path.join(workspace.root, "guides/mental-model.md"), """
    # Mental model

    ```mermaid
    flowchart TD
      Runtime --> Agent
    ```
    """)

    File.write!(Path.join(workspace.root, "guides/runtime.mmd"), """
    flowchart LR
      Graph --> Terminal
    """)

    File.write!(Path.join(workspace.root, "doc/dist/generated.md"), """
    ```mermaid
    flowchart TD
      Generated --> ShouldNotAppear
    ```
    """)

    File.write!(Path.join(workspace.root, "_build/generated.md"), """
    ```mermaid
    flowchart TD
      Build --> ShouldNotAppear
    ```
    """)

    assert {:ok, output} =
             Tools.extract_diagrams(workspace, %{
               path: ".",
               include_source: true,
               limit: 10,
               max_source_bytes: 32
             })

    assert output.directory?
    assert output.count == 2
    assert output.diagram_file_count == 2

    assert Enum.map(output.diagrams, & &1.path) == [
             "guides/mental-model.md",
             "guides/runtime.mmd"
           ]

    refute Enum.any?(output.diagrams, &String.contains?(&1.source_preview, "ShouldNotAppear"))
    assert Enum.all?(output.diagrams, &(byte_size(&1.source_preview) <= 32))
  end

  test "renders a directory diagram candidate selected by loose query" do
    workspace = sample_workspace()
    File.mkdir_p!(Path.join(workspace.root, "guides"))

    File.write!(Path.join(workspace.root, "guides/diagrams.md"), """
    # Diagrams

    Other graph:

    ```mermaid
    flowchart TD
      Other --> Graph
    ```

    Target graph:

    ```mermaid
    flowchart LR
      Target --> Diagram
    ```
    """)

    assert {:ok, output} =
             Tools.render_mermaid(workspace, %{
               path: ".",
               query: "target graph",
               format: "text",
               color: "off"
             })

    assert output.status in [:pass, :blocked]
    assert output.source == :directory
    assert output.directory == "."
    assert output.source_preview =~ "Target"
    refute output.source_preview =~ "Other"
  end

  test "does not render dynamic Kino.Mermaid expressions by default" do
    workspace = sample_workspace()

    File.write!(Path.join(workspace.root, "dynamic.livemd"), """
    # Dynamic Diagram

    ```elixir
    Kino.Layout.tabs(
      "Proposal graph": Kino.Mermaid.new(RunicAI.Livebook.CodingDemo.proposal_mermaid(proposal))
    )
    ```
    """)

    assert {:error, error} =
             Tools.render_mermaid(workspace, %{
               path: "dynamic.livemd",
               query: "proposal graph",
               format: "text",
               color: "off"
             })

    assert error.message =~ "dynamic"
    assert error.details.container == :kino_mermaid_dynamic
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
    assert "extract_diagrams" in Registry.names(registry)
    assert "render_mermaid" in Registry.names(registry)

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
