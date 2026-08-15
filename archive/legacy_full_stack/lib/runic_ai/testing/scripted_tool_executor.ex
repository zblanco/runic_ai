defmodule RunicAI.Testing.ScriptedToolExecutor do
  @moduledoc """
  Deterministic tool executor helpers for tests and replay.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry
  alias RunicAI.Testing.ScriptedSequence

  @spec executor(list(), keyword()) :: (map() -> {:ok, term()} | {:error, term()})
  def executor(script, opts \\ []) when is_list(script) and is_list(opts) do
    {:ok, pid} =
      ScriptedSequence.start_link(script, repeat_last: Keyword.get(opts, :repeat_last, false))

    fn arguments ->
      case ScriptedSequence.next(pid) do
        {:ok, step} ->
          resolve_step(step, arguments)

        :empty ->
          {:error, Error.unexpected("scripted tool sequence exhausted", source: __MODULE__)}
      end
    end
  end

  @spec registry(Registry.t() | [Definition.t() | keyword()], map(), keyword()) :: Registry.t()
  def registry(registry_input, scripts_by_name, opts \\ [])
      when is_map(scripts_by_name) and is_list(opts) do
    registry = Registry.from_input!(registry_input)

    tools =
      Enum.map(registry.tools, fn %Definition{} = definition ->
        case Map.get(scripts_by_name, definition.name) do
          nil ->
            definition

          script ->
            %Definition{definition | executor: executor(List.wrap(script), opts)}
        end
      end)

    Registry.new!(tools, metadata: registry.metadata)
  end

  defp resolve_step(step, arguments) when is_function(step, 1), do: step.(arguments)
  defp resolve_step({:ok, value}, _arguments), do: {:ok, value}
  defp resolve_step({:error, reason}, _arguments), do: {:error, reason}

  defp resolve_step(%CallResult{status: :ok, output: output}, _arguments), do: {:ok, output}

  defp resolve_step(%CallResult{status: status, error: error}, _arguments)
       when status in [:error, :retry],
       do: {:error, error || Error.unexpected("replayed tool call failed", source: __MODULE__)}

  defp resolve_step(other, _arguments), do: {:ok, other}
end
