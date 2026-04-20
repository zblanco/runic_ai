defmodule RunicAI.LLM.ReqLLMClient do
  @moduledoc """
  Default LLM client backed by ReqLLM.
  """

  @behaviour RunicAI.LLM

  alias RunicAI.Error
  alias RunicAI.LLM.Result
  alias RunicAI.Prompt

  @impl true
  def generate_text(model, prompt, opts \\ []) do
    model
    |> ReqLLM.generate_text(normalize_prompt(prompt), opts)
    |> case do
      {:ok, response} ->
        Result.from_req_llm_response(response)

      {:error, reason} ->
        {:error,
         Error.provider("ReqLLM generate_text failed",
           source: __MODULE__,
           details: %{reason: reason}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :provider, source: __MODULE__)}
  end

  @impl true
  def stream_text(model, prompt, opts \\ []) do
    model
    |> ReqLLM.stream_text(normalize_prompt(prompt), opts)
    |> case do
      {:ok, stream_response} ->
        {:ok, stream_response}

      {:error, reason} ->
        {:error,
         Error.provider("ReqLLM stream_text failed",
           source: __MODULE__,
           details: %{reason: reason}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :provider, source: __MODULE__)}
  end

  @impl true
  def generate_object(model, prompt, schema, opts \\ []) do
    model
    |> ReqLLM.generate_object(normalize_prompt(prompt), schema, opts)
    |> case do
      {:ok, %ReqLLM.Response{object: object}} when is_map(object) ->
        {:ok, object}

      {:ok, object} when is_map(object) ->
        {:ok, object}

      {:ok, other} ->
        {:error,
         Error.provider("ReqLLM generate_object returned an unexpected payload",
           source: __MODULE__,
           details: %{payload: other}
         )}

      {:error, reason} ->
        {:error,
         Error.provider("ReqLLM generate_object failed",
           source: __MODULE__,
           details: %{reason: reason}
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :provider, source: __MODULE__)}
  end

  defp normalize_prompt(%Prompt{} = prompt), do: Prompt.to_req_llm(prompt)
  defp normalize_prompt(prompt), do: prompt
end
