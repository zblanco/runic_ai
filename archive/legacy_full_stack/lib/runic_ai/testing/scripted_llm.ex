defmodule RunicAI.Testing.ScriptedLLM do
  @moduledoc """
  Deterministic multi-step LLM client helper for tests and replay.
  """

  alias RunicAI.Error
  alias RunicAI.LLM.Result
  alias RunicAI.Message
  alias RunicAI.Testing.ScriptedSequence

  @spec client(list(), keyword()) :: (term(), term(), keyword() ->
                                        {:ok, term()} | {:error, term()})
  def client(script, opts \\ []) when is_list(script) and is_list(opts) do
    {:ok, pid} =
      ScriptedSequence.start_link(script, repeat_last: Keyword.get(opts, :repeat_last, false))

    fn model, prompt, llm_opts ->
      case ScriptedSequence.next(pid) do
        {:ok, step} ->
          resolve_step(step, model, prompt, llm_opts)

        :empty ->
          {:error, Error.unexpected("scripted LLM sequence exhausted", source: __MODULE__)}
      end
    end
  end

  @spec response(String.t()) :: Result.t()
  def response(text) when is_binary(text) do
    Result.new!(
      Message.new!(:assistant, text),
      finish_reason: :stop,
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    )
  end

  defp resolve_step(step, model, prompt, llm_opts) when is_function(step, 3) do
    step.(model, prompt, llm_opts)
  end

  defp resolve_step({:ok, value}, _model, _prompt, _llm_opts), do: {:ok, value}
  defp resolve_step({:error, reason}, _model, _prompt, _llm_opts), do: {:error, reason}
  defp resolve_step(%Result{} = result, _model, _prompt, _llm_opts), do: {:ok, result}

  defp resolve_step(%ReqLLM.Response{} = response, _model, _prompt, _llm_opts),
    do: {:ok, response}

  defp resolve_step(text, _model, _prompt, _llm_opts) when is_binary(text),
    do: {:ok, response(text)}

  defp resolve_step(other, _model, _prompt, _llm_opts), do: {:ok, other}
end
