defmodule RunicAI.RLM.Components.LLMMap do
  @moduledoc """
  Bounded map-over-records LLM component for generated assistant workflows.
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
    limit = integer_opt(params, :limit, length(records))

    selected =
      records
      |> Enum.take(limit)
      |> Enum.with_index(1)

    max_concurrency = integer_opt(params, :max_concurrency, 1)
    model = model_name(params, opts)
    llm_opts = llm_opts(opts)

    results =
      selected
      |> Task.async_stream(
        fn {record, index} ->
          map_one(record, index, input, params, opts, model, llm_opts)
        end,
        max_concurrency: max(max_concurrency, 1),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, item}}, {:ok, acc} ->
          {:cont, {:ok, [item | acc]}}

        {:ok, {:error, %Error{} = error}}, {:ok, _acc} ->
          {:halt, {:error, error}}

        {:exit, reason}, {:ok, _acc} ->
          {:halt, {:error, Error.from_reason(reason, source: __MODULE__)}}
      end)

    with {:ok, items} <- results do
      {:ok,
       %{
         items: Enum.reverse(items),
         count: length(items),
         input_count: length(records),
         max_concurrency: max_concurrency,
         truncated?: length(records) > limit
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp map_one(record, index, input, params, opts, model, llm_opts) do
    prompt = prompt_for(record, index, input, params, opts)

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        {:ok,
         %{
           id: get(record, :id, "item_#{index}"),
           index: index,
           text: Result.text(result),
           input: Map.drop(Map.new(record), [:text]),
           provenance: get(record, :provenance, [])
         }}

      {:retry, %Error{} = error} ->
        {:error, error}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp prompt_for(record, index, input, params, opts) do
    template =
      get(params, :prompt, nil) ||
        get(params, :prompt_template, nil) ||
        """
        Objective:
        {{objective}}

        Source {{source_path}} slice {{index}} lines {{start_line}}-{{end_line}}:
        {{text}}

        Extract the facts, observations, evidence, uncertainties, and source references needed to satisfy the objective.
        """

    data = %{
      objective: Keyword.get(opts, :objective) || get(params, :objective, ""),
      text: record_text(record),
      record: record,
      source_path: get(record, :path, get(record, :source_path, "")),
      index: index,
      start_line: get(record, :start_line, ""),
      end_line: get(record, :end_line, ""),
      input: input
    }

    render_template(template, data)
  end

  defp render_template(template, data) do
    expr = %{op: "template", template: template, data: data}

    case BlueprintTransform.eval(expr, data) do
      {:ok, rendered} -> rendered
      {:error, _error} -> template
    end
  end

  defp records(%{slices: slices}) when is_list(slices), do: slices
  defp records(%{"slices" => slices}) when is_list(slices), do: slices
  defp records(%{items: items}) when is_list(items), do: items
  defp records(%{"items" => items}) when is_list(items), do: items
  defp records(values) when is_list(values), do: values
  defp records(value), do: List.wrap(value)

  defp record_text(record) do
    get(record, :text, nil) ||
      get(record, :content, nil) ||
      structured_text(record)
  end

  defp structured_text(value) when is_map(value) or is_list(value) do
    case Jason.encode(json_safe(value), pretty: true) do
      {:ok, json} -> json
      {:error, _error} -> inspect(value, limit: 60, printable_limit: 8_000)
    end
  end

  defp structured_text(value), do: to_string(value)

  defp json_safe(%_struct{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(value), do: inspect(value, limit: 20, printable_limit: 2_000)

  defp llm_opts(opts) do
    []
    |> maybe_put(:client, Keyword.get(opts, :client))
    |> Keyword.merge(Keyword.get(opts, :llm_opts, []))
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp integer_opt(opts, key, default) do
    case get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 0 -> integer
          _other -> default
        end

      _other ->
        default
    end
  end

  defp model_name(params, opts) do
    get(params, :model, nil) ||
      Keyword.get(opts, :model) ||
      @default_model
  end

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
