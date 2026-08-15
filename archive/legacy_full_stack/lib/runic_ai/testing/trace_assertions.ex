defmodule RunicAI.Testing.TraceAssertions do
  @moduledoc """
  Pure helpers for querying trajectories in tests.
  """

  alias RunicAI.Trace.Trajectory

  @spec kinds(Trajectory.t()) :: [atom()]
  def kinds(%Trajectory{} = trajectory), do: Enum.map(trajectory.events, & &1.kind)

  @spec count(Trajectory.t(), atom() | String.t()) :: non_neg_integer()
  def count(%Trajectory{} = trajectory, kind), do: Trajectory.count_events(trajectory, kind)

  @spec has_event?(Trajectory.t(), atom() | String.t(), (term() -> boolean()) | nil) :: boolean()
  def has_event?(%Trajectory{} = trajectory, kind, predicate \\ nil) do
    trajectory
    |> Trajectory.events_of_kind(kind)
    |> case do
      [] -> false
      events when is_function(predicate, 1) -> Enum.any?(events, predicate)
      _events -> true
    end
  end

  @spec tool_called?(Trajectory.t(), String.t() | nil) :: boolean()
  def tool_called?(%Trajectory{} = trajectory, tool_name \\ nil) do
    has_event?(trajectory, :tool_call, fn event ->
      case event.output do
        %{tool_name: ^tool_name} when is_binary(tool_name) -> true
        %{request: %{tool_name: ^tool_name}} when is_binary(tool_name) -> true
        _ when is_nil(tool_name) -> true
        _ -> false
      end
    end)
  end

  @spec review_requested?(Trajectory.t()) :: boolean()
  def review_requested?(%Trajectory{} = trajectory), do: has_event?(trajectory, :review_requested)

  @spec wait_registered?(Trajectory.t()) :: boolean()
  def wait_registered?(%Trajectory{} = trajectory), do: has_event?(trajectory, :wait_registered)

  @spec reply_contains?(Trajectory.t(), String.t()) :: boolean()
  def reply_contains?(%Trajectory{} = trajectory, text) when is_binary(text) do
    trajectory.events
    |> Enum.any?(fn event ->
      case event.output do
        %{message: %{content: content}} when is_binary(content) ->
          String.contains?(content, text)

        %{value: %{message: %{content: content}}} when is_binary(content) ->
          String.contains?(content, text)

        %{reply_text: content} when is_binary(content) ->
          String.contains?(content, text)

        _ ->
          false
      end
    end)
  end
end
