defmodule RunicAI.Workflows.AdapterResult do
  @moduledoc """
  Shared-IR adapter output with explicit semantic loss diagnostics.
  """

  alias RunicAI.Workflows.IR

  @enforce_keys [:ir, :diagnostics, :lossless?]
  defstruct [:ir, diagnostics: [], lossless?: false]

  @type t :: %__MODULE__{
          ir: IR.t(),
          diagnostics: [map()],
          lossless?: boolean()
        }
end
