defmodule RunicAI.Rules.ResolveGuardedAction do
  @moduledoc """
  Route a guard decision to allow, rewrite, review, wait, or deny behavior.
  """

  require Runic

  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  @type input :: %{request: GuardRequest.t(), decision: GuardDecision.t()}

  def input_step(opts \\ []) do
    name = Keyword.get(opts, :name, :guard_resolution_input)

    Runic.step(
      fn %GuardRequest{} = request, %GuardDecision{} = decision ->
        bundle_input!(request, decision)
      end,
      name: name
    )
  end

  @spec bundle_input(GuardRequest.t(), GuardDecision.t()) :: {:ok, input()} | {:error, Error.t()}
  def bundle_input(%GuardRequest{} = request, %GuardDecision{} = decision) do
    with {:ok, request} <- GuardRequest.validate(request),
         {:ok, decision} <- GuardDecision.validate(decision) do
      {:ok, %{request: request, decision: decision}}
    end
  end

  @spec bundle_input!(GuardRequest.t(), GuardDecision.t()) :: input()
  def bundle_input!(%GuardRequest{} = request, %GuardDecision{} = decision) do
    case bundle_input(request, decision) do
      {:ok, input} -> input
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def rules(opts \\ []) do
    name = Keyword.get(opts, :name, :guard_resolution)
    deny_action = Keyword.get(opts, :deny_action, :halt)

    [
      continue_rule(name),
      pause_rule(name),
      deny_rule(name, deny_action),
      invalid_rewrite_rule(name)
    ]
  end

  defp continue_rule(name) do
    Runic.rule(
      name: :"#{name}_continue",
      condition: fn
        %{decision: %GuardDecision{action: :allow}} ->
          true

        %{decision: %GuardDecision{action: :rewrite, replacement: replacement}} ->
          not is_nil(replacement)
      end,
      reaction: fn
        %{request: request, decision: %GuardDecision{action: :allow}} ->
          request.subject

        %{decision: %GuardDecision{replacement: replacement}} ->
          replacement
      end
    )
  end

  defp pause_rule(name) do
    Runic.rule(
      name: :"#{name}_pause",
      condition: fn %{decision: %GuardDecision{action: action}} -> action in [:review, :wait] end,
      reaction: fn %{request: request, decision: decision} ->
        case decision.action do
          :review ->
            ReviewRequest.new!(
              :guard_review,
              checkpoint: request.point,
              subject: request.subject,
              details: %{guard_request: request, guard_decision: decision},
              metadata: %{guard_point: request.point}
            )

          :wait ->
            Wait.new!(
              :guard,
              reason: decision.reason,
              payload: %{subject: request.subject, guard_request: request},
              details: %{guard_request: request, guard_decision: decision},
              metadata: %{guard_point: request.point}
            )
        end
      end
    )
  end

  defp deny_rule(name, :stop) do
    Runic.rule(
      name: :"#{name}_deny_stop",
      condition: fn %{decision: %GuardDecision{action: :deny}} -> true end,
      reaction: fn %{request: request, decision: decision} ->
        ContinueDecision.stop!(:guard_denied,
          metadata: %{guard_point: request.point, reason: decision.reason}
        )
      end
    )
  end

  defp deny_rule(name, _deny_action) do
    Runic.rule(
      name: :"#{name}_deny_halt",
      condition: fn %{decision: %GuardDecision{action: :deny}} -> true end,
      reaction: fn %{request: request, decision: decision} ->
        ContinueDecision.halt!(:guard_denied,
          metadata: %{guard_point: request.point, reason: decision.reason}
        )
      end
    )
  end

  defp invalid_rewrite_rule(name) do
    Runic.rule(
      name: :"#{name}_invalid_rewrite",
      condition: fn %{decision: %GuardDecision{action: :rewrite, replacement: nil}} -> true end,
      reaction: fn %{request: request} ->
        ContinueDecision.halt!(:guard_invalid_rewrite, metadata: %{guard_point: request.point})
      end
    )
  end
end
