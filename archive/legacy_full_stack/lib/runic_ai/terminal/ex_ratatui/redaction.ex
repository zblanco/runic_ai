defmodule RunicAI.Terminal.ExRatatui.Redaction do
  @moduledoc false

  @secret_key_parts ~w(api_key apikey authorization bearer cookie password secret token)

  @spec redact(term()) :: term()
  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(text) when is_binary(text), do: redact_text(text)
  def redact(value), do: value

  @spec redact_text(String.t()) :: String.t()
  def redact_text(text) when is_binary(text) do
    text
    |> String.replace(~r/(sk-[A-Za-z0-9_-]{8,})/, "sk-[REDACTED]")
    |> String.replace(~r/(?i)(bearer)\s+[A-Za-z0-9._~+\/-]+=*/, "\\1 [REDACTED]")
    |> String.replace(
      ~r/(?i)(api[_-]?key|authorization|cookie|password|secret|token)\s*[:=]\s*([^\s,;]+)/,
      "\\1=[REDACTED]"
    )
  end

  @spec inspect_redacted(term(), keyword()) :: String.t()
  def inspect_redacted(value, opts \\ []) do
    value
    |> redact()
    |> inspect(Keyword.merge([limit: 20, printable_limit: 4_000], opts))
  end

  defp secret_key?(key) do
    key =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")

    Enum.any?(@secret_key_parts, &String.contains?(key, &1))
  end
end
