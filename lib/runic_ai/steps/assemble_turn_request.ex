defmodule RunicAI.Steps.AssembleTurnRequest do
  @moduledoc """
  Build a normalized `RunicAI.Agent.TurnRequest` from input and defaults.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :assemble_turn_request)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        TurnRequest.from_input!(input, defaults)
      end,
      name: name
    )
  end
end
