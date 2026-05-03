defmodule RunicAI.RLM.ComponentError do
  @moduledoc """
  Exception wrapper for component adapter failures inside Runic runnables.
  """

  defexception [:message, :error, :component_id, :component_type]

  alias RunicAI.Error

  @type t :: %__MODULE__{
          message: String.t(),
          error: Error.t(),
          component_id: String.t() | nil,
          component_type: atom() | nil
        }

  @impl true
  def exception(opts) do
    error = Keyword.fetch!(opts, :error)
    component = Keyword.get(opts, :component)

    %__MODULE__{
      message: error.message,
      error: error,
      component_id: component && component.id,
      component_type: component && component.type
    }
  end
end
