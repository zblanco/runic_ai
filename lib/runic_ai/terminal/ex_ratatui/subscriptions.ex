defmodule RunicAI.Terminal.ExRatatui.Subscriptions do
  @moduledoc """
  Timer subscriptions for the TUI.
  """

  alias ExRatatui.Subscription
  alias RunicAI.Terminal.ExRatatui.Model

  @spec subscriptions(Model.t()) :: [Subscription.t()]
  def subscriptions(%Model{active_run?: true}) do
    [Subscription.interval(:active_refresh, 1_000, :refresh)]
  end

  def subscriptions(%Model{}), do: []
end
