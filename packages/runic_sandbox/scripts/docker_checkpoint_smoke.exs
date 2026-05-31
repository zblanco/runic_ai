image = System.get_env("RUNIC_SANDBOX_DOCKER_IMAGE", "runic-ai/sandbox:elixir-python-node")

docker_image_available? =
  case System.find_executable("docker") do
    nil ->
      false

    docker ->
      match?(
        {_output, 0},
        System.cmd(docker, ["image", "inspect", image], stderr_to_stdout: true)
      )
  end

if docker_image_available? do
  profile =
    RunicSandbox.Profile.new!(
      name: :local_code,
      backend: :docker,
      runtimes: [:bash],
      network: :disabled,
      image: image
    )

  {:ok, session} = RunicSandbox.open_session(:local_code, [], profile: profile)

  try do
    {:ok, _ref} = RunicSandbox.write_file(session, "checkpoint.txt", "before")
    {:ok, checkpoint} = RunicSandbox.checkpoint(session, id: "smoke")

    unless checkpoint.metadata.kind == :filesystem and
             checkpoint.metadata.preserves.process_memory == false do
      raise "docker checkpoint metadata overclaims preservation: #{inspect(checkpoint.metadata)}"
    end

    {:ok, _ref} = RunicSandbox.write_file(session, "checkpoint.txt", "after")
    {:ok, restored} = RunicSandbox.restore(session, checkpoint)
    {:ok, "before"} = RunicSandbox.read_file(restored, "checkpoint.txt")

    IO.puts("docker filesystem checkpoint smoke passed")
  after
    _ = RunicSandbox.close_session(session)
  end
else
  IO.puts("docker filesystem checkpoint smoke skipped: image not available (#{image})")
end
