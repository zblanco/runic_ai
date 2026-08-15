defmodule RunicAI.Retrieval.Provider do
  @moduledoc "Host-owned retrieval boundary; Core defines values and behavior but owns no index."

  alias RunicAI.Context.Window
  alias RunicAI.Error

  @callback retrieve(String.t(), map(), keyword()) ::
              {:ok, Window.t()} | {:retry, Error.t()} | {:error, Error.t()}
end
