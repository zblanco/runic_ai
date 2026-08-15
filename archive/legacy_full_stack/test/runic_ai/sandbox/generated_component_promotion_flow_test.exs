defmodule RunicAI.Sandbox.GeneratedComponentPromotionFlowTest do
  use ExUnit.Case, async: false

  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentCatalog
  alias RunicAI.Sandbox.GeneratedComponentPromotionFlow
  alias LitterBox.AttachEvents
  alias LitterBox.Capabilities
  alias LitterBox.Session

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
               capability_gap: capability_gap(),
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: fn ^session, _request, _opts ->
                 {:ok,
                  attach_handle(session, stdout: "proof-ok\n", status: :pass, exit_status: 0)}
               end,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    assert result.status == :ready
    assert result.capability_gap.selected_action == :generate_leaf
    assert result.component.promotion_status == :verified
    assert result.proof.status == :verified
    assert result.promotion_decision.action == :keep_ephemeral
    assert %WorkflowBlueprint{} = result.workflow
    assert result.workflow.metadata.generated_component_ids == ["generated:csv-parser"]
    assert result.repair_context == nil

    assert Enum.map(result.events, & &1.type) == [
             :generated_component_proposed,
             :generated_component_capability_gap_decided,
             :generated_component_proof_finished,
             :generated_component_promotion_decided,
             :generated_component_flow_finished
           ]
  end

  test "requires a capability gap before proving generated component proposals" do
    assert {:error, error} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}]
             )

    assert error.kind == :validation
    assert error.details.required_option == :capability_gap
  end

  test "artifact promotion writes the proven component into the generated catalog" do
    session = session()
    catalog = GeneratedComponentCatalog.new_store!()

    assert {:ok, result} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               id: "flow:catalog-write",
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               test_command: "sh component_test.sh",
               promotion_target: :artifact,
               generated_component_catalog: catalog,
               capability_gap: capability_gap(),
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

    assert result.status == :promoted
    assert result.catalog_entry.id == "generated:csv-parser"
    assert result.catalog_entry.promotion_target == :artifact

    assert {:ok, catalog_entry} =
             GeneratedComponentCatalog.get(result.catalog, "generated:csv-parser")

    assert catalog_entry.component.promotion_status == :promoted
    assert :generated_component_catalog_written in Enum.map(result.events, & &1.type)
  end

  test "later coordinator turn reuses the cataloged generated component without proof" do
    workspace = Workspace.new!(root: tmp_dir())
    session = session()

    assert {:ok, promoted} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               id: "flow:catalog-reuse-source",
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               test_command: "sh component_test.sh",
               promotion_target: :artifact,
               generated_component_catalog: GeneratedComponentCatalog.new_store!(),
               capability_gap: capability_gap(),
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: fn ^session, _request, _opts ->
                 {:ok,
                  attach_handle(session, stdout: "proof-ok\n", status: :pass, exit_status: 0)}
               end,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    client = fn _model, _prompt, _opts ->
      flunk("catalog-backed composition should not regenerate a workflow")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Parse CSV rows",
               generated_component_catalog: promoted.catalog,
               generated_component_inputs: [%{name: "csv"}],
               generated_component_outputs: [%{name: "rows"}],
               generated_component_kind: :sandbox_execute,
               generated_component_runtime: :bash,
               generated_component_policy: %{network: :disabled},
               validate?: false,
               client: client
             )

    assert blueprint.metadata.proposal_kind == :generated_component_catalog_reuse
    assert blueprint.metadata.generated_component_ids == ["generated:csv-parser"]

    assert blueprint.metadata.generated_component_catalog.selected_entry_id ==
             "generated:csv-parser"

    assert Enum.map(blueprint.components, & &1.type) == [:sandbox_execute, :objective_scorecard]
  end

  test "rejects promotion flow when the gap decision selected reuse" do
    assert {:error, error} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               capability_gap: reuse_gap()
             )

    assert error.kind == :validation
    assert error.details.selected_action == :reuse_exact
    assert error.details.selected_component_id == "generated:csv-parser"
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
               capability_gap: capability_gap(),
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
    assert result.repair_context.capability_gap.selected_action == :generate_leaf
    assert result.repair_context.stderr == "assertion failed\n"
    assert result.repair_context.exit_status == 1
    assert result.repair_context.source_artifacts != []
  end

  test "failed proof records negative catalog evidence and repaired proof can promote" do
    session = session()
    catalog = GeneratedComponentCatalog.new_store!()

    assert {:ok, failed} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               id: "flow:failed-first",
               source_files: [%{path: "component.sh", content: "exit 1"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               workflow_objective: "Parse CSV rows",
               workflow_opts: [validate?: false],
               promotion_target: :artifact,
               generated_component_catalog: catalog,
               capability_gap: capability_gap(),
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

    assert failed.status == :proof_failed
    assert failed.negative_evidence.component_id == "generated:csv-parser"
    assert [%{id: negative_id}] = GeneratedComponentCatalog.negative_evidence(failed.catalog)
    assert negative_id == failed.negative_evidence.id
    assert :generated_component_negative_evidence_recorded in Enum.map(failed.events, & &1.type)

    assert {:ok, repaired} =
             GeneratedComponentPromotionFlow.run(draft_component(),
               id: "flow:repaired-second",
               source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
               test_files: [%{path: "component_test.sh", content: "sh component.sh"}],
               workflow_objective: "Parse CSV rows",
               workflow_opts: [validate?: false],
               promotion_target: :artifact,
               generated_component_catalog: failed.catalog,
               capability_gap: %{capability_gap() | selected_action: :repair_generated},
               open_session: fn _sandbox, _spec, _opts -> {:ok, session} end,
               attach: fn ^session, _request, _opts ->
                 {:ok,
                  attach_handle(session, stdout: "proof-ok\n", status: :pass, exit_status: 0)}
               end,
               close_attach: fn _handle, _opts -> :ok end,
               close_session: fn _session, _opts -> :ok end
             )

    assert repaired.status == :promoted
    assert repaired.catalog_entry.id == "generated:csv-parser"
    assert [%{id: ^negative_id}] = GeneratedComponentCatalog.negative_evidence(repaired.catalog)
    assert {:ok, _entry} = GeneratedComponentCatalog.get(repaired.catalog, "generated:csv-parser")
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
               capability_gap: capability_gap(),
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
               capability_gap: capability_gap(),
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

  test "coordinator derives a capability gap from the catalog when none is provided" do
    workspace = Workspace.new!(root: tmp_dir())
    session = session()

    client = fn _model, _prompt, _opts ->
      flunk("catalog-derived generated component proposal should not call the LLM")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Parse CSV rows",
               generated_component_proposal: draft_component(),
               generated_component_catalog: catalog_store(),
               proof_opts: [
                 source_files: [%{path: "component.sh", content: "printf 'proof-ok\\n'"}],
                 test_files: [%{path: "component_test.sh", content: "sh component.sh"}]
               ],
               workflow_opts: [validate?: false],
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
    assert blueprint.metadata.generated_component_ids == ["generated:csv-parser"]
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

  defp catalog_store do
    component =
      GeneratedComponent.new!(
        id: "generated:generic-line-reader",
        name: "Generic line reader",
        language: :bash,
        runtime: :bash,
        entrypoint: "component.sh",
        source_artifacts: [%{path: "component.sh", ref: "source:line-reader"}],
        test_artifacts: [%{path: "component_test.sh", ref: "test:line-reader"}],
        interface: %{inputs: [%{name: "csv"}], outputs: [%{name: "lines"}]},
        verification: %{status: :pass, command: "sh component_test.sh"},
        promotion_status: :verified,
        metadata: %{intent_tags: [:parse], network: :disabled}
      )

    entry = GeneratedComponentCatalog.entry_from_component(component) |> ok!()
    GeneratedComponentCatalog.new_store!(entries: [entry])
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, error}), do: raise(error.message)

  defp capability_gap do
    %{
      id: "gap:csv-parser",
      objective: "Parse CSV rows",
      required_contract: %{
        inputs: [%{name: "csv"}],
        outputs: [%{name: "rows"}]
      },
      candidates: [
        %{
          id: "generated:generic-line-reader",
          score: 27,
          rejection_reason: "does not parse CSV columns"
        }
      ],
      selected_action: :generate_leaf,
      reason: "No catalog candidate parses CSV rows into structured rows."
    }
  end

  defp reuse_gap do
    %{
      id: "gap:csv-parser-reuse",
      objective: "Parse CSV rows",
      required_contract: %{inputs: [%{name: "csv"}], outputs: [%{name: "rows"}]},
      candidates: [%{id: "generated:csv-parser", score: 100}],
      selected_action: :reuse_exact,
      selected_component_id: "generated:csv-parser",
      reason: "Exact catalog candidate exists."
    }
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
      LitterBox.ExecutionResult.new!(
        status: Keyword.fetch!(opts, :status),
        stdout: Keyword.get(opts, :stdout, ""),
        stderr: Keyword.get(opts, :stderr, ""),
        exit_status: Keyword.fetch!(opts, :exit_status),
        backend: session.backend,
        isolation_level: session.isolation_level
      )

    request =
      LitterBox.ExecutionRequest.new!(
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
