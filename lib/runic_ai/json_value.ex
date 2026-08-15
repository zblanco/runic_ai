defmodule RunicAI.JSONValue do
  @moduledoc """
  Validates and canonicalizes JSON-compatible values.

  Trusted Elixir inputs may use atom keys. They are converted to strings, while
  atom/string collisions are rejected. Values decoded from JSON should already
  contain string keys. This module never creates atoms from input.
  """

  @type scalar :: nil | boolean() | number() | String.t()
  @type t :: scalar() | [t()] | %{optional(String.t()) => t()}
  @type path :: [String.t() | non_neg_integer()]
  @type issue :: %{path: path(), message: String.t()}

  @spec normalize(term()) :: {:ok, t()} | {:error, [issue()]}
  def normalize(value) do
    case normalize_at(value, []) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, issues} -> {:error, Enum.reverse(issues)}
    end
  end

  @spec normalize!(term()) :: t()
  def normalize!(value) do
    case normalize(value) do
      {:ok, normalized} -> normalized
      {:error, issues} -> raise ArgumentError, format_issues(issues)
    end
  end

  @spec canonical_json(term()) :: {:ok, String.t()} | {:error, [issue()]}
  def canonical_json(value) do
    with {:ok, normalized} <- normalize(value) do
      {:ok, encode_canonical(normalized)}
    end
  end

  @spec canonical_json!(term()) :: String.t()
  def canonical_json!(value) do
    case canonical_json(value) do
      {:ok, json} -> json
      {:error, issues} -> raise ArgumentError, format_issues(issues)
    end
  end

  @spec semantic_hash(term()) :: {:ok, String.t()} | {:error, [issue()]}
  def semantic_hash(value) do
    with {:ok, json} <- canonical_json(value) do
      {:ok, :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)}
    end
  end

  @spec semantic_hash!(term()) :: String.t()
  def semantic_hash!(value) do
    case semantic_hash(value) do
      {:ok, hash} -> hash
      {:error, issues} -> raise ArgumentError, format_issues(issues)
    end
  end

  defp normalize_at(nil, _path), do: {:ok, nil}
  defp normalize_at(value, _path) when is_boolean(value) or is_integer(value), do: {:ok, value}

  defp normalize_at(value, path) when is_float(value) do
    if finite_float?(value) do
      {:ok, value}
    else
      issue(path, "non-finite numbers are not JSON values")
    end
  end

  defp normalize_at(value, _path) when is_binary(value), do: {:ok, value}

  defp normalize_at(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce({:ok, []}, fn {item, index}, acc ->
      combine(acc, normalize_at(item, path ++ [index]))
    end)
    |> reverse_success()
  end

  defp normalize_at(value, path) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce({:ok, {%{}, %{}}}, fn {key, item}, acc ->
      normalize_entry(acc, key, item, path)
    end)
    |> case do
      {:ok, {normalized, _sources}} -> {:ok, normalized}
      {:error, issues} -> {:error, issues}
    end
  end

  defp normalize_at(_value, path), do: issue(path, "unsupported JSON value")

  defp normalize_entry({:error, issues}, key, item, path) do
    case normalize_entry({:ok, {%{}, %{}}}, key, item, path) do
      {:ok, _} -> {:error, issues}
      {:error, more_issues} -> {:error, more_issues ++ issues}
    end
  end

  defp normalize_entry({:ok, {normalized, sources}}, key, item, path) do
    with {:ok, string_key, source_kind} <- normalize_key(key, path),
         :ok <- reject_collision(sources, string_key, source_kind, path),
         {:ok, normalized_item} <- normalize_at(item, path ++ [string_key]) do
      {:ok,
       {Map.put(normalized, string_key, normalized_item),
        Map.put(sources, string_key, source_kind)}}
    else
      {:error, issues} -> {:error, issues}
    end
  end

  defp normalize_key(key, _path) when is_binary(key), do: {:ok, key, :string}
  defp normalize_key(key, _path) when is_atom(key), do: {:ok, Atom.to_string(key), :atom}
  defp normalize_key(_key, path), do: issue(path, "object keys must be strings or atoms")

  defp reject_collision(sources, key, source_kind, path) do
    case Map.fetch(sources, key) do
      :error -> :ok
      {:ok, ^source_kind} -> issue(path ++ [key], "duplicate object key")
      {:ok, _other_kind} -> issue(path ++ [key], "atom/string key collision")
    end
  end

  defp combine({:error, issues}, {:error, more}), do: {:error, more ++ issues}
  defp combine({:error, issues}, {:ok, _}), do: {:error, issues}
  defp combine({:ok, _values}, {:error, issues}), do: {:error, issues}
  defp combine({:ok, values}, {:ok, value}), do: {:ok, [value | values]}

  defp reverse_success({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_success(error), do: error

  defp finite_float?(value) do
    encoded = :erlang.float_to_binary(value, [:compact])
    encoded not in ["nan", "inf", "-inf"]
  rescue
    ArgumentError -> false
  end

  defp encode_canonical(nil), do: "null"

  defp encode_canonical(value) when is_boolean(value) or is_number(value) or is_binary(value),
    do: Jason.encode!(value)

  defp encode_canonical(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode_canonical/1) <> "]"
  end

  defp encode_canonical(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, item} ->
        Jason.encode!(key) <> ":" <> encode_canonical(item)
      end)

    "{" <> encoded <> "}"
  end

  defp issue(path, message), do: {:error, [%{path: path, message: message}]}

  defp format_issues(issues) do
    Enum.map_join(issues, "; ", fn %{path: path, message: message} ->
      rendered_path =
        if path == [], do: "/", else: "/" <> Enum.map_join(path, "/", &to_string/1)

      rendered_path <> ": " <> message
    end)
  end
end
