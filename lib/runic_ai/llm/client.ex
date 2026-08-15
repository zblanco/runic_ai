defmodule RunicAI.LLM.Client do
  @moduledoc "Behavior implemented by host-injected LLM clients."

  alias RunicAI.Error
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result

  @type outcome :: {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()}

  @callback generate(Request.t(), keyword()) :: outcome()
end
