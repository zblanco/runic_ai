defmodule RunicAI.Recipe.GuardedToolTurn do
  @moduledoc "Tool-turn recipe with explicit budget and host guard decisions before each effect."

  require Runic

  alias Runic.Workflow
  alias RunicAI.Component.{LLMGenerate, ToolExecute}
  alias RunicAI.Control.{Budget, Guard, Suspension}
  alias RunicAI.Error
  alias RunicAI.Recipe.ToolTurn
  alias RunicAI.Tool.Call

  def new(client, resolver, guard, %Budget{} = budget, opts \\ []) do
    client_opts = Keyword.get(opts, :client_opts, [])
    context = Keyword.get(opts, :context, %{})

    Workflow.new(name: Keyword.get(opts, :name, :guarded_tool_turn))
    |> Workflow.add(
      Runic.step(fn request -> LLMGenerate.run(request, client, client_opts) end,
        name: :generate
      )
    )
    |> Workflow.add(
      Runic.step(fn result -> budgeted_calls(result, budget) end, name: :plan_tool_calls),
      to: :generate
    )
    |> Workflow.add(
      Runic.map(fn planned -> execute(planned, resolver, guard, context) end,
        name: :guard_and_execute_tool_calls
      ),
      to: :plan_tool_calls
    )
    |> Workflow.add(
      Runic.reduce([], fn outcome, acc -> [outcome | acc] end,
        name: :collect_tool_results,
        map: :guard_and_execute_tool_calls
      ),
      to: :guard_and_execute_tool_calls
    )
  end

  def budgeted_calls(result, budget) do
    calls = ToolTurn.calls(result)

    case Budget.charge(budget, %{"steps" => length(calls), "tool_calls" => length(calls)}) do
      {:ok, charged} -> Enum.map(calls, &{:call, &1, charged})
      {:error, %Error{} = error} -> [{:error, error}]
    end
  end

  def execute({:error, %Error{} = error}, _resolver, _guard, _context), do: {:error, error}

  def execute({:call, %Call{} = call, budget}, resolver, guard, context) do
    case guard_decision(guard, call, context) do
      %Guard{decision: :allow} ->
        {ToolExecute.run(call, resolver, context), budget}

      %Guard{decision: :review} = decision ->
        {:review, review_request(call, decision), budget}

      %Guard{} = decision ->
        {Guard.enforce(decision), budget}
    end
  end

  def results(%Workflow{} = workflow) do
    case Workflow.raw_productions(workflow, :collect_tool_results) |> List.last() do
      values when is_list(values) -> Enum.reverse(values)
      _ -> []
    end
  end

  defp guard_decision(fun, call, context) when is_function(fun, 2), do: fun.(call, context)

  defp guard_decision({module, function, extra}, call, context),
    do: apply(module, function, [call, context | extra])

  defp guard_decision(module, call, context) when is_atom(module),
    do: module.decide(call, context)

  defp review_request(call, decision) do
    Suspension.request!(%{
      "id" => "review:#{call.id}",
      "kind" => "review",
      "reason" => decision.reason,
      "resume" => %{"type" => "boolean"},
      "payload" => %{"call" => Call.encode(call), "guard" => Guard.encode(decision)}
    })
  end
end
