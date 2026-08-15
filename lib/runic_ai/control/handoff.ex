defmodule RunicAI.Control.Handoff do
  @moduledoc "Portable context envelope for handing work between agent boundaries."

  alias RunicAI.JSONValue

  @wire_id "runic.ai/handoff/v1"
  @enforce_keys [:id, :source, :target, :objective, :payload]
  defstruct id: nil,
            source: nil,
            target: nil,
            objective: nil,
            payload: nil,
            context: %{},
            provenance: %{}

  @type t :: %__MODULE__{}

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Enum.all?(~w(id source target objective), &non_empty?(map[&1])),
         {:ok, payload} <- JSONValue.normalize(map["payload"]),
         context when is_map(context) <- Map.get(map, "context", %{}),
         provenance when is_map(provenance) <- Map.get(map, "provenance", %{}) do
      {:ok,
       %__MODULE__{
         id: map["id"],
         source: map["source"],
         target: map["target"],
         objective: map["objective"],
         payload: payload,
         context: context,
         provenance: provenance
       }}
    else
      false -> error([], "handoff identifiers and objective must be non-empty strings")
      {:ok, _other} -> error([], "handoff must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input), do: unwrap!(new(input))

  def encode(%__MODULE__{} = handoff),
    do: %{
      "$contract" => @wire_id,
      "id" => handoff.id,
      "source" => handoff.source,
      "target" => handoff.target,
      "objective" => handoff.objective,
      "payload" => handoff.payload,
      "context" => handoff.context,
      "provenance" => handoff.provenance
    }

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- map["$contract"] == @wire_id do
      new(map)
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "handoff must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  defp non_empty?(value), do: is_binary(value) and value != ""
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, issues}), do: raise(ArgumentError, inspect(issues))
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
