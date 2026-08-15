defmodule RunicAI.Context.ThreadStore do
  @moduledoc """
  Behaviour for persistence adapters that store long-horizon context snapshots.
  """

  alias RunicAI.Context.LineageSnapshot

  @type state :: term()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback put(LineageSnapshot.t(), state()) :: {:ok, state()} | {:error, term()}
  @callback get(String.t(), state()) :: {:ok, LineageSnapshot.t()} | {:error, term()}
  @callback list(String.t(), state()) :: {:ok, [LineageSnapshot.t()]} | {:error, term()}
  @callback delete(String.t(), state()) :: {:ok, state()} | {:error, term()}
end
