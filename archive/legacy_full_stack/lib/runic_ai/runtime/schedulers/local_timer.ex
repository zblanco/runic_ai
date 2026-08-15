defmodule RunicAI.Runtime.Schedulers.LocalTimer do
  @moduledoc """
  Local `Process.send_after/3` scheduler for `RunicAI.Wait` wake delivery.
  """

  @behaviour RunicAI.Runtime.Scheduler

  alias RunicAI.Error
  alias RunicAI.Wait

  defstruct timers: %{}

  @type t :: %__MODULE__{timers: %{String.t() => reference()}}

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def schedule(%Wait{} = wait, destination, %__MODULE__{} = state) do
    case wait_until(wait) do
      nil ->
        {:ok, state}

      %DateTime{} = until ->
        state = cancel_existing(wait.resume_key, state)
        delay_ms = max(DateTime.diff(until, DateTime.utc_now(), :millisecond), 0)
        ref = Process.send_after(destination, {:runic_ai_runtime_wake, wait}, delay_ms)
        {:ok, %{state | timers: Map.put(state.timers, wait.resume_key, ref)}}

      other ->
        {:error,
         Error.validation("wait until must be a DateTime for local timer scheduling",
           source: __MODULE__,
           details: %{until: other}
         )}
    end
  end

  @impl true
  def cancel(resume_key, %__MODULE__{} = state) when is_binary(resume_key) do
    {:ok, cancel_existing(resume_key, state)}
  end

  @impl true
  def shutdown(%__MODULE__{} = state) do
    Enum.each(state.timers, fn {_resume_key, ref} -> Process.cancel_timer(ref) end)
    :ok
  end

  defp wait_until(%Wait{until: %DateTime{} = until}), do: until
  defp wait_until(%Wait{metadata: %{until: %DateTime{} = until}}), do: until
  defp wait_until(%Wait{metadata: %{"until" => %DateTime{} = until}}), do: until

  defp wait_until(%Wait{details: %{guard_decision: %{metadata: %{until: %DateTime{} = until}}}}),
    do: until

  defp wait_until(%Wait{
         details: %{guard_decision: %{metadata: %{"until" => %DateTime{} = until}}}
       }),
       do: until

  defp wait_until(%Wait{details: %{budget_decision: %{metadata: %{until: %DateTime{} = until}}}}),
    do: until

  defp wait_until(%Wait{
         details: %{budget_decision: %{metadata: %{"until" => %DateTime{} = until}}}
       }),
       do: until

  defp wait_until(%Wait{until: nil}), do: nil
  defp wait_until(%Wait{until: other}), do: other

  defp cancel_existing(resume_key, %__MODULE__{} = state) do
    case Map.fetch(state.timers, resume_key) do
      {:ok, ref} ->
        Process.cancel_timer(ref)
        %{state | timers: Map.delete(state.timers, resume_key)}

      :error ->
        state
    end
  end
end
