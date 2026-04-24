defmodule RunicAI.Testing.ScriptedRetrieval do
  @moduledoc """
  Deterministic retrieval provider helper for tests and replay.
  """

  alias RunicAI.Error
  alias RunicAI.Retrieval.Result
  alias RunicAI.Testing.ScriptedSequence

  @spec provider(list(), keyword()) :: (term(), keyword() -> {:ok, term()} | {:error, term()})
  def provider(script, opts \\ []) when is_list(script) and is_list(opts) do
    {:ok, pid} =
      ScriptedSequence.start_link(script, repeat_last: Keyword.get(opts, :repeat_last, false))

    fn query, provider_opts ->
      case ScriptedSequence.next(pid) do
        {:ok, step} ->
          resolve_step(step, query, provider_opts)

        :empty ->
          {:error, Error.unexpected("scripted retrieval sequence exhausted", source: __MODULE__)}
      end
    end
  end

  defp resolve_step(step, query, provider_opts) when is_function(step, 2),
    do: step.(query, provider_opts)

  defp resolve_step({:ok, value}, _query, _provider_opts), do: {:ok, value}
  defp resolve_step({:error, reason}, _query, _provider_opts), do: {:error, reason}
  defp resolve_step(%Result{} = result, _query, _provider_opts), do: {:ok, result}

  defp resolve_step(documents, _query, _provider_opts) when is_list(documents),
    do: {:ok, documents}

  defp resolve_step(other, _query, _provider_opts), do: {:ok, other}
end
