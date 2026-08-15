defmodule RunicAI.Coding.ToolsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Coding.SandboxSessionRegistry
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Memory.LocalStore, as: MemoryLocalStore
  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.Schemas.SubagentRun
  alias RunicAI.Terminal.Event
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry
  import Ecto.Query

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

  test "execute_code and sandbox_status expose just_bash sandbox metadata" do
    workspace = sample_workspace()
    parent = self()
    event_sink = fn event -> send(parent, {:sandbox_event, event}) end

    assert {:ok, result} =
             Tools.execute_code(
               workspace,
               %{
                 runtime: "bash",
                 code: "echo tool-sandbox",
                 max_output_bytes: 1_024
               },
               nil,
               event_sink: event_sink
             )

    assert result.status == :pass
    assert result.output == "tool-sandbox\n"
    assert result.metadata.tool == :execute_code
    assert result.metadata.runtime == :bash
    assert result.metadata.sandbox_backend == :just_bash
    assert result.metadata.isolation_level == :in_process_virtual
    assert result.metadata.network == :disabled
    assert result.metadata.host_cwd == workspace.root
    assert result.metadata.sandbox_cwd == "/workspace"
    assert result.metadata.output_cap_bytes == 1_024
    assert result.metadata.changed_artifact_refs == []
    assert result.metadata.sandbox_capability.state_model == :one_shot
    assert result.metadata.sandbox_capability.transport_model == :in_process
    assert result.metadata.sandbox_capability.session == :one_shot

    assert_receive {:sandbox_event, started}
    assert started.kind == :coding_sandbox_started
    assert started.status == :running
    assert started.metadata.sandbox?
    assert started.metadata.runtime == :bash
    assert started.metadata.capability.state_model == :one_shot
    assert started.input.file_paths == []
    assert started.output.code_preview == "echo tool-sandbox"

    assert_receive {:sandbox_event, completed}
    assert completed.kind == :coding_sandbox_completed
    assert completed.status == :pass
    assert completed.output.backend == :just_bash
    assert completed.output.isolation_level == :in_process_virtual
    assert completed.output.output_preview == "tool-sandbox\n"
    assert completed.metadata.capability.state_model == :one_shot

    assert {:ok, status} = Tools.sandbox_status(workspace, %{})
    assert status.default_backend == :just_bash
    assert [%{name: :just_bash, runtimes: [:bash], security_boundary?: false}] = status.backends
  end

  test "stateful sandbox tools open execute and close managed sessions" do
    workspace = sample_workspace()
    {:ok, registry} = SandboxSessionRegistry.start_link()

    assert {:ok, opened} = Tools.open_sandbox_session(workspace, %{}, registry)
    assert opened.id =~ "sandbox_session_"
    assert opened.session_id
    assert opened.backend == :just_bash
    assert opened.capabilities.exec?

    assert {:ok, result} =
             Tools.sandbox_exec(
               workspace,
               %{session_id: opened.id, runtime: "bash", code: "echo managed-session"},
               registry
             )

    assert result.status == :pass
    assert result.stdout == "managed-session\n"
    assert result.session.id == opened.id

    assert {:ok, closed} =
             Tools.close_sandbox_session(workspace, %{session_id: opened.id}, registry)

    assert closed == %{id: opened.id, status: :closed}

    assert {:error, error} =
             Tools.sandbox_exec(
               workspace,
               %{session_id: opened.id, runtime: "bash", code: "echo stale"},
               registry
             )

    assert error.message == "unknown sandbox session id"
  end

  test "sandbox process tools are exposed through opaque ids and reject limited backends" do
    workspace = sample_workspace()
    {:ok, registry} = SandboxSessionRegistry.start_link()

    tool_registry = Tools.default_registry(workspace, sandbox_session_registry: registry)
    names = Registry.names(tool_registry)

    assert "start_sandbox_process" in names
    assert "sandbox_process_events" in names
    assert "write_sandbox_process" in names
    assert "kill_sandbox_process" in names

    start_tool = Registry.fetch!(tool_registry, "start_sandbox_process")
    write_tool = Registry.fetch!(tool_registry, "write_sandbox_process")
    events_tool = Registry.fetch!(tool_registry, "sandbox_process_events")
    wait_tool = Registry.fetch!(tool_registry, "wait_sandbox_process")

    assert start_tool.metadata.requires_review?
    assert write_tool.metadata.requires_review?
    refute events_tool.metadata.requires_review?
    refute wait_tool.metadata.requires_review?

    assert {:ok, opened} = Tools.open_sandbox_session(workspace, %{}, registry)

    assert {:error, error} =
             Tools.start_sandbox_process(
               workspace,
               %{session_id: opened.id, runtime: "bash", code: "cat"},
               registry
             )

    assert error.message == "sandbox session does not support process hosting"
    assert error.details.backend == :just_bash
  end

  test "execute_code metadata carries configured stateful sandbox capability shape" do
    workspace = sample_workspace()

    sandbox_opts = [
      profile: [
        backend: :vmsan,
        runtimes: [:bash, :python],
        network: :disabled,
        metadata: %{
          state_model: :checkpointable,
          transport_model: :local_microvm,
          session: :workspace,
          checkpoint_policy: %{mode: :manual}
        }
      ]
    ]

    registry = Tools.default_registry(workspace, sandbox_opts: sandbox_opts)
    tool = RunicAI.Tool.Registry.fetch!(registry, "execute_code")

    assert tool.metadata.sandbox_backend == :vmsan
    assert tool.metadata.isolation_level == :microvm
    assert tool.metadata.state_model == :checkpointable
    assert tool.metadata.transport_model == :local_microvm
    assert tool.metadata.session == :workspace
    assert tool.metadata.checkpoint_policy == %{mode: :manual}
  end

  test "execute_code normalizes explicit sandbox network policy values" do
    workspace = sample_workspace()

    assert {:ok, result} =
             Tools.execute_code(
               workspace,
               %{runtime: "bash", code: "echo network-policy", network: "host"},
               nil,
               sandbox_opts: [profile: [network: :host]]
             )

    assert result.status == :pass
    assert result.metadata.network == :host
  end

  test "execute_code selects non-bash runtimes from sandbox profile config" do
    workspace = sample_workspace()

    assert {:ok, result} =
             Tools.execute_code(
               workspace,
               %{runtime: "lua", code: "return 42"},
               nil,
               sandbox_opts: [profile: [backend: :lua, runtimes: [:lua]]]
             )

    assert result.status == :pass
    assert result.output == "42\n"
    assert result.metadata.runtime == :lua
    assert result.metadata.sandbox_backend == :lua
    assert result.metadata.isolation_level == :in_process
  end

  test "execute_code converts sandbox errors into blocked command results" do
    workspace = sample_workspace()

    assert {:ok, result} =
             Tools.execute_code(
               workspace,
               %{runtime: "python", code: "print('blocked')"},
               nil
             )

    assert result.status == :blocked
    assert [%{message: "sandbox runtime is not enabled by profile"}] = result.diagnostics
    assert result.metadata.error_kind == :validation
    assert result.metadata.tool == :execute_code
    assert result.metadata.sandbox_capability.backend == :just_bash
    assert result.metadata.sandbox_capability.state_model == :one_shot
  end

  test "memory tools write and recall local entries through a store adapter" do
    workspace = sample_workspace()
    store_opts = [namespace: "tools-#{System.unique_integer([:positive])}"]
    MemoryLocalStore.clear(store_opts)

    assert {:ok, written} =
             Tools.memory_write(
               workspace,
               %{
                 content: "RunicAI should prefer safe deterministic compute before shell tools.",
                 summary: "safe compute preference",
                 kind: "semantic",
                 salience: 0.9
               },
               MemoryLocalStore,
               store_opts
             )

    assert written.status == :written
    assert written.count == 1
    assert written.store == :local_ets

    assert {:ok, recalled} =
             Tools.memory_recall(
               workspace,
               %{query: "safe deterministic compute", kinds: ["semantic"], limit: 3},
               MemoryLocalStore,
               store_opts
             )

    assert recalled.status == :ok
    assert [%{content: content, source_ref: source_ref}] = recalled.entries
    assert content =~ "safe deterministic compute"
    assert source_ref =~ "memory:"
  end

  test "session_search reads persisted terminal events through SQLite FTS" do
    workspace = sample_workspace()
    {:ok, store} = SQLite.open(database: ":memory:", migrate?: true)
    on_exit(fn -> SQLite.close(store) end)

    event =
      Event.new!(:message,
        session_id: "session:tools",
        agent: :assistant,
        phase: :assistant,
        status: :ok,
        title: "Sandbox research",
        detail: "Firecracker microVMs can isolate code execution.",
        data: %{run_id: "run:tools", reply_text: "Use KVM-backed microVMs for strong isolation."}
      )

    assert {:ok, _persisted} = SQLite.record_terminal_event(store, event)

    assert {:ok, result} =
             Tools.session_search(workspace, %{query: "Firecracker", limit: 5}, store)

    assert result.status == :ok
    assert result.count == 1

    assert [%{source_ref: source_ref, session_id: "session:tools", run_id: "run:tools"}] =
             result.results

    assert source_ref =~ "terminal_event:"
  end

  test "web tools search and extract static sources with persisted source artifacts" do
    {:ok, store} = InMemory.start_link()
    workspace = sample_workspace(persistence: {InMemory, store})

    web_opts = [
      provider_opts: [
        sources: [
          %{
            title: "RunicAI Browser Plan",
            url: "https://example.test/browser",
            snippet: "Browser tools use compact accessibility snapshots.",
            html: "<html><title>Browser Plan</title><h1>Agent Browser</h1><p>Use refs.</p></html>"
          }
        ]
      ]
    ]

    assert {:ok, search} =
             Tools.web_search(workspace, %{query: "accessibility", limit: 3}, web_opts)

    assert search.count == 1
    assert [%{source_ref: source_ref}] = search.results
    assert source_ref =~ "web:"
    assert search.artifact_ref =~ "mem:"

    assert {:ok, extract} =
             Tools.web_extract(workspace, %{url: "https://example.test/browser"}, web_opts)

    assert extract.source.markdown =~ "Agent Browser"
    assert extract.source.artifact_ref =~ "mem:"
    assert length(InMemory.artifacts(store)) >= 2
  end

  test "media tools use injected clients and persist generated artifacts" do
    {:ok, store} = InMemory.start_link()
    workspace = sample_workspace(persistence: {InMemory, store})

    media_client = fn
      :generate_image, _model, _prompt, _opts ->
        {:ok, %{image: "png-bytes", media_type: "image/png"}}

      :speak, _model, _text, _opts ->
        {:ok, %{audio: "mp3-bytes", media_type: "audio/mpeg", format: "mp3"}}

      :transcribe, _model, _audio, _opts ->
        {:ok, %{text: "hello transcript", segments: []}}

      :ocr, _model, _document, _opts ->
        {:ok, %{markdown: "# OCR\n\nhello", pages: []}}

      :vision_analyze, _model, _input, _opts ->
        {:ok, %{text: "image contains a button"}}
    end

    opts = [client: media_client, model: "test:model"]

    assert {:ok, image} = Tools.image_generate(workspace, %{prompt: "draw"}, opts)
    assert image.artifact_ref =~ "mem:"
    assert image.image_byte_size == 9
    refute Map.has_key?(image, :image)

    assert {:ok, speech} = Tools.speech_generate(workspace, %{text: "say hi"}, opts)
    assert speech.artifact_ref =~ "mem:"
    assert speech.audio_byte_size == 9

    assert {:ok, transcript} =
             Tools.transcribe_audio(
               workspace,
               %{audio_base64: Base.encode64("audio"), media_type: "audio/mpeg"},
               opts
             )

    assert transcript.text == "hello transcript"
    assert transcript.artifact_ref =~ "mem:"

    assert {:ok, ocr} =
             Tools.ocr_document(workspace, %{document_base64: Base.encode64("pdf")}, opts)

    assert ocr.markdown =~ "OCR"
    assert ocr.artifact_ref =~ "mem:"

    assert {:ok, vision} =
             Tools.vision_analyze(
               workspace,
               %{prompt: "describe", image_base64: Base.encode64("png"), media_type: "image/png"},
               opts
             )

    assert vision.text =~ "button"
    assert vision.artifact_ref =~ "mem:"
  end

  test "browser tools use a supervised fake backend and compose screenshots with vision" do
    {:ok, store} = InMemory.start_link()
    workspace = sample_workspace(persistence: {InMemory, store})
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    {:ok, session} =
      RunicAI.Browser.Session.start_link(
        backend: RunicAI.Browser.Backends.Fake,
        backend_opts: [
          html:
            "<html><title>Fixture</title><h1>Fixture Page</h1><button>Approve</button></html>",
          console: [%{level: "log", text: "ready"}]
        ]
      )

    browser_opts = [
      session: session,
      event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
    ]

    media_opts = [
      client: fn :vision_analyze, _model, input, _opts ->
        {:ok, %{text: "vision saw #{byte_size(input.image)} bytes"}}
      end
    ]

    assert {:ok, nav} =
             Tools.browser_navigate(workspace, %{url: "https://example.test"}, browser_opts)

    assert nav.action == :navigated
    assert nav.snapshot =~ "Fixture Page"

    assert {:ok, snapshot} = Tools.browser_snapshot(workspace, %{}, browser_opts)
    assert map_size(snapshot.refs) >= 1

    assert {:ok, clicked} = Tools.browser_click(workspace, %{ref: "@e1"}, browser_opts)
    assert clicked.selector == "@e1"

    assert {:ok, console} = Tools.browser_console(workspace, %{}, browser_opts)
    assert console.count == 1

    assert {:ok, screenshot} = Tools.browser_screenshot(workspace, %{}, browser_opts)
    assert screenshot.artifact_ref =~ "mem:"
    assert screenshot.image_byte_size == 8

    assert {:ok, vision} =
             Tools.browser_vision(workspace, %{prompt: "describe"}, browser_opts, media_opts)

    assert vision.text =~ "8 bytes"
    assert vision.screenshot_artifact_ref =~ "mem:"

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &(&1.kind == :browser_operation_started and &1.metadata.operation == :navigate)
           )

    assert Enum.any?(
             emitted,
             &(&1.kind == :browser_operation_completed and &1.metadata.operation == :snapshot and
                 &1.output.refs_count >= 1)
           )

    assert Enum.any?(
             emitted,
             &(&1.kind == :browser_operation_completed and &1.metadata.operation == :click and
                 &1.output.selector == "@e1")
           )

    assert Enum.any?(
             emitted,
             &(&1.kind == :browser_operation_completed and &1.metadata.operation == :screenshot and
                 &1.output.image_byte_size == 8)
           )
  end

  test "clarify returns a wait and delegate_task persists compact subagent records" do
    workspace = sample_workspace()

    assert {:ok, wait} =
             Tools.clarify(workspace, %{
               question: "Which file should I edit?",
               choices: ["README.md", "CHANGELOG.md"]
             })

    assert wait.kind == :clarify
    assert wait.payload.question =~ "Which file"
    assert wait.payload.choices == ["README.md", "CHANGELOG.md"]

    {:ok, store} = SQLite.open(database: ":memory:", migrate?: true)
    on_exit(fn -> SQLite.close(store) end)

    runner = fn objective, _args, _context ->
      {:ok, %{summary: "child handled #{objective}", artifact_refs: ["artifact:child"]}}
    end

    assert {:ok, delegated} =
             Tools.delegate_task(
               workspace,
               %{
                 objective: "Read README",
                 agent_kind: "standard",
                 profile: "coding_read",
                 session_id: "session:parent",
                 run_id: "run:parent"
               },
               [runner: runner],
               store
             )

    assert delegated.summary == "child handled Read README"
    assert delegated.intermediate_events_included? == false

    subagents =
      SQLite.with_repo(store, fn ->
        store.repo.all(from(run in SubagentRun, where: run.parent_session_id == "session:parent"))
      end)

    assert [%SubagentRun{status: "completed", result_json: result_json}] = subagents
    assert result_json["summary"] == "child handled Read README"
    assert result_json["intermediate_events_included?"] == false
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
