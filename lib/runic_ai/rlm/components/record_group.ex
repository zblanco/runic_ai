defmodule RunicAI.RLM.Components.RecordGroup do
  @moduledoc """
  Group, dedupe, sort, and rank structured records with data-only parameters.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.Components.BlueprintTransform

  @spec run(term(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, params \\ %{}, opts \\ []) when is_list(opts) do
    params = opts_map(params)
    records = records(input)

    with {:ok, transformed} <- maybe_apply_function(records, params, opts) do
      {deduped, dedupe_diagnostics} = dedupe(transformed, params)
      sorted = sort_records(deduped, params)
      groups = group_records(sorted, params)
      limit = integer_opt(params, :limit, length(sorted))
      visible_records = Enum.take(sorted, limit)

      {:ok,
       %{
         records: visible_records,
         groups: groups,
         count: min(length(sorted), limit),
         input_count: length(records),
         output_count: length(visible_records),
         group_count: length(groups),
         record_ids: record_ids(visible_records),
         dropped_record_ids: dropped_record_ids(records, visible_records),
         dedupe: dedupe_diagnostics,
         truncated?: length(sorted) > limit
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp maybe_apply_function(records, params, opts) do
    case get(params, :function, nil) do
      nil ->
        {:ok, records}

      function ->
        BlueprintTransform.apply(function, records,
          max_tier: Keyword.get(opts, :max_tier, :tier1)
        )
    end
  end

  defp dedupe(records, params) do
    keys = path_list(get(params, :dedupe_by, []))

    if keys == [] do
      {records, %{dedupe_keys: [], input_count: length(records), output_count: length(records)}}
    else
      deduped =
        records
        |> Enum.with_index()
        |> Enum.uniq_by(fn {record, index} -> identity_key(record, keys, index) end)
        |> Enum.map(fn {record, _index} -> record end)

      {deduped,
       %{
         dedupe_keys: Enum.map(keys, &Enum.join(&1, ".")),
         input_count: length(records),
         output_count: length(deduped),
         dropped_count: max(length(records) - length(deduped), 0),
         missing_identity_key_count: missing_identity_key_count(records, keys)
       }}
    end
  end

  defp identity_key(record, keys, index) do
    values = Enum.map(keys, &get_path(record_data(record), &1))

    if Enum.all?(values, &blank?/1) do
      {:missing_identity, index}
    else
      {:identity, values}
    end
  end

  defp missing_identity_key_count(records, keys) do
    Enum.count(records, fn record ->
      keys
      |> Enum.map(&get_path(record_data(record), &1))
      |> Enum.all?(&blank?/1)
    end)
  end

  defp sort_records(records, params) do
    path = path(get(params, :sort_by, get(params, :rank_by, nil)))

    if path == [] do
      records
    else
      Enum.sort_by(records, fn record -> record_data(record) |> get_path(path) |> sort_key() end)
    end
  end

  defp group_records(records, params) do
    path = path(get(params, :group_by, nil))

    if path == [] do
      []
    else
      records
      |> Enum.group_by(fn record -> record_data(record) |> get_path(path) |> group_key() end)
      |> Enum.map(fn {key, group_records} ->
        %{key: key, count: length(group_records), records: group_records}
      end)
      |> Enum.sort_by(& &1.count, :desc)
    end
  end

  defp records(%{records: records}) when is_list(records), do: records
  defp records(%{"records" => records}) when is_list(records), do: records
  defp records(%{items: items}) when is_list(items), do: items
  defp records(%{"items" => items}) when is_list(items), do: items
  defp records(values) when is_list(values), do: values
  defp records(value), do: List.wrap(value)

  defp record_ids(records) do
    records
    |> Enum.map(&record_id/1)
    |> Enum.reject(&blank?/1)
  end

  defp dropped_record_ids(input_records, output_records) do
    input_ids = record_ids(input_records)
    output_ids = MapSet.new(record_ids(output_records))

    Enum.reject(input_ids, &MapSet.member?(output_ids, &1))
  end

  defp record_id(record) do
    data = record_data(record)

    get(data, :ticket_id, nil) ||
      get(data, :ticket, nil) ||
      get(data, :id, nil)
  end

  defp record_data(%{data: data}) when is_map(data), do: data
  defp record_data(%{"data" => data}) when is_map(data), do: data
  defp record_data(record) when is_map(record), do: record
  defp record_data(value), do: %{"value" => value}

  defp path_list(values),
    do: values |> List.wrap() |> Enum.map(&path/1) |> Enum.reject(&(&1 == []))

  defp path(nil), do: []
  defp path(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp path(value), do: value |> to_string() |> String.split(".", trim: true)

  defp get_path(value, []), do: value
  defp get_path(nil, _path), do: nil

  defp get_path(value, [key | rest]) when is_map(value) do
    value
    |> get(key, nil)
    |> get_path(rest)
  end

  defp get_path(_value, _path), do: nil

  defp sort_key(nil), do: ""
  defp sort_key(value), do: to_string(value)

  defp group_key(nil), do: "nil"
  defp group_key(value), do: to_string(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp integer_opt(opts, key, default) do
    case get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_integer(value, default)
      _other -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> default
    end
  end

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map) and is_binary(key),
    do: Map.get(map, key, Map.get(map, existing_atom_key(map, key), default))

  defp get(_map, _key, default), do: default

  defp existing_atom_key(map, key) do
    Enum.find(Map.keys(map), fn
      atom when is_atom(atom) -> Atom.to_string(atom) == key
      _other -> false
    end)
  end
end
