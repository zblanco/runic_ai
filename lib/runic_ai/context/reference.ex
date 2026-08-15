defmodule RunicAI.Context.Reference do
  @moduledoc "A portable retrieved-context value with provenance and sensitivity labels."

  alias RunicAI.JSONValue

  @wire_id "runic.ai/context-reference/v1"
  @enforce_keys [:id, :content]
  defstruct id: nil, content: nil, source: %{}, sensitivity: [], metadata: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          content: JSONValue.t(),
          source: map(),
          sensitivity: [String.t()],
          metadata: map()
        }

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         id when is_binary(id) and id != "" <- map["id"],
         true <- Map.has_key?(map, "content"),
         source when is_map(source) <- Map.get(map, "source", %{}),
         sensitivity when is_list(sensitivity) <- Map.get(map, "sensitivity", []),
         true <- Enum.all?(sensitivity, &is_binary/1),
         metadata when is_map(metadata) <- Map.get(map, "metadata", %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         content: map["content"],
         source: source,
         sensitivity: sensitivity,
         metadata: metadata
       }}
    else
      {:ok, _other} -> issue([], "context reference must be an object")
      _other -> issue([], "context reference is invalid")
    end
  end

  def new!(input) do
    case new(input) do
      {:ok, reference} -> reference
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def encode(%__MODULE__{} = reference),
    do: %{
      "$contract" => @wire_id,
      "id" => reference.id,
      "content" => reference.content,
      "source" => reference.source,
      "sensitivity" => reference.sensitivity,
      "metadata" => reference.metadata
    }

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- map["$contract"] == @wire_id do
      new(map)
    else
      false -> issue(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> issue([], "context reference must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  defp issue(path, message), do: {:error, [%{path: path, message: message}]}
end
