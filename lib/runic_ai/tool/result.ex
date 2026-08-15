defmodule RunicAI.Tool.Result do
  @moduledoc "Owned result of one tool call."

  alias RunicAI.Error
  alias RunicAI.JSONValue

  @wire_id "runic.ai/tool-result/v1"
  @enforce_keys [:call_id, :tool, :status]
  defstruct call_id: nil, tool: nil, status: nil, output: nil, error: nil, metadata: %{}

  @type t :: %__MODULE__{}

  def ok(call_id, tool, output, metadata \\ %{}) do
    with {:ok, output} <- JSONValue.normalize(output),
         {:ok, metadata} <- JSONValue.normalize(metadata) do
      {:ok,
       %__MODULE__{call_id: call_id, tool: tool, status: :ok, output: output, metadata: metadata}}
    end
  end

  def error(call_id, tool, %Error{} = error, metadata \\ %{}) do
    with {:ok, metadata} <- JSONValue.normalize(metadata) do
      {:ok,
       %__MODULE__{call_id: call_id, tool: tool, status: :error, error: error, metadata: metadata}}
    end
  end

  def encode(%__MODULE__{} = result) do
    %{
      "$contract" => @wire_id,
      "call_id" => result.call_id,
      "tool" => result.tool,
      "status" => Atom.to_string(result.status),
      "metadata" => result.metadata
    }
    |> put_if("output", result.output)
    |> put_if("error", if(result.error, do: Error.encode(result.error)))
  end

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, result} <- decode_status(map) do
      {:ok, result}
    else
      {:ok, _other} -> {:error, [%{path: [], message: "tool result must be an object"}]}
      {:error, issues} -> {:error, issues}
    end
  end

  defp decode_status(%{"status" => "ok"} = map),
    do: ok(map["call_id"], map["tool"], map["output"], map["metadata"] || %{})

  defp decode_status(%{"status" => "error"} = map) do
    with {:ok, error} <- Error.decode(map["error"]),
         do: error(map["call_id"], map["tool"], error, map["metadata"] || %{})
  end

  defp decode_status(_map), do: {:error, [%{path: ["status"], message: "must be ok or error"}]}
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
