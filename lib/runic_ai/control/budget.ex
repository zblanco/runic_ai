defmodule RunicAI.Control.Budget do
  @moduledoc "Immutable, serializable accounting for bounded agent execution."

  alias RunicAI.Error
  alias RunicAI.JSONValue

  @wire_id "runic.ai/control-budget/v1"
  @dimensions ~w(steps llm_calls tool_calls input_tokens output_tokens cost_microusd elapsed_ms)

  @enforce_keys [:limits, :used]
  defstruct limits: %{}, used: %{}

  @type t :: %__MODULE__{limits: map(), used: map()}

  def new(input \\ %{}) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, limits} <- dimensions(Map.get(map, "limits", map), :limit),
         {:ok, used} <- dimensions(Map.get(map, "used", %{}), :usage) do
      {:ok, %__MODULE__{limits: limits, used: Map.merge(empty_usage(), used)}}
    else
      {:ok, _other} -> error([], "budget must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input \\ %{}) do
    case new(input) do
      {:ok, budget} -> budget
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def charge(%__MODULE__{} = budget, usage) do
    with {:ok, increment} <- dimensions(usage, :usage) do
      used = Map.merge(budget.used, increment, fn _key, left, right -> left + right end)
      updated = %{budget | used: used}

      case exceeded(updated) do
        [] -> {:ok, updated}
        exceeded -> {:error, exhausted_error(updated, exceeded)}
      end
    end
  end

  def remaining(%__MODULE__{} = budget),
    do:
      Map.new(budget.limits, fn {key, limit} ->
        {key, max(limit - Map.get(budget.used, key, 0), 0)}
      end)

  def exceeded(%__MODULE__{} = budget) do
    budget.limits
    |> Enum.filter(fn {key, limit} -> Map.get(budget.used, key, 0) > limit end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  def encode(%__MODULE__{} = budget),
    do: %{"$contract" => @wire_id, "limits" => budget.limits, "used" => budget.used}

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract") == @wire_id do
      new(%{"limits" => Map.get(map, "limits", %{}), "used" => Map.get(map, "used", %{})})
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "budget must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  defp dimensions(input, kind) when is_map(input) do
    with {:ok, map} <- JSONValue.normalize(input), do: validate_dimensions(map, kind)
  end

  defp dimensions(_input, _kind), do: error([], "budget dimensions must be an object")

  defp validate_dimensions(map, kind) do
    issues =
      Enum.flat_map(map, fn {key, value} ->
        cond do
          key not in @dimensions ->
            [%{path: [key], message: "is not a supported dimension"}]

          not is_integer(value) or value < 0 ->
            [%{path: [key], message: "must be a non-negative integer"}]

          kind == :limit and value == 0 ->
            [%{path: [key], message: "limit must be positive"}]

          true ->
            []
        end
      end)

    if issues == [], do: {:ok, map}, else: {:error, issues}
  end

  defp exhausted_error(budget, dimensions) do
    Error.new!(:denied, "budget_exhausted", "execution budget was exhausted",
      source: inspect(__MODULE__),
      details: %{"dimensions" => dimensions, "limits" => budget.limits, "used" => budget.used}
    )
  end

  defp empty_usage, do: Map.new(@dimensions, &{&1, 0})
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
