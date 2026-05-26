defmodule RunicAI.RLM.SandboxLiveLanesTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM.SandboxLiveLanes

  test "preflight reports Docker, vmsan, Sprites, and no-network lanes with injected probes" do
    report =
      SandboxLiveLanes.preflight(
        execute?: true,
        find_executable: fn
          "docker" -> "/usr/bin/docker"
          "vmsan" -> "/usr/bin/vmsan"
          _other -> nil
        end,
        command_runner: fn
          "/usr/bin/docker", ["info", "--format", "{{.ServerVersion}}"], _opts ->
            {"28.0.0", 0}

          "/usr/bin/docker", ["image", "inspect", "runic-ai/sandbox:elixir-python-node"], _opts ->
            {"[]", 0}

          "/usr/bin/vmsan", ["--version"], _opts ->
            {"0.3.0", 0}
        end,
        file_exists?: fn "/dev/kvm" -> true end,
        env: fn
          "SPRITES_TOKEN" -> "token"
          _other -> nil
        end,
        sandbox_status: fn
          profile: [backend: :vmsan, runtimes: [:bash], network: :disabled] ->
            {:ok, %{backends: [%{name: :vmsan, available?: true}]}}

          profile: [
            backend: :sprites,
            runtimes: [:bash],
            network: :restricted,
            backend_options: _opts
          ] ->
            {:ok, %{backends: [%{name: :sprites, available?: true}]}}
        end,
        sandbox_exec: fn request, opts ->
          backend = get_in(opts, [:profile, :backend])

          {:ok,
           %{
             status: :pass,
             stdout: smoke_stdout(request.runtime, backend),
             isolation_level: if(backend == :docker, do: :container, else: :in_process_virtual),
             metadata: %{network: Map.get(request, :network)}
           }}
        end
      )

    assert report.summary.ready == 4
    assert report.summary.passed == 3
    assert report.summary.skipped == 0
    assert report.summary.blocked == 0

    docker = lane(report, :docker_polyglot)
    assert docker.status == :pass
    assert docker.smoke.status == :pass
    assert docker.metadata.runtimes == [:bash, :python, :node, :elixir, :lua]

    vmsan = lane(report, :vmsan_microvm)
    assert vmsan.status == :ready
    assert vmsan.smoke.status == :skipped
    assert vmsan.metadata.version == "0.3.0"

    sprites = lane(report, :sprites_stateful)
    assert sprites.status == :pass
    assert sprites.smoke.status == :pass
    assert sprites.metadata.token_present?

    offline = lane(report, :no_network_offline)
    assert offline.status == :pass
    assert offline.smoke.details.network == :disabled
  end

  test "preflight reports unavailable optional live lanes as skipped" do
    report =
      SandboxLiveLanes.preflight(
        find_executable: fn _ -> nil end,
        command_runner: fn _cmd, _args, _opts -> {"missing", 1} end,
        file_exists?: fn _ -> false end,
        env: fn _ -> nil end,
        sandbox_status: fn _opts -> {:ok, %{backends: []}} end
      )

    assert lane(report, :docker_polyglot).status == :skipped
    assert lane(report, :vmsan_microvm).status == :skipped
    assert lane(report, :sprites_stateful).status == :skipped
    assert lane(report, :no_network_offline).status == :ready
  end

  test "writes JSON and Markdown live lane reports" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-sandbox-live-lanes-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{report: report, json_path: json_path, markdown_path: markdown_path} =
      SandboxLiveLanes.write_report!(tmp_dir,
        basename: "live-lanes",
        find_executable: fn _ -> nil end,
        command_runner: fn _cmd, _args, _opts -> {"missing", 1} end,
        file_exists?: fn _ -> false end,
        env: fn _ -> nil end,
        sandbox_status: fn _opts -> {:ok, %{backends: []}} end
      )

    assert report.summary.skipped == 3
    assert File.exists?(json_path)
    assert File.exists?(markdown_path)

    json = json_path |> File.read!() |> Jason.decode!()
    markdown = File.read!(markdown_path)

    assert get_in(json, ["summary", "skipped"]) == 3
    assert markdown =~ "Sandbox Live Lane Preflight"
    assert markdown =~ "docker_polyglot"
    assert markdown =~ "no_network_offline"
  end

  defp lane(report, id), do: Enum.find(report.lanes, &(&1.id == id))

  defp smoke_stdout(:bash, :docker), do: "bash-ok\n"
  defp smoke_stdout(:python, :docker), do: "python-ok\n"
  defp smoke_stdout(:node, :docker), do: "node-ok\n"
  defp smoke_stdout(:elixir, :docker), do: "elixir-ok\n"
  defp smoke_stdout(:lua, :docker), do: "lua-ok\n"
  defp smoke_stdout(:bash, :sprites), do: "sprites-live-ok"
  defp smoke_stdout(:bash, :just_bash), do: "no-network-offline"
end
