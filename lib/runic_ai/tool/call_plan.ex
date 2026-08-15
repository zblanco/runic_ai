defmodule RunicAI.Tool.CallPlan do
  @moduledoc "Serializable, validated DAG of tool calls."

  alias RunicAI.JSONValue
  alias RunicAI.Tool.Call

  @wire_id "runic.ai/tool-call-plan/v1"
  @enforce_keys [:calls]
  defstruct calls: [], metadata: %{}

  @type t :: %__MODULE__{}

  def new(calls, opts \\ []) when is_list(calls) do
    with {:ok, calls} <- normalize_calls(calls),
         {:ok, metadata} when is_map(metadata) <-
           JSONValue.normalize(Keyword.get(opts, :metadata, %{})),
         :ok <- validate_unique(calls),
         :ok <- validate_dependencies(calls),
         :ok <- validate_acyclic(calls) do
      {:ok, %__MODULE__{calls: calls, metadata: metadata}}
    end
  end

  def new!(calls, opts \\ []) do
    case new(calls, opts) do
      {:ok, plan} -> plan
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def encode(%__MODULE__{} = plan),
    do: %{
      "$contract" => @wire_id,
      "calls" => Enum.map(plan.calls, &Call.encode/1),
      "metadata" => plan.metadata
    }

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract", @wire_id) == @wire_id do
      new(Map.get(map, "calls", []), metadata: Map.get(map, "metadata", %{}))
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "call plan must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def layers(%__MODULE__{calls: calls}) do
    do_layers(calls, MapSet.new(), [])
  end

  defp do_layers([], _completed, layers), do: Enum.reverse(layers)

  defp do_layers(remaining, completed, layers) do
    {ready, blocked} =
      Enum.split_with(remaining, &MapSet.subset?(MapSet.new(&1.dependencies), completed))

    completed = Enum.reduce(ready, completed, &MapSet.put(&2, &1.id))
    do_layers(blocked, completed, [ready | layers])
  end

  defp normalize_calls(calls) do
    calls
    |> Enum.reduce({:ok, []}, fn call, acc ->
      case {acc, normalize_call(call)} do
        {{:ok, values}, {:ok, normalized}} -> {:ok, [normalized | values]}
        {{:ok, _values}, {:error, issues}} -> {:error, issues}
        {{:error, issues}, _result} -> {:error, issues}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize_call(%Call{} = call), do: {:ok, call}
  defp normalize_call(input), do: Call.new(input)

  defp validate_unique(calls) do
    duplicates =
      calls
      |> Enum.map(& &1.id)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)

    if duplicates == [], do: :ok, else: error(["calls"], "call IDs must be unique")
  end

  defp validate_dependencies(calls) do
    ids = MapSet.new(calls, & &1.id)

    case Enum.find(calls, fn call -> not MapSet.subset?(MapSet.new(call.dependencies), ids) end) do
      nil -> :ok
      call -> error(["calls", call.id, "dependencies"], "contains an unknown call ID")
    end
  end

  defp validate_acyclic(calls) do
    graph = Map.new(calls, &{&1.id, &1.dependencies})

    if Enum.any?(Map.keys(graph), &cyclic?(&1, graph, MapSet.new())),
      do: error(["calls"], "dependency graph contains a cycle"),
      else: :ok
  end

  defp cyclic?(id, graph, visiting) do
    cond do
      MapSet.member?(visiting, id) -> true
      true -> Enum.any?(Map.get(graph, id, []), &cyclic?(&1, graph, MapSet.put(visiting, id)))
    end
  end

  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
