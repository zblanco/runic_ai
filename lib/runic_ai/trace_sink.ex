defmodule RunicAI.TraceSink do
  @moduledoc "Optional host adapter for portable trace events; no sink or process is owned by Core."

  alias RunicAI.Control.Trace.Event

  @callback emit(Event.t(), map()) :: :ok | {:error, term()}

  def emit(nil, %Event{}, _context), do: :ok

  def emit(module, %Event{} = event, context) when is_atom(module),
    do: module.emit(event, context)

  def emit(fun, %Event{} = event, context) when is_function(fun, 2), do: fun.(event, context)

  def emit({module, function, extra}, %Event{} = event, context),
    do: apply(module, function, [event, context | extra])
end
