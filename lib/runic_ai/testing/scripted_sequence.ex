defmodule RunicAI.Testing.ScriptedSequence do
  @moduledoc false

  @spec start_link(list(), keyword()) :: {:ok, pid()}
  def start_link(items, opts \\ []) when is_list(items) and is_list(opts) do
    Agent.start_link(fn ->
      %{
        remaining: items,
        repeat_last?: Keyword.get(opts, :repeat_last, false),
        last: nil
      }
    end)
  end

  @spec next(pid()) :: {:ok, term()} | :empty
  def next(pid) when is_pid(pid) do
    Agent.get_and_update(pid, fn
      %{remaining: [item | rest]} = state ->
        {{:ok, item}, %{state | remaining: rest, last: item}}

      %{repeat_last?: true, last: last} = state when not is_nil(last) ->
        {{:ok, last}, state}

      state ->
        {:empty, state}
    end)
  end
end
