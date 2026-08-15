defmodule RunicAI.Terminal.ExRatatui.Views.Logs do
  @moduledoc false

  alias ExRatatui.Widgets.Paragraph
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t(), non_neg_integer()) :: Paragraph.t()
  def widget(%Model{} = model, visible_lines \\ 8) do
    %Paragraph{
      text: text(model, visible_lines),
      block: Helpers.block(title(model), model),
      wrap: true
    }
  end

  defp title(%Model{} = model) do
    filtered = Model.filtered_logs(model)
    suffix = filter_suffix(model)

    "Logs #{length(filtered)}/#{length(model.logs)}#{suffix}"
  end

  defp text(%Model{logs: []}, _visible_lines), do: "No logs"

  defp text(%Model{} = model, visible_lines) do
    model
    |> Model.filtered_logs()
    |> Enum.take(-max(visible_lines, 1))
    |> Enum.map(&line/1)
    |> Enum.join("\n")
    |> case do
      "" -> "No matching logs"
      text -> text
    end
  end

  defp line(%{at: at, level: level, message: message, source: source}) do
    source =
      case source do
        nil -> ""
        "" -> ""
        value -> " #{Helpers.short(value, 32)}"
      end

    "#{at} [#{level}]#{source} #{Helpers.short(message, 160)}"
  end

  defp line(value), do: Helpers.short(value, 180)

  defp filter_suffix(%Model{log_filter_level: nil, log_filter_source: nil}), do: ""
  defp filter_suffix(%Model{log_filter_level: level}) when is_binary(level), do: " | #{level}"
  defp filter_suffix(%Model{log_filter_source: source}) when is_binary(source), do: " | #{source}"
end
