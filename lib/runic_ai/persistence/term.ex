defmodule RunicAI.Persistence.Term do
  @moduledoc false

  alias RunicAI.Persistence.JSON

  @spec to_blob(term()) :: binary()
  def to_blob(value), do: :erlang.term_to_binary(value)

  @spec from_blob(binary()) :: term()
  def from_blob(blob) when is_binary(blob), do: :erlang.binary_to_term(blob, [:safe])

  @spec key(term()) :: String.t()
  def key(value), do: Base.url_encode64(to_blob(value), padding: false)

  @spec preview(term()) :: map()
  def preview(value) do
    %{
      "inspect" => inspect(value, limit: 20, printable_limit: 1_000),
      "json" => JSON.safe(value)
    }
  end
end
