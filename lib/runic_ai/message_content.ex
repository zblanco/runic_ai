defmodule RunicAI.MessageContent do
  @moduledoc "A conservative provider-neutral message content part."

  alias RunicAI.JSONValue

  @types [:text, :image_ref, :document_ref, :tool_call, :tool_result]
  @wire_id "runic.ai/message-content/v1"

  @enforce_keys [:type]
  defstruct type: nil, text: nil, ref: nil, media_type: nil, name: nil, call_id: nil, value: nil

  @type t :: %__MODULE__{}

  def text(value) when is_binary(value), do: %__MODULE__{type: :text, text: value}

  def reference(type, ref, media_type \\ nil) when type in [:image_ref, :document_ref] do
    new!(%{"type" => Atom.to_string(type), "ref" => ref, "media_type" => media_type})
  end

  def tool_call(call_id, name, arguments),
    do: new!(%{type: "tool_call", call_id: call_id, name: name, value: arguments})

  def tool_result(call_id, name, result),
    do: new!(%{type: "tool_result", call_id: call_id, name: name, value: result})

  def new!(input) do
    case decode(input) do
      {:ok, content} -> content
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def decode(%__MODULE__{} = content), do: validate(content)

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, type} <- decode_type(Map.get(map, "type")) do
      validate(%__MODULE__{
        type: type,
        text: Map.get(map, "text"),
        ref: Map.get(map, "ref"),
        media_type: Map.get(map, "media_type"),
        name: Map.get(map, "name"),
        call_id: Map.get(map, "call_id"),
        value: Map.get(map, "value")
      })
    else
      {:ok, _other} -> error([], "content part must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def validate(%__MODULE__{type: :text, text: text} = content) when is_binary(text),
    do: {:ok, content}

  def validate(%__MODULE__{type: type, ref: ref} = content)
      when type in [:image_ref, :document_ref] and is_binary(ref) and ref != "" do
    if safe_ref?(ref),
      do: {:ok, content},
      else: error(["ref"], "must use https, artifact, or workspace reference syntax")
  end

  def validate(%__MODULE__{type: type, name: name, call_id: call_id, value: value} = content)
      when type in [:tool_call, :tool_result] and is_binary(name) and name != "" and
             is_binary(call_id) and call_id != "" do
    case JSONValue.normalize(value) do
      {:ok, _value} -> {:ok, content}
      {:error, issues} -> {:error, Enum.map(issues, &%{&1 | path: ["value"] ++ &1.path})}
    end
  end

  def validate(%__MODULE__{type: :text}), do: error(["text"], "must be a string")

  def validate(%__MODULE__{type: type}) when type in [:image_ref, :document_ref],
    do: error(["ref"], "is required")

  def validate(%__MODULE__{type: type}) when type in [:tool_call, :tool_result],
    do: error([], "tool content requires call_id, name, and a JSON-safe value")

  def validate(_other), do: error(["type"], "is not supported")

  def encode(%__MODULE__{} = content) do
    %{"$contract" => @wire_id, "type" => Atom.to_string(content.type)}
    |> put_if("text", content.text)
    |> put_if("ref", content.ref)
    |> put_if("media_type", content.media_type)
    |> put_if("name", content.name)
    |> put_if("call_id", content.call_id)
    |> put_if("value", content.value)
  end

  defp decode_type(value) do
    case Enum.find(@types, &(Atom.to_string(&1) == value)) do
      nil -> error(["type"], "is not supported")
      type -> {:ok, type}
    end
  end

  defp safe_ref?("https://" <> _), do: true
  defp safe_ref?("artifact:" <> _), do: true
  defp safe_ref?("workspace:" <> _), do: true
  defp safe_ref?(_), do: false
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, JSONValue.normalize!(value))
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
