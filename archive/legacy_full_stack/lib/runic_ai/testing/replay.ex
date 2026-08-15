defmodule RunicAI.Testing.Replay do
  @moduledoc """
  Helpers that derive deterministic test doubles from captured trajectories.
  """

  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.Registry
  alias RunicAI.Trace.Trajectory
  alias RunicAI.Testing.ScriptedLLM
  alias RunicAI.Testing.ScriptedRetrieval
  alias RunicAI.Testing.ScriptedToolExecutor

  @spec llm_client(Trajectory.t(), keyword()) :: (term(), term(), keyword() ->
                                                    {:ok, term()} | {:error, term()})
  def llm_client(%Trajectory{} = trajectory, opts \\ []) do
    script =
      trajectory
      |> Trajectory.events_of_kind(:llm_result)
      |> Enum.reverse()
      |> Enum.map(& &1.output)

    ScriptedLLM.client(script, opts)
  end

  @spec tool_registry(Trajectory.t(), Registry.t() | list(), keyword()) :: Registry.t()
  def tool_registry(%Trajectory{} = trajectory, registry_input, opts \\ []) do
    scripts =
      trajectory
      |> Trajectory.events_of_kind(:tool_result)
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn event, acc ->
        case tool_name_from_output(event.output) do
          nil ->
            acc

          tool_name ->
            Map.update(acc, tool_name, [event.output], &(&1 ++ [event.output]))
        end
      end)

    ScriptedToolExecutor.registry(registry_input, scripts, opts)
  end

  @spec retrieval_provider(Trajectory.t(), keyword()) :: (term(), keyword() ->
                                                            {:ok, term()} | {:error, term()})
  def retrieval_provider(%Trajectory{} = trajectory, opts \\ []) do
    script =
      trajectory
      |> Trajectory.events_of_kind(:retrieval_result)
      |> Enum.reverse()
      |> Enum.map(& &1.output)

    ScriptedRetrieval.provider(script, opts)
  end

  defp tool_name_from_output(%CallResult{request: request}), do: request.tool_name
  defp tool_name_from_output(%{request: %{tool_name: tool_name}}), do: tool_name
  defp tool_name_from_output(%{tool_name: tool_name}), do: tool_name
  defp tool_name_from_output(_output), do: nil
end
