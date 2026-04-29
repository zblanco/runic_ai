defmodule Mix.Tasks.RunicAi.Coding.Smoke do
  @moduledoc """
  Smoke test the local coding harness against a workspace.

      mix runic_ai.coding.smoke --cwd .

  The task exercises read-only inspection, patch dry-run, and bounded command
  execution without running a full agent loop.
  """

  use Mix.Task

  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.Profile
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Tool.Registry

  @shortdoc "Smoke test RunicAI coding tools"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          profile: :string,
          session_id: :string,
          test: :boolean,
          tools: :string
        ],
        aliases: [c: :cwd]
      )

    cwd = Keyword.get(opts, :cwd, File.cwd!())
    session_id = Keyword.get(opts, :session_id, "local-smoke")
    workspace = Workspace.new!(workspace_opts(cwd, opts))

    command_policy =
      CommandPolicy.new!(
        allowed_commands: ["mix"],
        timeout_ms: 30_000,
        max_output_bytes: 16_384
      )

    registry = Tools.default_registry(workspace, command_policy: command_policy)
    visible_tools = selected_tools(registry, Keyword.get(opts, :tools))

    Mix.shell().info("Session: #{session_id}")
    Mix.shell().info("Workspace: #{workspace.root}")
    Mix.shell().info("Profile: #{workspace.profile.name}")
    Mix.shell().info("Tools: #{Enum.join(visible_tools, ", ")}")

    {:ok, listing} = Tools.list_dir(workspace, %{path: ".", limit: 20})
    Mix.shell().info("Entries: #{listing.count}")

    {:ok, dry_run} =
      Tools.apply_patch(workspace, %{
        dry_run: true,
        operations: [
          %{
            op: :create,
            path: "runic_ai_smoke_probe",
            content: "probe\n"
          }
        ]
      })

    Mix.shell().info(
      "Patch dry-run status: #{dry_run.status}; operations: #{length(dry_run.operation_summaries)}"
    )

    if workspace.profile.name == :mix do
      {:ok, version} =
        Tools.run_command(
          workspace,
          %{argv: ["mix", "--version"], cwd: ".", timeout_ms: 10_000},
          command_policy
        )

      Mix.shell().info("Command status: #{version.status}; bytes: #{version.output_bytes}")
    end

    if Keyword.get(opts, :test, false) and workspace.profile.name == :mix do
      {:ok, result} = Tools.run_profile_task(workspace, :run_tests, %{}, command_policy)
      Mix.shell().info("Test command status: #{result.status}")
    end

    Mix.shell().info("Final observation: smoke complete")
  end

  defp workspace_opts(cwd, opts) do
    case profile_from_opts(opts) do
      nil -> [root: cwd]
      profile -> [root: cwd, profile: profile]
    end
  end

  defp profile_from_opts(opts) do
    case Keyword.get(opts, :profile) do
      nil -> nil
      "mix" -> Profile.mix()
      "generic" -> Profile.generic()
      profile -> Mix.raise("unknown coding profile: #{profile}")
    end
  end

  defp selected_tools(registry, nil), do: Registry.names(registry)

  defp selected_tools(registry, tools) do
    requested =
      tools
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    missing = Enum.reject(requested, &match?({:ok, _definition}, Registry.fetch(registry, &1)))

    if missing != [] do
      Mix.raise("unknown coding tools: #{Enum.join(missing, ", ")}")
    end

    requested
  end
end
