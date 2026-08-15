defmodule RunicAI.Control.Trace.Event do
  @moduledoc "One ordered, portable trace observation emitted by a component or host."

  @enforce_keys [:id, :sequence, :component, :status, :occurred_at]
  defstruct id: nil,
            sequence: nil,
            component: nil,
            status: nil,
            occurred_at: nil,
            input_ref: nil,
            output_ref: nil,
            error: nil,
            metadata: %{}

  @type t :: %__MODULE__{}
end
