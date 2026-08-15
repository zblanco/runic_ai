defmodule RunicAI.Tool.Call do
  @moduledoc "One serializable tool call with explicit dependency identities."

  alias RunicAI.JSONValue

  @wire_id "runic.ai/tool-call/v1"
  @enforce_keys [:id, :tool, :arguments]
  defstruct id: nil, tool: nil, arguments: %{}, dependencies: [], metadata: %{}

  @type t :: %__MODULE__{}

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- is_binary(Map.get(map, "id")) and Map.get(map, "id") != "",
         true <- is_binary(Map.get(map, "tool")) and Map.get(map, "tool") != "",
         arguments when is_map(arguments) <- Map.get(map, "arguments", %{}),
         dependencies when is_list(dependencies) <- Map.get(map, "dependencies", []),
         true <- Enum.all?(dependencies, &is_binary/1),
         metadata when is_map(metadata) <- Map.get(map, "metadata", %{}) do
      {:ok,
       %__MODULE__{
         id: map["id"],
         tool: map["tool"],
         arguments: arguments,
         dependencies: dependencies,
         metadata: metadata
       }}
    else
      _other ->
        {:error,
         [
           %{
             path: [],
             message: "tool call has invalid id, tool, arguments, dependencies, or metadata"
           }
         ]}
    end
  end

  def new!(input) do
    case new(input) do
      {:ok, call} -> call
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def encode(%__MODULE__{} = call),
    do: %{
      "$contract" => @wire_id,
      "id" => call.id,
      "tool" => call.tool,
      "arguments" => call.arguments,
      "dependencies" => call.dependencies,
      "metadata" => call.metadata
    }

  def decode(input), do: new(input)
end
