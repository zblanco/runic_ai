defmodule RunicAI.Recipes.HandoffContextBuilderTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.Recipes.HandoffContextBuilder

  test "builds a focused handoff artifact from state and a goal" do
    state =
      State.new!(system: "You are helpful")
      |> State.append_messages!([
        {:user, "We are debugging the auth callback in production."},
        {:assistant, "The failure appears after the OAuth exchange."},
        {:user, "Track down the callback mismatch and propose a fix."}
      ])

    workflow =
      HandoffContextBuilder.new()
      |> Workflow.react_until_satisfied(%{
        state: state,
        goal: "Finish debugging the auth callback mismatch"
      })

    artifact = HandoffContextBuilder.latest_handoff(workflow)

    assert artifact != nil
    assert artifact.brief =~ "Finish debugging the auth callback mismatch"
    assert artifact.seed_messages != []

    assert HandoffContextBuilder.latest_focus(workflow).goal ==
             "Finish debugging the auth callback mismatch"
  end
end
