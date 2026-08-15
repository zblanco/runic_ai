defmodule RunicAI.RLM.Components.ReportComposer do
  @moduledoc """
  Generic sectioned Markdown composer for generated RLM workflows.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.Components.BlueprintTransform

  @spec run(term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, params \\ %{}) do
    params = opts_map(params)
    title = get(params, :title, "Assistant Report")
    sections = List.wrap(get(params, :sections, []))

    rendered_sections =
      if sections == [] do
        fallback_sections(input)
      else
        Enum.map(sections, &render_section(&1, input))
      end

    text =
      ["# #{title}", "" | rendered_sections]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    {:ok,
     %{
       text: text,
       sections: section_titles(rendered_sections),
       count: length(rendered_sections),
       comparison_count: comparison_count(input),
       record_ids: record_ids(input),
       dropped_record_ids: dropped_record_ids(input),
       provenance: collect_provenance(input)
     }}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp render_section(section, input) when is_binary(section),
    do: "## #{section}\n\n#{section_text(section, input)}"

  defp render_section(section, input) when is_map(section) do
    title = get(section, :title, "Section")
    template = get(section, :template, nil) || get(section, :content, nil) || "{{content}}"

    content =
      render_template(template, %{
        input: input,
        content: fallback_text(input),
        records: records(input),
        groups: groups(input),
        comparisons: comparisons(input)
      })

    "## #{title}\n\n#{content}"
  end

  defp render_section(section, input), do: render_section(to_string(section), input)

  defp fallback_sections(input) do
    [
      "## Summary\n\n#{fallback_text(input)}"
    ]
  end

  defp section_text(section, input) do
    content = fallback_text(input)
    label = String.trim(section)

    if label == "" do
      content
    else
      "#{label}:\n\n#{content}"
    end
  end

  defp render_template(template, data) do
    expr = %{op: "template", template: template, data: data}

    case BlueprintTransform.eval(expr, data) do
      {:ok, rendered} -> rendered
      {:error, _error} -> template
    end
  end

  defp fallback_text(%{text: text}) when is_binary(text), do: text
  defp fallback_text(%{"text" => text}) when is_binary(text), do: text
  defp fallback_text(%{items: items}) when is_list(items), do: render_items(items)
  defp fallback_text(%{"items" => items}) when is_list(items), do: render_items(items)
  defp fallback_text(%{records: records}) when is_list(records), do: render_items(records)
  defp fallback_text(%{"records" => records}) when is_list(records), do: render_items(records)
  defp fallback_text(%{groups: groups}) when is_list(groups), do: render_items(groups)
  defp fallback_text(%{"groups" => groups}) when is_list(groups), do: render_items(groups)

  defp fallback_text(%{comparisons: comparisons}) when is_list(comparisons),
    do: render_items(comparisons)

  defp fallback_text(%{"comparisons" => comparisons}) when is_list(comparisons),
    do: render_items(comparisons)

  defp fallback_text(value) when is_binary(value), do: value
  defp fallback_text(value), do: inspect(value, limit: 40, printable_limit: 4_000)

  defp records(%{records: records}) when is_list(records), do: records
  defp records(%{"records" => records}) when is_list(records), do: records
  defp records(_input), do: []

  defp groups(%{groups: groups}) when is_list(groups), do: groups
  defp groups(%{"groups" => groups}) when is_list(groups), do: groups
  defp groups(_input), do: []

  defp comparisons(%{comparisons: comparisons}) when is_list(comparisons), do: comparisons
  defp comparisons(%{"comparisons" => comparisons}) when is_list(comparisons), do: comparisons
  defp comparisons(_input), do: []

  defp comparison_count(input), do: length(comparisons(input))

  defp record_ids(%{record_ids: ids}) when is_list(ids), do: ids
  defp record_ids(%{"record_ids" => ids}) when is_list(ids), do: ids
  defp record_ids(_input), do: []

  defp dropped_record_ids(%{dropped_record_ids: ids}) when is_list(ids), do: ids
  defp dropped_record_ids(%{"dropped_record_ids" => ids}) when is_list(ids), do: ids
  defp dropped_record_ids(_input), do: []

  defp render_items(items) do
    items
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> "- #{text}"
      %{"text" => text} when is_binary(text) -> "- #{text}"
      %{output: output} when is_binary(output) -> "- #{output}"
      %{"output" => output} when is_binary(output) -> "- #{output}"
      %{data: data} when is_map(data) -> "- #{render_map(data)}"
      %{"data" => data} when is_map(data) -> "- #{render_map(data)}"
      value when is_map(value) -> "- #{render_map(value)}"
      value -> "- #{inspect(value, limit: 20, printable_limit: 1_000)}"
    end)
    |> Enum.join("\n")
  end

  defp render_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
    |> Enum.map(fn {key, value} -> "#{humanize_key(key)}: #{render_value(value)}" end)
    |> Enum.join("; ")
  end

  defp render_value(value) when is_binary(value), do: value
  defp render_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp render_value(value) when is_atom(value), do: Atom.to_string(value)

  defp render_value(value) when is_list(value) do
    value
    |> Enum.map(&render_value/1)
    |> Enum.join(", ")
  end

  defp render_value(value) when is_map(value), do: render_map(value)
  defp render_value(value), do: inspect(value, limit: 10, printable_limit: 500)

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
      |> Map.take([
        :items,
        "items",
        :records,
        "records",
        :groups,
        "groups",
        :comparisons,
        "comparisons",
        :sources,
        "sources",
        :slices,
        "slices",
        :outputs,
        "outputs"
      ])
      |> Map.values()
      |> Enum.flat_map(&collect_provenance/1)

    Enum.uniq(own ++ nested)
  end

  defp collect_provenance(_value), do: []

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
  end

  defp section_titles(rendered_sections) do
    Enum.flat_map(rendered_sections, fn section ->
      Regex.scan(~r/^##\s+(.+)$/m, section, capture: :all_but_first)
      |> List.flatten()
    end)
  end

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
