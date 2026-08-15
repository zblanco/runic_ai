defmodule RunicAI.LLM.Usage do
  @moduledoc "Normalized token and authoritative cost accounting for one LLM call."

  alias RunicAI.JSONValue

  @wire_id "runic.ai/llm-usage/v1"
  defstruct input_tokens: nil, output_tokens: nil, total_tokens: nil, cost: nil, currency: nil

  @type t :: %__MODULE__{}

  def new(input \\ %{}) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input) do
      usage = %__MODULE__{
        input_tokens: field(map, "input_tokens"),
        output_tokens: field(map, "output_tokens"),
        total_tokens: field(map, "total_tokens"),
        cost: field(map, "cost"),
        currency: field(map, "currency")
      }

      validate(usage)
    else
      {:ok, _other} -> error([], "usage must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input \\ %{}) do
    case new(input) do
      {:ok, usage} -> usage
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def validate(%__MODULE__{} = usage) do
    counts = [usage.input_tokens, usage.output_tokens, usage.total_tokens]

    cond do
      not Enum.all?(counts, &(is_nil(&1) or (is_integer(&1) and &1 >= 0))) ->
        error([], "token counts must be non-negative integers or null")

      not is_nil(usage.cost) and not (is_number(usage.cost) and usage.cost >= 0) ->
        error(["cost"], "must be a non-negative number or null")

      is_nil(usage.cost) != is_nil(usage.currency) ->
        error(["currency"], "cost and currency must be provided together")

      not is_nil(usage.currency) and not is_binary(usage.currency) ->
        error(["currency"], "must be a string")

      true ->
        {:ok, usage}
    end
  end

  def encode(%__MODULE__{} = usage) do
    %{"$contract" => @wire_id}
    |> put_if("input_tokens", usage.input_tokens)
    |> put_if("output_tokens", usage.output_tokens)
    |> put_if("total_tokens", usage.total_tokens)
    |> put_if("cost", usage.cost)
    |> put_if("currency", usage.currency)
  end

  def decode(input), do: new(input)

  defp field(map, key), do: Map.get(map, key)
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
