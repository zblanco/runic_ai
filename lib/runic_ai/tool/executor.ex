defmodule RunicAI.Tool.Executor do
  @moduledoc "Validates, authorizes, invokes, and validates one host-bound tool call."

  alias RunicAI.Contract.Value
  alias RunicAI.Error
  alias RunicAI.Tool.Binding
  alias RunicAI.Tool.Call
  alias RunicAI.Tool.Result

  @spec execute(Call.t(), Binding.t() | nil, map()) :: {:ok, Result.t()} | {:error, Error.t()}
  def execute(%Call{} = call, nil, _context) do
    {:error,
     Error.new!(
       :unavailable,
       "missing_tool_binding",
       "no runtime binding is available for the tool",
       source: inspect(__MODULE__),
       details: %{"tool" => call.tool}
     )}
  end

  def execute(%Call{} = call, %Binding{spec: spec} = binding, context) when is_map(context) do
    with :ok <- require_matching_spec(call, spec.name),
         :ok <- validate_arguments(spec.input, call.arguments),
         :ok <- authorize(binding, call, context),
         {:ok, output} <- invoke(binding.executor, call.arguments, context),
         :ok <- validate_output(spec.output, output),
         {:ok, result} <- Result.ok(call.id, call.tool, output) do
      {:ok, result}
    end
  rescue
    exception ->
      {:error,
       Error.from_exception(exception,
         code: "tool_executor_exception",
         source: inspect(__MODULE__),
         details: %{"tool" => call.tool}
       )}
  end

  defp require_matching_spec(%Call{tool: name}, name), do: :ok

  defp require_matching_spec(call, _name),
    do:
      {:error,
       Error.validation("tool call does not match its binding",
         code: "tool_binding_mismatch",
         details: %{"tool" => call.tool},
         source: inspect(__MODULE__)
       )}

  defp validate_arguments(contract, arguments) do
    case Value.validate_value(contract, arguments) do
      :ok ->
        :ok

      {:error, issues} ->
        {:error,
         Error.validation("tool arguments failed validation",
           code: "invalid_tool_arguments",
           details: %{"issues" => issues},
           source: inspect(__MODULE__)
         )}
    end
  end

  defp validate_output(contract, output) do
    case Value.validate_value(contract, output) do
      :ok ->
        :ok

      {:error, issues} ->
        {:error,
         Error.new!(:validation, "invalid_tool_output", "tool output failed validation",
           details: %{"issues" => issues},
           source: inspect(__MODULE__)
         )}
    end
  end

  defp authorize(%Binding{authorize: nil}, _call, _context), do: :ok

  defp authorize(%Binding{authorize: authorize}, call, context) do
    case authorize.(call, context) do
      :ok ->
        :ok

      true ->
        :ok

      {:error, %Error{} = error} ->
        {:error, error}

      _denied ->
        {:error,
         Error.new!(:denied, "tool_binding_denied", "tool execution was denied by the host",
           details: %{"tool" => call.tool},
           source: inspect(__MODULE__)
         )}
    end
  end

  defp invoke(fun, arguments, context) when is_function(fun, 2),
    do: normalize_outcome(fun.(arguments, context))

  defp invoke({module, function, extra}, arguments, context),
    do: normalize_outcome(apply(module, function, [arguments, context | extra]))

  defp invoke(module, arguments, context) when is_atom(module),
    do: normalize_outcome(module.execute(arguments, context))

  defp normalize_outcome({:ok, output}), do: {:ok, output}
  defp normalize_outcome({:error, %Error{} = error}), do: {:error, error}

  defp normalize_outcome({:error, _reason}),
    do:
      {:error,
       Error.new!(:internal, "tool_execution_failed", "tool binding reported a failure",
         source: inspect(__MODULE__)
       )}

  defp normalize_outcome(_other),
    do:
      {:error,
       Error.new!(
         :internal,
         "invalid_tool_binding_result",
         "tool binding returned an invalid outcome", source: inspect(__MODULE__))}
end
