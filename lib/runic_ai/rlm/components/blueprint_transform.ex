defmodule RunicAI.RLM.Components.BlueprintTransform do
  @moduledoc """
  Interpreter for safe assistant function blueprints.

  This module intentionally does not evaluate Elixir source. Tier 0 compiles a
  known built-in operation, and Tier 1 interprets a small expression language
  over ordinary maps/lists/scalars.
  """

  alias RunicAI.Assistant.RLM.FunctionBlueprint
  alias RunicAI.Error

  @spec compile(FunctionBlueprint.t() | map(), keyword()) ::
          {:ok, (term() -> term())} | {:error, Error.t()}
  def compile(blueprint_input, opts \\ []) do
    with {:ok, blueprint} <- FunctionBlueprint.from_input(blueprint_input),
         :ok <- enforce_policy(blueprint, opts) do
      case blueprint.tier do
        :tier0 -> compile_tier0(blueprint)
        :tier1 -> {:ok, fn input -> eval!(blueprint.expr, input) end}
        :tier2 -> tier2_error()
      end
    end
  end

  @spec apply(FunctionBlueprint.t() | map(), term(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def apply(blueprint_input, input, opts \\ []) do
    with {:ok, fun} <- compile(blueprint_input, opts) do
      {:ok, fun.(input)}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @spec eval(term(), term()) :: {:ok, term()} | {:error, Error.t()}
  def eval(expr, input) do
    {:ok, eval!(expr, input)}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp enforce_policy(%FunctionBlueprint{tier: tier}, opts) do
    max_tier = normalize_tier(Keyword.get(opts, :max_tier, :tier1))

    if FunctionBlueprint.tier_rank(tier) <= FunctionBlueprint.tier_rank(max_tier) do
      :ok
    else
      {:error,
       Error.validation("function blueprint tier exceeds execution policy",
         source: __MODULE__,
         details: %{tier: tier, max_tier: max_tier}
       )}
    end
  end

  defp normalize_tier(tier) when tier in [:tier0, :tier1, :tier2], do: tier
  defp normalize_tier("tier0"), do: :tier0
  defp normalize_tier("tier1"), do: :tier1
  defp normalize_tier("tier2"), do: :tier2
  defp normalize_tier("tier2_review"), do: :tier2
  defp normalize_tier("tier2-review"), do: :tier2
  defp normalize_tier(_tier), do: :tier1

  defp compile_tier0(%FunctionBlueprint{op: op, expr: expr}) do
    {:ok,
     fn input ->
       expr =
         if is_nil(expr) do
           %{op: op, from: %{op: "input"}}
         else
           expr
         end

       expr
       |> map_op(op)
       |> eval!(input)
     end}
  end

  defp tier2_error do
    {:error,
     Error.validation("tier2 Elixir function blueprints are review-gated and not executable yet",
       source: __MODULE__
     )}
  end

  defp map_op(expr, op) when is_map(expr), do: Map.put_new(expr, :op, op)
  defp map_op(expr, op), do: %{op: op, from: expr}

  defp eval!(%{} = expr, input) do
    case op(expr) do
      nil ->
        Map.new(expr, fn {key, value} -> {key, eval!(value, input)} end)

      "input" ->
        input

      "literal" ->
        value(expr, :value)

      "get" ->
        get_path(eval_from(expr, input), List.wrap(value(expr, :path) || value(expr, :key)))

      "pick" ->
        pick(eval_from(expr, input), List.wrap(value(expr, :keys)))

      "map" ->
        map_each(eval_from(expr, input), value(expr, :expr), input)

      "filter" ->
        filter_each(eval_from(expr, input), value(expr, :expr), input)

      "flatten" ->
        eval_from(expr, input) |> List.wrap() |> List.flatten()

      "group_by" ->
        group_by(eval_from(expr, input), List.wrap(value(expr, :path) || value(expr, :key)))

      "dedupe_by" ->
        dedupe_by(eval_from(expr, input), List.wrap(value(expr, :keys)))

      "sort_by" ->
        sort_by(eval_from(expr, input), List.wrap(value(expr, :path) || value(expr, :key)))

      "join" ->
        join_values(eval_join_values(expr, input), value(expr, :separator) || "\n")

      "template" ->
        render_template(value(expr, :template) || "", eval_data(expr, input), input)

      "json_encode" ->
        Jason.encode!(eval_from(expr, input))

      "concat" ->
        expr |> value(:values) |> List.wrap() |> Enum.map(&eval!(&1, input)) |> Enum.join("")

      "count" ->
        eval_from(expr, input) |> count_value()

      "if" ->
        eval_if(expr, input)

      other ->
        raise ArgumentError, "unsupported function blueprint expression op #{inspect(other)}"
    end
  end

  defp eval!(values, input) when is_list(values), do: Enum.map(values, &eval!(&1, input))
  defp eval!(value, _input), do: value

  defp eval_from(expr, input) do
    case value(expr, :from) do
      nil -> input
      from -> eval!(from, input)
    end
  end

  defp eval_data(expr, input) do
    case value(expr, :data) do
      nil -> eval_from(expr, input)
      data -> eval!(data, input)
    end
  end

  defp eval_join_values(expr, input) do
    cond do
      not is_nil(value(expr, :values)) ->
        value(expr, :values) |> List.wrap() |> Enum.map(&eval!(&1, input))

      true ->
        eval_from(expr, input)
    end
  end

  defp eval_if(expr, input) do
    if truthy?(eval!(value(expr, :condition), input)) do
      eval!(value(expr, :then), input)
    else
      eval!(value(expr, :else), input)
    end
  end

  defp map_each(values, expr, _root) when is_list(values), do: Enum.map(values, &eval!(expr, &1))
  defp map_each(_values, _expr, _root), do: []

  defp filter_each(values, expr, _root) when is_list(values) do
    Enum.filter(values, fn item -> truthy?(eval!(expr, item)) end)
  end

  defp filter_each(_values, _expr, _root), do: []

  defp pick(value, keys) when is_map(value) do
    keys
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn key -> {to_string(key), get_value(value, key)} end)
  end

  defp pick(_value, _keys), do: %{}

  defp group_by(values, path) when is_list(values) do
    Enum.group_by(values, fn value -> value |> get_path(path) |> to_group_key() end)
  end

  defp group_by(_values, _path), do: %{}

  defp dedupe_by(values, keys) when is_list(values) do
    Enum.uniq_by(values, fn value -> Enum.map(keys, &get_path(value, List.wrap(&1))) end)
  end

  defp dedupe_by(value, _keys), do: value

  defp sort_by(values, path) when is_list(values) do
    Enum.sort_by(values, fn value -> value |> get_path(path) |> sort_key() end)
  end

  defp sort_by(value, _path), do: value

  defp join_values(values, separator) when is_list(values) do
    values
    |> Enum.map(&stringify/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(to_string(separator))
  end

  defp join_values(value, _separator), do: stringify(value)

  defp render_template(template, data, input) when is_binary(template) do
    Regex.replace(~r/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/, template, fn _match, key ->
      data_value = get_path(data, String.split(key, "."))

      if is_nil(data_value) do
        input |> get_path(String.split(key, ".")) |> stringify()
      else
        stringify(data_value)
      end
    end)
  end

  defp render_template(template, _data, _input), do: to_string(template)

  defp count_value(value) when is_list(value), do: length(value)
  defp count_value(value) when is_map(value), do: map_size(value)
  defp count_value(value) when is_binary(value), do: String.length(value)
  defp count_value(nil), do: 0
  defp count_value(_value), do: 1

  defp get_path(value, []), do: value
  defp get_path(nil, _path), do: nil

  defp get_path(values, [index | rest]) when is_list(values) and is_integer(index) do
    values |> Enum.at(index) |> get_path(rest)
  end

  defp get_path(value, [key | rest]) when is_map(value) do
    value |> get_value(key) |> get_path(rest)
  end

  defp get_path(_value, _path), do: nil

  defp get_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp get_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, safe_existing_atom_key(map, key)))
  end

  defp get_value(_map, _key), do: nil

  defp safe_existing_atom_key(map, key) do
    Enum.find(Map.keys(map), fn
      atom when is_atom(atom) -> Atom.to_string(atom) == key
      _other -> false
    end)
  end

  defp value(map, key), do: get_value(map, key)

  defp op(expr) do
    case value(expr, :op) do
      nil -> nil
      op when is_atom(op) -> Atom.to_string(op)
      op when is_binary(op) -> op |> String.downcase() |> String.replace("-", "_")
      other -> other
    end
  end

  defp truthy?(value), do: value not in [false, nil, "", [], %{}]

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp stringify(value), do: inspect(value, limit: 40, printable_limit: 2_000)

  defp to_group_key(nil), do: "nil"
  defp to_group_key(value), do: stringify(value)

  defp sort_key(nil), do: ""
  defp sort_key(value), do: stringify(value)
end
