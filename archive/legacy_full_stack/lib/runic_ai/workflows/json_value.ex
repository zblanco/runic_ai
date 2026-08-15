defmodule RunicAI.Workflows.JSONValue do
  @moduledoc false

  alias RunicAI.Error

  @spec validate_unambiguous(term(), module(), atom()) :: :ok | {:error, Error.t()}
  def validate_unambiguous(value, source, field) do
    case find_problem(value, [field]) do
      nil ->
        :ok

      {:ambiguous_key, path, canonical_key, keys} ->
        {:error,
         Error.validation("workflow IR contains keys that collide after JSON encoding",
           source: source,
           details: %{
             code: :ambiguous_json_key,
             field: field,
             path: path,
             canonical_key: canonical_key,
             keys: Enum.map(keys, &inspect/1)
           }
         )}

      {:invalid_key, path, key} ->
        {:error,
         Error.validation("workflow IR map keys must be strings or atoms",
           source: source,
           details: %{code: :invalid_json_key, field: field, path: path, key: inspect(key)}
         )}
    end
  end

  defp find_problem(%_{} = struct, path), do: struct |> Map.from_struct() |> find_problem(path)

  defp find_problem(map, path) when is_map(map) do
    with nil <- invalid_key(map, path),
         nil <- ambiguous_key(map, path) do
      Enum.find_value(map, fn {key, value} ->
        find_problem(value, path ++ [canonical_key(key)])
      end)
    end
  end

  defp find_problem(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {value, index} -> find_problem(value, path ++ [index]) end)
  end

  defp find_problem(_value, _path), do: nil

  defp invalid_key(map, path) do
    Enum.find_value(Map.keys(map), fn
      key when is_binary(key) or is_atom(key) -> nil
      key -> {:invalid_key, path, key}
    end)
  end

  defp ambiguous_key(map, path) do
    map
    |> Map.keys()
    |> Enum.group_by(&canonical_key/1)
    |> Enum.find_value(fn
      {_canonical_key, [_single]} -> nil
      {canonical_key, keys} -> {:ambiguous_key, path, canonical_key, keys}
    end)
  end

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
end
