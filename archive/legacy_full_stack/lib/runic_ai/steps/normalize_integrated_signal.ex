defmodule RunicAI.Steps.NormalizeIntegratedSignal do
  @moduledoc """
  Normalize external or internal input into an `Integrated.Signal`.
  """

  require Runic

  alias RunicAI.Integrated.Signal

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :normalize_integrated_signal)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        Signal.from_input!(input, options)
      end,
      name: name
    )
  end
end
