defmodule RunicAI.Terminal.ExRatatui.Theme do
  @moduledoc """
  ExRatatui style tokens mirroring `.docs/DESIGN.md`.
  """

  alias ExRatatui.Style
  alias RunicAI.Terminal.ExRatatui.Model

  @spec style(atom(), Model.t() | atom()) :: Style.t()
  def style(token, %Model{theme: theme}), do: style(token, theme)

  def style(_token, :plain), do: %Style{}
  def style(:bg, :runic), do: %Style{fg: :light_yellow, bg: :black}
  def style(:surface, :runic), do: %Style{fg: :light_yellow, bg: :black}
  def style(:border, :runic), do: %Style{fg: :yellow}
  def style(:muted, :runic), do: %Style{fg: :dark_gray}
  def style(:primary, :runic), do: %Style{fg: :cyan, modifiers: [:bold]}
  def style(:gold, :runic), do: %Style{fg: :yellow, modifiers: [:bold]}
  def style(:purple, :runic), do: %Style{fg: :magenta}
  def style(:magenta, :runic), do: %Style{fg: :magenta, modifiers: [:bold]}
  def style(:success, :runic), do: %Style{fg: :green}
  def style(:warning, :runic), do: %Style{fg: :yellow}
  def style(:error, :runic), do: %Style{fg: :red, modifiers: [:bold]}
  def style(:info, :runic), do: %Style{fg: :blue}
  def style(:selected, :runic), do: %Style{fg: :black, bg: :cyan, modifiers: [:bold]}
  def style(_token, :runic), do: %Style{fg: :light_yellow}

  @spec status_style(String.t() | atom(), Model.t()) :: Style.t()
  def status_style(status, %Model{} = model) do
    case to_string(status) do
      "ok" -> style(:success, model)
      "completed" -> style(:success, model)
      "running" -> style(:primary, model)
      "review" -> style(:magenta, model)
      "waiting" -> style(:warning, model)
      "blocked" -> style(:warning, model)
      "failed" -> style(:error, model)
      "error" -> style(:error, model)
      _other -> style(:muted, model)
    end
  end
end
