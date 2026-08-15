defmodule RunicAI.Steps.SelectReadyAgent do
  @moduledoc """
  Select the next ready integrated agent lane from runtime state.
  """

  require Runic

  alias RunicAI.Error
  alias RunicAI.Integrated.RuntimeState

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :select_ready_agent)

    Runic.step(
      fn %RuntimeState{} = runtime_state ->
        select!(runtime_state)
      end,
      name: name
    )
  end

  @spec select(RuntimeState.t()) ::
          {:ok,
           %{runtime: RuntimeState.t(), agent_id: String.t(), session: term(), signal: term()}}
          | {:error, Error.t()}
  def select(%RuntimeState{} = runtime_state) do
    case RuntimeState.next_ready(runtime_state) do
      {:ok, ready_bundle} ->
        {:ok, ready_bundle}

      :empty ->
        {:error,
         Error.validation("integrated runtime does not have a ready agent lane",
           source: __MODULE__,
           details: %{runtime_state: runtime_state}
         )}
    end
  end

  @spec select!(RuntimeState.t()) :: map()
  def select!(%RuntimeState{} = runtime_state) do
    case select(runtime_state) do
      {:ok, ready_bundle} -> ready_bundle
      {:error, error} -> raise ArgumentError, error.message
    end
  end
end
