defmodule RunicAI.RLM.Components.SourceMaterializer do
  @moduledoc """
  Applies late materialization caps to source slices.
  """

  alias RunicAI.Error

  @default_max_slice_bytes 8_000
  @default_max_total_bytes 120_000

  @spec run(term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, opts \\ %{}) do
    opts = opts_map(opts)
    max_slice_bytes = integer_opt(opts, :max_slice_bytes, @default_max_slice_bytes)
    max_total_bytes = integer_opt(opts, :max_total_bytes, @default_max_total_bytes)

    slices = slices(input)

    {materialized, total_bytes, truncated?} =
      slices
      |> Enum.reduce({[], 0, false}, fn slice, {acc, total, truncated?} ->
        text = to_string(get(slice, :text, ""))
        capped_text = cap_text(text, max_slice_bytes)
        next_total = total + byte_size(capped_text)

        cond do
          next_total > max_total_bytes ->
            {acc, total, true}

          true ->
            capped_slice =
              slice
              |> Map.new()
              |> Map.put(:text, capped_text)
              |> Map.put(:byte_size, byte_size(capped_text))
              |> Map.put(:truncated?, byte_size(capped_text) < byte_size(text))

            {[capped_slice | acc], next_total, truncated? or capped_slice.truncated?}
        end
      end)

    {:ok,
     %{
       slices: Enum.reverse(materialized),
       count: length(materialized),
       total_bytes: total_bytes,
       truncated?: truncated?
     }}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp slices(%{slices: slices}) when is_list(slices), do: slices
  defp slices(%{"slices" => slices}) when is_list(slices), do: slices
  defp slices(values) when is_list(values), do: values
  defp slices(value), do: List.wrap(value)

  defp cap_text(text, max_bytes) when byte_size(text) <= max_bytes, do: text
  defp cap_text(text, max_bytes), do: binary_part(text, 0, max_bytes) |> safe_string()

  defp safe_string(text) do
    if String.valid?(text), do: text, else: text |> :unicode.characters_to_binary(:latin1, :utf8)
  rescue
    _exception ->
      text
      |> String.graphemes()
      |> Enum.join()
  end

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp integer_opt(opts, key, default) do
    case get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _other -> default
        end

      _other ->
        default
    end
  end

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
