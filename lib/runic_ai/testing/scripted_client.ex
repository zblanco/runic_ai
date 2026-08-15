defmodule RunicAI.Testing.ScriptedClient do
  @moduledoc "Stateless scripted LLM client for contract and workflow tests."

  @behaviour RunicAI.LLM.Client

  alias RunicAI.Error
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result

  @impl true
  def generate(%Request{} = request, opts) do
    case Keyword.fetch(opts, :script) do
      {:ok, script} when is_function(script, 1) ->
        normalize(script.(request))

      {:ok, outcome} ->
        normalize(outcome)

      :error ->
        {:error,
         Error.validation("scripted client requires :script", source: inspect(__MODULE__))}
    end
  rescue
    exception ->
      {:error,
       Error.from_exception(exception, source: inspect(__MODULE__), code: "script_exception")}
  end

  defp normalize(%Result{} = result), do: {:ok, result}
  defp normalize({tag, %Result{} = result}) when tag == :ok, do: {:ok, result}
  defp normalize({tag, %Error{} = error}) when tag in [:retry, :error], do: {tag, error}

  defp normalize(other) do
    {:error,
     Error.new!(:internal, "invalid_client_result", "script returned an invalid LLM outcome",
       source: inspect(__MODULE__),
       details: %{"shape" => inspect_shape(other)}
     )}
  end

  defp inspect_shape(value) when is_tuple(value), do: "tuple/#{tuple_size(value)}"
  defp inspect_shape(%{__struct__: module}), do: "struct:" <> inspect(module)
  defp inspect_shape(value) when is_map(value), do: "map"
  defp inspect_shape(value) when is_list(value), do: "list"
  defp inspect_shape(_value), do: "scalar"
end
