defmodule RunicAI.Sandbox.GeneratedComponentProofTest do
  use ExUnit.Case, async: false

  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentProof
  alias LitterBox.AttachEvents
  alias LitterBox.Capabilities
  alias LitterBox.Session

  test "proves a generated component through attach summary evidence" do
    parent = self()
    session = session(:just_bash, Capabilities.attach_metadata(:terminal_adapter))

    open_session = fn sandbox, spec, opts ->
      send(parent, {:open_session, sandbox, spec, opts})
      {:ok, session}
    end

    attach = fn ^session, request, opts ->
      send(parent, {:attach, request, opts})

      {:ok,
       attach_handle(session,
         stdout: "proof-ok\n",
         status: :pass,
         exit_status: 0,
         metadata: %{terminal_result?: true}
       )}
    end

    assert {:ok, proof} =
             GeneratedComponentProof.run(component(),
               id: "proof:test",
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               open_session: open_session,
               attach: attach,
               close_attach: fn handle, opts ->
                 send(parent, {:close_attach, handle.id, opts})
                 :ok
               end,
               close_session: fn closed_session, opts ->
                 send(parent, {:close_session, closed_session.id, opts})
                 :ok
               end
             )

    assert proof.id == "proof:test"
    assert proof.status == :verified
    assert GeneratedComponent.verified?(proof.component)
    assert proof.component.verification.status == :pass
    assert proof.component.verification.attach_summary.stdout == "proof-ok\n"
    assert proof.attach_summary.stdout == "proof-ok\n"
    assert proof.capabilities.attach_mode == :terminal_adapter
    assert proof.capabilities.terminal_result_adapter?
    assert proof.cleanup == %{attach_closed?: true, session_closed?: true}

    assert [%{path: "component.sh", materialized_by: :sandbox_request_files}] =
             proof.source_artifacts

    assert [%{path: "component_test.sh", materialized_by: :sandbox_request_files}] =
             proof.test_artifacts

    assert_receive {:open_session, :local_code, [], []}
    assert_receive {:attach, request, []}
    assert request.cwd == "."
    assert request.network == :disabled

    assert request.files == %{
             "component.sh" => "printf 'proof-ok\\n'",
             "component_test.sh" => "sh component.sh"
           }

    assert_receive {:close_attach, _attach_id, []}
    assert_receive {:close_session, "session-just_bash", []}
  end

  test "keeps failed proofs as draft components with terminal evidence" do
    session = session(:docker, Capabilities.attach_metadata(:live_stream, stdin_supported?: true))

    attach = fn ^session, _request, _opts ->
      {:ok,
       attach_handle(session,
         stdout: "",
         stderr: "assertion failed\n",
         status: :fail,
         exit_status: 1
       )}
    end

    assert {:ok, proof} =
             GeneratedComponentProof.run(component(),
               source_files: [%{path: "component.sh", content: "exit 1"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: attach,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    assert proof.status == :failed
    assert proof.component.promotion_status == :draft
    refute GeneratedComponent.promotable?(proof.component)
    assert proof.component.verification.status == :failed
    assert proof.component.verification.diagnostics.stderr_preview == "assertion failed\n"
    assert proof.attach_summary.status == :fail
    assert proof.attach_summary.exit_status == 1
    assert proof.capabilities.attach_mode == :live_stream
  end

  test "uses session default cwd metadata for provider-backed proof requests" do
    parent = self()

    session =
      session(
        :sprites,
        Capabilities.attach_metadata(:terminal_adapter, default_cwd: "/home/sprite")
      )

    attach = fn ^session, request, _opts ->
      send(parent, {:attach_request, request})

      {:ok,
       attach_handle(session,
         stdout: "proof-ok\n",
         status: :pass,
         exit_status: 0
       )}
    end

    assert {:ok, proof} =
             GeneratedComponentProof.run(component(),
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: attach,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    assert proof.status == :verified
    assert_receive {:attach_request, request}
    assert request.cwd == "/home/sprite"
  end

  test "rejects sessions without attach support and still closes the session" do
    parent = self()
    capabilities = Capabilities.one_shot_exec(streaming?: false)
    session = session(:unsupported, capabilities.metadata, capabilities: capabilities)

    assert {:error, error} =
             GeneratedComponentProof.run(component(),
               source_files: [%{path: "component.sh", content: "true"}],
               test_files: [%{path: "component_test.sh", content: "true"}],
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               close_session: fn closed_session, _opts ->
                 send(parent, {:closed, closed_session.id})
                 :ok
               end
             )

    assert error.kind == :validation
    assert error.message == "generated component proof requires sandbox attach support"
    assert error.details.attach_mode == :none
    assert_receive {:closed, "session-unsupported"}
  end

  test "proves a bash component through the JustBash terminal adapter" do
    if Code.ensure_loaded?(JustBash) do
      assert {:ok, proof} =
               GeneratedComponentProof.run(component(),
                 source_files: [
                   %{path: "component.sh", content: "printf 'proof-ok\\n'"}
                 ],
                 test_files: [
                   %{
                     path: "component_test.sh",
                     content: "cat component.sh"
                   }
                 ],
                 test_command: "cat component.sh",
                 sandbox_cwd: ".",
                 session_opts: [
                   profile: [
                     name: :local_code,
                     backend: :just_bash,
                     runtimes: [:bash],
                     network: :disabled
                   ]
                 ]
               )

      assert proof.status == :verified
      assert proof.attach_summary.status == :pass
      assert proof.capabilities.attach_mode == :terminal_adapter
      assert proof.cleanup.session_closed?
    end
  end

  defp component do
    GeneratedComponent.new!(
      id: "generated:bash_component",
      name: "Bash component",
      language: :bash,
      runtime: :bash,
      entrypoint: "component.sh",
      interface: %{inputs: [%{name: "input"}], outputs: [%{name: "output"}]},
      verification: %{commands: ["sh component_test.sh"]},
      promotion_status: :draft
    )
  end

  defp session(backend, metadata, opts \\ []) do
    Session.new!(
      id: "session-#{backend}",
      sandbox: :local_code,
      backend: backend,
      capabilities:
        Keyword.get(
          opts,
          :capabilities,
          Capabilities.one_shot_exec(streaming?: true, metadata: metadata)
        ),
      isolation_level: :in_process_virtual,
      state_model: :one_shot,
      transport_model: :in_process,
      persistent_identity?: false,
      policy: [network: :disabled]
    )
  end

  defp attach_handle(%Session{} = session, opts) do
    result =
      LitterBox.ExecutionResult.new!(
        status: Keyword.fetch!(opts, :status),
        stdout: Keyword.get(opts, :stdout, ""),
        stderr: Keyword.get(opts, :stderr, ""),
        exit_status: Keyword.fetch!(opts, :exit_status),
        backend: session.backend,
        isolation_level: session.isolation_level
      )

    {:ok, request} =
      LitterBox.ExecutionRequest.new(
        sandbox: :local_code,
        runtime: :bash,
        source: "sh component_test.sh"
      )

    {:ok, handle} =
      AttachEvents.terminal_handle(session, request, result,
        metadata: Keyword.get(opts, :metadata, %{})
      )

    handle
  end
end
