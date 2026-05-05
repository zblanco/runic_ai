defmodule RunicAI.Terminal.ExRatatui.Views.Evals do
  @moduledoc false

  alias ExRatatui.Widgets.Table
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Table.t()
  def widget(%Model{} = model) do
    rows =
      Enum.map(model.eval_cohort, fn record ->
        run = record.run || %{}

        [
          Helpers.short(record.objective_status, 20),
          Helpers.short(run[:workflow_key] || run["workflow_key"] || run[:id], 28),
          to_string(record.tool_call_count),
          to_string(record.repair_count),
          to_string(record.artifact_count)
        ]
      end)

    %Table{
      header: ["Objective", "Run", "Tools", "Repairs", "Artifacts"],
      rows: rows,
      widths: [percentage: 30, percentage: 35, length: 7, length: 8, min: 9],
      block: Helpers.block("Evals", model),
      highlight_style: Theme.style(:selected, model)
    }
  end
end
