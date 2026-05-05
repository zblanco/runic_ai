defmodule RunicAI.Terminal.ExRatatui.Views.ReviewModal do
  @moduledoc false

  alias ExRatatui.Widgets.{Markdown, Popup}
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Redaction
  alias RunicAI.Terminal.ExRatatui.Views.Helpers
  alias RunicAI.Terminal.MarkdownBlocks

  @spec widget(Model.t()) :: Popup.t() | nil
  def widget(%Model{} = model) do
    case Model.selected_review(model) do
      nil ->
        nil

      review ->
        %Popup{
          content: %Markdown{content: text(review), wrap: true},
          block: Helpers.block("Review Required", model),
          percent_width: 70,
          percent_height: 45
        }
    end
  end

  defp text(review) do
    [
      "## #{review.kind || "review"}",
      "",
      "- status: #{review.status}",
      "- checkpoint: #{review.checkpoint || "-"}",
      "- resume: #{review.resume_key || "-"}",
      "",
      "### Details",
      "",
      "~~~elixir",
      Redaction.inspect_redacted(review.details),
      "~~~",
      "",
      "a approve | d deny | s stop | w rewrite"
    ]
    |> Enum.join("\n")
    |> MarkdownBlocks.escape_raw_html()
  end
end
