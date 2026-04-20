defmodule RunicAI.Memory.Store do
  @moduledoc """
  Optional behaviour for external memory stores.
  """

  alias RunicAI.Memory.Entry
  alias RunicAI.Memory.Query
  alias RunicAI.Memory.ReadResult

  @callback write([Entry.t()], keyword()) :: {:ok, term()} | {:error, term()}
  @callback read(Query.t(), keyword()) :: {:ok, ReadResult.t()} | {:error, term()}
end
