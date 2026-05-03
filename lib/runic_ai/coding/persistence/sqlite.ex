defmodule RunicAI.Coding.Persistence.SQLite do
  @moduledoc """
  Ecto SQLite-backed coding persistence compatibility adapter.

  The durable SQLite implementation now lives under `RunicAI.Persistence`.
  This module preserves the existing `RunicAI.Coding.Persistence` adapter shape
  for workspaces and tests that still pass `{RunicAI.Coding.Persistence.SQLite,
  store}`.
  """

  @behaviour RunicAI.Coding.Persistence

  alias RunicAI.Persistence.SQLite, as: Store

  @spec available?() :: boolean()
  defdelegate available?(), to: Store

  @spec open(Path.t() | keyword()) :: {:ok, term()} | {:error, RunicAI.Error.t()}
  defdelegate open(opts \\ []), to: Store

  @spec close(term()) :: :ok | {:error, RunicAI.Error.t()}
  defdelegate close(store), to: Store

  @spec migrate!(term()) :: term()
  defdelegate migrate!(store), to: Store

  @impl true
  defdelegate put_artifact(store, artifact), to: Store

  @impl true
  defdelegate get_artifact(store, ref), to: Store

  @impl true
  defdelegate record_event(store, event), to: Store

  @spec events(term()) :: {:ok, [map()]} | {:error, RunicAI.Error.t()}
  defdelegate events(store), to: Store

  @spec schema_version(term()) :: {:ok, non_neg_integer()} | {:error, RunicAI.Error.t()}
  defdelegate schema_version(store), to: Store
end
