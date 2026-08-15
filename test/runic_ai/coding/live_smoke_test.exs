defmodule RunicAI.Coding.LiveSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :live_smoke

  if System.get_env("RUNIC_AI_LIVE_SMOKE") != "1" do
    @moduletag skip: "set RUNIC_AI_LIVE_SMOKE=1 to run the live coding-agent smoke test"
  end

  alias Runic.Workflow
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Recipes.IntegratedToolAgent

  @model "openai:gpt-5.6-luna"
  @required_tools MapSet.new(["apply_patch", "run_tests"])
  @read_tools MapSet.new(["find_files", "list_dir", "read_file", "read_many", "search_text"])

  @tag timeout: 180_000
  test "gpt-5.6-luna can inspect, patch, and verify a disposable Mix project" do
    root = mix_project_fixture()
    workspace = Workspace.new!(root: root)

    assert {_output, failing_status} =
             System.cmd("mix", ["test"], cd: root, stderr_to_stdout: true)

    assert failing_status != 0

    command_policy =
      CommandPolicy.new!(
        allowed_commands: ["mix"],
        timeout_ms: 30_000,
        max_output_bytes: 32_768,
        allow_shell: false
      )

    registry = Tools.default_registry(workspace, command_policy: command_policy)

    workflow =
      IntegratedToolAgent.new(
        model: @model,
        registry: registry,
        visible_tools: [
          "list_dir",
          "find_files",
          "read_file",
          "read_many",
          "search_text",
          "apply_patch",
          "run_tests"
        ],
        tool_requirement: :required,
        max_turns: 8,
        system: """
        You are a coding agent smoke test running inside a disposable Elixir Mix project.
        Use the available tools to inspect the project, find the failing test, make the
        smallest patch, and run the tests after editing. Do not use shell commands. Do not
        modify files outside the workspace.

        Keep using tools until you have run the test tool and observed a passing result.
        Do not give a final answer before you have used apply_patch and run_tests. When
        the tests pass, reply with a concise summary and include RUNIC_AI_LIVE_SMOKE_DONE.
        """
      )
      |> Workflow.react_until_satisfied(%{
        user: """
        The project has one failing test. Fix the implementation, verify it with the
        test tool, and summarize the result.
        """
      })

    session = IntegratedToolAgent.session(workflow, "agent")
    tool_names = tool_names(session)
    latest_reply = IntegratedToolAgent.latest_reply_text(workflow, "agent")

    assert MapSet.subset?(@required_tools, MapSet.new(tool_names)),
           "expected #{inspect(MapSet.to_list(@required_tools))}, got #{inspect(tool_names)}; latest reply: #{inspect(latest_reply)}"

    assert Enum.any?(tool_names, &MapSet.member?(@read_tools, &1)),
           "expected at least one read/search tool, got #{inspect(tool_names)}"

    assert File.read!(Path.join(root, "lib/smoke.ex")) =~ "42"

    {test_output, test_status} = System.cmd("mix", ["test"], cd: root, stderr_to_stdout: true)

    assert test_status == 0, test_output
    assert test_output =~ "1 test, 0 failures"

    assert latest_reply =~ "RUNIC_AI_LIVE_SMOKE_DONE"
  end

  defp mix_project_fixture do
    root = tmp_dir()

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Smoke.MixProject do
      use Mix.Project

      def project do
        [
          app: :smoke,
          version: "0.1.0",
          elixir: "~> 1.18",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """)

    File.write!(Path.join(root, "lib/smoke.ex"), """
    defmodule Smoke do
      def answer, do: 41
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/smoke_test.exs"), """
    defmodule SmokeTest do
      use ExUnit.Case, async: true

      test "answer is correct" do
        assert Smoke.answer() == 42
      end
    end
    """)

    root
  end

  defp tool_names(session) do
    session.agent_state.conversation.messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(& &1.name)
    |> Enum.reject(&is_nil/1)
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "runic-ai-live-smoke-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
