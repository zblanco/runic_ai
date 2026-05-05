defmodule RunicAI.Terminal.ExRatatui.Views.ManagedWorkflows do
  @moduledoc false

  alias ExRatatui.Widgets.Table
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Table.t()
  def widget(%Model{} = model) do
    rows =
      Enum.map(model.managed_workflows, fn workflow ->
        [
          Helpers.short(workflow.status, 10),
          Helpers.short(workflow.workflow_key || workflow.id, 30),
          Helpers.short(workflow.trigger, 12),
          Helpers.short(workflow.last_run_id, 24)
        ]
      end)

    %Table{
      header: ["State", "Workflow", "Trigger", "Last run"],
      rows: rows,
      widths: [length: 10, percentage: 40, length: 12, min: 12],
      block: Helpers.block("Managed", model),
      highlight_style: Theme.style(:selected, model)
    }
  end
end
