defmodule RunicAI.Rules.BudgetGateTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Control.BudgetDecision
  alias RunicAI.Control.BudgetSnapshot
  alias RunicAI.ReviewRequest
  alias RunicAI.Rules.BudgetGate
  alias RunicAI.Wait

  test "continues by passing through the subject" do
    decision =
      BudgetDecision.new!(
        :within_limits,
        :continue,
        BudgetSnapshot.new!()
      )

    workflow =
      workflow_for(BudgetGate.rules(name: :budget_gate))
      |> Workflow.react_until_satisfied(BudgetGate.bundle_input!("subject", decision))

    assert latest_binary(workflow) == "subject"
  end

  test "pauses with a review request when the budget asks for review" do
    decision =
      BudgetDecision.new!(
        :exhausted,
        :review,
        BudgetSnapshot.new!(tool_calls: 3),
        reasons: [%{metric: :tool_calls, actual: 3, limit: 2}]
      )

    workflow =
      workflow_for(BudgetGate.rules(name: :budget_gate_review))
      |> Workflow.react_until_satisfied(
        BudgetGate.bundle_input!(%{subject: :tool_plan}, decision)
      )

    assert %ReviewRequest{} = latest_of(workflow, ReviewRequest)
  end

  test "pauses with a wait when the budget asks for wait" do
    decision =
      BudgetDecision.new!(
        :exhausted,
        :wait,
        BudgetSnapshot.new!(elapsed_ms: 3_000),
        reasons: [%{metric: :elapsed_ms, actual: 3_000, limit: 2_000}]
      )

    workflow =
      workflow_for(BudgetGate.rules(name: :budget_gate_wait))
      |> Workflow.react_until_satisfied(BudgetGate.bundle_input!(%{subject: :answer}, decision))

    assert %Wait{} = latest_of(workflow, Wait)
  end

  test "halts with a continue decision when the budget asks for halt" do
    decision =
      BudgetDecision.new!(
        :exhausted,
        :halt,
        BudgetSnapshot.new!(turns: 5),
        reasons: [%{metric: :turns, actual: 5, limit: 4}]
      )

    workflow =
      workflow_for(BudgetGate.rules(name: :budget_gate_halt))
      |> Workflow.react_until_satisfied(BudgetGate.bundle_input!(%{subject: :answer}, decision))

    assert %ContinueDecision{action: :halt, reason: :budget_exhausted} =
             latest_of(workflow, ContinueDecision)
  end

  defp workflow_for(rules) do
    input_step = Runic.step(& &1, name: :budget_gate_input)

    workflow =
      Workflow.new(name: :budget_gate_test)
      |> Workflow.add(input_step)

    Enum.reduce(rules, workflow, fn rule, acc ->
      Workflow.add(acc, rule, to: :budget_gate_input)
    end)
  end

  defp latest_of(%Workflow{} = workflow, module) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%{__struct__: ^module}, &1))
    |> List.last()
  end

  defp latest_binary(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&is_binary/1)
    |> List.last()
  end
end
