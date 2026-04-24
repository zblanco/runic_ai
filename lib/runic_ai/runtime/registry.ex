defmodule RunicAI.Runtime.Registry do
  @moduledoc """
  Registry helpers for addressed runtime sessions.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    Registry.child_spec(
      keys: :unique,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_id) when is_binary(session_id) do
    {:via, Registry, {__MODULE__, session_id}}
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(__MODULE__, session_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
