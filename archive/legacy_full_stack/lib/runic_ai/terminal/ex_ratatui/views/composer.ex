defmodule RunicAI.Terminal.ExRatatui.Views.Composer do
  @moduledoc false

  alias ExRatatui.Widgets.Textarea
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme
  alias RunicAI.Terminal.ExRatatui.Views.Helpers

  @spec widget(Model.t()) :: Textarea.t()
  def widget(%Model{slash_mode?: true} = model) do
    %Textarea{
      state: model.slash_ref,
      placeholder: "/help",
      placeholder_style: Theme.style(:muted, model),
      cursor_style: Theme.style(:selected, model),
      block: Helpers.block("Command", model)
    }
  end

  def widget(%Model{} = model) do
    %Textarea{
      state: model.composer_ref,
      placeholder: "Objective or /command",
      placeholder_style: Theme.style(:muted, model),
      cursor_style: Theme.style(:selected, model),
      block: Helpers.block("Composer", model)
    }
  end
end
