defmodule RunicAI.LLM.GenerationEvidence do
  @moduledoc """
  Bounded generation evidence retained by conversational agent sessions.

  This projection intentionally keeps provider completion metadata separate
  from the conversation transcript so operator diagnostics do not depend on
  parsing assistant text.
  """

  alias RunicAI.LLM.Result
  alias RunicAI.Error

  @default_limit 20

  @spec append(map(), Result.t(), keyword()) :: map()
  def append(control, %Result{} = result, opts \\ []) when is_map(control) do
    append_evidence(control, Result.evidence(result), opts)
  end

  @spec append_error(map(), Error.t(), keyword()) :: map()
  def append_error(control, %Error{} = error, opts \\ []) when is_map(control) do
    evidence =
      %{
        error_kind: error.kind,
        error_message: error.message,
        error_source: error.source,
        retryable?: error.retryable?,
        requested_model: field(error.details, :requested_model),
        status: field(error.details, :status),
        reason_type: field(error.details, :reason_type),
        reason_message: field(error.details, :reason_message),
        retry_after_ms: field(error.details, :retry_after_ms),
        response_body_preview: field(error.details, :response_body_preview),
        fallback?: field(error.details, :fallback?),
        primary_model: field(error.details, :primary_model),
        fallback_model: field(error.details, :fallback_model)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    append_evidence(control, evidence, opts)
  end

  defp append_evidence(control, evidence, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    history = List.wrap(Map.get(control, :generation_evidence, []))

    Map.put(control, :generation_evidence, Enum.take(history ++ [evidence], -limit))
  end

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
