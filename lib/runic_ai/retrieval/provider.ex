defmodule RunicAI.Retrieval.Provider do
  @moduledoc """
  Optional behaviour for external retrieval providers.
  """

  alias RunicAI.Retrieval.Query
  alias RunicAI.Retrieval.Result

  @callback retrieve(Query.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
end
