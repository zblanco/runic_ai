defmodule RunicAI.Terminal.ExRatatui.EventBridge do
  @moduledoc """
  Bridges live terminal events into SQLite before TUI refresh.
  """

  alias RunicAI.Persistence.SQLite
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Terminal.Event

  @spec persist_event(Store.t() | nil, Event.t() | map()) :: :ok | {:error, term()}
  def persist_event(nil, _event), do: :ok

  def persist_event(%Store{} = store, event) do
    case SQLite.record_terminal_event(store, event) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
