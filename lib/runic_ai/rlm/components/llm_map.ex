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

    results =
      Enum.reduce_while(selected, {:ok, []}, fn {record, index}, {:ok, acc} ->
        prompt = prompt_for(record, index, input, params, opts)
        model = model_name(params, opts)
        llm_opts = llm_opts(opts)

        case LLM.generate_text(model, prompt, llm_opts) do
          {:ok, %Result{} = result} ->
            item = %{
              id: get(record, :id, "item_#{index}"),
              index: index,
              text: Result.text(result),
              input: Map.drop(Map.new(record), [:text]),
              provenance: get(record, :provenance, [])
            }

            {:cont, {:ok, [item | acc]}}

          {:retry, %Error{} = error} ->
            {:halt, {:error, error}}

          {:error, %Error{} = error} ->
            {:halt, {:error, error}}
        end
      end)

    with {:ok, items} <- results do
      {:ok,
       %{
         items: Enum.reverse(items),
         count: length(items),
         input_count: length(records),
         truncated?: length(records) > limit
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
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
      text: get(record, :text, ""),
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
