defmodule RunicAI.LLM.Result do
  @moduledoc "Owned result for text, structured, and tool-requesting generation."

  alias RunicAI.JSONValue
  alias RunicAI.LLM.Evidence
  alias RunicAI.LLM.Usage
  alias RunicAI.Message

  @wire_id "runic.ai/llm-result/v1"
  @enforce_keys [:message, :usage, :evidence]
  defstruct message: nil, object: nil, tool_requests: [], usage: nil, evidence: nil, warnings: []

  @type t :: %__MODULE__{}

  def new(message, opts \\ []) do
    with {:ok, message} <- Message.normalize(message),
         true <- message.role == :assistant,
         {:ok, object} <- normalize_optional_json(Keyword.get(opts, :object)),
         {:ok, tool_requests} when is_list(tool_requests) <-
           JSONValue.normalize(Keyword.get(opts, :tool_requests, [])),
         {:ok, usage} <- Usage.new(Keyword.get(opts, :usage, %{})),
         {:ok, evidence} <- Evidence.new(Keyword.get(opts, :evidence, %{})),
         warnings when is_list(warnings) <- Keyword.get(opts, :warnings, []),
         true <- Enum.all?(warnings, &is_binary/1) do
      {:ok,
       %__MODULE__{
         message: message,
         object: object,
         tool_requests: tool_requests,
         usage: usage,
         evidence: evidence,
         warnings: warnings
       }}
    else
      false -> error([], "result requires an assistant message and text warnings")
      {:ok, _other} -> error(["tool_requests"], "must be a list")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(message, opts \\ []) do
    case new(message, opts) do
      {:ok, result} -> result
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def encode(%__MODULE__{} = result) do
    %{
      "$contract" => @wire_id,
      "message" => Message.encode(result.message),
      "tool_requests" => result.tool_requests,
      "usage" => Usage.encode(result.usage),
      "evidence" => Evidence.encode(result.evidence),
      "warnings" => result.warnings
    }
    |> put_if("object", result.object, not is_nil(result.object))
  end

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract", @wire_id) == @wire_id,
         {:ok, message} <- Message.decode(Map.get(map, "message")) do
      new(message,
        object: Map.get(map, "object"),
        tool_requests: Map.get(map, "tool_requests", []),
        usage: Map.get(map, "usage", %{}),
        evidence: Map.get(map, "evidence", %{}),
        warnings: Map.get(map, "warnings", [])
      )
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "result must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def text(%__MODULE__{message: message}), do: Message.text(message)
  defp normalize_optional_json(nil), do: {:ok, nil}
  defp normalize_optional_json(value), do: JSONValue.normalize(value)
  defp put_if(map, _key, _value, false), do: map
  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
