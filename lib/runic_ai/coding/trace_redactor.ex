defmodule RunicAI.Coding.TraceRedactor do
  @moduledoc """
  Redacts secret-looking values before coding observations enter traces.
  """

  @redacted "[REDACTED]"
  @secret_key_pattern ~r/(api[_-]?key|authorization|bearer|credential|password|secret|token)/i
  @secret_value_patterns [
    {~r/sk-[A-Za-z0-9_-]{12,}/, @redacted},
    {~r/gh[pousr]_[A-Za-z0-9_]{12,}/, @redacted},
    {~r/xox[baprs]-[A-Za-z0-9-]{12,}/, @redacted},
    {~r/AKIA[0-9A-Z]{16}/, @redacted},
    {~r/Authorization:\s*Bearer\s+[A-Za-z0-9._-]+/i, "Authorization: Bearer " <> @redacted}
  ]

  @credential_path_pattern ~r{(^|[\s"'=:/])(\.env|\.netrc|\.npmrc|\.pypirc|\.aws|\.ssh|id_rsa|id_ed25519|credentials|secrets)(?=$|[\s"'/:])}i

  @spec redactor() :: (term(), term() -> term())
  def redactor do
    fn value, _field -> redact(value) end
  end

  @spec redact(term()) :: term()
  def redact(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, value} ->
      if secret_key?(key) do
        {key, @redacted}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value) when is_binary(value) do
    value
    |> redact_secret_values()
    |> redact_credential_paths()
  end

  def redact(value), do: value

  @spec secret_key?(term()) :: boolean()
  def secret_key?(key) when is_atom(key), do: secret_key?(Atom.to_string(key))
  def secret_key?(key) when is_binary(key), do: Regex.match?(@secret_key_pattern, key)
  def secret_key?(_key), do: false

  defp redact_secret_values(value) do
    Enum.reduce(@secret_value_patterns, value, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp redact_credential_paths(value) do
    Regex.replace(@credential_path_pattern, value, fn _match, prefix, _name ->
      prefix <> "[REDACTED_PATH]"
    end)
  end
end
