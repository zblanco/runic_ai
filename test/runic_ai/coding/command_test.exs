defmodule RunicAI.Coding.CommandTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.CommandRunner
  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace

  test "runs direct argv commands and captures normalized output" do
    workspace = Workspace.new!(root: tmp_dir())
    policy = CommandPolicy.new!(allowed_commands: ["elixir"], max_output_bytes: 10)

    assert {:ok, result} =
             CommandRunner.run(
               workspace,
               %{argv: ["elixir", "-e", ~S|IO.write("hello world")|]},
               policy: policy
             )

    assert result.status == :pass
    assert result.output == "hello worl"
    assert result.truncated?
    assert result.artifact_ref =~ "sha256:"
    assert result.metadata.classification == :unknown
    assert result.metadata.mutates?
  end

  test "classifies read-only commands in result metadata" do
    workspace = Workspace.new!(root: tmp_dir())
    policy = CommandPolicy.new!(allowed_commands: ["echo"])

    assert {:ok, result} =
             CommandRunner.run(workspace, %{argv: ["echo", "hello"]}, policy: policy)

    assert result.status == :pass
    assert result.metadata.classification == :read_only
    refute result.metadata.network?
    refute result.metadata.mutates?
  end

  test "normalizes command failures without making them tool errors" do
    workspace = Workspace.new!(root: tmp_dir())
    policy = CommandPolicy.new!(allowed_commands: ["elixir"])

    assert {:ok, result} =
             CommandRunner.run(
               workspace,
               %{argv: ["elixir", "-e", "System.halt(2)"]},
               policy: policy
             )

    assert result.status == :fail
    assert result.exit_status == 2
  end

  test "blocks shell backend unless policy allows it" do
    workspace = Workspace.new!(root: tmp_dir())

    assert {:ok, result} =
             CommandRunner.run(workspace, %{backend: "shell", command: "echo nope"})

    assert result.status == :blocked
    assert hd(result.diagnostics).message =~ "shell"
  end

  test "runs just_bash as an optional in-memory shell backend" do
    workspace = Workspace.new!(root: tmp_dir())
    policy = CommandPolicy.new!(allowed_commands: ["just_bash"])

    assert {:ok, result} =
             CommandRunner.run(
               workspace,
               %{backend: "just_bash", command: "echo hi"},
               policy: policy
             )

    assert result.status == :pass
    assert result.output == "hi\n"
    assert result.metadata.backend == :just_bash
  end

  test "allows disabling just_bash independently of shell commands" do
    workspace = Workspace.new!(root: tmp_dir())

    policy =
      CommandPolicy.new!(
        allowed_commands: ["just_bash"],
        allow_shell: true,
        allow_just_bash: false
      )

    assert {:ok, result} =
             CommandRunner.run(
               workspace,
               %{backend: "just_bash", command: "echo hi"},
               policy: policy
             )

    assert result.status == :blocked
    assert hd(result.diagnostics).message =~ "just_bash"
  end

  test "enforces env allowlist and timeout" do
    workspace = Workspace.new!(root: tmp_dir())
    policy = CommandPolicy.new!(allowed_commands: ["elixir"], timeout_ms: 50)

    assert {:ok, blocked} =
             CommandRunner.run(
               workspace,
               %{
                 argv: ["elixir", "-e", "IO.write(System.get_env(\"SECRET\"))"],
                 env: %{"SECRET" => "x"}
               },
               policy: policy
             )

    assert blocked.status == :blocked

    assert {:ok, timeout} =
             CommandRunner.run(
               workspace,
               %{argv: ["elixir", "-e", "Process.sleep(:infinity)"]},
               policy: policy
             )

    assert timeout.status == :timeout
  end

  test "stores truncated command output through workspace persistence" do
    {:ok, store} = InMemory.start_link()
    workspace = Workspace.new!(root: tmp_dir(), persistence: {InMemory, store})
    policy = CommandPolicy.new!(allowed_commands: ["elixir"], max_output_bytes: 5)

    assert {:ok, result} =
             CommandRunner.run(
               workspace,
               %{argv: ["elixir", "-e", ~S|IO.write("hello world")|]},
               policy: policy
             )

    assert result.truncated?
    assert result.artifact_ref =~ "mem:"
    assert {:ok, artifact} = Persistence.get_artifact(workspace.persistence, result.artifact_ref)
    assert artifact.content == "hello world"
  end

  @tag timeout: 60_000
  test "runs Mix profile compile, tests, and formatter through the command runner" do
    root = mix_project_fixture()
    workspace = Workspace.new!(root: root)
    policy = CommandPolicy.new!(allowed_commands: ["mix"], timeout_ms: 30_000)

    assert {:ok, compile} = Tools.run_profile_task(workspace, :compile_project, %{}, policy)
    assert compile.status == :pass

    assert {:ok, tests} = Tools.run_profile_task(workspace, :run_tests, %{}, policy)
    assert tests.status == :pass

    assert {:ok, format} = Tools.run_profile_task(workspace, :run_formatter, %{}, policy)
    assert format.status == :pass
  end

  test "uses detected Mix profile command definitions" do
    root = tmp_dir()
    File.write!(Path.join(root, "mix.exs"), "defmodule Demo.MixProject do\nend\n")
    workspace = Workspace.new!(root: root)

    assert {:error, error} =
             Tools.run_profile_task(workspace, :missing_task, %{}, CommandPolicy.new!())

    assert error.message =~ "does not define"
    assert {:ok, ["mix", "test"]} = RunicAI.Coding.Profile.command(workspace.profile, :run_tests)
  end

  @tag timeout: 60_000
  test "profile task tools detect Mix profile from cwd under a generic workspace" do
    root = tmp_dir()
    project = Path.join(root, "nested_app")
    File.mkdir_p!(Path.join(project, "test"))

    File.write!(Path.join(project, "mix.exs"), """
    defmodule NestedApp.MixProject do
      use Mix.Project

      def project, do: [app: :nested_app, version: "0.1.0", elixir: "~> 1.18", deps: []]
    end
    """)

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(project, "test/nested_app_test.exs"), """
    defmodule NestedAppTest do
      use ExUnit.Case, async: true
      test "ok", do: assert(true)
    end
    """)

    workspace = Workspace.new!(root: root)
    assert workspace.profile.name == :generic

    assert {:ok, result} =
             Tools.run_profile_task(workspace, :run_tests, %{cwd: "nested_app"},
               allowed_commands: ["mix"],
               timeout_ms: 30_000
             )

    assert result.status == :pass
  end

  defp mix_project_fixture do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, ".formatter.exs"), """
    [
      inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"]
    ]
    """)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end

      def application, do: []
    end
    """)

    File.write!(Path.join(root, "lib/demo.ex"), """
    defmodule Demo do
      def answer, do: 42
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/demo_test.exs"), """
    defmodule DemoTest do
      use ExUnit.Case, async: true

      test "answer" do
        assert Demo.answer() == 42
      end
    end
    """)

    root
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
