defmodule RunicAI.SandboxTest do
  use ExUnit.Case, async: true

  alias RunicSandbox, as: Sandbox
  alias RunicSandbox.ExecutionRequest
  alias RunicSandbox.ExecutionResult
  alias RunicSandbox.Manager
  alias RunicSandbox.Policy
  alias RunicSandbox.Profile

  test "validates sandbox request and result contracts" do
    assert {:ok, request} =
             ExecutionRequest.new(
               sandbox: :local_code,
               runtime: "bash",
               source: "echo contract",
               network: %{enabled: false}
             )

    assert request.runtime == :bash
    assert request.network == :disabled

    assert {:error, error} =
             ExecutionResult.new(
               status: :pass,
               stdout: "",
               stderr: "",
               backend: :just_bash,
               isolation_level: nil
             )

    assert error.message =~ "isolation_level"
  end

  test "profile captures backend isolation, workspace, pool, and policy" do
    assert {:ok, profile} =
             Profile.from_named_config(:local_code,
               backend: :just_bash,
               pool: [warm: 0, max: 1],
               network: :disabled,
               workspace: [mode: :copy_in, persist?: true]
             )

    assert profile.name == :local_code
    assert profile.backend == :just_bash
    assert profile.isolation_level == :in_process_virtual
    assert profile.workspace.mode == :copy_in
    assert profile.workspace.persist?
    assert profile.policy.allowed_runtimes == [:bash]
    assert :in_process_virtual in Policy.isolation_levels()
  end

  test "just_bash backend executes through the sandbox facade with backend truth metadata" do
    assert {:ok, result} =
             Sandbox.exec(%{
               sandbox: :local_code,
               runtime: :bash,
               source: "echo sandbox-contract",
               max_output_bytes: 1_024
             })

    assert result.status == :pass
    assert result.stdout == "sandbox-contract\n"
    assert result.backend == :just_bash
    assert result.isolation_level == :in_process_virtual
    refute result.metadata.security_boundary?
  end

  test "lua backend executes small transform snippets with in-process truth metadata" do
    assert {:ok, result} =
             Sandbox.exec(
               %{
                 sandbox: :local_code,
                 runtime: :lua,
                 source: "return 2 + 3",
                 max_output_bytes: 1_024
               },
               profile: [backend: :lua]
             )

    assert result.status == :pass
    assert result.stdout == "5\n"
    assert result.backend == :lua
    assert result.isolation_level == :in_process
    refute result.metadata.security_boundary?

    assert {:ok, status} = Sandbox.status(profile: [backend: :lua])
    assert status.profile.runtimes == [:lua]

    assert [%{name: :lua, isolation_level: :in_process, security_boundary?: false}] =
             status.backends
  end

  test "lua backend turns long-running snippets into timeout results" do
    assert {:ok, result} =
             Sandbox.exec(
               %{
                 sandbox: :local_code,
                 runtime: :lua,
                 source: "while true do end",
                 timeout_ms: 25,
                 max_output_bytes: 1_024
               },
               profile: [backend: :lua]
             )

    assert result.status == :timeout
    assert result.stderr == "lua execution timed out"
    assert [%{message: "lua execution timed out"}] = result.diagnostics
  end

  test "supervised manager accepts application-style sandbox config" do
    name = :"sandbox_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Sandbox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           pool: [warm: 0, max: 1],
           network: :disabled,
           workspace: [mode: :copy_in, persist?: true]
         ]
       ]}
    )

    assert {:ok, status} = Manager.status(name)
    assert status.sandboxes.local_code.backend == :just_bash
    assert status.sandboxes.local_code.workspace.persist?

    assert {:ok, result} =
             Manager.exec(name, %{
               sandbox: :local_code,
               runtime: :bash,
               source: "echo supervised-sandbox"
             })

    assert result.status == :pass
    assert result.stdout == "supervised-sandbox\n"
  end

  test "RunicSandbox facade supports extraction-style supervision and execution" do
    name = :"runic_sandbox_#{System.unique_integer([:positive])}"

    start_supervised!(
      {RunicSandbox,
       name: name,
       sandboxes: [
         local_code: [
           backend: :just_bash,
           pool: [warm: 0, max: 1],
           network: :disabled,
           workspace: [mode: :copy_in, persist?: false]
         ]
       ]}
    )

    assert {:ok, status} = RunicSandbox.status(server: name)
    assert status.sandboxes.local_code.backend == :just_bash

    assert {:ok, result} =
             RunicSandbox.exec(
               %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "echo extraction-facade"
               },
               server: name
             )

    assert result.status == :pass
    assert result.stdout == "extraction-facade\n"
    assert result.backend == :just_bash
  end

  test "docker backend reports container truth and executes when a local image is available" do
    image = local_docker_image()

    assert {:ok, status} =
             Sandbox.status(
               profile: [
                 name: :local_code,
                 backend: :docker,
                 image: image || "missing-runic-sandbox-test-image:local",
                 runtimes: [:bash],
                 network: :disabled,
                 workspace: [mode: :copy_in, persist?: false]
               ]
             )

    assert status.default_backend == :docker

    assert [%{name: :docker, isolation_level: :container, security_boundary?: true}] =
             status.backends

    if image do
      assert {:ok, result} =
               Sandbox.exec(
                 %{
                   sandbox: :local_code,
                   runtime: :bash,
                   source:
                     "cat input.txt && printf ' network=' && echo artifact-output > output.txt",
                   files: %{"input.txt" => "docker-sandbox"},
                   timeout_ms: 10_000,
                   max_output_bytes: 2_048
                 },
                 profile: [
                   name: :local_code,
                   backend: :docker,
                   image: image,
                   runtimes: [:bash],
                   network: :disabled,
                   workspace: [mode: :copy_in, persist?: false]
                 ]
               )

      assert result.status == :pass
      assert result.stdout =~ "docker-sandbox"
      assert result.stdout =~ "network="
      assert result.backend == :docker
      assert result.isolation_level == :container
      assert result.metadata.image == image
      assert result.metadata.network == :disabled
      assert result.metadata.security_boundary?
      assert [%{path: "output.txt", kind: :created}] = result.files_changed
      assert [%{ref: "sandbox://output.txt", preview: "artifact-output\n"}] = result.artifacts
    end
  end

  test "gvisor backend reports runsc detection and executes when Docker runsc is available" do
    image = local_docker_image()

    assert {:ok, status} =
             Sandbox.status(
               profile: [
                 name: :local_code,
                 backend: :gvisor,
                 image: image || "missing-runic-sandbox-test-image:local",
                 runtimes: [:bash],
                 network: :disabled,
                 workspace: [mode: :copy_in, persist?: false]
               ]
             )

    assert status.default_backend == :gvisor
    assert status.profile.isolation_level == :gvisor

    assert [
             %{
               name: :gvisor,
               isolation_level: :gvisor,
               security_boundary?: true,
               container_runtime: "runsc"
             } = health
           ] = status.backends

    assert is_boolean(health.available?)
    assert is_boolean(health.docker_available?)
    assert is_boolean(health.runsc_available?)
    assert is_boolean(health.docker_runsc_runtime_available?)
    assert is_list(health.diagnostics)

    if image && health.available? do
      assert {:ok, result} =
               Sandbox.exec(
                 %{
                   sandbox: :local_code,
                   runtime: :bash,
                   source: "echo gvisor-sandbox",
                   timeout_ms: 10_000,
                   max_output_bytes: 2_048
                 },
                 profile: [
                   name: :local_code,
                   backend: :gvisor,
                   image: image,
                   runtimes: [:bash],
                   network: :disabled,
                   workspace: [mode: :copy_in, persist?: false]
                 ]
               )

      assert result.status == :pass
      assert result.stdout == "gvisor-sandbox\n"
      assert result.backend == :gvisor
      assert result.isolation_level == :gvisor
      assert result.metadata.container_runtime == "runsc"
      assert result.metadata.security_boundary?
    end
  end

  test "remote backend reports Fly Machines configuration and preflight diagnostics" do
    assert {:ok, status} =
             Sandbox.status(
               profile: [
                 name: :remote_code,
                 backend: :remote,
                 runtimes: [:bash],
                 network: :restricted,
                 backend_options: [
                   provider: :fly_machines,
                   app: "runic-sandbox-test",
                   machine_id: "machine-test-id",
                   token_env: "RUNIC_AI_MISSING_FLY_TOKEN",
                   executable: "runic-ai-missing-flyctl"
                 ]
               ]
             )

    assert status.default_backend == :remote
    assert status.profile.isolation_level == :remote_microvm

    assert [
             %{
               name: :remote,
               provider: :fly_machines,
               isolation_level: :remote_microvm,
               security_boundary?: true,
               configured?: true,
               auth_configured?: false,
               fly_cli_available?: false
             } = health
           ] = status.backends

    refute Map.has_key?(health, :provider_config)
    refute inspect(health) =~ "machine-test-id"
    assert %{message: "fly or flyctl executable is unavailable"} in health.diagnostics

    assert {:error, error} =
             Sandbox.exec(
               %{
                 sandbox: :remote_code,
                 runtime: :bash,
                 source: "echo remote-sandbox",
                 timeout_ms: 1_000
               },
               profile: [
                 name: :remote_code,
                 backend: :remote,
                 runtimes: [:bash],
                 network: :restricted,
                 backend_options: [
                   provider: :fly_machines,
                   app: "runic-sandbox-test",
                   machine_id: "machine-test-id",
                   token_env: "RUNIC_AI_MISSING_FLY_TOKEN",
                   executable: "runic-ai-missing-flyctl"
                 ]
               ]
             )

    assert error.kind == :validation
    assert error.message == "remote sandbox provider is not available for execution"
    assert error.details.provider == :fly_machines
    assert %{message: "fly or flyctl executable is unavailable"} in error.details.diagnostics
  end

  test "docker manager profile can persist workspace state across executions" do
    image = local_docker_image()

    if image do
      name = :"docker_sandbox_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Sandbox,
         name: name,
         sandboxes: [
           local_code: [
             backend: :docker,
             image: image,
             runtimes: [:bash],
             network: :disabled,
             stateful?: true,
             workspace: [mode: :copy_in, persist?: true]
           ]
         ]}
      )

      assert {:ok, first} =
               Manager.exec(name, %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "echo persistent-state > persisted.txt",
                 timeout_ms: 10_000
               })

      assert first.status == :pass
      assert [%{path: "persisted.txt", kind: :created}] = first.files_changed

      assert {:ok, second} =
               Manager.exec(name, %{
                 sandbox: :local_code,
                 runtime: :bash,
                 source: "cat persisted.txt",
                 timeout_ms: 10_000
               })

      assert second.status == :pass
      assert second.stdout == "persistent-state\n"
      assert second.files_changed == []

      assert {:ok, isolated} =
               Sandbox.exec(
                 %{
                   sandbox: :local_code,
                   runtime: :bash,
                   source:
                     "if test -f persisted.txt; then cat persisted.txt; else printf missing; fi",
                   timeout_ms: 10_000
                 },
                 profile: [
                   backend: :docker,
                   image: image,
                   runtimes: [:bash],
                   network: :disabled,
                   workspace: [mode: :copy_in, persist?: false]
                 ]
               )

      assert isolated.status == :pass
      assert isolated.stdout == "missing"
    end
  end

  defp local_docker_image do
    with docker when is_binary(docker) <- System.find_executable("docker"),
         {_info, 0} <- System.cmd(docker, ["info"], stderr_to_stdout: true),
         {images, 0} <-
           System.cmd(docker, ["images", "--format", "{{.Repository}}:{{.Tag}}"],
             stderr_to_stdout: true
           ) do
      images
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.contains?(&1, "<none>"))
      |> Enum.find(&image_has_shell?/1)
    else
      _other -> nil
    end
  end

  defp image_has_shell?(image) do
    case System.cmd(
           "docker",
           ["run", "--rm", "--pull", "never", "--network", "none", image, "sh", "-lc", "true"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _other -> false
    end
  rescue
    _exception -> false
  end
end
