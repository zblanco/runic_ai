defmodule RunicAI.Recipe.ToolTurn do
  @moduledoc "One generation followed by scheduler-visible native tool fan-out and collection."

  require Runic

  alias Runic.Workflow
  alias RunicAI.Component.{LLMGenerate, ToolExecute}
  alias RunicAI.LLM.Result, as: LLMResult
  alias RunicAI.Tool.Call

  def new(client, resolver, opts \\ []) do
    client_opts = Keyword.get(opts, :client_opts, [])
    context = Keyword.get(opts, :context, %{})

    Workflow.new(name: Keyword.get(opts, :name, :tool_turn))
    |> Workflow.add(
      Runic.step(fn request -> LLMGenerate.run(request, client, client_opts) end,
        name: :generate
      )
    )
    |> Workflow.add(Runic.step(&calls/1, name: :plan_tool_calls), to: :generate)
    |> Workflow.add(
      Runic.map(fn call -> ToolExecute.run(call, resolver, context) end,
        name: :execute_tool_calls
      ),
      to: :plan_tool_calls
    )
    |> Workflow.add(
      Runic.reduce([], fn outcome, acc -> [outcome | acc] end,
        name: :collect_tool_results,
        map: :execute_tool_calls
      ),
      to: :execute_tool_calls
    )
  end

  def calls({:ok, %LLMResult{tool_requests: requests}}), do: Enum.map(requests, &call!/1)
  def calls(%LLMResult{tool_requests: requests}), do: Enum.map(requests, &call!/1)
  def calls(_outcome), do: []

  def results(%Workflow{} = workflow) do
    case Workflow.raw_productions(workflow, :collect_tool_results) |> List.last() do
      values when is_list(values) -> Enum.reverse(values)
      _ -> []
    end
  end

  defp call!(request) do
    Call.new!(%{
      "id" => request["id"],
      "tool" => request["name"] || request["tool"],
      "arguments" => request["arguments"] || %{},
      "dependencies" => request["dependencies"] || [],
      "metadata" => request["metadata"] || %{}
    })
  end
end
