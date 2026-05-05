defmodule RunicAI.Terminal.ExRatatui.Views.Helpers do
  @moduledoc false

  alias ExRatatui.Widgets.Block
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme

  @spec block(String.t(), Model.t()) :: Block.t()
  def block(title, %Model{} = model) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :plain,
      border_style: Theme.style(:border, model),
      padding: {1, 1, 0, 0}
    }
  end

  @spec short(term(), non_neg_integer()) :: String.t()
  def short(value, limit \\ 80)

  def short(nil, _limit), do: ""

  def short(value, limit) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(limit)
  end

  def short(value, limit), do: value |> inspect(limit: 8, printable_limit: limit) |> short(limit)

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(text, limit) when byte_size(text) <= limit, do: text
  def truncate(text, limit) when limit <= 3, do: String.slice(text, 0, limit)
  def truncate(text, limit), do: String.slice(text, 0, limit - 3) <> "..."

  @spec time(term()) :: String.t()
  def time(%DateTime{} = dt),
    do: dt |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_iso8601()

  def time(nil), do: "-"
  def time(other), do: short(other, 16)
end
