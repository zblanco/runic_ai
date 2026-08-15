defmodule RunicAI.HostFixtureTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result, as: LLMResult
  alias RunicAI.Message
  alias RunicAI.Recipe.ToolTurn
  alias RunicAI.Testing.ScriptedClient
  alias RunicAI.Tool.{Binding, Spec}
  alias RunicAI.Tool.Result, as: ToolResult

  test "an independent host owns supervision execution persistence bindings and presentation" do
    store = start_supervised!({Agent, fn -> %{} end})

    llm_result =
      LLMResult.new!(Message.assistant(""),
        tool_requests: [
          %{"id" => "call-1", "name" => "host.echo", "arguments" => %{"text" => "hello"}}
        ]
      )

    workflow =
      ToolTurn.new(ScriptedClient, &resolve/2, client_opts: [script: llm_result])
      |> Workflow.plan_eagerly(Request.new!("fixture:model", "use the host tool"))
      |> Workflow.react_until_satisfied()

    [{:ok, %ToolResult{} = tool_result}] = ToolTurn.results(workflow)
    encoded = ToolResult.encode(tool_result)
    Agent.update(store, &Map.put(&1, "run-1", encoded))

    assert %{"status" => "ok", "output" => %{"echo" => "hello"}} = Agent.get(store, & &1["run-1"])
    assert %{title: "host.echo", body: %{"echo" => "hello"}} = present(tool_result)
    assert Application.spec(:runic_ai, :mod) in [nil, []]
  end

  defp resolve("host.echo", _context) do
    Binding.new!(spec(), fn arguments, _context -> {:ok, %{"echo" => arguments["text"]}} end)
  end

  defp spec do
    Spec.new!(%{
      name: "host.echo",
      version: "1",
      description: "echo",
      input: %{type: "object", properties: %{text: %{type: "string"}}, required: ["text"]},
      output: %{type: "object", properties: %{echo: %{type: "string"}}, required: ["echo"]},
      effects: ["pure"],
      replay: "pure"
    })
  end

  defp present(result), do: %{title: result.tool, body: result.output}
end
