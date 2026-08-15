defmodule RunicAI.RLM.Components.RecordMap do
  @moduledoc """
  Map over structured records with either Tier 0/1 transforms or LLM prompts.
  """

  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.RLM.Components.BlueprintTransform

  @default_model "openai:gpt-5.4-mini"

  @spec run(term(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, params \\ %{}, opts \\ []) when is_list(opts) do
    params = opts_map(params)
    records = records(input)
    selected = items(input, params)

    with {:ok, mapped} <- map_records(selected, input, params, opts) do
      {:ok,
       %{
         records: mapped,
         items: mapped,
         count: length(mapped),
         input_count: length(records),
         truncated?: length(records) > length(selected)
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  @spec items(term(), map() | keyword()) :: [{term(), pos_integer()}]
  def items(input, params \\ %{}) do
    params = opts_map(params)
    records = records(input)
    limit = integer_opt(params, :limit, integer_opt(params, :max_items, length(records)))

    records
    |> Enum.take(limit)
    |> Enum.with_index(1)
  end

  @spec map_item(term(), pos_integer(), term(), map() | keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def map_item(record, index, input, params \\ %{}, opts \\ []) when is_list(opts) do
    params = opts_map(params)

    cond do
      function = get(params, :function, nil) ->
        transform_item(record, index, function, opts)

      prompt = get(params, :prompt, nil) || get(params, :prompt_template, nil) ->
        llm_item(record, index, input, prompt, params, opts)

      true ->
        {:ok, record}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp map_records(selected, input, params, opts) do
    Enum.reduce_while(selected, {:ok, []}, fn {record, index}, {:ok, acc} ->
      case map_item(record, index, input, params, opts) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp transform_item(record, index, function, opts) do
    case BlueprintTransform.apply(function, record_data(record),
           max_tier: Keyword.get(opts, :max_tier, :tier1)
         ) do
      {:ok, output} -> {:ok, mapped_record(record, index, output)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp llm_item(record, index, input, prompt_template, params, opts) do
    model = get(params, :model, nil) || Keyword.get(opts, :model) || @default_model
    llm_opts = llm_opts(opts)

    prompt =
      render_template(prompt_template, %{
        objective: Keyword.get(opts, :objective) || get(params, :objective, ""),
        record: record_data(record),
        input: input,
        index: index
      })
      |> append_record_context(record, index)

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        {:ok, mapped_record(record, index, Result.text(result))}

      {:retry, %Error{} = error} ->
        {:error, error}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp mapped_record(record, index, output) do
    %{
      id: get(record, :id, "record_#{index}"),
      index: index,
      data: if(is_map(output), do: output, else: record_data(record)),
      output: output,
      text: if(is_binary(output), do: output, else: inspect(output, limit: 40)),
      input: record_data(record),
      provenance: get(record, :provenance, [])
    }
  end

  defp render_template(template, data) do
    expr = %{op: "template", template: template, data: data}

    case BlueprintTransform.eval(expr, data) do
      {:ok, rendered} -> rendered
      {:error, _error} -> template
    end
  end

  # Model-authored prompts sometimes describe the transformation but omit the
  # `{{record}}` placeholder. The component boundary owns data delivery, so the
  # authoritative record is always appended rather than trusting prompt prose.
  defp append_record_context(prompt, record, index) do
    context = %{
      index: index,
      id: get(record, :id, "record_#{index}"),
      record: record_data(record),
      provenance: get(record, :provenance, [])
    }

    encoded =
      case Jason.encode(context) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(context, limit: :infinity, printable_limit: :infinity)
      end

    "#{prompt}\n\nAuthoritative input record (JSON):\n#{encoded}"
  end

  defp records(%{records: records}) when is_list(records), do: records
  defp records(%{"records" => records}) when is_list(records), do: records
  defp records(%{items: items}) when is_list(items), do: items
  defp records(%{"items" => items}) when is_list(items), do: items
  defp records(values) when is_list(values), do: values
  defp records(value), do: List.wrap(value)

  defp record_data(%{data: data}) when is_map(data), do: data
  defp record_data(%{"data" => data}) when is_map(data), do: data
  defp record_data(record) when is_map(record), do: record
  defp record_data(value), do: %{"value" => value}

  defp llm_opts(opts) do
    []
    |> maybe_put(:client, Keyword.get(opts, :client))
    |> Keyword.merge(Keyword.get(opts, :llm_opts, []))
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

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

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  defp get(_map, _key, default), do: default
end
