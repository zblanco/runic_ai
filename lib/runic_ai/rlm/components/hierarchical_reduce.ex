defmodule RunicAI.RLM.Components.HierarchicalReduce do
  @moduledoc """
  Generic join and LLM synthesis reducer for assistant-generated workflows.
  """

  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.RLM.Components.BlueprintTransform

  @default_model "openai:gpt-5.4-mini"

  @spec run(term(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, params \\ %{}, opts \\ []) when is_list(opts) do
    params = opts_map(params)
    strategy = strategy(params)
    items = items(input)

    case strategy do
      :join ->
        {:ok, joined(items, params)}

      :llm_reduce ->
        llm_reduce(items, input, params, opts)
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp joined(items, params) do
    separator = get(params, :separator, "\n\n")

    text =
      items
      |> Enum.map(&item_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(separator)

    %{text: text, count: length(items), strategy: :join, provenance: collect_provenance(items)}
  end

  defp llm_reduce(items, input, params, opts) do
    chunks = chunk_items(items, integer_opt(params, :max_group_items, 12))
    model = model_name(params, opts)
    llm_opts = llm_opts(opts)

    with {:ok, intermediate} <- reduce_groups(chunks, input, params, model, llm_opts, opts),
         {:ok, final} <- final_reduce(intermediate, input, params, model, llm_opts, opts) do
      {:ok,
       %{
         text: final,
         count: length(items),
         groups: length(chunks),
         strategy: :llm_reduce,
         intermediate: intermediate,
         provenance: collect_provenance(input)
       }}
    end
  end

  defp reduce_groups(chunks, input, params, model, llm_opts, opts) do
    chunks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, acc} ->
      prompt =
        render_template(
          get(params, :group_prompt, nil) || default_group_prompt(),
          %{
            objective: Keyword.get(opts, :objective) || get(params, :objective, ""),
            input: input,
            group_index: index,
            group_count: length(chunks),
            items: render_items(chunk)
          }
        )

      case LLM.generate_text(model, prompt, llm_opts) do
        {:ok, %Result{} = result} -> {:cont, {:ok, [Result.text(result) | acc]}}
        {:retry, %Error{} = error} -> {:halt, {:error, error}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp final_reduce(intermediate, input, params, model, llm_opts, opts) do
    prompt =
      render_template(
        get(params, :prompt, nil) || get(params, :final_prompt, nil) || default_final_prompt(),
        %{
          objective: Keyword.get(opts, :objective) || get(params, :objective, ""),
          input: input,
          items: Enum.join(intermediate, "\n\n---\n\n")
        }
      )

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} -> {:ok, Result.text(result)}
      {:retry, %Error{} = error} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp default_group_prompt do
    """
    Objective:
    {{objective}}

    Partial notes group {{group_index}} of {{group_count}}:
    {{items}}

    Merge this group into concise, evidence-preserving notes for the objective.
    """
  end

  defp default_final_prompt do
    """
    Objective:
    {{objective}}

    Merged notes:
    {{items}}

    Produce the final artifact requested by the objective. Include concrete facts, actors, decisions, evidence, uncertainties, and takeaways where the objective asks for them.
    """
  end

  defp render_template(template, data) do
    expr = %{op: "template", template: template, data: data}

    case BlueprintTransform.eval(expr, data) do
      {:ok, rendered} -> rendered
      {:error, _error} -> template
    end
  end

  defp items(%{items: items}) when is_list(items), do: items
  defp items(%{"items" => items}) when is_list(items), do: items
  defp items(%{slices: slices}) when is_list(slices), do: slices
  defp items(%{"slices" => slices}) when is_list(slices), do: slices
  defp items(%{text: text}), do: [%{text: text}]
  defp items(%{"text" => text}), do: [%{text: text}]
  defp items(values) when is_list(values), do: values
  defp items(value), do: List.wrap(value)

  defp chunk_items(items, max_group_items) when max_group_items > 0 do
    Enum.chunk_every(items, max_group_items)
  end

  defp item_text(%{text: text}) when is_binary(text), do: text
  defp item_text(%{"text" => text}) when is_binary(text), do: text
  defp item_text(value) when is_binary(value), do: value
  defp item_text(value), do: inspect(value, limit: 40, printable_limit: 2_000)

  defp collect_provenance(value) when is_list(value) do
    value
    |> Enum.flat_map(&collect_provenance/1)
    |> Enum.uniq()
  end

  defp collect_provenance(value) when is_map(value) do
    own =
      value
      |> get(:provenance, [])
      |> case do
        provenance when is_list(provenance) -> provenance
        _other -> []
      end

    nested =
      value
      |> Map.take([:items, "items", :records, "records", :slices, "slices", :outputs, "outputs"])
      |> Map.values()
      |> Enum.flat_map(&collect_provenance/1)

    Enum.uniq(own ++ nested)
  end

  defp collect_provenance(_value), do: []

  defp render_items(items) do
    items
    |> Enum.map(&item_text/1)
    |> Enum.join("\n\n")
  end

  defp strategy(params) do
    case get(params, :strategy, :join) do
      value when value in [:join, :llm_reduce] -> value
      "join" -> :join
      "llm_reduce" -> :llm_reduce
      "llm-reduce" -> :llm_reduce
      "synthesize" -> :llm_reduce
      _other -> :join
    end
  end

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

  defp model_name(params, opts) do
    get(params, :model, nil) ||
      Keyword.get(opts, :model) ||
      @default_model
  end

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
