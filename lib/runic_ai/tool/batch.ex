defmodule RunicAI.Tool.Batch do
  @moduledoc "Native Runic map/reduce execution for an independent tool-call collection."

  require Runic

  alias Runic.Workflow
  alias RunicAI.Component.ToolExecute
  alias RunicAI.Tool.Call
  alias RunicAI.Tool.Result

  def workflow(resolver, opts \\ []) do
    map_name = Keyword.get(opts, :map_name, :execute_tool_calls)
    reduce_name = Keyword.get(opts, :reduce_name, :collect_tool_results)
    context = Keyword.get(opts, :context, %{})

    Workflow.new(name: Keyword.get(opts, :name, :tool_batch))
    |> Workflow.add(
      Runic.map(fn call -> ToolExecute.run(call, resolver, context) end, name: map_name)
    )
    |> Workflow.add(
      Runic.reduce([], fn outcome, acc -> [outcome | acc] end,
        name: reduce_name,
        map: map_name
      ),
      to: map_name
    )
  end

  @spec execute([Call.t()], function(), keyword()) :: [
          {:ok, Result.t()} | {:error, RunicAI.Error.t()}
        ]
  def execute(calls, resolver, opts \\ []) when is_list(calls) do
    reduce_name = Keyword.get(opts, :reduce_name, :collect_tool_results)

    workflow =
      resolver
      |> workflow(opts)
      |> Workflow.plan_eagerly(calls)
      |> Workflow.react_until_satisfied()

    case Workflow.raw_productions(workflow, reduce_name) |> List.last() do
      results when is_list(results) -> Enum.reverse(results)
      _other -> []
    end
  end
end
