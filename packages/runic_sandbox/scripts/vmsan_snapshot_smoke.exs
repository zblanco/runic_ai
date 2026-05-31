profile =
  RunicSandbox.Profile.new!(
    name: :local_code,
    backend: :vmsan,
    runtimes: [:bash],
    network: :disabled,
    backend_options: %{
      sudo?: true
    }
  )

case RunicSandbox.status(profile: profile) do
  {:ok, %{backends: [%{available?: true}]}} ->
    case RunicSandbox.open_session(:local_code, [], profile: profile) do
      {:ok, session} ->
        try do
          {:ok, _result} =
            RunicSandbox.exec(session,
              runtime: :bash,
              source: "printf before > /workspace/checkpoint.txt"
            )

          {:ok, checkpoint} = RunicSandbox.checkpoint(session, id: "smoke")

          unless checkpoint.metadata.kind == :microvm_snapshot and
                   checkpoint.metadata.preserves.process_memory == true do
            raise "vmsan checkpoint metadata is not a microVM snapshot: #{inspect(checkpoint.metadata)}"
          end

          {:ok, restored} = RunicSandbox.restore(session, checkpoint)
          Process.put(:runic_sandbox_vmsan_snapshot_smoke_session, restored)

          {:ok, result} =
            RunicSandbox.exec(restored,
              runtime: :bash,
              source: "cat /workspace/checkpoint.txt"
            )

          unless result.stdout =~ "before" do
            raise "vmsan snapshot smoke did not restore expected file: #{inspect(result.stdout)}"
          end

          IO.puts("vmsan snapshot smoke passed")
        after
          _ =
            RunicSandbox.close_session(
              Process.get(:runic_sandbox_vmsan_snapshot_smoke_session, session)
            )
        end

      {:error, error} ->
        IO.puts("vmsan snapshot smoke skipped: session could not be opened")
        IO.inspect(error, label: "error")
    end

  {:ok, %{backends: [%{missing_requirements: missing, diagnostics: diagnostics}]}} ->
    IO.puts("vmsan snapshot smoke skipped: provider unavailable")
    IO.inspect(missing, label: "missing_requirements")
    IO.inspect(diagnostics, label: "diagnostics")

  {:error, error} ->
    raise "vmsan snapshot smoke failed before status: #{error.message}"
end
