defmodule RunicAI.Rules.BudgetGate do
  @moduledoc """
  Route a budget decision to continuation, review, wait, or halt behavior.
  """

  require Runic

  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Control.BudgetDecision
  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  @type input :: %{subject: term(), decision: BudgetDecision.t()}

  def input_step(opts \\ []) do
    name = Keyword.get(opts, :name, :budget_gate_input)

    Runic.step(
      fn subject, %BudgetDecision{} = decision ->
        bundle_input!(subject, decision)
      end,
      name: name
    )
  end

  @spec bundle_input(term(), BudgetDecision.t()) :: {:ok, input()} | {:error, Error.t()}
  def bundle_input(subject, %BudgetDecision{} = decision) do
    with {:ok, decision} <- BudgetDecision.validate(decision) do
      {:ok, %{subject: subject, decision: decision}}
    end
  end

  @spec bundle_input!(term(), BudgetDecision.t()) :: input()
  def bundle_input!(subject, %BudgetDecision{} = decision) do
    case bundle_input(subject, decision) do
      {:ok, input} -> input
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  def rules(opts \\ []) do
    name = Keyword.get(opts, :name, :budget_gate)
    checkpoint = Keyword.get(opts, :checkpoint, :budget)

    [
      continue_rule(name),
      pause_rule(name, checkpoint),
      halt_rule(name, checkpoint)
    ]
  end

  defp continue_rule(name) do
    Runic.rule(
      name: :"#{name}_continue",
      condition: fn %{decision: %BudgetDecision{action: :continue}} -> true end,
      reaction: fn %{subject: subject} -> subject end
    )
  end

  defp pause_rule(name, checkpoint) do
    Runic.rule(
      name: :"#{name}_pause",
      condition: fn %{decision: %BudgetDecision{action: action}} -> action in [:review, :wait] end,
      reaction: fn %{subject: subject, decision: decision} ->
        case decision.action do
          :review ->
            ReviewRequest.new!(
              :budget_review,
              checkpoint: checkpoint,
              subject: subject,
              details: %{budget_decision: decision},
              metadata: %{checkpoint: checkpoint}
            )

          :wait ->
            Wait.new!(
              :budget,
              reason: :budget_exhausted,
              payload: %{subject: subject, budget_decision: decision},
              details: %{budget_decision: decision},
              metadata: %{checkpoint: checkpoint}
            )
        end
      end
    )
  end

  defp halt_rule(name, checkpoint) do
    Runic.rule(
      name: :"#{name}_halt",
      condition: fn %{decision: %BudgetDecision{action: :halt}} -> true end,
      reaction: fn %{decision: decision} ->
        ContinueDecision.halt!(:budget_exhausted,
          metadata: %{checkpoint: checkpoint, reasons: decision.reasons}
        )
      end
    )
  end
end
