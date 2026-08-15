defmodule RunicAI.Persistence.SQLite.Repo do
  @moduledoc """
  Default Ecto repository for RunicAI's local SQLite durability store.

  Callers may use this repo directly, start it with a runtime `:database`
  option, or provide their own Ecto repo to `RunicAI.Persistence.SQLite.Store`.
  """

  use Ecto.Repo,
    otp_app: :runic_ai,
    adapter: Ecto.Adapters.SQLite3

  @impl Ecto.Repo
  def init(_type, config), do: {:ok, config}
end
