defmodule RunicAI.Sandbox.GeneratedComponentPromotionPolicy do
  @moduledoc """
  Promotion policy for verified generated sandbox components.

  The policy distinguishes ephemeral use, durable artifact storage, and host
  repo materialization. Host materialization always requires human review.
  """

  alias RunicAI.Error
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Sandbox.GeneratedComponent

  @targets [:ephemeral, :artifact, :host_repo]
  @actions [:keep_ephemeral, :store_artifact, :review, :reject]

  @type target :: :ephemeral | :artifact | :host_repo
  @type action :: :keep_ephemeral | :store_artifact | :review | :reject

  @type decision :: %{
          required(:action) => action(),
          required(:reason) => atom(),
          required(:details) => map(),
          optional(:review_request) => ReviewRequest.t()
        }

  @spec targets() :: [target()]
  def targets, do: @targets

  @spec actions() :: [action()]
  def actions, do: @actions

  @spec evaluate(GeneratedComponent.t() | map() | keyword(), keyword()) ::
          {:ok, decision()} | {:error, Error.t()}
  def evaluate(component_input, opts \\ []) when is_list(opts) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input),
         {:ok, target} <- target(Keyword.get(opts, :target, :ephemeral)) do
      cond do
        not GeneratedComponent.promotable?(component) ->
          {:ok, reject(:component_not_promotable, component, target)}

        policy_escalations(component) != [] ->
          {:ok,
           review(:policy_escalation, component, target, policy_escalations(component), opts)}

        target == :ephemeral ->
          {:ok, allow(:keep_ephemeral, :ephemeral_component, component, target)}

        target == :artifact ->
          {:ok, allow(:store_artifact, :durable_artifact_allowed, component, target)}

        target == :host_repo ->
          {:ok, review(:host_materialization_requires_review, component, target, [], opts)}
      end
    end
  end

  @spec apply_decision(GeneratedComponent.t() | map() | keyword(), decision() | map(), keyword()) ::
          {:ok, GeneratedComponent.t()} | {:error, Error.t()}
  def apply_decision(component_input, decision, opts \\ [])
      when is_map(decision) and is_list(opts) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input),
         {:ok, action} <- action(Map.get(decision, :action, Map.get(decision, "action"))) do
      case action do
        :store_artifact ->
          promote(component, decision, opts)

        :keep_ephemeral ->
          {:ok, component}

        :review ->
          apply_review_decision(component, decision, Keyword.get(opts, :review_decision), opts)

        :reject ->
          reject_component(component, decision)
      end
    end
  end

  defp apply_review_decision(_component, decision, nil, _opts) do
    {:error,
     Error.validation("generated component promotion requires an approved review decision",
       source: __MODULE__,
       details: %{decision: summarize_decision(decision)}
     )}
  end

  defp apply_review_decision(component, decision, review_decision_input, opts) do
    with {:ok, review_decision} <- ReviewDecision.from_input(review_decision_input) do
      if review_decision.status == :approved and
           review_decision.resume_key == review_resume_key(decision) do
        promote(component, decision, Keyword.put(opts, :review_decision, review_decision))
      else
        reject_component(component, Map.put(decision, :review_decision, review_decision))
      end
    end
  end

  defp promote(%GeneratedComponent{} = component, decision, opts) do
    metadata =
      component.metadata
      |> Map.put(:promotion, %{
        action: Map.get(decision, :action, Map.get(decision, "action")),
        reason: Map.get(decision, :reason, Map.get(decision, "reason")),
        target: get_in(decision, [:details, :target]) || get_in(decision, ["details", "target"]),
        reviewed_by:
          opts
          |> Keyword.get(:review_decision)
          |> case do
            %ReviewDecision{} = review_decision -> review_decision.actor
            _other -> nil
          end
      })

    GeneratedComponent.validate(%{component | promotion_status: :promoted, metadata: metadata})
  end

  defp reject_component(%GeneratedComponent{} = component, decision) do
    metadata =
      Map.put(component.metadata, :promotion_rejection, summarize_decision(decision))

    GeneratedComponent.validate(%{component | promotion_status: :rejected, metadata: metadata})
  end

  defp allow(action, reason, component, target) do
    %{
      action: action,
      reason: reason,
      details: details(component, target, [])
    }
  end

  defp reject(reason, component, target) do
    %{
      action: :reject,
      reason: reason,
      details: details(component, target, []) |> Map.put(:promotable?, false)
    }
  end

  defp review(reason, component, target, escalations, opts) do
    details =
      details(component, target, escalations) |> Map.put(:required_decision, :human_review)

    review_request =
      ReviewRequest.new!(:generated_component_promotion,
        subject: component.id,
        checkpoint: :generated_component_promotion,
        resume_key:
          Keyword.get(opts, :resume_key, "review:generated_component_promotion:#{component.id}"),
        details: details,
        metadata: %{generated_component_id: component.id, target: target}
      )

    %{
      action: :review,
      reason: reason,
      details: details,
      review_request: review_request
    }
  end

  defp details(component, target, escalations) do
    %{
      component_id: component.id,
      target: target,
      promotion_status: component.promotion_status,
      verification: component.verification,
      source_artifact_count: length(component.source_artifacts),
      test_artifact_count: length(component.test_artifacts),
      policy_escalations: escalations
    }
  end

  defp policy_escalations(%GeneratedComponent{} = component) do
    policy = map_get(component.metadata, :policy, %{})
    network = map_get(policy, :network, "disabled")
    filesystem = map_get(policy, :filesystem, "sandbox_only")

    [
      if(to_string(network) != "disabled", do: :network),
      if(to_string(filesystem) != "sandbox_only", do: :filesystem)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp review_resume_key(%{review_request: %ReviewRequest{} = review_request}),
    do: review_request.resume_key

  defp review_resume_key(%{"review_request" => %ReviewRequest{} = review_request}),
    do: review_request.resume_key

  defp review_resume_key(_decision), do: nil

  defp summarize_decision(decision) when is_map(decision) do
    %{
      action: Map.get(decision, :action, Map.get(decision, "action")),
      reason: Map.get(decision, :reason, Map.get(decision, "reason")),
      details: Map.get(decision, :details, Map.get(decision, "details", %{}))
    }
  end

  defp target(value) when value in @targets, do: {:ok, value}

  defp target(value) when is_binary(value) do
    @targets
    |> Enum.find(&(Atom.to_string(&1) == value))
    |> case do
      nil -> invalid_target(value)
      value -> {:ok, value}
    end
  end

  defp target(value), do: invalid_target(value)

  defp invalid_target(value) do
    {:error,
     Error.validation("invalid generated component promotion target",
       source: __MODULE__,
       details: %{target: value, valid_targets: @targets}
     )}
  end

  defp action(value) when value in @actions, do: {:ok, value}

  defp action(value) when is_binary(value) do
    @actions
    |> Enum.find(&(Atom.to_string(&1) == value))
    |> case do
      nil -> invalid_action(value)
      value -> {:ok, value}
    end
  end

  defp action(value), do: invalid_action(value)

  defp invalid_action(value) do
    {:error,
     Error.validation("invalid generated component promotion action",
       source: __MODULE__,
       details: %{action: value, valid_actions: @actions}
     )}
  end

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
