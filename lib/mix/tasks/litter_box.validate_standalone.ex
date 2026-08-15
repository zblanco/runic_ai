defmodule Mix.Tasks.LitterBox.ValidateStandalone do
  @moduledoc """
  Validate the extraction-facing LitterBox API from a tiny Mix project.

      mix litter_box.validate_standalone

  The task creates a temporary project with a path dependency on the local
  sibling `litter_box` package,
  starts `{LitterBox, ...}` in that project, executes a small JustBash
  snippet through the facade, then removes the temporary project unless
  `--keep` is supplied.
  """

  use Mix.Task

  @shortdoc "Smoke test LitterBox from a standalone Mix project"

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          keep: :boolean,
          tmp_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("invalid litter_box.validate_standalone options: #{inspect(invalid)}")
    end

    package_root = Path.expand("../litter_box", File.cwd!())
    project_dir = project_dir(opts)

    File.rm_rf!(project_dir)
    File.mkdir_p!(Path.join(project_dir, "config"))

    write_mix_project!(project_dir, package_root)
    write_smoke_script!(project_dir)

    try do
      run_mix!(project_dir, ["deps.get"])
      run_mix!(project_dir, ["run", "litter_box_smoke.exs"])
      Mix.shell().info("LitterBox standalone smoke passed in #{project_dir}")
    after
      unless Keyword.get(opts, :keep, false) do
        File.rm_rf!(project_dir)
      end
    end
  end

  defp project_dir(opts) do
    Keyword.get_lazy(opts, :tmp_dir, fn ->
      Path.join(
        System.tmp_dir!(),
        "litter_box_standalone_#{System.unique_integer([:positive])}"
      )
    end)
  end

  defp write_mix_project!(project_dir, package_root) do
    File.write!(Path.join(project_dir, "mix.exs"), """
    defmodule LitterBoxStandalone.MixProject do
      use Mix.Project

      def project do
        [
          app: :litter_box_standalone,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: deps()
        ]
      end

      def application do
        [
          extra_applications: [:logger]
        ]
      end

      defp deps do
        [
          {:litter_box, path: #{inspect(package_root)}},
          {:just_bash, "~> 0.3"}
        ]
      end
    end
    """)
  end

  defp write_smoke_script!(project_dir) do
    File.write!(Path.join(project_dir, "litter_box_smoke.exs"), """
    children = [
      {LitterBox,
       name: LitterBoxStandalone.Sandbox,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           pool: [warm: 0, max: 1],
           network: :disabled,
           workspace: [mode: :copy_in, persist?: false]
         ]
       ]}
    ]

    {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    {:ok, status} = LitterBox.status(server: LitterBoxStandalone.Sandbox)
    :just_bash = status.sandboxes.local_code.backend

    {:ok, result} =
      LitterBox.exec(
        %{
          sandbox: :local_code,
          runtime: :bash,
          source: "echo standalone-litter-box",
          timeout_ms: 5_000
        },
        server: LitterBoxStandalone.Sandbox
      )

    :pass = result.status
    :just_bash = result.backend
    :in_process_virtual = result.isolation_level
    "standalone-litter-box\\n" = result.stdout

    IO.puts("standalone status=ok backend=\#{result.backend} isolation=\#{result.isolation_level}")
    """)
  end

  defp run_mix!(project_dir, args) do
    env = [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", Path.join(project_dir, "_build")},
      {"MIX_DEPS_PATH", Path.join(project_dir, "deps")}
    ]

    case System.cmd("mix", args, cd: project_dir, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)

      {output, status} ->
        Mix.shell().error(output)

        Mix.raise(
          "standalone Mix command failed with status #{status}: mix #{Enum.join(args, " ")}"
        )
    end
  end
end
