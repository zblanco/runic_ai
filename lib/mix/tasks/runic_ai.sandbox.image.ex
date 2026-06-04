defmodule Mix.Tasks.RunicAi.Sandbox.Image do
  @moduledoc """
  Build and smoke test the default RunicAI sandbox Docker image.

      mix runic_ai.sandbox.image
      mix runic_ai.sandbox.image --no-build --image runic-ai/sandbox:elixir-python-node
      mix runic_ai.sandbox.image --variant agent-cli
  """

  use Mix.Task

  @shortdoc "Build and smoke test the RunicAI sandbox image"

  @default_image "runic-ai/sandbox:elixir-python-node"
  @default_dockerfile "priv/runic_ai/sandbox/Dockerfile"
  @agent_cli_image "runic-ai/sandbox-agent-cli:latest"
  @agent_cli_dockerfile "priv/runic_ai/sandbox/agent-cli/Dockerfile"
  @variants %{
    "default" => %{image: @default_image, dockerfile: @default_dockerfile, cli_smoke?: false},
    "agent-cli" => %{image: @agent_cli_image, dockerfile: @agent_cli_dockerfile, cli_smoke?: true}
  }

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
          variant: :string,
          image: :string,
          dockerfile: :string,
          build: :boolean,
          no_build: :boolean,
          smoke: :boolean,
          no_smoke: :boolean,
          cli_smoke: :boolean,
          no_cli_smoke: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid runic_ai.sandbox.image options: #{inspect(invalid)}")
    end

    variant_name = Keyword.get(opts, :variant, "default")

    variant =
      Map.get(@variants, variant_name) ||
        Mix.raise("unknown sandbox image variant: #{variant_name}")

    image = Keyword.get(opts, :image, variant.image)
    dockerfile = Keyword.get(opts, :dockerfile, variant.dockerfile)

    if build?(opts) do
      build_image!(image, dockerfile)
    end

    if smoke?(opts) do
      smoke_image!(image)

      if cli_smoke?(opts, variant) do
        smoke_agent_cli!(image)
      end
    end
  end

  defp build?(opts), do: Keyword.get(opts, :build, not Keyword.get(opts, :no_build, false))
  defp smoke?(opts), do: Keyword.get(opts, :smoke, not Keyword.get(opts, :no_smoke, false))

  defp cli_smoke?(opts, variant) do
    Keyword.get(opts, :cli_smoke, variant.cli_smoke?) and
      not Keyword.get(opts, :no_cli_smoke, false)
  end

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

  defp smoke_agent_cli!(image) do
    profile = [
      backend: :docker,
      image: image,
      runtimes: [:bash],
      network: :disabled,
      backend_options: [
        environment: %{
          "RUNIC_MCP_URL" => "http://host.docker.internal:4000",
          "RUNIC_MODEL_PROXY_URL" => "http://host.docker.internal:4100"
        }
      ],
      workspace: [mode: :copy_in, persist?: false]
    ]

    case RunicSandbox.exec(
           %{
             sandbox: :local_code,
             runtime: :bash,
             source:
               "runic-agent-cli-check claude codex; python3 -c 'import json; print(\"python-json=ok\")'; printf 'uid=%s\\n' \"$(id -u)\"; printf 'env=%s|%s\\n' \"$RUNIC_MCP_URL\" \"$RUNIC_MODEL_PROXY_URL\"",
             timeout_ms: 30_000,
             max_output_bytes: 8_192
           },
           profile: profile
         ) do
      {:ok, %{status: :pass, stdout: stdout, isolation_level: :container}} ->
        unless stdout =~ "env=http://host.docker.internal:4000|http://host.docker.internal:4100" and
                 stdout =~ "python-json=ok" and stdout =~ "uid=10001" do
          Mix.raise("agent-cli env smoke failed: #{inspect(stdout)}")
        end

        Mix.shell().info("agent-cli: #{String.trim(stdout)}")

      {:ok, result} ->
        Mix.raise("agent-cli smoke failed: #{inspect(result)}")

      {:error, error} ->
        Mix.raise("agent-cli smoke errored: #{error.message}")
    end
  end
end
