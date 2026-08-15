defmodule RunicAI.Steps.InterpretToolRequests do
  @moduledoc """
  Normalize and validate tool requests from interpreted model turns.
  """

  require Runic

  alias RunicAI.Agent.TurnResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Selection

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :interpret_tool_requests)

    Runic.step(
      fn %TurnResult{} = turn_result, %Selection{} = selection ->
        normalize!(turn_result, selection)
      end,
      name: name
    )
  end

  @spec normalize(TurnResult.t(), Selection.t()) ::
          {:ok, TurnResult.t()} | {:error, RunicAI.Error.t()}
  def normalize(%TurnResult{kind: kind} = turn_result, %Selection{} = selection)
      when kind != :tool_requests do
    with {:ok, turn_result} <- TurnResult.validate(turn_result),
         {:ok, _selection} <- Selection.validate(selection) do
      {:ok, turn_result}
    end
  end

  def normalize(%TurnResult{kind: :tool_requests} = turn_result, %Selection{} = selection) do
    with {:ok, turn_result} <- TurnResult.validate(turn_result),
         {:ok, selection} <- Selection.validate(selection),
         {:ok, calls} <- normalize_calls(turn_result, selection) do
      TurnResult.tool_requests(turn_result.message,
        details: Map.put(turn_result.details, :tool_calls, calls),
        raw: turn_result.raw,
        metadata: turn_result.metadata
      )
    end
  end

  @spec normalize!(TurnResult.t(), Selection.t()) :: TurnResult.t()
  def normalize!(%TurnResult{} = turn_result, %Selection{} = selection) do
    case normalize(turn_result, selection) do
      {:ok, normalized_turn_result} ->
        normalized_turn_result

      {:error, error} ->
        TurnResult.error!(error, details: %{phase: :interpret_tool_requests})
    end
  end

  defp normalize_calls(%TurnResult{details: details}, selection) do
    details
    |> Map.get(:tool_calls, [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool_call, index}, {:ok, acc} ->
      case normalize_call(tool_call, index, selection) do
        {:ok, normalized_call} -> {:cont, {:ok, [normalized_call | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp normalize_call(%CallRequest{} = call_request, index, selection) do
    with {:ok, call_request} <- CallRequest.validate(call_request),
         {:ok, definition} <- Selection.fetch_visible(selection, call_request.tool_name),
         {:ok, arguments} <- Definition.validate_arguments(definition, call_request.arguments) do
      CallRequest.new(call_request.id, call_request.tool_name, arguments,
        request_index: index,
        raw: call_request.raw,
        metadata: call_request.metadata
      )
    end
  end

  defp normalize_call(tool_call, index, selection) do
    with {:ok, call_request} <- CallRequest.from_provider(tool_call, request_index: index),
         {:ok, definition} <- Selection.fetch_visible(selection, call_request.tool_name),
         {:ok, arguments} <- Definition.validate_arguments(definition, call_request.arguments) do
      CallRequest.new(call_request.id, call_request.tool_name, arguments,
        request_index: index,
        raw: call_request.raw,
        metadata: call_request.metadata
      )
    end
  end
end
