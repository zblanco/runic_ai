defmodule RunicAI.Browser.Backend do
  @moduledoc """
  Behaviour for browser automation backends.

  Backends own the concrete browser connection. `RunicAI.Browser.Session`
  normalizes state, timeouts, and model-facing observations around this contract.
  """

  @callback init(keyword()) :: {:ok, term()} | {:error, term()}
  @callback navigate(term(), String.t(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback snapshot(term(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback click(term(), String.t(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback type(term(), String.t(), String.t(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback press(term(), String.t(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback scroll(term(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback console(term(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback screenshot(term(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback close(term()) :: :ok | {:error, term()}
end
