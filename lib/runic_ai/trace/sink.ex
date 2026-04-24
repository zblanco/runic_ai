defmodule RunicAI.Trace.Sink do
  @moduledoc """
  Behaviour and helpers for trace event sinks.
  """

  alias RunicAI.Error
  alias RunicAI.Trace.Event

  @type normalized_sink :: %{module: module(), state: term()}

  @callback emit(Event.t(), term()) :: {:ok, term()} | {:error, term()}
  @callback flush(term()) :: {:ok, term()} | {:error, term()}

  @spec normalize_input(nil | module() | {module(), term()} | [module() | {module(), term()}]) ::
          {:ok, [normalized_sink()]} | {:error, Error.t()}
  def normalize_input(nil), do: {:ok, []}

  def normalize_input(sinks) when is_list(sinks) do
    sinks
    |> Enum.reduce_while({:ok, []}, fn sink, {:ok, acc} ->
      case normalize_sink(sink) do
        {:ok, normalized_sink} -> {:cont, {:ok, [normalized_sink | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_sinks} -> {:ok, Enum.reverse(normalized_sinks)}
      error -> error
    end
  end

  def normalize_input(sink) do
    case normalize_sink(sink) do
      {:ok, normalized_sink} -> {:ok, [normalized_sink]}
      {:error, error} -> {:error, error}
    end
  end

  @spec normalize_input!(nil | module() | {module(), term()} | [module() | {module(), term()}]) ::
          [normalized_sink()]
  def normalize_input!(input) do
    case normalize_input(input) do
      {:ok, normalized_sinks} -> normalized_sinks
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec emit_all([normalized_sink()], Event.t()) ::
          {:ok, [normalized_sink()]} | {:error, [term()]}
  def emit_all(sinks, %Event{} = event) when is_list(sinks) do
    {updated_sinks, errors} =
      Enum.reduce(sinks, {[], []}, fn %{module: module, state: state}, {acc, errors} ->
        case module.emit(event, state) do
          {:ok, updated_state} ->
            {[%{module: module, state: updated_state} | acc], errors}

          {:error, reason} ->
            {[%{module: module, state: state} | acc], [reason | errors]}

          other ->
            {[%{module: module, state: state} | acc], [other | errors]}
        end
      end)

    if errors == [] do
      {:ok, Enum.reverse(updated_sinks)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @spec flush_all([normalized_sink()]) :: {:ok, [normalized_sink()]} | {:error, [term()]}
  def flush_all(sinks) when is_list(sinks) do
    {updated_sinks, errors} =
      Enum.reduce(sinks, {[], []}, fn %{module: module, state: state}, {acc, errors} ->
        case module.flush(state) do
          {:ok, updated_state} ->
            {[%{module: module, state: updated_state} | acc], errors}

          {:error, reason} ->
            {[%{module: module, state: state} | acc], [reason | errors]}

          other ->
            {[%{module: module, state: state} | acc], [other | errors]}
        end
      end)

    if errors == [] do
      {:ok, Enum.reverse(updated_sinks)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp normalize_sink(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :emit, 2) and
         function_exported?(module, :flush, 1) do
      {:ok, %{module: module, state: []}}
    else
      {:error,
       Error.validation("trace sink module must implement emit/2 and flush/1",
         source: __MODULE__,
         details: %{sink: module}
       )}
    end
  end

  defp normalize_sink({module, state}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :emit, 2) and
         function_exported?(module, :flush, 1) do
      {:ok, %{module: module, state: state}}
    else
      {:error,
       Error.validation("trace sink module must implement emit/2 and flush/1",
         source: __MODULE__,
         details: %{sink: module}
       )}
    end
  end

  defp normalize_sink(%{module: module, state: state}) when is_atom(module) do
    normalize_sink({module, state})
  end

  defp normalize_sink(other) do
    {:error,
     Error.validation("unsupported trace sink specification",
       source: __MODULE__,
       details: %{sink: other}
     )}
  end
end
