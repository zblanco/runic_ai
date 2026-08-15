defmodule RunicAI.Terminal.ExRatatui.Views.Suggestions do
  @moduledoc false

  alias ExRatatui.Widgets.List
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: List.t() | nil
  def widget(%Model{slash_mode?: true, suggestions: suggestions} = model)
      when is_list(suggestions) and suggestions != [] do
    %List{
      items: Enum.map(suggestions, &line/1),
      selected: model.suggestion_index,
      style: Theme.style(:text, model),
      highlight_style: Theme.style(:selected, model),
      highlight_symbol: "> ",
      block: Helpers.block("Suggestions", model)
    }
  end

  def widget(_model), do: nil

  defp line(suggestion) do
    "#{suggestion.label}  #{suggestion.description}"
  end
end
