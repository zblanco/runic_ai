defmodule RunicAI.Steps.InterpretTurn do
  @moduledoc """
  Interpret a generated turn outcome into a typed `RunicAI.Agent.TurnResult`.
  """

  require Runic

  alias RunicAI.Agent.TurnResult
  alias RunicAI.Error
  alias RunicAI.LLM.Result

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :interpret_turn)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        interpret!(input, options)
      end,
      name: name
    )
  end

  @spec interpret(
          Result.t() | {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()},
          keyword()
        ) ::
          {:ok, TurnResult.t()} | {:error, Error.t()}
  def interpret({:ok, %Result{} = result}, opts), do: interpret(result, opts)

  def interpret({:retry, %Error{} = error}, _opts) do
    TurnResult.error(error, details: %{retryable: true, phase: :generate_turn})
  end

  def interpret({:error, %Error{} = error}, _opts) do
    TurnResult.error(error, details: %{phase: :generate_turn})
  end

  def interpret(%Result{} = result, opts) do
    case classify_result(result, opts) do
      {:custom, %TurnResult{} = turn_result} ->
        TurnResult.validate(turn_result)

      {:tool_requests, details} ->
        TurnResult.tool_requests(result, details: details, raw: result)

      {:final, details} ->
        TurnResult.final(result, details: details, raw: result)

      {:reply, details} ->
        TurnResult.reply(result, details: details, raw: result)
    end
  end

  def interpret(other, _opts) do
    {:error,
     Error.validation("unsupported interpret_turn input: #{inspect(other)}", source: __MODULE__)}
  end

  @spec interpret!(
          Result.t() | {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()},
          keyword()
        ) ::
          TurnResult.t()
  def interpret!(input, opts \\ []) do
    case interpret(input, opts) do
      {:ok, turn_result} -> turn_result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp classify_result(%Result{} = result, opts) do
    case extract_tool_requests(result) do
      %{} = details ->
        {:tool_requests, details}

      false ->
        case run_custom_final_when(result, Keyword.get(opts, :final_when)) do
          {:custom, %TurnResult{} = turn_result} ->
            {:custom, turn_result}

          {:final, details} ->
            {:final, details}

          false ->
            if matches_final_pattern?(Result.text(result), Keyword.get(opts, :final_pattern)) do
              {:final, %{source: :pattern}}
            else
              {:reply, %{}}
            end
        end
    end
  end

  defp extract_tool_requests(%Result{} = result) do
    tool_requests_from_response(result) || tool_requests_from_message(result) || false
  end

  defp tool_requests_from_response(%Result{raw: %ReqLLM.Response{} = response}) do
    classified = ReqLLM.Response.classify(response)
    tool_calls = Map.get(classified, :tool_calls) || Map.get(classified, "tool_calls") || []
    type = Map.get(classified, :type) || Map.get(classified, "type")

    if type == :tool_calls and tool_calls != [] do
      %{
        tool_calls: Enum.map(tool_calls, &ReqLLM.ToolCall.from_map/1),
        finish_reason:
          Map.get(classified, :finish_reason) || Map.get(classified, "finish_reason"),
        source: :provider
      }
    end
  end

  defp tool_requests_from_response(_result), do: nil

  defp tool_requests_from_message(%Result{message: %{metadata: metadata}})
       when is_map(metadata) do
    tool_calls = Map.get(metadata, :tool_calls) || Map.get(metadata, "tool_calls") || []

    if tool_calls != [] do
      %{
        tool_calls: Enum.map(tool_calls, &ReqLLM.ToolCall.from_map/1),
        source: :message_metadata
      }
    end
  end

  defp tool_requests_from_message(_result), do: nil

  defp run_custom_final_when(_result, nil), do: false

  defp run_custom_final_when(%Result{} = result, fun) when is_function(fun, 1) do
    case fun.(result) do
      %TurnResult{} = turn_result -> {:custom, turn_result}
      {:final, details} when is_map(details) -> {:final, details}
      true -> {:final, %{source: :callback}}
      false -> false
      nil -> false
      other -> raise ArgumentError, "unsupported final_when result: #{inspect(other)}"
    end
  end

  defp matches_final_pattern?(_text, nil), do: false

  defp matches_final_pattern?(text, pattern) when is_binary(pattern),
    do: String.contains?(text, pattern)

  defp matches_final_pattern?(text, %Regex{} = pattern), do: String.match?(text, pattern)

  defp matches_final_pattern?(text, patterns) when is_list(patterns),
    do: Enum.any?(patterns, &matches_final_pattern?(text, &1))
end
