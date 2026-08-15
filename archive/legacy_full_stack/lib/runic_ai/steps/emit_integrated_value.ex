defmodule RunicAI.Steps.EmitIntegratedValue do
  @moduledoc """
  Extract integrated emissions from a session update.
  """

  require Runic

  alias RunicAI.Integrated.Emission

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :emit_integrated_value)

    Runic.step(
      fn update ->
        emissions(update)
      end,
      name: name
    )
  end

  @spec emissions(term()) :: [Emission.t()]
  def emissions(%{emissions: emissions}) when is_list(emissions) do
    Enum.filter(emissions, &match?(%Emission{}, &1))
  end

  def emissions(_update), do: []
end
