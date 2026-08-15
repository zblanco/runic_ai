defmodule RunicAI.Recipe.ToolTurnTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Control.{Budget, Guard}
  alias RunicAI.LLM.{Request, Result}
  alias RunicAI.Message
  alias RunicAI.Recipe.{GuardedToolTurn, ToolTurn}
  alias RunicAI.Testing.ScriptedClient
  alias RunicAI.Tool.{Binding, Spec}

  test "tool turn exposes generation, planning, native map, and reduce nodes" do
    workflow =
      ToolTurn.new(ScriptedClient, &resolve/2,
        client_opts: [script: tool_result()],
        context: %{"workspace" => "fixture"}
      )
      |> Workflow.plan_eagerly(Request.new!("test:model", "use a tool"))
      |> Workflow.react_until_satisfied()

    assert [{:ok, result}] = ToolTurn.results(workflow)
    assert result.output == %{"echo" => "hello"}
    assert Workflow.get_component(workflow, :execute_tool_calls)
    assert Workflow.get_component(workflow, :collect_tool_results)
  end

  test "guarded turn emits an inert review request without running the effect" do
    budget = Budget.new!(%{"steps" => 1, "tool_calls" => 1})

    workflow =
      GuardedToolTurn.new(ScriptedClient, &resolve/2, &review/2, budget,
        client_opts: [script: tool_result()]
      )
      |> Workflow.plan_eagerly(Request.new!("test:model", "review a tool"))
      |> Workflow.react_until_satisfied()

    assert [{:review, request, charged}] = GuardedToolTurn.results(workflow)
    assert request.kind == :review
    assert charged.used["tool_calls"] == 1
  end

  defp tool_result do
    Result.new!(Message.assistant(""),
      tool_requests: [
        %{"id" => "call-1", "name" => "fixture.echo", "arguments" => %{"text" => "hello"}}
      ]
    )
  end

  defp resolve("fixture.echo", _context) do
    Binding.new!(spec(), fn arguments, _context -> {:ok, %{"echo" => arguments["text"]}} end)
  end

  defp review(_call, _context),
    do: Guard.new!(%{"id" => "fixture.review", "decision" => "review", "reason" => "confirm"})

  defp spec do
    Spec.new!(%{
      name: "fixture.echo",
      version: "1",
      description: "echo",
      input: %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]},
      output: %{type: "object", properties: %{echo: %{type: "string"}}, required: ["echo"]},
      effects: ["pure"],
      replay: "pure"
    })
  end
end
