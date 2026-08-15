defmodule RunicAI.RLM.ValueContract do
  @moduledoc """
  Runic-compatible value contracts for dynamically generated RLM workflows.

  These contracts intentionally stay at the value level. They describe the
  shape flowing between components, not the user's domain.
  """

  @types [
    :assistant_input,
    :source_request,
    :source_set,
    :source_slices,
    :lambda_plan,
    :materialized_slices,
    :records,
    :record_items,
    :record_groups,
    :comparisons,
    :llm_items,
    :synthesis,
    :report,
    :artifact,
    :tool_result,
    :coding_context,
    :computed,
    :scorecard,
    :budget_summary,
    :workflow_input,
    :workflow_output,
    :any
  ]

  @type value_type :: atom()
  @type port_schema :: keyword()
  @type ports :: keyword(port_schema())

  @spec types() :: [value_type()]
  def types, do: @types

  @spec input(value_type() | [value_type()], String.t()) :: ports()
  def input(types, doc \\ "Input value"), do: [in: port(types, doc)]

  @spec output(value_type() | [value_type()], String.t()) :: ports()
  def output(types, doc \\ "Output value"), do: [out: port(types, doc)]

  @spec port(value_type() | [value_type()], String.t()) :: port_schema()
  def port(types, doc \\ "Value") do
    [type: type_expr(types), doc: doc]
  end

  @spec type_expr(value_type() | [value_type()]) :: value_type() | {:one_of, [value_type()]}
  def type_expr(types) when is_list(types) do
    types =
      types
      |> List.wrap()
      |> Enum.map(&normalize_type!/1)
      |> Enum.uniq()

    case types do
      [type] -> type
      types -> {:one_of, types}
    end
  end

  def type_expr(type), do: normalize_type!(type)

  @spec valid_type?(term()) :: boolean()
  def valid_type?(type) when type in @types, do: true
  def valid_type?(_type), do: false

  @spec json_ports(ports()) :: [map()]
  def json_ports(ports) when is_list(ports) do
    Enum.map(ports, fn {name, schema} ->
      %{
        name: name,
        type: json_type(Keyword.get(schema, :type, :any)),
        required: Keyword.get(schema, :required, true),
        doc: Keyword.get(schema, :doc)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  @spec json_type(term()) :: term()
  def json_type({:one_of, types}), do: %{one_of: Enum.map(types, &json_type/1)}
  def json_type({:list, type}), do: %{list: json_type(type)}
  def json_type(type) when is_atom(type), do: Atom.to_string(type)
  def json_type(type), do: inspect(type)

  defp normalize_type!(type) when type in @types, do: type

  defp normalize_type!(type) do
    raise ArgumentError, "unknown RunicAI RLM value contract type: #{inspect(type)}"
  end
end
