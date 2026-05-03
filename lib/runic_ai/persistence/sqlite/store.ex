defmodule RunicAI.Persistence.SQLite.Store do
  @moduledoc """
  Handle for an Ecto-backed SQLite persistence store.
  """

  alias RunicAI.Persistence.SQLite.Repo

  @enforce_keys [:repo]
  defstruct [
    :repo,
    :dynamic_repo,
    :database,
    :owner,
    migrations_path: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          repo: module(),
          dynamic_repo: pid() | atom() | nil,
          database: String.t() | nil,
          owner: pid() | nil,
          migrations_path: String.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      repo: Keyword.get(opts, :repo, Repo),
      dynamic_repo: Keyword.get(opts, :dynamic_repo),
      database: Keyword.get(opts, :database),
      owner: Keyword.get(opts, :owner),
      migrations_path: Keyword.get(opts, :migrations_path),
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }
  end

  def new(opts) when is_map(opts) do
    opts
    |> Map.to_list()
    |> new()
  end
end
