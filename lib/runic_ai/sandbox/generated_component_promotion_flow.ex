defmodule RunicAI.Sandbox.GeneratedComponentPromotionFlow do
  @moduledoc """
  Proof-first orchestration for sandbox-generated components.

  This module sits above `RunicSandbox`. It does not execute provider-specific
  logic itself; it coordinates RunicAI's generated-component contract, sandbox
  proof runner, promotion policy, and workflow composition.
  """

  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentProof
  alias RunicAI.Sandbox.GeneratedComponentPromotionPolicy
  alias RunicAI.Sandbox.GeneratedComponentWorkflow

  @statuses [:ready, :promoted, :review_required, :rejected, :proof_failed]

  @type status :: :ready | :promoted | :review_required | :rejected | :proof_failed

  @type t :: %{
          required(:id) => String.t(),
          required(:status) => status(),
          required(:component) => GeneratedComponent.t(),
          required(:proof) => GeneratedComponentProof.result(),
          required(:promotion_decision) => GeneratedComponentPromotionPolicy.decision(),
          required(:workflow) => WorkflowBlueprint.t() | nil,
          required(:events) => [map()],
          required(:repair_context) => map() | nil
        }

  @spec run(GeneratedComponent.t() | map() | keyword(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def run(component_input, opts \\ []) when is_list(opts) do
    flow_id =
      Keyword.get(
        opts,
        :id,
        "generated_component_promotion:#{System.unique_integer([:positive])}"
      )

    with {:ok, proposal} <- GeneratedComponent.from_input(component_input),
         {:ok, proof} <- proof_component(proposal, flow_id, opts),
         {:ok, decision} <- promotion_decision(proof.component, opts),
         {:ok, component, status} <- apply_decision(proof, decision, opts),
         {:ok, workflow} <- maybe_compose_workflow(component, status, opts) do
      {:ok,
       %{
         id: flow_id,
         status: status,
         component: component,
         proof: proof,
         promotion_decision: decision,
         workflow: workflow,
         events: events(flow_id, proposal, proof, decision, component, status, workflow),
         repair_context: repair_context(proof, decision, status)
       }}
    end
  end

  defp proof_component(%GeneratedComponent{} = component, flow_id, opts) do
    proof_opts =
      opts
      |> Keyword.get(:proof_opts, [])
      |> Keyword.merge(
        Keyword.drop(opts, [
          :id,
          :proof_opts,
          :promotion_target,
          :review_decision,
          :resume_key,
          :workflow_objective,
          :workflow_opts
        ])
      )
      |> Keyword.put_new(:id, "#{flow_id}:proof")

    GeneratedComponentProof.run(component, proof_opts)
  end

  defp promotion_decision(%GeneratedComponent{} = component, opts) do
    policy_opts =
      [target: Keyword.get(opts, :promotion_target, :ephemeral)]
      |> maybe_put(:resume_key, Keyword.get(opts, :resume_key))

    GeneratedComponentPromotionPolicy.evaluate(component, policy_opts)
  end

  defp apply_decision(proof, %{action: :review} = decision, opts) do
    case Keyword.get(opts, :review_decision) do
      nil ->
        {:ok, proof.component, :review_required}

      review_decision ->
        with {:ok, component} <-
               GeneratedComponentPromotionPolicy.apply_decision(proof.component, decision,
                 review_decision: review_decision
               ) do
          {:ok, component, status_for_component(component, proof)}
        end
    end
  end

  defp apply_decision(proof, decision, opts) do
    with {:ok, component} <-
           GeneratedComponentPromotionPolicy.apply_decision(proof.component, decision,
             review_decision: Keyword.get(opts, :review_decision)
           ) do
      {:ok, component, status_for_component(component, proof)}
    end
  end

  defp status_for_component(%GeneratedComponent{promotion_status: :promoted}, _proof),
    do: :promoted

  defp status_for_component(%GeneratedComponent{promotion_status: :rejected}, %{status: :failed}),
    do: :proof_failed

  defp status_for_component(%GeneratedComponent{promotion_status: :rejected}, _proof),
    do: :rejected

  defp status_for_component(%GeneratedComponent{promotion_status: :verified}, _proof), do: :ready

  defp maybe_compose_workflow(_component, status, _opts)
       when status in [:review_required, :rejected, :proof_failed],
       do: {:ok, nil}

  defp maybe_compose_workflow(component, _status, opts) do
    case Keyword.get(opts, :workflow_objective) do
      objective when is_binary(objective) and objective != "" ->
        GeneratedComponentWorkflow.compose(
          objective,
          component,
          Keyword.get(opts, :workflow_opts, [])
        )

      _other ->
        {:ok, nil}
    end
  end

  defp events(flow_id, proposal, proof, decision, component, status, workflow) do
    [
      event(:generated_component_proposed, flow_id, proposal, %{
        promotion_status: proposal.promotion_status
      }),
      event(:generated_component_proof_finished, flow_id, proof.component, %{
        proof_id: proof.id,
        proof_status: proof.status,
        attach_status: proof.attach_summary.status,
        attach_mode: proof.capabilities.attach_mode,
        streaming_live?: proof.capabilities.streaming_live?
      }),
      event(:generated_component_promotion_decided, flow_id, proof.component, %{
        action: decision.action,
        reason: decision.reason,
        target: get_in(decision, [:details, :target]),
        required_decision: get_in(decision, [:details, :required_decision])
      }),
      event(:generated_component_flow_finished, flow_id, component, %{
        status: status,
        workflow_id: if(workflow, do: workflow.id)
      })
    ]
  end

  defp event(type, flow_id, %GeneratedComponent{} = component, payload) do
    %{
      type: type,
      flow_id: flow_id,
      component_id: component.id,
      timestamp: DateTime.utc_now(),
      payload: payload
    }
  end

  defp repair_context(%{status: :failed} = proof, decision, status) do
    %{
      status: status,
      reason: decision.reason,
      component_id: proof.component.id,
      command: proof.command,
      stdout: proof.attach_summary.stdout,
      stderr: proof.attach_summary.stderr,
      exit_status: proof.attach_summary.exit_status,
      diagnostics: proof.component.verification.diagnostics,
      source_artifacts: proof.source_artifacts,
      test_artifacts: proof.test_artifacts
    }
  end

  defp repair_context(_proof, _decision, _status), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  def statuses, do: @statuses
end
