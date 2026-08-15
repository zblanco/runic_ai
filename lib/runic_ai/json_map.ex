defmodule RunicAI.JSONMap do
  @moduledoc """
  Updates maps without creating atom/string keys that collide in JSON.
  """

  @spec put(map(), atom() | String.t(), term()) :: map()
  def put(map, key, value) when is_map(map) and (is_atom(key) or is_binary(key)) do
    storage_key =
      Enum.find(Map.keys(map), key, fn existing -> canonical(existing) == canonical(key) end)

    Map.put(map, storage_key, value)
  end

  @spec merge(map(), map()) :: map()
  def merge(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, value}, acc -> put(acc, key, value) end)
  end

  defp canonical(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical(key), do: key
end
