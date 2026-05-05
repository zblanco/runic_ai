defmodule RunicAI.Ids do
  @moduledoc false

  @spec unique(String.t() | atom()) :: String.t()
  def unique(prefix) when is_atom(prefix), do: unique(Atom.to_string(prefix))

  def unique(prefix) when is_binary(prefix) and prefix != "" do
    micros = System.system_time(:microsecond) |> Integer.to_string(36)
    counter = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    "#{prefix}:#{micros}:#{counter}:#{random}"
  end
end
