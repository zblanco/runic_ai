defmodule RunicAI.Terminal.ExRatatui.Views.StatusBar do
  @moduledoc false

  alias ExRatatui.Widgets.Paragraph
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Paragraph.t()
  def widget(%Model{} = model) do
    text =
      [
        "RunicAI",
        "cwd=#{Path.basename(model.cwd || ".")}",
        "agent=#{model.agent}",
        "model=#{model.model || "default"}",
        "db=#{db_label(model)}",
        "view=#{model.view_mode}",
        "focus=#{model.focus}",
        "status=#{model.status}",
        Helpers.short(model.status_message, 80)
      ]
      |> Enum.join(" | ")

    %Paragraph{text: text, style: Theme.style(:primary, model), wrap: false}
  end

  defp db_label(%Model{persistence: :sqlite, sqlite_path: path}), do: path || "sqlite"
  defp db_label(%Model{persistence: persistence}), do: persistence
end
