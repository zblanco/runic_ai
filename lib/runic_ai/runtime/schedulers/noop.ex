defmodule RunicAI.Runtime.Schedulers.Noop do
  @moduledoc """
  Scheduler adapter that records no timers.
  """

  @behaviour RunicAI.Runtime.Scheduler

  alias RunicAI.Wait

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def schedule(%Wait{}, _destination, state), do: {:ok, state}

  @impl true
  def cancel(_resume_key, state), do: {:ok, state}

  @impl true
  def shutdown(_state), do: :ok
end
