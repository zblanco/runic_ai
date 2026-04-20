defmodule RunicAI.Rules.ResolveGuardedActionTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardRequest
  alias RunicAI.ReviewRequest
  alias RunicAI.Rules.ResolveGuardedAction
  alias RunicAI.Wait

  test "continues with the original subject when allowed" do
    state = State.new!(system: "You are helpful")
    request = GuardRequest.new!(:pre_answer, state, subject: %{answer: "draft"})
    decision = GuardDecision.allow!(:allow)

    workflow =
      workflow_for(ResolveGuardedAction.rules(name: :guard_resolution))
      |> Workflow.react_until_satisfied(ResolveGuardedAction.bundle_input!(request, decision))

    assert %{answer: "draft"} = latest_map(workflow)
  end

  test "continues with the replacement subject when rewritten" do
    state = State.new!(system: "You are helpful")
    request = GuardRequest.new!(:pre_answer, state, subject: %{answer: "draft"})
    decision = GuardDecision.rewrite!(:rewrite, %{answer: "approved"})

    workflow =
      workflow_for(ResolveGuardedAction.rules(name: :guard_resolution_rewrite))
      |> Workflow.react_until_satisfied(ResolveGuardedAction.bundle_input!(request, decision))

    assert %{answer: "approved"} = latest_map(workflow)
  end

  test "pauses with a review request" do
    state = State.new!(system: "You are helpful")
    request = GuardRequest.new!(:pre_tool, state, subject: %{tool: "write_file"})
    decision = GuardDecision.review!(:sensitive_tool)

    workflow =
      workflow_for(ResolveGuardedAction.rules(name: :guard_resolution_review))
      |> Workflow.react_until_satisfied(ResolveGuardedAction.bundle_input!(request, decision))

    assert %ReviewRequest{checkpoint: :pre_tool} = latest_struct(workflow, ReviewRequest)
  end

  test "pauses with a wait" do
    state = State.new!(system: "You are helpful")
    request = GuardRequest.new!(:pre_continue, state, subject: %{turn: 2})
    decision = GuardDecision.wait!(:needs_resume)

    workflow =
      workflow_for(ResolveGuardedAction.rules(name: :guard_resolution_wait))
      |> Workflow.react_until_satisfied(ResolveGuardedAction.bundle_input!(request, decision))

    assert %Wait{kind: :guard} = latest_struct(workflow, Wait)
  end

  test "halts when denied" do
    state = State.new!(system: "You are helpful")
    request = GuardRequest.new!(:pre_answer, state, subject: %{answer: "draft"})
    decision = GuardDecision.deny!(:blocked)

    workflow =
      workflow_for(ResolveGuardedAction.rules(name: :guard_resolution_deny))
      |> Workflow.react_until_satisfied(ResolveGuardedAction.bundle_input!(request, decision))

    assert %ContinueDecision{action: :halt, reason: :guard_denied} =
             latest_struct(workflow, ContinueDecision)
  end

  defp workflow_for(rules) do
    input_step = Runic.step(& &1, name: :guard_resolution_input)

    workflow =
      Workflow.new(name: :guard_resolution_test)
      |> Workflow.add(input_step)

    Enum.reduce(rules, workflow, fn rule, acc ->
      Workflow.add(acc, rule, to: :guard_resolution_input)
    end)
  end

  defp latest_struct(%Workflow{} = workflow, module) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&match?(%{__struct__: ^module}, &1))
    |> List.last()
  end

  defp latest_map(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions()
    |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, :answer)))
    |> List.last()
  end
end
