defmodule RunicAI.LLM.ReqLLMClient do
  @moduledoc """
  Default LLM client backed by ReqLLM.
  """

  @behaviour RunicAI.LLM

  alias RunicAI.Error
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.Retry
  alias RunicAI.Prompt

  @impl true
  def generate_text(model, prompt, opts \\ []) do
    model
    |> ReqLLM.generate_text(normalize_prompt(prompt), opts)
    |> case do
      {:ok, response} ->
        Result.from_req_llm_response(response,
          requested_model: model,
          tool_choice: Keyword.get(opts, :tool_choice)
        )

      {:error, reason} ->
        details = provider_error_details(reason) |> Map.put(:requested_model, model)

        {:error,
         Error.provider("ReqLLM generate_text failed",
           source: __MODULE__,
           details: details,
           retryable?: Retry.retryable_provider_error?(reason)
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
        details = provider_error_details(reason)

        {:error,
         Error.provider("ReqLLM stream_text failed",
           source: __MODULE__,
           details: details,
           retryable?: Retry.retryable_provider_error?(reason)
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
        details = provider_error_details(reason)

        {:error,
         Error.provider("ReqLLM generate_object failed",
           source: __MODULE__,
           details: details,
           retryable?: Retry.retryable_provider_error?(reason)
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :provider, source: __MODULE__)}
  end

  defp normalize_prompt(%Prompt{} = prompt), do: Prompt.to_req_llm(prompt)
  defp normalize_prompt(prompt), do: prompt

  defp provider_error_details(reason) do
    %{
      reason: reason,
      reason_message: reason_message(reason)
    }
    |> maybe_put(:status, field(reason, :status))
    |> maybe_put(:retry_after_ms, Retry.retry_after_ms(reason))
    |> maybe_put(:response_body_preview, response_body_preview(field(reason, :response_body)))
  end

  defp reason_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp reason_message(reason) when is_binary(reason), do: reason
  defp reason_message(reason), do: inspect(reason, limit: 20, printable_limit: 512)

  defp response_body_preview(nil), do: nil
  defp response_body_preview(body) when is_binary(body), do: truncate(body)

  defp response_body_preview(body),
    do: body |> inspect(limit: 20, printable_limit: 1_000) |> truncate()

  defp truncate(value) when byte_size(value) > 1_000, do: binary_part(value, 0, 1_000) <> "..."
  defp truncate(value), do: value

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, to_string(key))

  defp field(_value, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
