defmodule RunicAI.RLM.SandboxLiveLanes do
  @moduledoc """
  Live/manual sandbox lane preflight reports for Phase 8 evaluation.

  This module keeps backend-specific checks out of the strategy fixtures. It
  answers a narrower question: which real-world lanes are ready to run, which
  are missing host/provider prerequisites, and which safe local smoke checks
  were executed.
  """

  @default_output_dir "tmp/rlm_sandbox_eval/reports"
  @default_image "runic-ai/sandbox:elixir-python-node"

  @lane_ids [:docker_polyglot, :vmsan_microvm, :sprites_stateful, :no_network_offline]

  @spec lane_ids() :: [atom()]
  def lane_ids, do: @lane_ids

  @spec preflight(keyword()) :: map()
  def preflight(opts \\ []) when is_list(opts) do
    execute? = Keyword.get(opts, :execute?, false)

    lanes = [
      docker_lane(opts, execute?),
      vmsan_lane(opts, execute?),
      sprites_lane(opts, execute?),
      no_network_lane(opts, execute?)
    ]

    %{
      generated_at: DateTime.utc_now(),
      execute?: execute?,
      lanes: lanes,
      summary: summary(lanes)
    }
  end

  @spec write_report!(Path.t(), keyword()) :: map()
  def write_report!(output_dir \\ @default_output_dir, opts \\ [])
      when is_binary(output_dir) and is_list(opts) do
    report = preflight(opts)
    File.mkdir_p!(output_dir)

    basename = Keyword.get(opts, :basename, "sandbox-live-lanes")
    json_path = Path.join(output_dir, "#{basename}.json")
    markdown_path = Path.join(output_dir, "#{basename}.md")

    File.write!(json_path, Jason.encode!(payload(report), pretty: true))
    File.write!(markdown_path, markdown(report))

    %{report: report, json_path: json_path, markdown_path: markdown_path}
  end

  @spec payload(map()) :: map()
  def payload(report) when is_map(report) do
    %{
      generated_at: timestamp(report.generated_at),
      execute?: report.execute?,
      summary: report.summary,
      lanes: report.lanes
    }
  end

  @spec markdown(map()) :: String.t()
  def markdown(report) when is_map(report) do
    rows =
      Enum.map(report.lanes, fn lane ->
        [
          lane.id,
          lane.backend,
          lane.status,
          lane.ready?,
          lane.executed?,
          lane.smoke && lane.smoke.status,
          lane.manual_command || ""
        ]
        |> Enum.map(&to_string/1)
        |> Enum.join(" | ")
      end)

    """
    # Sandbox Live Lane Preflight

    Generated: #{timestamp(report.generated_at)}

    Execute smoke checks: #{report.execute?}

    | Lane | Backend | Status | Ready | Executed | Smoke | Manual command |
    | --- | --- | --- | --- | --- | --- | --- |
    #{Enum.map_join(rows, "\n", &("| " <> &1 <> " |"))}

    ## Summary

    - ready: #{report.summary.ready}
    - passed: #{report.summary.passed}
    - skipped: #{report.summary.skipped}
    - blocked: #{report.summary.blocked}
    """
  end

  defp docker_lane(opts, execute?) do
    image = Keyword.get(opts, :docker_image, @default_image)
    docker_path = find_executable(opts, "docker")

    docker_info =
      if docker_path, do: command(opts, docker_path, ["info", "--format", "{{.ServerVersion}}"])

    image_info =
      if command_success?(docker_info),
        do: command(opts, docker_path, ["image", "inspect", image])

    checks = [
      check(:docker_cli, docker_path != nil, "Docker CLI is installed"),
      check(:docker_daemon, command_success?(docker_info), "Docker daemon is reachable"),
      check(
        :docker_image,
        command_success?(image_info),
        "Configured sandbox image exists locally",
        details: %{image: image}
      )
    ]

    ready? = Enum.all?(checks, & &1.passed?)
    smoke = maybe_docker_smoke(opts, execute?, ready?, image)

    lane(
      :docker_polyglot,
      :docker,
      ready?,
      execute?,
      checks,
      smoke,
      "mix runic_ai.sandbox.image --no-build --image #{image}",
      %{image: image, runtimes: [:bash, :python, :node, :elixir, :lua]}
    )
  end

  defp maybe_docker_smoke(_opts, false, _ready?, _image), do: nil

  defp maybe_docker_smoke(_opts, true, false, _image),
    do: smoke(:skipped, "docker lane is not ready")

  defp maybe_docker_smoke(opts, true, true, image) do
    smokes = [
      bash: "printf bash-ok",
      python: "print('python-ok')",
      node: "console.log('node-ok')",
      elixir: "IO.puts(\"elixir-ok\")",
      lua: "print('lua-ok')"
    ]

    results =
      Enum.map(smokes, fn {runtime, source} ->
        case sandbox_exec(
               opts,
               %{
                 sandbox: :local_code,
                 runtime: runtime,
                 source: source,
                 timeout_ms: 30_000,
                 max_output_bytes: 8_192
               },
               profile: [
                 backend: :docker,
                 image: image,
                 runtimes: [runtime],
                 network: :disabled,
                 workspace: [mode: :copy_in, persist?: false]
               ]
             ) do
          {:ok, %{status: :pass, stdout: stdout, isolation_level: :container}} ->
            %{runtime: runtime, status: :pass, stdout: String.trim(stdout)}

          {:ok, result} ->
            %{runtime: runtime, status: :fail, result: inspect(result)}

          {:error, error} ->
            %{runtime: runtime, status: :error, error: error_message(error)}
        end
      end)

    if Enum.all?(results, &(&1.status == :pass)) do
      smoke(:pass, "docker polyglot smoke passed", %{results: results})
    else
      smoke(:fail, "docker polyglot smoke failed", %{results: results})
    end
  end

  defp vmsan_lane(opts, execute?) do
    executable = find_executable(opts, "vmsan")
    version = if executable, do: command(opts, executable, ["--version"])
    kvm_exists? = file_exists?(opts, "/dev/kvm")

    status =
      sandbox_status(opts, profile: [backend: :vmsan, runtimes: [:bash], network: :disabled])

    health = status_health(status, :vmsan)

    checks = [
      check(:vmsan_cli, executable != nil, "vmsan CLI is installed"),
      check(:vmsan_version, command_success?(version), "vmsan version command succeeds"),
      check(:kvm_device, kvm_exists?, "/dev/kvm exists"),
      check(:litter_box_health, health_ready?(health), "LitterBox vmsan health is ready")
    ]

    ready? = Enum.all?(checks, & &1.passed?)

    lane(
      :vmsan_microvm,
      :vmsan,
      ready?,
      false,
      checks,
      if(execute?, do: smoke(:skipped, "vmsan live execution is manual-gated"), else: nil),
      "mix runic_ai.rlm.sandbox_eval --live-lanes --execute-live-lanes",
      %{version: command_output(version), health: health}
    )
  end

  defp sprites_lane(opts, execute?) do
    token_env = Keyword.get(opts, :sprites_token_env, "SPRITES_TOKEN")
    token_present? = env(opts, token_env) not in [nil, ""]

    status =
      sandbox_status(opts,
        profile: [
          backend: :sprites,
          runtimes: [:bash],
          network: :restricted,
          backend_options: [
            token_env: token_env,
            sprite: Keyword.get(opts, :sprites_name, "runic-ai-phase8-preflight"),
            create_policy: :reuse
          ]
        ]
      )

    health = status_health(status, :sprites)

    checks = [
      check(:sprites_token, token_present?, "#{token_env} is configured"),
      check(:litter_box_health, health_ready?(health), "LitterBox sprites health is ready")
    ]

    ready? = Enum.all?(checks, & &1.passed?)

    smoke = maybe_sprites_smoke(opts, execute?, ready?, token_env)

    lane(
      :sprites_stateful,
      :sprites,
      ready?,
      execute?,
      checks,
      smoke,
      "SPRITES_TOKEN=... mix runic_ai.rlm.sandbox_eval --live-lanes --execute-live-lanes",
      %{token_env: token_env, token_present?: token_present?, health: health}
    )
  end

  defp maybe_sprites_smoke(_opts, false, _ready?, _token_env), do: nil

  defp maybe_sprites_smoke(_opts, true, false, _token_env),
    do: smoke(:skipped, "Sprites lane is not ready")

  defp maybe_sprites_smoke(opts, true, true, token_env) do
    sprite =
      Keyword.get_lazy(opts, :sprites_name, fn ->
        "runic-ai-live-lane-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
      end)

    case sandbox_exec(
           opts,
           %{
             sandbox: :sprites_stateful,
             runtime: :bash,
             source: "printf sprites-live-ok",
             cwd: "/home/sprite",
             network: :restricted,
             timeout_ms: 30_000,
             max_output_bytes: 1_024
           },
           profile: [
             name: :sprites_stateful,
             backend: :sprites,
             runtimes: [:bash],
             network: :restricted,
             backend_options: [
               token_env: token_env,
               sprite: sprite,
               create_policy: :ephemeral
             ]
           ],
           timeout_ms: 60_000
         ) do
      {:ok, %{status: :pass, stdout: "sprites-live-ok", metadata: metadata} = result} ->
        smoke(:pass, "Sprites stateful smoke passed", %{
          sprite: Map.get(metadata, :sprite),
          backend: Map.get(result, :backend, :sprites),
          isolation_level: Map.get(result, :isolation_level),
          stateful?: Map.get(metadata, :stateful?),
          security_boundary?: Map.get(metadata, :security_boundary?)
        })

      {:ok, %{status: :pass, stdout: stdout} = result} ->
        smoke(:fail, "Sprites stateful smoke returned unexpected stdout", %{
          stdout: stdout,
          stderr: Map.get(result, :stderr),
          exit_status: Map.get(result, :exit_status)
        })

      {:ok, result} ->
        smoke(:fail, "Sprites stateful smoke failed", %{result: inspect(result)})

      {:error, error} ->
        smoke(:error, "Sprites stateful smoke errored", %{error: error_message(error)})
    end
  end

  defp no_network_lane(opts, execute?) do
    checks = [
      check(:network_policy, true, "request network policy is disabled"),
      check(:backend, true, "just_bash offline smoke is available")
    ]

    smoke =
      if execute? do
        case sandbox_exec(
               opts,
               %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "printf no-network-offline",
                 network: :disabled,
                 timeout_ms: 5_000,
                 max_output_bytes: 1_024
               },
               profile: [
                 backend: :just_bash,
                 runtimes: [:bash],
                 network: :disabled,
                 workspace: [mode: :copy_in, persist?: false]
               ]
             ) do
          {:ok, %{status: :pass, stdout: "no-network-offline", metadata: metadata}} ->
            smoke(:pass, "no-network offline smoke passed", %{network: metadata.network})

          {:ok, result} ->
            smoke(:fail, "no-network offline smoke failed", %{result: inspect(result)})

          {:error, error} ->
            smoke(:error, "no-network offline smoke errored", %{error: error_message(error)})
        end
      end

    lane(
      :no_network_offline,
      :just_bash,
      true,
      execute?,
      checks,
      smoke,
      "mix runic_ai.rlm.sandbox_eval --live-lanes --execute-live-lanes",
      %{network: :disabled}
    )
  end

  defp lane(id, backend, ready?, execute?, checks, smoke, manual_command, metadata) do
    status =
      cond do
        smoke && smoke.status in [:fail, :error] -> :blocked
        smoke && smoke.status == :pass -> :pass
        ready? -> :ready
        true -> :skipped
      end

    %{
      id: id,
      backend: backend,
      status: status,
      ready?: ready?,
      executed?: execute? and smoke != nil and smoke.status != :skipped,
      checks: checks,
      smoke: smoke,
      manual_command: manual_command,
      metadata: metadata
    }
  end

  defp check(id, passed?, message, opts \\ []) do
    %{
      id: id,
      passed?: passed?,
      status: if(passed?, do: :pass, else: :skip),
      message: message,
      details: Keyword.get(opts, :details, %{})
    }
  end

  defp smoke(status, message, details \\ %{}),
    do: %{status: status, message: message, details: details}

  defp summary(lanes) do
    %{
      ready: Enum.count(lanes, & &1.ready?),
      passed: Enum.count(lanes, &(&1.status == :pass)),
      skipped: Enum.count(lanes, &(&1.status == :skipped)),
      blocked: Enum.count(lanes, &(&1.status == :blocked))
    }
  end

  defp status_health({:ok, %{backends: backends}}, name) when is_list(backends) do
    Enum.find(backends, &(&1.name == name))
  end

  defp status_health({:error, error}, _name),
    do: %{available?: false, diagnostics: [error_message(error)]}

  defp status_health(_other, _name), do: nil

  defp health_ready?(%{available?: true}), do: true
  defp health_ready?(%{exec_ready?: true}), do: true
  defp health_ready?(_health), do: false

  defp find_executable(opts, executable) do
    Keyword.get(opts, :find_executable, &System.find_executable/1).(executable)
  end

  defp command(opts, executable, args) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case command_runner.(executable, args, stderr_to_stdout: true) do
      {output, status} ->
        if(status == 0, do: {:ok, status, output}, else: {:error, status, output})
    end
  rescue
    exception -> {:error, :exception, Exception.message(exception)}
  end

  defp command_output({:ok, _status, output}), do: String.trim(output)
  defp command_output(_other), do: nil

  defp command_success?({:ok, 0, _output}), do: true
  defp command_success?(_result), do: false

  defp file_exists?(opts, path), do: Keyword.get(opts, :file_exists?, &File.exists?/1).(path)
  defp env(opts, name), do: Keyword.get(opts, :env, &System.get_env/1).(name)

  defp sandbox_exec(opts, request, exec_opts),
    do: Keyword.get(opts, :sandbox_exec, &LitterBox.exec/2).(request, exec_opts)

  defp sandbox_status(opts, status_opts),
    do: Keyword.get(opts, :sandbox_status, &LitterBox.status/1).(status_opts)

  defp error_message(%{message: message}), do: message
  defp error_message(error), do: inspect(error)

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
