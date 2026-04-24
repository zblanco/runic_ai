defmodule RunicAI.Tool.Adapters.ExternalWorker do
  @moduledoc """
  Adapter boundary for application-owned external workers.
  """

  @behaviour RunicAI.Tool.ExecutionAdapter

  alias RunicAI.Error

  @impl true
  def execute(arguments, opts) when is_map(arguments) and is_list(opts) do
    case Keyword.get(opts, :dispatch) || Keyword.get(opts, :callback) do
      callback when is_function(callback, 1) ->
        normalize(callback.(arguments))

      callback when is_function(callback, 2) ->
        normalize(callback.(arguments, opts))

      {module, function} when is_atom(module) and is_atom(function) ->
        normalize(apply(module, function, [arguments]))

      {module, function, extra_args}
      when is_atom(module) and is_atom(function) and is_list(extra_args) ->
        normalize(apply(module, function, [arguments | extra_args]))

      other ->
        {:error,
         Error.validation("external worker adapter requires a callback or dispatch MFA",
           source: __MODULE__,
           details: %{dispatch: other}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp normalize({:ok, _value} = ok), do: ok
  defp normalize({:error, %Error{}} = error), do: error
  defp normalize({:error, reason}), do: {:error, Error.from_reason(reason, source: __MODULE__)}
  defp normalize(other), do: {:ok, other}
end
