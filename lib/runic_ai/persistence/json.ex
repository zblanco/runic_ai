defmodule RunicAI.Persistence.JSON do
  @moduledoc false

  @max_binary 8_192
  @max_list 100
  @max_map 100

  @spec safe(term()) :: term()
  def safe(value), do: safe(value, 0)

  defp safe(_value, depth) when depth > 8, do: "[depth limit]"

  defp safe(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value), do: value

  defp safe(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp safe(value, _depth) when is_binary(value) do
    if String.valid?(value) do
      truncate(value)
    else
      "[binary #{byte_size(value)} bytes]"
    end
  end

  defp safe(%DateTime{} = value, _depth), do: DateTime.to_iso8601(value)
  defp safe(%NaiveDateTime{} = value, _depth), do: NaiveDateTime.to_iso8601(value)
  defp safe(%Date{} = value, _depth), do: Date.to_iso8601(value)
  defp safe(%Time{} = value, _depth), do: Time.to_iso8601(value)

  defp safe(%module{} = value, depth) do
    value
    |> Map.from_struct()
    |> Map.put(:__struct__, module)
    |> safe(depth + 1)
  end

  defp safe(value, depth) when is_list(value) do
    value
    |> Enum.take(@max_list)
    |> Enum.map(&safe(&1, depth + 1))
  end

  defp safe(value, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> safe(depth + 1)
  end

  defp safe(value, depth) when is_map(value) do
    value
    |> Enum.take(@max_map)
    |> Map.new(fn {key, val} -> {safe_key(key), safe(val, depth + 1)} end)
  end

  defp safe(value, _depth), do: inspect(value, limit: 50, printable_limit: 1_000)

  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(key), do: inspect(key)

  defp truncate(value) do
    if byte_size(value) > @max_binary do
      binary_part(value, 0, @max_binary) <> "...[truncated]"
    else
      value
    end
  end
end
