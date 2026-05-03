defmodule RunicAI.Persistence.Store do
  @moduledoc """
  Behaviour for RunicAI agent, harness, and observability persistence.

  This sits above `Runic.Runner.Store`. Runner durability still flows through
  Runic's store callbacks; this behaviour covers RunicAI-specific read models
  such as sessions, terminal events, tool calls, scorecards, and artifacts.
  """

  @type handle :: term()
  @type attrs :: map()

  @callback migrate!(handle()) :: handle()
  @callback put_artifact(handle(), attrs()) :: {:ok, String.t()} | {:error, term()}
  @callback get_artifact(handle(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback record_event(handle(), attrs()) :: :ok | {:error, term()}

  @optional_callbacks migrate!: 1,
                      put_artifact: 2,
                      get_artifact: 2,
                      record_event: 2
end
