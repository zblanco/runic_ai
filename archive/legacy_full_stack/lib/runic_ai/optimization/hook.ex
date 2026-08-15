defmodule RunicAI.Optimization.Hook do
  @moduledoc """
  Behaviour for observational optimization hooks.

  Hooks consume trajectories, evaluation runs, or comparison artifacts and
  return suggestions. They do not mutate live runtime sessions.
  """

  alias RunicAI.Error
  alias RunicAI.Optimization.Suggestion

  @callback suggest(term(), keyword()) :: {:ok, [Suggestion.t()]} | {:error, Error.t()}

  @spec run(module() | function(), term(), keyword()) ::
          {:ok, [Suggestion.t()]} | {:error, Error.t()}
  def run(hook, artifact, opts \\ [])

  def run(hook, artifact, opts) when is_atom(hook) and is_list(opts) do
    if Code.ensure_loaded?(hook) and function_exported?(hook, :suggest, 2) do
      normalize(hook.suggest(artifact, opts))
    else
      {:error,
       Error.validation("optimization hook module must export suggest/2",
         source: __MODULE__,
         details: %{hook: hook}
       )}
    end
  end

  def run(hook, artifact, opts) when is_function(hook, 2) and is_list(opts) do
    normalize(hook.(artifact, opts))
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def run(hook, _artifact, _opts) do
    {:error,
     Error.validation("optimization hook must be a module or function",
       source: __MODULE__,
       details: %{hook: hook}
     )}
  end

  defp normalize({:ok, suggestions}) when is_list(suggestions) do
    {:ok, suggestions}
  end

  defp normalize(%Suggestion{} = suggestion), do: {:ok, [suggestion]}
  defp normalize([%Suggestion{} | _rest] = suggestions), do: {:ok, suggestions}
  defp normalize({:error, %Error{}} = error), do: error
  defp normalize({:error, reason}), do: {:error, Error.from_reason(reason, source: __MODULE__)}

  defp normalize(other) do
    {:error,
     Error.validation("optimization hook returned an unsupported result",
       source: __MODULE__,
       details: %{result: other}
     )}
  end
end
