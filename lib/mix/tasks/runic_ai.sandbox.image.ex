defmodule Mix.Tasks.RunicAi.Sandbox.Image do
  @moduledoc """
  Build and smoke test the default RunicAI sandbox Docker image.

      mix runic_ai.sandbox.image
      mix runic_ai.sandbox.image --no-build --image runic-ai/sandbox:elixir-python-node
  """

  use Mix.Task

  @shortdoc "Build and smoke test the RunicAI sandbox image"

  @default_image "runic-ai/sandbox:elixir-python-node"
  @default_dockerfile "priv/runic_ai/sandbox/Dockerfile"

  @smokes [
    bash: "printf bash-ok",
    python: "print('python-ok')",
    node: "console.log('node-ok')",
    elixir: "IO.puts(\"elixir-ok\")",
    lua: "print('lua-ok')"
  ]

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          image: :string,
          dockerfile: :string,
          build: :boolean,
          no_build: :boolean,
          smoke: :boolean,
          no_smoke: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid runic_ai.sandbox.image options: #{inspect(invalid)}")
    end

    image = Keyword.get(opts, :image, @default_image)
    dockerfile = Keyword.get(opts, :dockerfile, @default_dockerfile)

    if build?(opts) do
      build_image!(image, dockerfile)
    end

    if smoke?(opts) do
      smoke_image!(image)
    end
  end

  defp build?(opts), do: Keyword.get(opts, :build, not Keyword.get(opts, :no_build, false))
  defp smoke?(opts), do: Keyword.get(opts, :smoke, not Keyword.get(opts, :no_smoke, false))

  defp build_image!(image, dockerfile) do
    Mix.shell().info("Building #{image} from #{dockerfile}")

    case System.cmd("docker", ["build", "-f", dockerfile, "-t", image, "."],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        Mix.shell().info(output)

      {output, status} ->
        Mix.shell().error(output)
        Mix.raise("docker build failed with status #{status}")
    end
  end

  defp smoke_image!(image) do
    Enum.each(@smokes, fn {runtime, source} ->
      profile = [
        backend: :docker,
        image: image,
        runtimes: [runtime],
        network: :disabled,
        workspace: [mode: :copy_in, persist?: false]
      ]

      case RunicSandbox.exec(
             %{
               sandbox: :local_code,
               runtime: runtime,
               source: source,
               timeout_ms: 30_000,
               max_output_bytes: 8_192
             },
             profile: profile
           ) do
        {:ok, %{status: :pass, stdout: stdout, isolation_level: :container}} ->
          Mix.shell().info("#{runtime}: #{String.trim(stdout)}")

        {:ok, result} ->
          Mix.raise("#{runtime} smoke failed: #{inspect(result)}")

        {:error, error} ->
          Mix.raise("#{runtime} smoke errored: #{error.message}")
      end
    end)
  end
end
