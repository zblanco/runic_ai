defmodule RunicAI.Terminal.InteractiveContext do
  @moduledoc """
  Small prompt carryover helpers for interactive terminal sessions.

  The CLI still starts a normal agent run per prompt. This helper carries only
  bounded terminal-relevant context that a follow-up prompt is likely to need,
  such as the last rendered source diagram target.
  """

  @spec add_carryover(String.t(), map() | nil) :: String.t()
  def add_carryover(objective, nil) when is_binary(objective), do: objective

  def add_carryover(objective, last_result) when is_binary(objective) and is_map(last_result) do
    case diagram_context(last_result) do
      nil -> objective
      context -> objective <> "\n\n" <> context
    end
  end

  defp diagram_context(last_result) do
    last_result
    |> rendered_diagrams()
    |> Enum.take(3)
    |> case do
      [] ->
        nil

      diagrams ->
        lines =
          Enum.map(diagrams, fn diagram ->
            [
              "- path: #{field(diagram, :path)}",
              field(diagram, :diagram_index) && "diagram_index: #{field(diagram, :diagram_index)}",
              field(diagram, :heading) && "heading: #{field(diagram, :heading)}",
              field(diagram, :line_start) && "line: #{field(diagram, :line_start)}"
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(", ")
          end)

        [
          "Previous terminal diagram context:",
          "When the user asks to render the same, previous, or extracted diagrams, prefer these source targets before broad workspace discovery.",
          lines
        ]
        |> List.flatten()
        |> Enum.join("\n")
    end
  end

  defp rendered_diagrams(result) do
    result
    |> field(:summary)
    |> case do
      summary when is_map(summary) -> field(summary, :rendered_diagrams) || []
      _other -> []
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
