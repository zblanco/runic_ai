defmodule RunicAI.Terminal.ExRatatui.Views.Evidence do
  @moduledoc false

  alias ExRatatui.Widgets.Paragraph
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Paragraph.t()
  def widget(%Model{} = model) do
    %Paragraph{text: evidence_text(model), block: Helpers.block("Evidence", model), wrap: true}
  end

  defp evidence_text(%Model{} = model) do
    [
      "scorecards=#{length(model.scorecards)}",
      "artifacts=#{length(model.artifacts)}",
      "repairs=#{length(model.repairs)}",
      "tools=#{length(model.tool_calls)}",
      "failed_runnables=#{length(model.failed_runnables)}"
    ]
    |> Enum.join(" ")
  end
end
