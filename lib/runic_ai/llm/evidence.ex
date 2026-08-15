defmodule RunicAI.LLM.Evidence do
  @moduledoc "Safe provenance retained for an LLM generation result."

  alias RunicAI.JSONValue

  @wire_id "runic.ai/llm-evidence/v1"
  defstruct provider: nil, model: nil, request_id: nil, duration_ms: nil, finish_reason: nil

  @type t :: %__MODULE__{}

  def new(input \\ %{}) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input) do
      evidence = %__MODULE__{
        provider: Map.get(map, "provider"),
        model: Map.get(map, "model"),
        request_id: Map.get(map, "request_id"),
        duration_ms: Map.get(map, "duration_ms"),
        finish_reason: Map.get(map, "finish_reason")
      }

      validate(evidence)
    else
      {:ok, _other} -> error([], "evidence must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input \\ %{}) do
    case new(input) do
      {:ok, evidence} -> evidence
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def validate(%__MODULE__{} = evidence) do
    values = [evidence.provider, evidence.model, evidence.request_id, evidence.finish_reason]

    cond do
      not Enum.all?(values, &(is_nil(&1) or is_binary(&1))) ->
        error([], "provider, model, request ID, and finish reason must be strings or null")

      not is_nil(evidence.duration_ms) and
          not (is_integer(evidence.duration_ms) and evidence.duration_ms >= 0) ->
        error(["duration_ms"], "must be a non-negative integer or null")

      true ->
        {:ok, evidence}
    end
  end

  def encode(%__MODULE__{} = evidence) do
    %{"$contract" => @wire_id}
    |> put_if("provider", evidence.provider)
    |> put_if("model", evidence.model)
    |> put_if("request_id", evidence.request_id)
    |> put_if("duration_ms", evidence.duration_ms)
    |> put_if("finish_reason", evidence.finish_reason)
  end

  def decode(input), do: new(input)
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
