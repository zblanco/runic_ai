defmodule RunicAI.Sandbox.GeneratedComponentPromotionFlowTest do
  use ExUnit.Case, async: false

  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentPromotionFlow
  alias RunicSandbox.AttachEvents
  alias RunicSandbox.Capabilities
  alias RunicSandbox.Session

  test "proves a draft component before composing a generated-component workflow" do
    session = session()

    assert {:ok, result} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               id: "flow:csv-parser",
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               test_command: "sh component_test.sh",
               workflow_objective: "Parse CSV rows",
               workflow_opts: [validate?: false],
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: fn ^session, _request, _opts ->
                 {:ok,
                  attach_handle(session, stdout: "proof-ok\n", status: :pass, exit_status: 0)}
               end,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    assert result.status == :ready
    assert result.component.promotion_status == :verified
    assert result.proof.status == :verified
    assert result.promotion_decision.action == :keep_ephemeral
    assert %WorkflowBlueprint{} = result.workflow
    assert result.workflow.metadata.generated_component_ids == ["generated:csv-parser"]
    assert result.repair_context == nil

    assert Enum.map(result.events, & &1.type) == [
             :generated_component_proposed,
             :generated_component_proof_finished,
             :generated_component_promotion_decided,
             :generated_component_flow_finished
           ]
  end

  test "failed proofs are rejected with repair context instead of composed" do
    session = session()

    assert {:ok, result} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               source_files: [%{path: "component.sh", content: "exit 1"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               workflow_objective: "Parse CSV rows",
               workflow_opts: [validate?: false],
               promotion_target: :artifact,
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: fn ^session, _request, _opts ->
                 {:ok,
                  attach_handle(session,
                    stdout: "",
                    stderr: "assertion failed\n",
                    status: :fail,
                    exit_status: 1
                  )}
               end,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    assert result.status == :proof_failed
    assert result.component.promotion_status == :rejected
    assert result.workflow == nil
    assert result.promotion_decision.action == :reject
    assert result.repair_context.stderr == "assertion failed\n"
    assert result.repair_context.exit_status == 1
    assert result.repair_context.source_artifacts != []
  end

  test "host repo promotion pauses at review without composing a workflow" do
    session = session()

    assert {:ok, result} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               workflow_objective: "Parse CSV rows",
               workflow_opts: [validate?: false],
               promotion_target: :host_repo,
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: fn ^session, _request, _opts ->
                 {:ok,
                  attach_handle(session, stdout: "proof-ok\n", status: :pass, exit_status: 0)}
               end,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    assert result.status == :review_required
    assert result.component.promotion_status == :verified
    assert result.workflow == nil
    assert result.promotion_decision.action == :review
    assert result.promotion_decision.review_request.kind == :generated_component_promotion
  end

  test "coordinator proof-gates generated component proposals before returning a workflow" do
    workspace = Workspace.new!(root: tmp_dir())
    session = session()

    client = fn _model, _prompt, _opts ->
      flunk("proof-gated generated component proposal should not call the LLM")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Parse CSV rows",
               generated_component_proposal: draft_component(),
               proof_opts: [
                 source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
                 test_files: [%{path: "component_test.sh", content: "sh component.sh"}]
               ],
               workflow_opts: [validate?: false, metadata: %{consumer: :coordinator_test}],
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: fn ^session, _request, _opts ->
                 {:ok,
                  attach_handle(session, stdout: "proof-ok\n", status: :pass, exit_status: 0)}
               end,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end,
               client: client,
               validate?: false
             )

    assert blueprint.metadata.proposal_kind == :generated_component_promotion_flow
    assert blueprint.metadata.consumer == :coordinator_test
    assert Enum.map(blueprint.components, & &1.type) == [:sandbox_execute, :objective_scorecard]
  end

  defp draft_component do
    GeneratedComponent.new!(
      id: "generated:csv-parser",
      name: "CSV parser",
      language: :bash,
      runtime: :bash,
      entrypoint: "component.sh",
      interface: %{inputs: [%{name: "csv"}], outputs: [%{name: "rows"}]},
      verification: %{commands: ["sh component_test.sh"]},
      promotion_status: :draft,
      sandbox_profile: :local_code,
      metadata: %{policy: %{network: "disabled", filesystem: "sandbox_only"}}
    )
  end

  defp session do
    Session.new!(
      id: "session-proof",
      sandbox: :local_code,
      backend: :just_bash,
      capabilities:
        Capabilities.one_shot_exec(
          streaming?: true,
          metadata: Capabilities.attach_metadata(:terminal_adapter)
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
      RunicSandbox.ExecutionResult.new!(
        status: Keyword.fetch!(opts, :status),
        stdout: Keyword.get(opts, :stdout, ""),
        stderr: Keyword.get(opts, :stderr, ""),
        exit_status: Keyword.fetch!(opts, :exit_status),
        backend: session.backend,
        isolation_level: session.isolation_level
      )

    request =
      RunicSandbox.ExecutionRequest.new!(
        sandbox: :local_code,
        runtime: :bash,
        source: "sh component_test.sh"
      )

    {:ok, handle} = AttachEvents.terminal_handle(session, request, result)
    handle
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-generated-component-promotion-flow-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
