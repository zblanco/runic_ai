defmodule RunicAI.Runtime.Scheduler do
  @moduledoc """
  Behaviour for explicit wait scheduling adapters.
  """

  alias RunicAI.Runtime.Handle
  alias RunicAI.Wait

  @type state :: term()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback schedule(Wait.t(), Handle.server_ref(), state()) ::
              {:ok, state()} | {:error, term()}
  @callback cancel(String.t(), state()) :: {:ok, state()} | {:error, term()}
  @callback shutdown(state()) :: :ok | {:error, term()}
end
