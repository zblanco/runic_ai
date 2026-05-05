defmodule RunicAI.Terminal.ExRatatui.Views.RunPicker do
  @moduledoc false

  alias ExRatatui.Widgets.Table
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Table.t()
  def widget(%Model{} = model) do
    rows =
      Enum.map(model.runs, fn run ->
        [
          Helpers.short(run.status, 8),
          Helpers.short(run.workflow_name || run.workflow_key || run.id, 24),
          Helpers.time(run.started_at)
        ]
      end)

    %Table{
      header: ["State", "Run", "Started"],
      rows: rows,
      selected: selected_index(model.runs, model.selected_run_id),
      widths: [length: 9, percentage: 55, min: 8],
      block: Helpers.block("Runs", model),
      highlight_style: Theme.style(:selected, model),
      highlight_symbol: "> "
    }
  end

  defp selected_index(rows, id), do: Enum.find_index(rows, &(&1.id == id))
end
