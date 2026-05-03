defmodule RunicAI.RLM.ComponentSpec do
  @moduledoc """
  Normalized component data used to compile generated blueprints into Runic.
  """

  alias RunicAI.RLM.ValueContract

  @enforce_keys [:id, :type, :execution_shape, :inputs, :outputs]
  defstruct [
    :id,
    :type,
    :execution_shape,
    :blueprint,
    params: %{},
    inputs: [],
    outputs: [],
    policy: %{},
    provenance: [],
    metadata: %{}
  ]

  @type execution_shape ::
          :step | :map | :reduce | :rule | :accumulator | :side_effect_step

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          execution_shape: execution_shape(),
          params: map(),
          inputs: keyword(),
          outputs: keyword(),
          policy: map(),
          provenance: [term()],
          metadata: map(),
          blueprint: term()
        }

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = spec) do
    %{
      id: spec.id,
      type: spec.type,
      execution_shape: spec.execution_shape,
      inputs: ValueContract.json_ports(spec.inputs),
      outputs: ValueContract.json_ports(spec.outputs),
      policy: spec.policy,
      metadata: spec.metadata
    }
  end
end
